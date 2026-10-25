-- Proves that temporary files left by a store killed inside write_file are never cleaned up by
-- later frontier_forest_store/frontier_forest_load calls, so they accumulate across crashes.
local fs = require("cartesi.filesystem")
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = os.tmpname(); os.remove(root)
assert(os.execute("mkdir -p " .. root .. "/forests"))
local dir, fpath = root .. "/forests", root .. "/frontier.json"
local function run(mode, seed)
    local cmd = string.format("timeout 30 lua5.4 %s/child.lua %s %s %s %d", here, dir, fpath, mode, seed)
    local ok, how, code = os.execute(cmd)
    return ok, how, code
end
local function count_tmp()
    local n, total = 0, 0
    for _, name in ipairs(fs.list_directory(dir)) do
        if name:find("%.tmp%.") then
            n = n + 1
            total = total + fs.get_file_size(dir .. "/" .. name)
        end
    end
    for _, name in ipairs(fs.list_directory(root)) do
        if name:find("%.tmp%.") then n = n + 1; total = total + fs.get_file_size(root .. "/" .. name) end
    end
    return n, total
end
local CRASHES = 5
for i = 1, CRASHES do
    local ok, how, code = run("kill", i)
    print(string.format("crash %d: ok=%s how=%s code=%s tmp files now=%d", i, tostring(ok), how, code, (count_tmp())))
end
-- A healthy restart: store and load again in the same directory
assert(run("load", 100), "healthy store/load failed")
local n, bytes = count_tmp()
print(string.format("after healthy store+load: %d leftover .tmp. files (%d bytes)", n, bytes))
for _, name in ipairs(fs.list_directory(dir)) do if name:find("%.tmp%.") then print("  " .. name) end end
os.execute("rm -rf " .. root)
if n > 0 then
    print(string.format("BUG: %d orphaned temporary files from %d interrupted stores remain after a later store/load; nothing cleans them", n, CRASHES))
    os.exit(1)
end
print("OK: no leftover temporary files")
