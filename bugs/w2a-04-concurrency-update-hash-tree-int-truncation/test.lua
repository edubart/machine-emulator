-- PoC: runtime concurrency.update_hash_tree values such as 0xffffffff or UINT64_MAX (-1)
-- are narrowed to a negative int in hash_tree, so every hash-tree update throws vector::reserve.
-- Exits 1 and prints BUG: while the defect is present, 0 once fixed.
local cartesi = require("cartesi")
local bad = false
local function try(label, v)
  local ok, err = pcall(function()
    local m = cartesi.machine({ ram = { length = 0x100000 } }, { concurrency = { update_hash_tree = v } })
    local h = m:get_root_hash()
    m:destroy()
    return h
  end)
  if ok then
    print(string.format("OK  : update_hash_tree=%s -> get_root_hash succeeded", label))
  else
    print(string.format("BUG: update_hash_tree=%s accepted at machine creation but get_root_hash fails: %s", label, tostring(err)))
    bad = true
  end
end
try("0 (default)", 0)
try("4", 4)
try("0x7fffffff", 0x7fffffff)
try("0x80000000", 0x80000000)
try("0xffffffff", 0xffffffff)
try("-1 (UINT64_MAX)", -1)
os.exit(bad and 1 or 0)
