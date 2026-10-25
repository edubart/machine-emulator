-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Exits successfully when nesting drops access to lazy descendants.
local c = require('cartesi')
local h = require('cartesi.hash-tree')
local fs = require('cartesi.filesystem')
local base = fs.temp_pathname()
fs.create_directory(base)
local source_dir, dest_dir = base .. '/source', base .. '/dest'
fs.create_directory(source_dir)
fs.create_directory(dest_dir)
local cleanup <close> = setmetatable({}, { __close = function()
    for _, dir in ipairs({ source_dir, dest_dir }) do
        for _, name in ipairs(fs.list_directory(dir)) do fs.remove_file(dir .. '/' .. name) end
        fs.remove_directory(dir)
    end
    fs.remove_directory(base)
end })
local leaves = {}
for i = 1, 4 do leaves[i] = c.keccak256('composition leaf ' .. i) end
local source = h.frontier_forest(2, 'keccak256')
for j = 0, 1 do
    local bundle = h.frontier_forest(1, 'keccak256')
    h.frontier_forest_append(bundle, leaves, 2 * j + 1, 2 * j + 3)
    h.frontier_forest_push_back(source, bundle)
end
h.frontier_forest_store(source, source_dir, source_dir .. '/frontier.json')
local cold = h.frontier_forest_load(source_dir, source_dir .. '/frontier.json')
local dest = h.frontier_forest(3, 'keccak256')
h.frontier_forest_pad_back(dest, cold)
local leaf, err = h.frontier_forest_get_node_hash(dest, 0, 0)
assert(leaf == nil and err == 'the node is below an opaque hash')
print('nested cold source before store:', leaf, err)
local independent_source = h.frontier_forest_load(source_dir, source_dir .. '/frontier.json')
assert(h.frontier_forest_get_node_hash(independent_source, 0, 0) == leaves[1])
local eager_dest = h.frontier_forest(3, 'keccak256')
h.frontier_forest_pad_back(eager_dest, source)
assert(h.frontier_forest_get_node_hash(eager_dest, 0, 0) == leaves[1])
local root = h.frontier_forest_get_root_hash(eager_dest)
assert(h.frontier_forest_get_root_hash(dest) == root)
h.frontier_forest_store(dest, dest_dir, dest_dir .. '/frontier.json')
local reopened = h.frontier_forest_load(dest_dir, dest_dir .. '/frontier.json')
assert(h.frontier_forest_get_root_hash(reopened) == root)
local saved_leaf, saved_err = h.frontier_forest_get_node_hash(reopened, 0, 0)
assert(saved_leaf == nil and saved_err == err)
print('nested cold source after successful store/reload:', saved_leaf, saved_err)
print('source and eager controls retain the leaf; all commitment roots match')
print('BUG 007 reproduced: nesting discarded the source storage context')
