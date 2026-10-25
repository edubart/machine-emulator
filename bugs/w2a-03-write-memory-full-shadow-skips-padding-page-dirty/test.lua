-- Repro: write_memory(0, full 0x8000 shadow) does not mark page 0x7000 (tlb_padding_) dirty
local cartesi = require("cartesi")
local m = cartesi.machine({ ram = { length = 0x10000 } })
local before = m:get_root_hash()
local s = m:read_memory(0, 0x8000)
assert(s:byte(0x7001) == 0)
local s2 = s:sub(1, 0x7000) .. "\1" .. s:sub(0x7002)
m:write_memory(0, s2)
local back = m:read_memory(0, 0x8000)
local mem_changed = back ~= s and back:byte(0x7001) == 1
local after = m:get_root_hash()
local ok_verify, verify_res = pcall(function() return m:verify_hash_tree() end)
-- rebuild the hash tree from scratch
m:clear_hash_tree()
local recomputed = m:get_root_hash()
print("memory at 0x7000 changed:", mem_changed)
print("root before:     ", cartesi.tohex and cartesi.tohex(before) or #before)
print("root changed by write:", before ~= after)
print("verify_hash_tree:", ok_verify, verify_res)
print("root after clear_hash_tree differs from incremental root:", recomputed ~= after)
local bug = mem_changed and (after == before or recomputed ~= after or verify_res == false)
if bug then
  print("BUG: write_memory(0, full shadow) changed byte 0x7000 but root hash did not track it (incremental root ~= recomputed root)")
  os.exit(1)
end
print("OK")
os.exit(0)
