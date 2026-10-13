-- cm_collect_uarch_cycle_root_hashes() replaces the uarch reset at the end of each mcycle with a "direct reset" that
-- restores only the uarch RAM words written during that mcycle, and its entry check only tests uarch_cycle == 0.
-- If the uarch state is not pristine when collection starts (here: one word of uarch RAM, beyond the uarch image,
-- written with cm_write_memory), the collector's post-reset state keeps that word, while the canonical transition
-- (cm_run_uarch + cm_reset_uarch, and cm_log_reset_uarch, which the on-chain verifier replays) restores the pristine
-- uarch. The collected post-reset root hash then disagrees with the transition a verifier checks.
-- Fixed behavior: the collector either performs the canonical reset (same root hash) or refuses to start.
-- Usage: lua5.4 repro.lua [control]
--   control: pristine uarch; the collector must agree with the canonical reset (validates the test)
local cartesi = require("cartesi")
local control = arg[1] == "control"
local UWORD = 0x7f0000 -- uarch RAM spans 0x600000-0x7fffff; the built-in uarch image is much smaller

local function make()
    -- RAM is all zeros: the main CPU just takes illegal-instruction traps, which is enough for one mcycle
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    if not control then
        m:write_memory(UWORD, string.pack("<I8", 0xdeadbeef))
    end
    return m
end

-- Canonical transition for one mcycle: run the uarch to halt, then reset it (also with the logged reset)
local canonical, logged
do
    local b <close> = make()
    b:run_uarch()
    b:reset_uarch()
    canonical = b:get_root_hash()
    local c <close> = make()
    c:run_uarch()
    c:log_reset_uarch()
    logged = c:get_root_hash()
end
assert(canonical == logged, "test error: cm_reset_uarch and cm_log_reset_uarch disagree")

-- Collector for the same mcycle
local a <close> = make()
local tail = { a:read_revert_root_hash(), a:read_revert_root_hash() } -- required by the API, unused here
local ok, res = pcall(a.collect_uarch_cycle_root_hashes, a, 1, 0, tail)
if not ok then
    if control then
        error("test error: collection failed on a pristine uarch: " .. tostring(res))
    end
    print("collector refuses a non-pristine uarch: " .. tostring(res))
    print("OK: cm_collect_uarch_cycle_root_hashes does not produce hashes for a non-pristine uarch")
    os.exit(0)
end
assert(#res.mcycle_hash_offsets == 2 and #res.hashes > 0, "test error: expected exactly one collected mcycle")
local collected = res.hashes[#res.hashes] -- state root hash right after the (only) uarch reset
local after = a:get_root_hash()
print("uarch RAM word at start    : " .. (control and "pristine" or "0xdeadbeef (written with cm_write_memory)"))
print("collector post-reset hash  : " .. cartesi.tohex(collected))
print("machine root after collect : " .. cartesi.tohex(after))
print("run_uarch + reset_uarch    : " .. cartesi.tohex(canonical))
print("run_uarch + log_reset_uarch: " .. cartesi.tohex(logged))
print(string.format("uarch RAM word after reset : 0x%x (canonical reset restores 0)",
    string.unpack("<I8", a:read_memory(UWORD, 8))))
if collected ~= canonical or after ~= canonical then
    print("BUG REPRODUCED: the collector's uarch reset diverges from the canonical uarch reset (stale uarch RAM kept)")
    os.exit(1)
end
print("OK: the collector's post-reset state matches the canonical uarch reset")
os.exit(0)
