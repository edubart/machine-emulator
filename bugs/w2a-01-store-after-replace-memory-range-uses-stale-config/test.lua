-- BUG repro: machine::store() after replace_memory_range() uses stale m_c backing-store config
local cartesi = require("cartesi")
-- Work directory: $TMPW if set, otherwise a fresh mktemp -d directory (removed at the end)
local W = os.getenv("TMPW")
if not W then
  local p = assert(io.popen("mktemp -d"))
  W = p:read("l") .. "/run"
  p:close()
end
os.execute("rm -rf " .. W .. " && mkdir -p " .. W)
local A, B = W .. "/A.bin", W .. "/B.bin"
local f = io.open(A, "wb") f:write(string.rep("A", 0x2000)) f:close()
f = io.open(B, "wb") f:write(string.rep("B", 0x2000)) f:close()
local FS = 0x90000000
local m = cartesi.machine({ ram = { length = 0x10000 },
  flash_drive = { { start = FS, length = 0x2000, backing_store = { data_filename = A } } } })
m:store(W .. "/D", cartesi.SHARING_ALL)
m:destroy()
-- Load private copy of D (flash backing store is D's private file containing "AAAA...")
m = cartesi.new():load(W .. "/D", nil, cartesi.SHARING_NONE)
-- Swap the flash for a shared backing store B
m:replace_memory_range({ start = FS, length = 0x2000, backing_store = { data_filename = B, shared = true } })
m:write_memory(FS, "modified")
local live = m:read_memory(FS, 12)
local root = m:get_root_hash()
local cfg_fn = m:get_initial_config().flash_drive[1].backing_store.data_filename
local cfg_shared = m:get_initial_config().flash_drive[1].backing_store.shared
print("live flash content:", live)
print("initial config after replace: data_filename=" .. tostring(cfg_fn) .. " shared=" .. tostring(cfg_shared))
m:store(W .. "/E", cartesi.SHARING_CONFIG)
local e = cartesi.new():load(W .. "/E", { hash_tree = { } })
local stored = e:read_memory(FS, 12)
local eroot = e:get_root_hash()
print("stored (E) flash content:", stored)
print("E root == machine root at store time:", eroot == root)
-- Expected semantics of SHARING_CONFIG: the replacement range is shared, so its live content
-- ("modified" + "BBBB") must be written to E; root hashes must match.
local bug = false
if stored ~= live then
  print("BUG: store(SHARING_CONFIG) after replace_memory_range wrote the pre-replacement image (" ..
    stored .. ") instead of the live/replacement content (" .. live .. ")")
  bug = true
end
if eroot ~= root then
  print("BUG: stored machine root hash differs from machine root hash at store time")
  bug = true
end
if cfg_fn ~= B then
  print("BUG: get_initial_config() still reports the pre-replacement backing store " .. tostring(cfg_fn))
  bug = true
end
os.execute("rm -rf " .. W)
os.exit(bug and 1 or 0)
