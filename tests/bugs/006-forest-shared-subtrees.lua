-- Bounded complexity regression: maximum height 10, no large or hanging run.
-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
local c = require('cartesi')
local h = require('cartesi.hash-tree')
local fs = require('cartesi.filesystem')
local leaf = c.keccak256('repeated normal leaf')

local function measure(height, checkpoint)
    local dir = fs.temp_pathname()
    fs.create_directory(dir)
    local cleanup <close> = setmetatable({}, { __close = function()
        for _, name in ipairs(fs.list_directory(dir)) do fs.remove_file(dir .. '/' .. name) end
        fs.remove_directory(dir)
    end })
    local tree = h.frontier_forest(0, 'keccak256')
    h.frontier_forest_push_back(tree, leaf)
    for level = 1, height do
        local parent = h.frontier_forest(level, 'keccak256')
        h.frontier_forest_push_back(parent, tree)
        if checkpoint then h.frontier_forest_store(parent, dir, dir .. '/partial.json') end
        h.frontier_forest_push_back(parent, tree)
        h.frontier_forest_store(parent, dir, dir .. '/final.json')
        tree = parent
    end
    local reads, paths, read_file = 0, {}, fs.read_file
    fs.read_file = function(path)
        reads = reads + 1
        paths[path] = true
        return read_file(path)
    end
    local ok, loaded = pcall(h.frontier_forest_load, dir, dir .. '/final.json')
    fs.read_file = read_file
    assert(ok, loaded)
    assert(h.frontier_forest_get_root_hash(loaded) == h.frontier_forest_get_root_hash(tree))
    local unique = 0
    for _ in pairs(paths) do unique = unique + 1 end
    local nodes = {}
    local function visit(t)
        if type(t) ~= 'table' or nodes[t] then return end
        nodes[t] = true
        if t.kind == 'mixed' then
            visit(t.left)
            visit(t.right)
        elseif t.kind == 'fixed_point' then
            for _, value in ipairs(t[1]) do visit(value) end
        end
    end
    visit(loaded[height + 1])
    local objects = 0
    for _ in pairs(nodes) do objects = objects + 1 end
    print(checkpoint and 'checkpointed' or 'control', height, 'files', #fs.list_directory(dir),
        'reads', reads, 'distinct paths', unique, 'objects', objects)
    assert(reads == (checkpoint and 1 << height or 2))
    assert(unique == (checkpoint and height + 1 or 2))
    assert(objects == (checkpoint and (1 << (height + 1)) - 1 or 1))
    assert(h.frontier_forest_get_node_hash(loaded, 0, 0) == leaf)
    return h.frontier_forest_get_root_hash(loaded)
end

for _, height in ipairs({ 4, 7, 10 }) do
    assert(measure(height, true) == measure(height, false))
end
print('BUG 006 reproduced: loading duplicates shared subtrees exponentially')
