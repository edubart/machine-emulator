-- Proof: hash_tree.frontier_store / frontier_forest_store with a file directly under "/"
-- raise "unable to sync directory" (open("") ENOENT) AFTER the file was already renamed in place.
-- To avoid touching the real "/", the script re-executes itself inside a private mount namespace
-- whose "/" is a throwaway overlay (tmpfs upper layer) over the real root (needs root + unshare).
-- Run from the repo root with the emulator environment loaded (eval $(make -s env)), as root.
local function sh_out(cmd)
    local p = assert(io.popen(cmd))
    local s = p:read("l")
    p:close()
    return s
end
if os.getenv("HT_ROOT_SANDBOX") ~= "1" then
    local script = assert(sh_out("realpath '" .. arg[0] .. "'"), "cannot resolve script path")
    local mnt = assert(sh_out("mktemp -d"), "cannot create temporary directory")
    local cmd = table.concat({
        "timeout 60 unshare -m --propagation private sh -c '",
        "set -e; mkdir -p ", mnt, "; mount -t tmpfs none ", mnt, "; ",
        "mkdir -p ", mnt, "/u ", mnt, "/w ", mnt, "/root; ",
        "mount -t overlay overlay -o lowerdir=/,upperdir=", mnt, "/u,workdir=", mnt, "/w ", mnt, "/root; ",
        "for d in /tmp /home /usr /nix; do [ -d \"$d\" ] && mount --rbind \"$d\" ", mnt, "/root\"$d\" || true; done; ",
        "exec chroot ", mnt, "/root env HT_ROOT_SANDBOX=1 lua5.4 ", script, "'",
    })
    local ok, how, code = os.execute(cmd)
    os.execute("rmdir '" .. mnt .. "' 2>/dev/null")
    os.exit(ok and 0 or (code or 1))
end

local hash_tree = require("cartesi.hash-tree")
local fs = require("cartesi.filesystem")

local failures = 0
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end

-- 1) frontier_store with a root-level path
local path = "/frontier-" .. tostring(os.time()) .. ".json"
os.remove(path)
local f = hash_tree.frontier(4, "keccak256")
hash_tree.frontier_push_back(f, string.rep("\1", 32))
local ok, err = pcall(hash_tree.frontier_store, f, path)
print("frontier_store(" .. path .. "): ok=" .. tostring(ok) .. " err=" .. tostring(err) .. " file_exists=" .. tostring(exists(path)))
if not ok then
    failures = failures + 1
    print("BUG: frontier_store of a file directly under '/' raised after committing the file (exists=" ..
        tostring(exists(path)) .. "): " .. tostring(err))
else
    local g = hash_tree.frontier_load(path, 4, "keccak256")
    assert(hash_tree.frontier_get_root_hash(g) == hash_tree.frontier_get_root_hash(f))
end

-- 2) frontier_forest_store with a root-level frontier path (trees directory elsewhere)
local dir = "/forest-trees-" .. tostring(os.time())
os.execute("mkdir -p " .. dir)
local fpath = "/forest-frontier-" .. tostring(os.time()) .. ".json"
local forest = hash_tree.frontier_forest(4, "keccak256")
hash_tree.frontier_forest_push_back(forest, string.rep("\2", 32))
local ok2, err2 = pcall(hash_tree.frontier_forest_store, forest, dir, fpath)
print("frontier_forest_store(" .. dir .. ", " .. fpath .. "): ok=" .. tostring(ok2) .. " err=" .. tostring(err2) ..
    " file_exists=" .. tostring(exists(fpath)))
if not ok2 then
    failures = failures + 1
    print("BUG: frontier_forest_store with frontier file directly under '/' raised after committing it (exists=" ..
        tostring(exists(fpath)) .. "): " .. tostring(err2))
end

-- 3) root cause: sync_directory("") vs sync_directory("/")
print("sync_directory('/') ok=" .. tostring((pcall(fs.sync_directory, "/"))))
print("sync_directory('')  -> " .. select(2, pcall(fs.sync_directory, "")) )

os.exit(failures == 0 and 0 or 1)
