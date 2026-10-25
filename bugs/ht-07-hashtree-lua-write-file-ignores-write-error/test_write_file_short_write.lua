-- Proof: cartesi.hash-tree's write_file ignores file:write() errors, so a short write (disk full,
-- EFBIG) is silently committed as a truncated tree file. store_tree never rewrites an existing
-- tree file, so the corruption persists across later stores and the forest cannot be reloaded.
--
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua
-- The disk-full condition is simulated in a child process with RLIMIT_FSIZE (ulimit -f) and
-- SIGXFSZ ignored, which makes write(2) fail with EFBIG once the file reaches the limit, just as
-- ENOSPC would on a full disk.
local cartesi = require("cartesi")
local hash_tree = require("cartesi.hash-tree")

local LOG2_LEAVES = 9 -- 512 distinct leaves -> one fixed-point tree file of ~35 KB
local LIMIT_KIB = 8 -- file-size limit for the child, well below the tree file size

local function build_forest()
    local forest = hash_tree.frontier_forest(LOG2_LEAVES, "keccak256")
    local leaves = {}
    for i = 1, 1 << LOG2_LEAVES do
        leaves[i] = cartesi.keccak256(string.pack(">I8", i))
    end
    hash_tree.frontier_forest_append(forest, leaves)
    return forest
end

local mode, dir = arg[1], arg[2]
if mode == "child-store" then
    -- Child: store the forest (under ulimit -f). Report whether the store raised.
    local forest = build_forest()
    local ok, err = pcall(hash_tree.frontier_forest_store, forest, dir .. "/trees", dir .. "/frontier.json")
    io.stdout:write(ok and "STORE-OK\n" or ("STORE-FAILED " .. tostring(err) .. "\n"))
    os.exit(0)
end

-- Parent
local function sh(cmd)
    local p = assert(io.popen(cmd, "r"))
    local out = p:read("a")
    p:close()
    return out
end

local work = sh("mktemp -d"):gsub("%s+$", "")
assert(os.execute("mkdir -p " .. work .. "/trees"))
local script = arg[0]

local expected_forest = build_forest()
local expected_root = hash_tree.frontier_forest_get_root_hash(expected_forest)

-- 1) Store under a file-size limit (simulates a full disk).
local out = sh(
    string.format(
        "timeout 60 bash -c \"trap '' XFSZ; ulimit -f %d; exec lua5.4 '%s' child-store '%s'\" 2>&1",
        LIMIT_KIB,
        script,
        work
    )
)
io.write("child (limited store): ", out)

local function list_trees()
    local files = {}
    for name in sh("ls " .. work .. "/trees"):gmatch("[^\n]+") do
        local f = assert(io.open(work .. "/trees/" .. name, "rb"))
        local size = f:seek("end")
        f:close()
        files[#files + 1] = { name = name, size = size }
    end
    return files
end

local files = list_trees()
for _, f in ipairs(files) do
    print(string.format("tree file %s size %d", f.name, f.size))
end

local store_reported_ok = out:find("STORE-OK", 1, true) ~= nil

-- 2) Store again without the limit, in this process (a restart after freeing space). A fixed
-- store_tree would rewrite or detect the bad file. The current one skips existing files.
local ok2, err2 = pcall(hash_tree.frontier_forest_store, build_forest(), work .. "/trees", work .. "/frontier.json")
print("second (unlimited) store:", ok2, err2)
for _, f in ipairs(list_trees()) do
    print(string.format("tree file after second store %s size %d", f.name, f.size))
end

-- 3) Reload the forest and query it, as a node does after a restart.
local load_ok, load_err = pcall(function()
    local forest = hash_tree.frontier_forest_load(work .. "/trees", work .. "/frontier.json")
    assert(hash_tree.frontier_forest_get_root_hash(forest) == expected_root, "root mismatch")
    -- reach into the stored tree to force a load of its file
    local h = hash_tree.frontier_forest_get_node_hash(forest, 0, 0)
    assert(h == cartesi.keccak256(string.pack(">I8", 1)), "leaf mismatch")
end)
print("reload + query:", load_ok, load_err)

os.execute("rm -rf " .. work)

local bug = false
if store_reported_ok then
    print("BUG: frontier_forest_store reported success although writing the tree file failed (EFBIG)")
    bug = true
end
if not load_ok then
    print("BUG: the committed tree file is truncated and the forest cannot be reloaded/queried: " .. tostring(load_err))
    bug = true
end
if not ok2 or not load_ok then
    if ok2 then
        print("BUG: a later store over the same directory did not repair the truncated file (store_tree skips existing files)")
    end
end
if bug then os.exit(1) end
print("OK: write errors are detected and no truncated file is committed")
os.exit(0)
