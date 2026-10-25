-- Proof: after a failed store_expansion (transient write failure), a later
-- frontier_forest_store never persists the in-memory expansion, so the reloaded
-- forest is opaque below the expanded leaf even though the in-memory forest is not.
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")
local hash_tree = require("cartesi.hash-tree")

local base = os.getenv("WORKDIR") or os.getenv("TMPDIR") or "/tmp"
local dir = base .. "/store-" .. tostring(os.time()) .. "-" .. tostring(math.random(1 << 30))
os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "/forests'")
local forests, frontier_path = dir .. "/forests", dir .. "/frontier.json"

local function leaf(i) return cartesi.keccak256(string.pack("<i8", i)) end

-- 4 bundles of 4 leaves each (bundle height 2), outer forest height 4.
local bundles = {}
local outer = hash_tree.frontier_forest(4, "keccak256")
for b = 0, 3 do
    local bundle = hash_tree.frontier_forest(2, "keccak256")
    for j = 0, 3 do hash_tree.frontier_forest_push_back(bundle, leaf(4 * b + j)) end
    bundles[b] = bundle
    hash_tree.frontier_forest_push_back(outer, hash_tree.frontier_forest_get_root_hash(bundle), 2)
end

-- Snapshot 1: trees become durable.
hash_tree.frontier_forest_store(outer, forests, frontier_path)
assert(hash_tree.frontier_forest_get_node_hash(outer, 4, 0) == nil, "leaf should be opaque before expansion")

-- Inject one transient failure while the expansion is written.
local real_sync_file = fs.sync_file
local failed = false
fs.sync_file = function(...)
    if not failed then
        failed = true
        error("injected transient I/O error")
    end
    return real_sync_file(...)
end
local ok, err = pcall(hash_tree.frontier_forest_expand_leaf, outer, 4, bundles[1])
fs.sync_file = real_sync_file
print("expand_leaf with injected failure:", ok, err)
assert(not ok and failed, "failure was not injected")

-- In memory the expansion took effect.
local mem_hash = hash_tree.frontier_forest_get_node_hash(outer, 5, 0)
print("in-memory node hash at (5,0):", mem_hash and cartesi.tohex(mem_hash))
assert(mem_hash == leaf(5), "in-memory expansion missing")

-- Snapshot 2 succeeds; it should persist the in-memory expansion.
hash_tree.frontier_forest_store(outer, forests, frontier_path)

local bundle_file = forests .. "/" .. cartesi.tohex(hash_tree.frontier_forest_get_root_hash(bundles[1])) .. ".json"
print("bundle tree file exists after snapshot 2:", fs.exists(bundle_file))

-- "Restart": reload from disk.
local reloaded = hash_tree.frontier_forest_load(forests, frontier_path)
local disk_hash, disk_err = hash_tree.frontier_forest_get_node_hash(reloaded, 5, 0)
print("reloaded node hash at (5,0):", disk_hash and cartesi.tohex(disk_hash), disk_err)

-- Control: a fresh store of the same in-memory forest into a new directory persists it.
local dir2 = dir .. "-control"
os.execute("rm -rf '" .. dir2 .. "' && mkdir -p '" .. dir2 .. "/forests'")
local copy = hash_tree.frontier_forest(4, "keccak256")
for b = 0, 3 do
    hash_tree.frontier_forest_push_back(copy, hash_tree.frontier_forest_get_root_hash(bundles[b]), 2)
end
hash_tree.frontier_forest_store(copy, dir2 .. "/forests", dir2 .. "/frontier.json")
hash_tree.frontier_forest_expand_leaf(copy, 4, bundles[1])
hash_tree.frontier_forest_store(copy, dir2 .. "/forests", dir2 .. "/frontier.json")
local control = hash_tree.frontier_forest_load(dir2 .. "/forests", dir2 .. "/frontier.json")
local control_hash = hash_tree.frontier_forest_get_node_hash(control, 5, 0)
print("control (no failure) reloaded node hash at (5,0):", control_hash and cartesi.tohex(control_hash))
assert(control_hash == leaf(5), "control failed")

os.execute("rm -rf '" .. dir .. "' '" .. dir2 .. "'")
if disk_hash ~= mem_hash then
    print("BUG: frontier_forest_store after a failed expansion store did not persist the in-memory expansion; "
        .. "reloaded forest is opaque below the expanded leaf (" .. tostring(disk_err) .. ")")
    os.exit(1)
end
print("OK: expansion persisted by later store")
os.exit(0)
