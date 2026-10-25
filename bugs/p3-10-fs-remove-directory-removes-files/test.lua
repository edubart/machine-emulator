-- Proves fs.remove_directory removes regular files and fs.remove_file removes empty directories.
local fs = require("cartesi.filesystem")
local base = assert(os.tmpname()); os.remove(base)
fs.create_directory(base)
local bugs = 0
-- 1) remove_directory on a regular file
local f = base .. "/regular_file"
fs.write_file("payload", f)
local ok, err = pcall(fs.remove_directory, f)
if ok then
    if not fs.exists(f) then
        print("BUG: fs.remove_directory(regular file) succeeded and deleted the file")
        bugs = bugs + 1
    end
else print("ok: remove_directory(file) failed: " .. tostring(err)) end
-- 2) remove_file on an empty directory
local d = base .. "/empty_dir"
fs.create_directory(d)
ok, err = pcall(fs.remove_file, d)
if ok then
    if not fs.exists(d) then
        print("BUG: fs.remove_file(empty directory) succeeded and deleted the directory")
        bugs = bugs + 1
    end
else print("ok: remove_file(dir) failed: " .. tostring(err)) end
-- cleanup
for _, n in ipairs(fs.list_directory(base)) do os.remove(base .. "/" .. n) end
os.remove(base)
if bugs > 0 then os.exit(1) end
print("PASS")
