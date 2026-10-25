-- Shows that hash-tree.lua derives the temporary-file directory, its name prefix, and the
-- directory to sync from a path by splitting only on '/'. A native Windows path such as
-- C:\node\frontier.json therefore yields directory "." and the prefix "C:\node\frontier.json.tmp.",
-- so os::create_temporary_file builds "./C:\node\frontier.json.tmp.XXXXXX", which is an invalid
-- name on Windows (':' inside a component), and every store fails.
-- The filesystem calls are intercepted so the test runs on Linux.
local fs = require("cartesi.filesystem")
local hash_tree = require("cartesi.hash-tree")

local calls = {}
local real_new_tmp, real_sync_dir, real_rename = fs.new_temporary_file, fs.sync_directory, fs.rename_file
local scratch = os.getenv("TMPDIR") or "/tmp"
fs.new_temporary_file = function(dirname, prefix)
    calls.tmp_dir, calls.tmp_prefix = dirname, prefix
    -- create a real file somewhere harmless so write_file can proceed
    return real_new_tmp(scratch, "w2a07.")
end
fs.rename_file = function(from, to) calls.rename_to = to; os.remove(from) end
fs.sync_directory = function(d) calls.sync_dir = d end

local f = hash_tree.frontier(4, "keccak256")
local path = [[C:\node\frontier.json]]
local ok, err = pcall(hash_tree.frontier_store, f, path)
fs.new_temporary_file, fs.sync_directory, fs.rename_file = real_new_tmp, real_sync_dir, real_rename
assert(ok, err)

local template = calls.tmp_dir .. "/" .. calls.tmp_prefix .. "XXXXXX" -- as os-filesystem.cpp builds it
print(string.format("path            = %s", path))
print(string.format("temporary dir   = %s", calls.tmp_dir))
print(string.format("temporary prefix= %s", calls.tmp_prefix))
print(string.format("mkstemp template= %s", template))
print(string.format("synced dir      = %s", calls.sync_dir))

local bad = false
if calls.tmp_dir ~= [[C:\node]] then
    print("BUG: temporary file directory is '" .. calls.tmp_dir .. "' instead of 'C:\\node'")
    bad = true
end
if calls.tmp_prefix:find("[\\/:]") then
    print("BUG: temporary file prefix contains path separators / drive colon: '" .. calls.tmp_prefix .. "'")
    bad = true
end
if calls.sync_dir ~= [[C:\node]] then
    print("BUG: synced directory is '" .. calls.sync_dir .. "' instead of 'C:\\node'")
    bad = true
end
os.exit(bad and 1 or 0)
