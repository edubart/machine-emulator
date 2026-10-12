-- Regression: a hash-tree update interrupted after page leaf hashes were written to a shared dense
-- hash tree (process killed between src/hash-tree.cpp:308 and :702) leaves a stored machine whose
-- every later load silently computes a stale root hash.
--
-- Run (from repo root, after sourcing bugs/env/env.sh):
--   lua5.4 interrupted-update-stale-root.lua
--
-- Deterministic: instead of killing a process, it crafts on disk exactly the state such a kill leaves
-- in a directory used with sharing "all": memory already modified, page still marked dirty in the
-- .dpt, page leaf hash in the .dht already updated, inner dense nodes not yet updated.
local cartesi = require("cartesi")
local tests_util = require("cartesi.tests.util")

local RAM_START, RAM_LENGTH, PAGE = 0x80000000, 1 << 20, 5
local paddr_page = RAM_START + PAGE * 4096
local dir = os.tmpname()
os.remove(dir)

local function cleanup() os.execute(string.format("rm -rf %q", dir)) end

-- 1. Hash a machine, modify one page, and store it (store() does not update the hash tree, so the stored
--    .dpt marks the page dirty and the .dht still holds the old hashes, as at the start of an update).
local m = cartesi.machine({ ram = { length = RAM_LENGTH } })
m:get_root_hash()
m:write_memory(paddr_page + 16, "interrupted hash-tree update")
m:store(dir, cartesi.SHARING_ALL)
-- Reference values, computed by the in-memory machine (never interrupted)
local leaf = m:get_node_hash(paddr_page, 12)
local expected = m:get_root_hash()
assert(expected == tests_util.calculate_emulator_hash(m), "reference root hash disagrees with memory")
m:destroy()

-- Control: the stored directory itself loads fine
do
    local c = cartesi.machine(dir, {}, cartesi.SHARING_NONE)
    local h = c:get_root_hash()
    c:destroy()
    if h ~= expected then
        cleanup()
        error("control failed: unpatched stored machine has wrong root hash")
    end
end

-- 2. Emulate a kill right after return_updated_dirty_pages() wrote the page leaf into the shared .dht
--    (hash-tree.cpp:308) and before update_dense_trees()/dpt.clean() ran.
local dht = string.format("%s/%016x-%x.dht", dir, RAM_START, RAM_LENGTH)
local f = assert(io.open(dht, "r+b"))
local size = f:seek("end")
local level_count = math.floor(math.log(size // 32, 2) + 0.5)
local leaf_index = (1 << (level_count - 1)) + PAGE -- heap layout, see dense-hash-tree.hpp to_index()
f:seek("set", leaf_index * 32)
f:write(leaf)
f:close()

-- 3. Load the directory and compute its root hash
local l = cartesi.machine(dir, {}, cartesi.SHARING_NONE)
local got = l:get_root_hash()
local recomputed = tests_util.calculate_emulator_hash(l)
local verified = l:verify_hash_tree()
l:destroy()
cleanup()

assert(recomputed == expected, "memory contents of loaded machine differ")
if got ~= expected then
    print("expected root: " .. cartesi.tohex(expected))
    print("got root:      " .. cartesi.tohex(got) .. " (verify_hash_tree() = " .. tostring(verified) .. ")")
    print("BUG REPRODUCED")
    os.exit(1, true)
end
print("OK")
