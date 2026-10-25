-- Proof: a write error (here EFBIG via RLIMIT_FSIZE, same path as ENOSPC/EDQUOT/EIO) while
-- storing hash-tree files is silently ignored; truncated files are committed under their final
-- content-addressed names, and the corruption is never repaired by later stores.
-- Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/lua-01-tempfile-write-error-silently-committed/test_tempfile_write_error.lua
-- Exits 1 with BUG: lines while the bug is present, 0 with OK: once fixed. Needs bash and ulimit -f.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fs = require("cartesi.filesystem")

local function leaves()
    local hs = {}
    for i = 1, 128 do hs[i] = cartesi.keccak256("leaf" .. i) end
    return hs
end

local mode, dir = arg[1], arg[2]
if mode == "child-forest" then
    -- runs with RLIMIT_FSIZE = 4 KiB
    local f = ht.frontier_forest(7, "keccak256")
    ht.frontier_forest_append(f, leaves())
    local ok, err = pcall(ht.frontier_forest_store, f, dir .. "/forests", dir .. "/frontier.json")
    print("child: frontier_forest_store ok=" .. tostring(ok) .. " err=" .. tostring(err))
    os.exit(ok and 0 or 3)
elseif mode == "child-raw" then
    -- the raw API pattern: new_temporary_file + file:write + sync_file + rename
    local ok, err = pcall(function()
        local t <close> = fs.new_temporary_file(dir, "raw.json.tmp.")
        t.file:write(string.rep("x", 20000))
        fs.sync_file(t.file)
        t:rename(dir .. "/raw.json")
    end)
    print("child: raw temp write ok=" .. tostring(ok) .. " err=" .. tostring(err))
    os.exit(ok and 0 or 3)
end

local self = arg[0]
local base = os.getenv("WORKDIR")
local own_base = false
if not base then
    local p = assert(io.popen("mktemp -d"))
    base = assert(p:read("l"))
    p:close()
    own_base = true
else
    os.execute("rm -rf '" .. base .. "'")
end
local function finish(code)
    if own_base then os.execute("rm -rf '" .. base .. "'") end
    os.exit(code)
end
assert(os.execute("mkdir -p '" .. base .. "/forests'"))
local function run_limited(child, kib)
    local cmd = string.format("timeout 30 bash -c \"trap '' XFSZ; ulimit -f %d; exec lua5.4 '%s' %s '%s'\"",
        kib, self, child, base)
    local ok, how, code = os.execute(cmd)
    return ok, code
end

local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end

-- 1) raw API: pre-existing good file replaced by truncated one, with no error raised
fs.write_file("GOOD", base .. "/raw.json")
local ok = run_limited("child-raw", 8)
local sz = fs.get_file_size(base .. "/raw.json")
print(string.format("raw: child succeeded=%s, raw.json size=%d (expected 20000 or untouched 4)", tostring(ok), sz))
if ok and sz ~= 20000 then
    bug("new_temporary_file/file:write/sync_file/rename reported success but committed a truncated file ("
        .. sz .. " of 20000 bytes), replacing the previous good file")
end

-- 2) frontier_forest_store of 128 distinct leaves (tree JSON > 4 KiB)
ok = run_limited("child-forest", 4)
for _, n in ipairs(fs.list_directory(base .. "/forests")) do
    print("  forests/" .. n, fs.get_file_size(base .. "/forests/" .. n))
end
local fexists = fs.exists(base .. "/frontier.json")
print("forest: child succeeded=" .. tostring(ok) .. ", frontier.json exists=" .. tostring(fexists))
if ok and fexists then
    local lok, lerr = pcall(function()
        local g = ht.frontier_forest_load(base .. "/forests", base .. "/frontier.json")
        return ht.frontier_forest_get_node_hash(g, 0, 0)
    end)
    print("  load+get_node_hash after limited store: ok=" .. tostring(lok) .. " " .. tostring(lerr))
    if not lok then
        bug("frontier_forest_store reported success and committed frontier.json, but the forest cannot be reloaded: "
            .. tostring(lerr))
    end
end

-- 3) re-store an identical forest with no limit: does it repair?
local g = ht.frontier_forest(7, "keccak256")
ht.frontier_forest_append(g, leaves())
local expected_root = g[8] and g[8].hash
ht.frontier_forest_store(g, base .. "/forests", base .. "/frontier2.json")
local rok, rerr = pcall(function()
    local h = ht.frontier_forest_load(base .. "/forests", base .. "/frontier2.json")
    return ht.frontier_forest_get_node_hash(h, 0, 0)
end)
print("re-store without limit then load+get_node_hash: ok=" .. tostring(rok) .. " " .. tostring(rerr))
if not rok then
    bug("re-storing an identical, freshly built forest with free space does not repair it (store_tree skips the "
        .. "existing corrupt file): " .. tostring(rerr))
end

if bugs > 0 then finish(1) end
print("OK: no defect observed")
finish(0)
