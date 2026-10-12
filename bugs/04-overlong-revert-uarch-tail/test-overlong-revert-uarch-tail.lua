#!/usr/bin/env lua5.4
-- Regression test: revert_uarch_tail has no upper-bound length check.
-- Run (from repo root, after sourcing bugs/env/env.sh):
--   lua5.4 <path>/test-overlong-revert-uarch-tail.lua
-- A valid tail has at most 2^ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE entries (one per position of the
-- mcycle). We pass 2^20 + 2 entries to a machine stopped at an rx-rejected manual yield and expect every
-- entry point to reject it with an error. Buggy behaviour:
--   (a) collect_uarch_cycle_root_hashes(log2 > 0) aborts the process (assert in append_uarch_reset_root_hash)
--   (b) collect_uarch_cycle_root_hashes(log2 = 0) returns a period with more than 2^20 entries
--   (c) collect_uarch_cycle_bundle silently truncates the tail and returns a bundle
-- Prints "BUG REPRODUCED" and exits 1 on buggy behaviour, "OK" and exits 0 when fixed.
local cartesi = require("cartesi")

local function make_machine()
    local m = cartesi.machine({
        ram = {
            length = 8191 * 4096,
            backing_store = { data_filename = assert(os.getenv("CARTESI_TESTS_PATH")) .. "/htif_yield.bin" },
        },
    })
    -- htif_yield.bin issues manual yields; the one reached at mcycle 138 is rx-rejected
    while m:read_reg("mcycle") < 138 do
        local br = m:run(138)
        if br == cartesi.BREAK_REASON_YIELDED_MANUALLY and m:read_reg("mcycle") < 138 then
            m:write_reg("iflags_Y", 0)
        end
    end
    assert(m:read_reg("htif_tohost_reason") == cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED)
    return m
end

local P = 1 << cartesi.ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE
local function make_tail(m, n)
    local tail = {}
    local filler = string.rep("\1", 32)
    for i = 1, n - 2 do
        tail[i] = filler
    end
    tail[n - 1] = string.rep("\2", 32) -- halted state root hash
    tail[n] = m:read_revert_root_hash() -- reset state root hash == revert root hash
    return tail
end

if arg[1] == "child" then
    -- (a) runs in a child process because the buggy build aborts
    local m = make_machine()
    local ok, err = pcall(m.collect_uarch_cycle_root_hashes, m, m:read_reg("mcycle"), 1, make_tail(m, P + 2))
    os.exit(ok and 3 or 0) -- 0: rejected with error (fixed); 3: accepted
end

local bugs = {}

-- (a)
local lua = arg[-1] or "lua5.4"
local ok, how, code = os.execute(string.format("%q %q child 2>/dev/null", lua, arg[0]))
if not ok then
    bugs[#bugs + 1] = string.format("(a) collect_uarch_cycle_root_hashes(log2=1) child died (%s %s)", how, code)
end

local m = make_machine()
local tail = make_tail(m, P + 2)

-- (b)
local okb, res = pcall(m.collect_uarch_cycle_root_hashes, m, m:read_reg("mcycle"), 0, tail)
if okb then
    bugs[#bugs + 1] = string.format("(b) collect_uarch_cycle_root_hashes(log2=0) accepted it, returned %d entries (> %d)",
        #res.hashes, P)
end

-- (c)
local okc, bundle = pcall(m.collect_uarch_cycle_bundle, m, (P >> 1) - 1, 1, tail)
if okc then
    bugs[#bugs + 1] = string.format("(c) collect_uarch_cycle_bundle accepted it, returned %d entries", #bundle)
end

if #bugs > 0 then
    print("BUG REPRODUCED: " .. (P + 2) .. "-entry revert_uarch_tail was not rejected")
    for _, b in ipairs(bugs) do
        print("  " .. b)
    end
    os.exit(1, true)
end
print("OK")
os.exit(0, true)
