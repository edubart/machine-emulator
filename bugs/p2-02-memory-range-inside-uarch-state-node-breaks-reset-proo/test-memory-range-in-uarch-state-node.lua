-- Bug p2-02: config validation accepts memory ranges inside the 2^22-byte
-- uarch-state hash node [0x400000, 0x800000), in the gap 0x401000-0x5fffff
-- between the uarch shadow and the uarch RAM. Once such a range holds
-- non-zero data, log_reset_uarch can never produce a proof, and
-- collect_uarch_cycle_root_hashes commits to the post-reset root that keeps
-- the drive data (which replay / on-chain reset would wipe).
--
-- Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo/test-memory-range-in-uarch-state-node.lua
-- Exits 1 while the bug is present, 0 once such configs are rejected.
local cartesi = require("cartesi")
local bug = false
for _, st in ipairs({ 0x401000, 0x500000, 0x5ff000 }) do
    local cfg = { ram = { length = 1 << 20 }, flash_drive = { { start = st, length = 0x1000 } } }
    local ok, m = pcall(cartesi.machine, cfg)
    if not ok then
        print(string.format("start 0x%x rejected by config validation: %s (fixed)", st, m))
    else
        m:write_memory(st, "app data")
        -- commitment via collect_uarch_cycle_root_hashes (one mcycle, no bundling)
        local r = m:collect_uarch_cycle_root_hashes(1, 0, { m:get_root_hash(), m:read_revert_root_hash() })
        -- reference path: run uarch to halt, then try to prove the reset
        local m2 = cartesi.machine(cfg)
        m2:write_memory(st, "app data")
        m2:run_uarch(cartesi.UARCH_CYCLE_MAX)
        assert(m2:read_reg("uarch_halt") ~= 0)
        local before = m2:get_root_hash()
        local okl, log = pcall(m2.log_reset_uarch, m2)
        if not okl then
            print(
                string.format(
                    "BUG: flash drive at 0x%x (inside uarch-state node 0x400000..0x800000) accepted; log_reset_uarch fails: %s",
                    st,
                    tostring(log)
                )
            )
            bug = true
        else
            local okv, verr = pcall(m2.verify_reset_uarch, m2, before, log)
            print(string.format("start 0x%x: log_reset_uarch ok, verify_reset_uarch: %s %s", st, okv, verr))
        end
        m2:reset_uarch()
        if r.hashes[#r.hashes] == m2:get_root_hash() then
            print("  collect_uarch_cycle_root_hashes last leaf == reset_uarch root (unprovable root committed)")
        end
    end
end
-- control: same placement but the drive stays all zero -> reset proof works
do
    local m = cartesi.machine({ ram = { length = 1 << 20 }, flash_drive = { { start = 0x500000, length = 0x1000 } } })
    m:run_uarch(cartesi.UARCH_CYCLE_MAX)
    local before = m:get_root_hash()
    local log = m:log_reset_uarch()
    assert(m:verify_reset_uarch(before, log) == m:get_root_hash())
    print("control: all-zero drive at 0x500000, log_reset_uarch + verify_reset_uarch ok")
end
if bug then
    os.exit(1)
end
print("OK")
