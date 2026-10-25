-- Proves files committed through filesystem.new_temporary_file (hash-tree frontier/forest stores)
-- keep mkstemp's 0600 mode instead of the umask-respecting mode used by every other file the
-- emulator/Lua library writes (io.open -> 0666 & ~umask, os::create_file -> 0644 & ~umask).
local hash_tree = require("cartesi.hash-tree")
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")

local function mode(path)
    local p <close> = assert(io.popen("stat -c %a '" .. path .. "'"))
    return (assert(p:read("l")))
end

local dir = assert(os.tmpname()); os.remove(dir)
fs.create_directory(dir)
local cleanup = {}

-- reference: a file written by the library's own write_file (io.open)
local ref = dir .. "/reference.bin"
fs.write_file("x", ref); cleanup[#cleanup + 1] = ref
local ref_mode = mode(ref)

-- frontier_store
local fpath = dir .. "/frontier.json"
hash_tree.frontier_store(hash_tree.frontier(4, "keccak256"), fpath); cleanup[#cleanup + 1] = fpath

-- frontier_forest_store
local forest = hash_tree.frontier_forest(4, "keccak256")
for i = 1, 5 do hash_tree.frontier_forest_push_back(forest, cartesi.keccak256(tostring(i))) end
local tdir = dir .. "/trees"; fs.create_directory(tdir)
local ffpath = dir .. "/forest-frontier.json"
hash_tree.frontier_forest_store(forest, tdir, ffpath); cleanup[#cleanup + 1] = ffpath

local bad = 0
print("reference io.open/write_file mode: " .. ref_mode)
local function check(path)
    local m = mode(path)
    print(string.format("%s mode: %s", path:sub(#dir + 2), m))
    if m ~= ref_mode then bad = bad + 1 end
end
check(fpath); check(ffpath)
for _, name in ipairs(fs.list_directory(tdir)) do
    if name ~= "." and name ~= ".." then check(tdir .. "/" .. name); cleanup[#cleanup + 1] = tdir .. "/" .. name end
end
os.execute("rm -rf '" .. dir .. "'")
if bad > 0 then
    print(string.format("BUG: %d file(s) committed via new_temporary_file+rename have mode 600, ignoring umask (other emulator-written files get %s)", bad, ref_mode))
    os.exit(1)
end
print("OK")
