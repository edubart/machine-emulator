-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Model temporary storage unavailability without changing checkpoint contents.
local c = require('cartesi')
local h = require('cartesi.hash-tree')
local fs = require('cartesi.filesystem')

local function reproduce(reload_first)
    local dir = fs.temp_pathname()
    fs.create_directory(dir)
    local cleanup <close> = setmetatable({}, { __close = function()
        if fs.exists(dir .. '.held') then fs.rename_file(dir .. '.held', dir) end
        for _, name in ipairs(fs.list_directory(dir)) do fs.remove_file(dir .. '/' .. name) end
        fs.remove_directory(dir)
    end })
    local leaves = { c.keccak256('expand a'), c.keccak256('expand b') }
    local bundle = h.frontier_forest(1, 'keccak256')
    h.frontier_forest_append(bundle, leaves)
    local bundle_hash = h.frontier_forest_get_root_hash(bundle)
    local forest = h.frontier_forest(2, 'keccak256')
    h.frontier_forest_pad_back(forest, bundle_hash, nil, 1)
    local frontier = dir .. '/frontier.json'
    h.frontier_forest_store(forest, dir, frontier)
    if reload_first then forest = h.frontier_forest_load(dir, frontier) end
    local root = h.frontier_forest_get_root_hash(forest)
    fs.rename_file(dir, dir .. '.held')
    local ok, err = pcall(h.frontier_forest_expand_leaf, forest, 0, bundle)
    fs.rename_file(dir .. '.held', dir)
    assert(not ok, 'the unavailable directory should cause a reported failure')
    print('initial expansion failed, loaded=' .. tostring(reload_first) .. ':', err)
    assert(h.frontier_forest_get_node_hash(forest, 0, 0) == leaves[1])
    local retry_ok, retry_err = pcall(h.frontier_forest_expand_leaf, forest, 0, bundle)
    assert(not retry_ok and tostring(retry_err):find('leaf height mismatch', 1, true))
    print('same expansion retry failed:', retry_err)
    h.frontier_forest_store(forest, dir, frontier)
    h.frontier_forest_store(forest, dir, frontier)
    local reopened = h.frontier_forest_load(dir, frontier)
    assert(h.frontier_forest_get_root_hash(reopened) == root)
    local leaf, query_err = h.frontier_forest_get_node_hash(reopened, 0, 0)
    assert(leaf == nil and query_err == 'the node is below an opaque hash')
    assert(not fs.exists(dir .. '/' .. c.tohex(bundle_hash) .. '.json'))
    print('leaf after two successful stores and reload:', leaf, query_err)
    -- A clean reload followed by expansion is a successful recovery control.
    h.frontier_forest_expand_leaf(reopened, 0, bundle)
    local recovered = h.frontier_forest_load(dir, frontier)
    assert(h.frontier_forest_get_node_hash(recovered, 0, 0) == leaves[1])
    assert(h.frontier_forest_get_root_hash(recovered) == root)
end

reproduce(false)
reproduce(true)
print('BUG 008 reproduced: later successful stores omitted the failed expansion')
