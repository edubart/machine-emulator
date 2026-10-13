-- A machine stored in the middle of an advance-state input (right after send_cmio_response) is loaded by the CLI
-- and inspected with --print-uarch-cycle-root-hashes. The guest rejects the input. Every hash the CLI prints must
-- equal the canonical collect_uarch_cycle_root_hashes() sequence computed with the real revert uarch tail (what
-- --uarch-cycle-computation-hash commits to). Omitting the post-rejection group (which cannot be derived without
-- the tail) is acceptable; printing different hashes is not.
-- usage: lua5.4 compare.lua <guest.bin> <work-dir> <cartesi-machine.lua>
-- exit 0 = fixed, 1 = bug reproduced, 2 = harness problem
local cartesi = require("cartesi")
local bin, W, CM = assert(arg[1]), assert(arg[2]), assert(arg[3])
local LUA = os.getenv("LUA") or "lua5.4"
local function short(h) return h and h:sub(1, 18) or "-" end

local m <close> = cartesi.machine({ ram = { length = 0x10000, backing_store = { data_filename = bin } } })
assert(m:run(1000) == cartesi.BREAK_REASON_YIELDED_MANUALLY, "guest did not wait for an input")
-- the real revert uarch tail: one uarch period of the machine that waits for the input
local tail = m:collect_uarch_cycle_root_hashes(m:read_reg("mcycle"), 0).hashes
local revert = m:get_root_hash()
assert(tail[#tail] == revert)
m:send_cmio_response(cartesi.HTIF_YIELD_REASON_ADVANCE_STATE, "input", revert)
local start = m:read_reg("mcycle")
m:store(W .. "/mid")
local canon = m:collect_uarch_cycle_root_hashes(start + 1000, 0, tail)
assert(canon.break_reason == cartesi.BREAK_REASON_YIELDED_MANUALLY, "guest did not reject the input")
local canon_hex = {}
for i, h in ipairs(canon.hashes) do canon_hex[i] = cartesi.tohex(h) end
print(string.format("revert uarch tail: %d entries; canonical collection: %d entries over %d mcycles", #tail,
    #canon.hashes, #canon.mcycle_hash_offsets - 1))

-- the CLI on the stored machine
local cmd = string.format("'%s' '%s' --load='%s/mid' --print-uarch-cycle-root-hashes=1000,start:%d 2>&1", LUA, CM,
    W, start)
local p = assert(io.popen(cmd))
local out = p:read("a")
local ok = p:close()
if not ok then
    print(out)
    print("ERROR: cartesi-machine failed")
    os.exit(2)
end
-- lines "<mcycle>[,<uarch cycle>]: 0x<hash>"; the first one is the window-start hash, then one per canonical entry
local printed, labels = {}, {}
for label, h in out:gmatch("(%d+[,%d]*): (0x%x+)") do
    if #h == 66 then
        labels[#labels + 1] = label
        printed[#printed + 1] = h
    end
end
if #printed < 2 or printed[2] ~= canon_hex[1] then
    print(out:sub(1, 2000))
    print("ERROR: unexpected CLI output (the first printed uarch-cycle hash is not the canonical first entry)")
    os.exit(2)
end
print(string.format("CLI printed %d per-uarch-cycle entries (canonical %d)", #printed - 1, #canon.hashes))
local first_bad
for i = 1, #printed - 1 do
    if printed[i + 1] ~= canon_hex[i] then
        first_bad = i
        break
    end
end
if first_bad then
    local off = canon.mcycle_hash_offsets
    print(string.format("first mismatch at entry %d (the post-rejection group starts at entry %d):", first_bad,
        off[#off - 1]))
    for i = first_bad, math.min(first_bad + 2, math.max(#printed - 1, #canon_hex)) do
        print(string.format("  entry %d: CLI %-6s %s | canonical %s", i, tostring(labels[i + 1]),
            short(printed[i + 1]), short(canon_hex[i])))
    end
    print("  revert root hash: " .. short(cartesi.tohex(revert)))
    print("BUG REPRODUCED: --print-uarch-cycle-root-hashes prints a fabricated uarch group after an rx-rejected yield")
    os.exit(1)
end
print("OK: every printed uarch-cycle root hash equals the canonical entry at the same position")
os.exit(0)
