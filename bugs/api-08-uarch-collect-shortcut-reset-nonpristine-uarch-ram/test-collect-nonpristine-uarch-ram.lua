-- Usage (repo root): eval $(make -s env); lua5.4 bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua
-- Exit 1 = bug present, 0 = fixed, 2 = unexpected control failure.
--
-- collect_uarch_cycle_root_hashes / collect_uarch_cycle_bundle reset uarch RAM with a shortcut
-- that restores only the words the uarch wrote during the mcycle. When the machine's uarch RAM
-- differs from the library's built-in pristine image in words the uarch never writes, the
-- collected reset leaves (and all later leaves) disagree with reset_uarch / verify_reset_uarch.
local cartesi = require("cartesi")
-- scratch directory: first argument, or the directory holding this script
local dir = arg[1] or (arg[0]:match("^(.*)/[^/]*$") or ".")
local ram_len = 4096
local MCYCLES = 3
local h = function(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 16) end

local function reference(cfg)
    -- reference: run uarch to halt, then full reset_uarch, verified with verify_reset_uarch
    local m = cartesi.machine(cfg)
    local out = {}
    for _ = 1, MCYCLES do
        m:run_uarch(cartesi.UARCH_CYCLE_MAX)
        local halt = m:get_root_hash()
        local log = m:log_reset_uarch()
        local reset = cartesi.machine:verify_reset_uarch(halt, log)
        assert(reset == m:get_root_hash())
        out[#out + 1] = { halt = halt, reset = reset }
    end
    return out
end

local function collected(cfg)
    local m = cartesi.machine(cfg)
    local tail = { string.rep("\0", 32), string.rep("\0", 32) }
    local r = m:collect_uarch_cycle_root_hashes(MCYCLES, 0, tail)
    local out = {}
    local offs = r.mcycle_hash_offsets
    for k = 1, MCYCLES do
        local reset_i = offs[k + 1] - 1 -- offsets are 1-based start indices; last entry of mcycle k is the reset leaf
        out[k] = { halt = r.hashes[reset_i - 1], reset = r.hashes[reset_i] }
    end
    -- collect_uarch_cycle_bundle for the first mcycle (bundle 0 of log2 count = 0 -> one hash per uarch cycle)
    local m2 = cartesi.machine(cfg)
    local b = m2:collect_uarch_cycle_bundle(0, 0, tail)
    return out, m:get_root_hash(), b, m2:get_root_hash()
end

local function check(name, cfg)
    local ref = reference(cfg)
    local col, final_root, _, bundle_root = collected(cfg)
    local ok = true
    for k = 1, MCYCLES do
        local hm, rm = col[k].halt == ref[k].halt, col[k].reset == ref[k].reset
        print(string.format("[%s] mcycle %d: halt leaf %s (%s vs %s), reset leaf %s (%s vs verify_reset_uarch %s)", name, k,
            hm and "ok" or "MISMATCH", h(col[k].halt), h(ref[k].halt), rm and "ok" or "MISMATCH", h(col[k].reset),
            h(ref[k].reset)))
        ok = ok and hm and rm
    end
    local fm = final_root == ref[MCYCLES].reset
    print(string.format("[%s] machine root after collect == root after reference: %s", name, tostring(fm)))
    local bm = bundle_root == ref[1].reset
    print(string.format("[%s] machine root after collect_uarch_cycle_bundle == reference reset of mcycle 1: %s", name,
        tostring(bm)))
    return ok and fm and bm
end

-- control: built-in uarch RAM
local base_ok = check("built-in uarch ram", { ram = { length = ram_len } })
if not base_ok then
    print("UNEXPECTED: control with built-in uarch RAM already mismatches")
    os.exit(2)
end

-- uarch RAM image identical to the built-in one except for its last page (never touched by uarch)
local m0 = cartesi.machine({ ram = { length = ram_len } })
local uram = m0:read_memory(cartesi.UARCH_RAM_START_ADDRESS, cartesi.UARCH_RAM_LENGTH)
local img = uram:sub(1, #uram - 4096) .. string.rep("\xaa", 4096)
local fname = dir .. "/uram-nonpristine.bin"
local f = assert(io.open(fname, "wb"))
f:write(img)
f:close()
local cfg = { ram = { length = ram_len }, uarch = { ram = { backing_store = { data_filename = fname } } } }
local bug_ok = check("custom uarch ram", cfg)
os.remove(fname)
if not bug_ok then
    print("BUG: collect_uarch_cycle_root_hashes/collect_uarch_cycle_bundle reset leaves differ from " ..
        "reset_uarch/verify_reset_uarch when uarch RAM is not the built-in pristine image")
    os.exit(1)
end
print("OK: collected leaves match reset_uarch/verify_reset_uarch")
os.exit(0)
