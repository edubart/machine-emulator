-- Exercises cartesi.filesystem rename_file / temporary_file:rename (as used by hash-tree.lua write_file,
-- i.e. frontier_store / frontier_forest_store) replacing an existing destination.
-- Usage: lua test.lua <repo-src-dir> <work-dir>
local src, dir = arg[1], arg[2]
package.path = src .. "/?.lua;" .. package.path
-- Stub the C core only for what new_temporary_file needs (the real core is not built for Windows here);
-- rename_file itself is pure Lua (os.rename) and is loaded unchanged from the repo.
local n = 0
package.preload["cartesi.filesystem.core"] = function()
    return {
        create_temporary_file = function(dirname, prefix)
            n = n + 1
            local path = dirname .. "/" .. prefix .. string.format("%06d", n)
            return assert(io.open(path, "w+b")), path
        end,
        sync_file = function() end,
        sync_directory = function() end,
    }
end
local fs = require("cartesi.filesystem")
local dest = dir .. "/frontier.json"
os.remove(dest)
-- Mimic hash-tree.lua write_file(contents, path) twice (two consecutive commits)
local function write_file(contents, path)
    local temporary <close> = fs.new_temporary_file(dir, "frontier.json.tmp.")
    assert(temporary.file:write(contents))
    fs.sync_file(temporary.file)
    temporary:rename(path)
end
local ok1, e1 = pcall(write_file, "commit-1", dest)
print("first store:", ok1, e1)
local ok2, e2 = pcall(write_file, "commit-2", dest)
print("second store:", ok2, e2)
local f = io.open(dest, "rb"); local got = f and f:read("a"); if f then f:close() end
print("destination contents:", got)
if not ok1 then print("BUG: first store failed: " .. tostring(e1)); os.exit(1) end
if not ok2 or got ~= "commit-2" then
    print("BUG: rename_file did not replace existing destination (second frontier store failed): " .. tostring(e2))
    os.exit(1)
end
print("OK: destination replaced")
os.exit(0)
