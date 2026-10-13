-- iunrep has two sources of truth: the configured value (machine::is_unreproducible(), used by every guard and by
-- the interpreter) and the shadow register (committed by the root hash). The shadow one stays writable.
--
-- Usage: lua5.4 iunrep.lua <work-dir>
--
-- machine::is_unreproducible() reads m_c.processor.registers.iunrep (fixed at construction). The shadow iunrep can
-- still be changed by write_reg("iunrep", ...) (src/machine.cpp, unlike the read-only mvendorid/marchid/mimpid) and by
-- the full-shadow write_memory "manual snapshot" path. validate_processor_shadow (shadow == config) runs only at
-- construction and load, and store() checks only the config. Effects checked here:
--   store-load/write_reg, store-load/snapshot: a reproducible machine whose shadow iunrep became 1 is accepted by
--       store(), but the stored directory can never be loaded ("iunrep mismatch between shadow state and config").
--   same-root/write_reg, same-root/snapshot: an unreproducible machine whose shadow iunrep became 0 has the same root
--       hash as the genuinely reproducible machine, yet run() performs a different (host-time dependent) transition.
--   control: store/load of an untouched machine works, and the two configurations have different root hashes.
-- Property checked (what a fix restores): the committed iunrep cannot diverge from the one the machine obeys:
-- a machine accepted by store() can be loaded back, and equal root hashes imply the same run() transition (either by
-- refusing the write, or by rejecting the inconsistent state in store()).
--
-- Exit codes: 0 = fixed, 10 = bug reproduced, anything else = test error.
local cartesi = require("cartesi")

local EXIT_OK, EXIT_BUG, EXIT_SETUP = 0, 10, 2
local RAM = 0x80000000
local SHADOW_START, SHADOW_LENGTH = 0, 0x8000
local wd = assert(arg[1], "usage: iunrep.lua <work-dir>")

-- Guest: wfi x3, then halt via HTIF. Reproducible: wfi is a NOP. Unreproducible: the first wfi waits (host time) and
-- fast-forwards mcycle up to the timer deadline mtimecmp*8192.
local function prog()
    local words = {
        0x10500073, -- wfi
        0x10500073, -- wfi
        0x10500073, -- wfi
        0x400082b7, -- lui  t0, 0x40008      (HTIF)
        0x00100713, -- addi a4, zero, 1
        0x00e2b023, -- sd   a4, 0(t0)        (tohost = 1: halt, exit code 0)
        0x0000006f, -- j    .
    }
    local t = {}
    for i, w in ipairs(words) do
        t[i] = string.pack("<I4", w)
    end
    return table.concat(t)
end

local function new_machine(iunrep)
    local m = cartesi.machine({ ram = { length = 1 << 16 }, processor = { registers = { iunrep = iunrep } } },
        { console = { output_destination = "to_null" } })
    m:write_memory(RAM, prog())
    m:write_reg("clint_mtimecmp", 20) -- timer deadline at mcycle 20*8192 = 163840
    return m
end

local function hex(h)
    return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 16)
end

local function config_iunrep(m)
    return m:get_initial_config().processor.registers.iunrep
end

-- Ways to change the shadow iunrep of m to value (other is a machine whose shadow has that value)
local function via_write_reg(m, value)
    return pcall(m.write_reg, m, "iunrep", value)
end
local function via_snapshot(m, value)
    local other = new_machine(value)
    return pcall(m.write_memory, m, SHADOW_START, other:read_memory(SHADOW_START, SHADOW_LENGTH))
end

local n = 0
local function store_load(m)
    n = n + 1
    local dir = string.format("%s/stored-%d", wd, n)
    local ok_s, err_s = pcall(m.store, m, dir)
    if not ok_s then return false, "store: " .. err_s end
    local ok_l, err_l = pcall(cartesi.machine, dir, { console = { output_destination = "to_null" } })
    if not ok_l then return true, "load: " .. err_l end
    return true, "ok"
end

-- control
do
    print("== control")
    local stored, res = store_load(new_machine(0))
    print("  store/load of an untouched machine: " .. (stored and res or "store failed: " .. res))
    local h0, h1 = new_machine(0):get_root_hash(), new_machine(1):get_root_hash()
    print(string.format("  root iunrep=0: %s, root iunrep=1: %s", hex(h0), hex(h1)))
    if res ~= "ok" or h0 == h1 then os.exit(EXIT_SETUP) end
end

local bugs = 0
local routes = { { "write_reg", via_write_reg }, { "snapshot", via_snapshot } }

for _, route in ipairs(routes) do
    local name, change = route[1], route[2]
    print(string.format("== store-load/%s: reproducible machine, shadow iunrep set to 1", name))
    local m = new_machine(0)
    local ok, err = change(m, 1)
    if not ok then
        print("  change refused: " .. err)
    else
        print(string.format("  shadow iunrep=%d, configured iunrep=%d", m:read_reg("iunrep"), config_iunrep(m)))
        local stored, res = store_load(m)
        print("  " .. res)
        if stored and res ~= "ok" then
            print("  store() accepted a machine whose stored directory cannot be loaded")
            bugs = bugs + 1
        end
    end
end

for _, route in ipairs(routes) do
    local name, change = route[1], route[2]
    print(string.format("== same-root/%s: unreproducible machine, shadow iunrep set to 0", name))
    local r, u = new_machine(0), new_machine(1)
    local ok, err = change(u, 0)
    if not ok then
        print("  change refused: " .. err)
    else
        local hr, hu = r:get_root_hash(), u:get_root_hash()
        print(string.format("  root reproducible=%s root unreproducible=%s (%s)", hex(hr), hex(hu),
            hr == hu and "IDENTICAL" or "different"))
        r:run(1000000)
        u:run(1000000)
        local hr1, hu1 = r:get_root_hash(), u:get_root_hash()
        print(string.format("  after run(1e6): reproducible mcycle=%d root=%s ; unreproducible mcycle=%d root=%s",
            r:read_reg("mcycle"), hex(hr1), u:read_reg("mcycle"), hex(hu1)))
        if hr == hu and hr1 ~= hu1 then
            print("  same root hash, different run() transition")
            bugs = bugs + 1
        end
    end
end

print(string.format("== %d of 4 case(s) reproduced", bugs))
os.exit(bugs > 0 and EXIT_BUG or EXIT_OK)
