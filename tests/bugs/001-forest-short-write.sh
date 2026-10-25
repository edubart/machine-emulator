#!/usr/bin/env bash
# Run from the repository root after `make`. Exits successfully when the bug is reproduced.
set -eu
trap '' XFSZ
# Bash expresses this limit in KiB. Model a failed filesystem write without filling a disk.
ulimit -f 1
export LUA_PATH='./src/?.lua;;'
export LUA_CPATH='./src/?.so;;'
export LD_LIBRARY_PATH="./src${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec lua5.4 - <<'LUA'
local fs = require('cartesi.filesystem')
local h = require('cartesi.hash-tree')
local dir = fs.temp_pathname()
fs.create_directory(dir)
local cleanup <close> = setmetatable({}, { __close = function()
    for _, name in ipairs(fs.list_directory(dir)) do fs.remove_file(dir .. '/' .. name) end
    fs.remove_directory(dir)
end })
local forest = h.frontier_forest(8, 'keccak256')
local hashes = {}
for i = 1, 256 do hashes[i] = string.rep(string.char(i % 256), 32) end
h.frontier_forest_append(forest, hashes)
local ok, err = pcall(h.frontier_forest_store, forest, dir, dir .. '/frontier.json')
print('store reported success:', ok, err)
local reload_ok, reload_err = pcall(h.frontier_forest_load, dir, dir .. '/frontier.json')
print('reload succeeded:', reload_ok, reload_err)
local truncated = false
for _, name in ipairs(fs.list_directory(dir)) do
    local size = fs.get_file_size(dir .. '/' .. name)
    print(name, size)
    if name ~= 'frontier.json' and size == 1024 then truncated = true end
end
assert(ok, 'store correctly reported the failed write; bug not reproduced')
assert(not reload_ok and tostring(reload_err):find('parse error', 1, true))
assert(truncated, 'expected a truncated tree file')
print('BUG 001 reproduced: successful store committed an unreadable forest')
LUA
