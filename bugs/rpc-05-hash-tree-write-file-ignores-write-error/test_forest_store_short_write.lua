-- Proof: cartesi.hash-tree write_file ignores file:write() errors.
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/rpc-05-hash-tree-write-file-ignores-write-error/test_forest_store_short_write.lua
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fs = require("cartesi.filesystem")

local function build()
    local f = ht.frontier_forest(10, "keccak256")
    for i = 1, 1024 do
        ht.frontier_forest_push_back(f, cartesi.keccak256(string.pack("<i8", i)))
    end
    return f
end

local mode, dir = arg[1], arg[2]
if mode == "store" then
    local ok, err = pcall(ht.frontier_forest_store, build(), dir, dir .. "/frontier.json")
    io.stdout:write("store ", tostring(ok), " ", tostring(err), "\n")
    os.exit(ok and 0 or 3)
end

local script = arg[0]
local base = os.getenv("TMPDIR_TEST") or ("/tmp/hash-tree-write-file-" .. tostring(os.time()) .. "-" .. math.random(1 << 30))
os.execute("rm -rf '" .. base .. "'")
assert(fs.create_directory(base) ~= false)
dir = base .. "/forest"
fs.create_directory(dir)

local expected_root = ht.frontier_forest_get_root_hash(build())

-- 1. Store with a 16 KiB file-size limit (SIGXFSZ ignored so write() fails with EFBIG,
--    as a short write on a full disk would).
local cmd = string.format(
    "timeout 60 bash -c \"trap '' XFSZ; ulimit -f 16; lua5.4 '%s' store '%s'\"", script, dir)
local p = io.popen(cmd)
local out = p:read("a")
local _, _, code = p:close()
io.stdout:write("limited store child (exit ", tostring(code), "): ", out)
local limited_ok = (code == 0)

-- Report on stored files.
local truncated = {}
for _, name in ipairs(fs.list_directory(dir)) do
    local size = fs.get_file_size(dir .. "/" .. name)
    io.stdout:write(string.format("  %s %d bytes\n", name, size))
    local contents = fs.read_file(dir .. "/" .. name)
    if name:match("%.json$") and not pcall(cartesi.fromjson, contents) then truncated[#truncated + 1] = name end
end

-- 2. Load what the limited store claimed to commit.
local load_ok, load_err = pcall(ht.frontier_forest_load, dir, dir .. "/frontier.json")
io.stdout:write("load after limited store: ", tostring(load_ok), " ", tostring(load_ok or load_err), "\n")

-- 3. "Free the disk" and store again without limit, then load.
local p2 = io.popen(string.format("timeout 60 lua5.4 '%s' store '%s'", script, dir))
io.stdout:write("unlimited re-store: ", p2:read("a"))
p2:close()
local load2_ok, f2 = pcall(ht.frontier_forest_load, dir, dir .. "/frontier.json")
local root_ok = false
if load2_ok then
    -- force the trees to load by querying a leaf proof
    local q_ok, q = pcall(function()
        return ht.frontier_forest_get_root_hash(f2) == expected_root and ht.frontier_forest_get_node_hash
            and true
    end)
    root_ok = q_ok and q
end
io.stdout:write("load after unlimited re-store: ", tostring(load2_ok), " ", tostring(load2_ok and "" or f2), "\n")

os.execute("rm -rf '" .. base .. "'")

local bug = false
if limited_ok and #truncated > 0 then
    print("BUG: frontier_forest_store reported success under a write error but left truncated file(s): "
        .. table.concat(truncated, ", "))
    bug = true
end
if limited_ok and not load_ok then
    print("BUG: frontier committed by a successful store cannot be loaded: " .. tostring(load_err))
    bug = true
end
if not load2_ok then
    print("BUG: re-storing after the error condition cleared does not repair the corrupt tree file: " .. tostring(f2))
    bug = true
end
if bug then os.exit(1) end
print("OK: write errors are reported and no corrupt file is committed")
os.exit(0)
