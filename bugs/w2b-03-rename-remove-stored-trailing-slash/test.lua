-- Repro: rename_stored/remove_stored with trailing slash perform the operation
-- on disk but then report failure (parent_directory() returns the dir itself).
local cartesi = require("cartesi")
local base = os.getenv("WORKDIR") or ((os.getenv("TMPDIR") or "/tmp") .. "/w2b-03-rename-remove-stored-trailing-slash-st")
os.execute("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "'")

local function exists(p)
    local f = io.open(p .. "/config.json", "r")
    if f then f:close() return true end
    return false
end
local function dir_exists(p) return os.execute("test -d '" .. p .. "'") == true end

local m = cartesi.machine({
    ram = { length = 1 << 20 },
}, { })
local failed = false

-- rename_stored with trailing slash
m:store(base .. "/a")
assert(exists(base .. "/a"), "store failed")
local ok, err = pcall(m.rename_stored, m, base .. "/a/", base .. "/b/")
print(string.format("rename_stored('a/','b/'): ok=%s err=%s; a exists=%s b exists=%s",
    tostring(ok), tostring(err), tostring(dir_exists(base .. "/a")), tostring(exists(base .. "/b"))))
if not ok and exists(base .. "/b") and not dir_exists(base .. "/a") then
    print("BUG: rename_stored with trailing slash renamed the directory on disk but reported failure: " .. tostring(err))
    failed = true
end

-- remove_stored with trailing slash
m:store(base .. "/c")
assert(exists(base .. "/c"), "store failed")
ok, err = pcall(m.remove_stored, m, base .. "/c/")
print(string.format("remove_stored('c/'): ok=%s err=%s; c exists=%s",
    tostring(ok), tostring(err), tostring(dir_exists(base .. "/c"))))
if not ok and not dir_exists(base .. "/c") then
    print("BUG: remove_stored with trailing slash removed the directory on disk but reported failure: " .. tostring(err))
    failed = true
end

os.execute("rm -rf '" .. base .. "'")
if failed then os.exit(1) end
print("OK")
os.exit(0)
