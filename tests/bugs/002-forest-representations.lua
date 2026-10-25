-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Exits successfully when the bug is reproduced.
local c = require('cartesi')
local h = require('cartesi.hash-tree')
local fs = require('cartesi.filesystem')
local dir = fs.temp_pathname()
fs.create_directory(dir)
local cleanup <close> = setmetatable({}, { __close = function()
    for _, name in ipairs(fs.list_directory(dir)) do fs.remove_file(dir .. '/' .. name) end
    fs.remove_directory(dir)
end })
local leaves = {}
for i = 1, 4 do leaves[i] = c.keccak256('leaf' .. i) end
local coarse = h.frontier_forest(2, 'keccak256')
h.frontier_forest_append(coarse, {
    c.keccak256(leaves[1], leaves[2]), c.keccak256(leaves[3], leaves[4]),
}, nil, nil, 1)
h.frontier_forest_store(coarse, dir, dir .. '/coarse.json')
local fine = h.frontier_forest(2, 'keccak256')
h.frontier_forest_append(fine, leaves)
assert(h.frontier_forest_get_root_hash(coarse) == h.frontier_forest_get_root_hash(fine))
assert(h.frontier_forest_get_node_hash(fine, 0, 0) == leaves[1])
h.frontier_forest_store(fine, dir, dir .. '/fine.json')
local loaded = h.frontier_forest_load(dir, dir .. '/fine.json')
assert(h.frontier_forest_get_root_hash(loaded) == h.frontier_forest_get_root_hash(fine))
local leaf, err = h.frontier_forest_get_node_hash(loaded, 0, 0)
print('expected leaf:', c.tohex(leaves[1]))
print('loaded leaf:', leaf and c.tohex(leaf), err)
assert(leaf == nil and err == 'the node is below an opaque hash')
assert(h.frontier_forest_get_node_hash(fine, 0, 0) == leaves[1])
print('BUG 002 reproduced: store/load discarded available descendants')
