-- Child: stores a forest and SIGKILLs itself while write_file holds a temporary file
-- (after the write, at the fsync before rename), simulating a crash/kill mid-store.
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")
local hash_tree = require("cartesi.hash-tree")
local dir, frontier_path, mode, seed = arg[1], arg[2], arg[3], tonumber(arg[4])
local forest = hash_tree.frontier_forest(10, "keccak256")
local hashes = {}
for i = 1, 1 << 10 do
    hashes[i] = cartesi.keccak256(string.pack("<i8i8", seed, i))
end
hash_tree.frontier_forest_append(forest, hashes)
if mode == "kill" then
    local orig = fs.sync_file
    fs.sync_file = function(f)
        orig(f)
        local stat = io.open("/proc/self/stat"):read("l")
        local pid = stat:match("^(%d+)")
        io.stdout:flush()
        os.execute("kill -KILL " .. pid)
        while true do end
    end
end
hash_tree.frontier_forest_store(forest, dir, frontier_path)
if mode == "load" then
    local f = hash_tree.frontier_forest_load(dir, frontier_path)
    assert(hash_tree.frontier_forest_get_root_hash(f) == hash_tree.frontier_forest_get_root_hash(forest))
end
