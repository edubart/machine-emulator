-- A reproducible machine (iunrep = 0) gets HTIF console getchar enabled through the host API, which create() and
-- load() forbid ("TTY stdin is only supported in unreproducible machines"):
--   write_reg("htif_iconsole", 3)                   (machine::write_reg accepts the getchar bit)
--   write_memory(0, <whole 0x8000-byte shadow>)     (the "manual snapshot" path copies any iconsole)
--   set_runtime_config({console = {input_source = "from_buffer"}})
-- The fast interpreter (run) then answers the guest's getchar from the host console, while log_step/verify_step
-- and the uarch (the on-chain step) answer "no character": from the same root hash and for the same mcycle count
-- the paths reach different root hashes. store() accepts the poked machine and load() refuses the snapshot.
-- Property checked (what a fix restores): run() agrees with log_step()+verify_step() and run_uarch(), the host
-- byte never reaches the guest of a reproducible machine, and store() does not write a snapshot load() rejects
-- (the API may refuse the poke instead).
-- usage: lua5.4 getchar.lua <work-dir>     exit 0 = fixed, 1 = bug reproduced, 2 = harness problem
local cartesi = require("cartesi")
local WORK = assert(arg[1], "missing work directory")

local function hex(h) return cartesi.tohex(h):sub(1, 18) end

-- Guest (hand-encoded RV64, no toolchain needed):
--   lui s0,0x40008 ; li t0,1 ; slli t0,t0,56 ; sd t0,0(s0)   -> HTIF tohost: console (dev 1) getchar (cmd 0)
--   ld a0,8(s0)                                               -> a0 = fromhost (getchar answer: c + 1, 0 = none)
--   auipc t1,1 ; sd a0,-20(t1)                                -> keep the answer in RAM at 0x80001000
--   li t0,1 ; sd t0,0(s0) ; j .                               -> halt
local words = { 0x40008437, 0x00100293, 0x03829293, 0x00543023, 0x00843503, 0x00001317, 0xfea33623, 0x00100293,
    0x00543023, 0x0000006f }
local prog = {}
for i, w in ipairs(words) do prog[i] = string.pack("<I4", w) end
prog = table.concat(prog)
local RESULT = 0x80001000
local MCYCLES = 64 -- the guest halts at mcycle 9
local CONFIG = { ram = { length = 0x10000 } } -- reproducible; default iconsole = putchar only

-- Applies one way of enabling getchar; returns false (and prints) if the API refuses it
local function setup(m, how)
    m:write_memory(0x80000000, prog)
    local ok, err = pcall(function()
        if how == "write_reg" then
            m:write_reg("htif_iconsole", 3) -- getchar | putchar
        elseif how == "shadow" then
            local shadow = m:read_memory(0, 0x8000)
            local off = m:get_reg_address("htif_iconsole")
            m:write_memory(0, shadow:sub(1, off) .. string.pack("<I8", 3) .. shadow:sub(off + 9))
        elseif how == "from_buffer" then
            m:set_runtime_config({ console = { input_source = "from_buffer" } })
            m:write_reg("htif_iconsole", 3)
            m:write_console_input("Q")
        end
    end)
    if not ok then
        print("  " .. how .. ": refused by the API: " .. tostring(err))
        return false
    end
    assert(m:read_reg("iunrep") == 0)
    return true
end

local function answer(m) return string.unpack("<I8", m:read_memory(RESULT, 8)) end

local function run_fast(m)
    local br
    repeat
        br = m:run(MCYCLES)
    until br == cartesi.BREAK_REASON_HALTED or br == cartesi.BREAK_REASON_REACHED_TARGET_MCYCLE
    return { name = "run()", root = m:get_root_hash(), answer = answer(m) }
end

local function run_logged(m, tag)
    local before = m:get_root_hash()
    local log = WORK .. "/step-" .. tag .. ".log"
    os.remove(log)
    m:log_step(MCYCLES, log)
    local obtained = m:verify_step(before, log, MCYCLES)
    os.remove(log)
    assert(obtained == m:get_root_hash(), "verify_step result differs from the logging machine")
    return { name = "log_step()+verify_step()", root = obtained, answer = answer(m) }
end

local function run_uarch(m)
    while m:read_reg("iflags_H") == 0 and m:read_reg("mcycle") < MCYCLES do
        m:run_uarch(math.maxinteger)
        m:reset_uarch()
    end
    return { name = "run_uarch() per mcycle", root = m:get_root_hash(), answer = answer(m) }
end

local bug = false
local function compare(label, a, b)
    for _, r in ipairs({ a, b }) do
        print(string.format("    %-26s answer=0x%016x root=%s", r.name, r.answer, hex(r.root)))
    end
    if a.root ~= b.root then
        print("    -> " .. label .. ": DIVERGENCE (same initial state, same mcycle count, different root hash)")
        return false
    end
    print("    -> " .. label .. ": agree")
    return true
end

local function new_machine() return cartesi.machine(CONFIG) end

print("[0] control: reproducible machine, iconsole untouched")
do
    local a, b = new_machine(), new_machine()
    setup(a, "none")
    setup(b, "none")
    if not compare("run vs log_step", run_fast(a), run_logged(b, "0")) then
        print("ERROR: control diverged")
        os.exit(2)
    end
end

for _, how in ipairs({ "write_reg", "shadow", "from_buffer" }) do
    print("[" .. how .. "] getchar enabled on a reproducible machine through " .. how)
    local a, b, c = new_machine(), new_machine(), new_machine()
    if setup(a, how) and setup(b, how) and setup(c, how) then
        local fast = run_fast(a)
        if not compare("run vs log_step", fast, run_logged(b, how)) then bug = true end
        if not compare("run vs uarch", fast, run_uarch(c)) then bug = true end
        if how == "from_buffer" and (fast.answer & 0xff) == string.byte("Q") + 1 then
            print("    -> the guest of a reproducible machine read a host-supplied byte ('Q' + 1 = 0x52)")
            bug = true
        end
    end
end

print("[store/load] getchar bit set through the shadow write_memory path, then store() and load()")
do
    local m = new_machine()
    if setup(m, "shadow") then
        local dir = WORK .. "/stored"
        local sok, serr = pcall(m.store, m, dir)
        local lok, lerr = false, "not stored"
        if sok then lok, lerr = pcall(cartesi.machine, dir) end
        print("    store: " .. (sok and "ok" or tostring(serr)) .. "; load: " .. (lok and "ok" or tostring(lerr)))
        if sok and not lok then
            print("    -> store() wrote a snapshot that load() rejects")
            bug = true
        end
    end
end

if bug then
    print("BUG REPRODUCED: the host API enables HTIF getchar on a reproducible machine; run() diverges from log_step/uarch")
    os.exit(1)
end
print("OK: getchar cannot make run() diverge on a reproducible machine")
os.exit(0)
