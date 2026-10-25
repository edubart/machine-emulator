-- Requires gdb. Run from the repo root: eval $(make -s env); lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test.lua
-- Exits 1 and prints "BUG:" while the defect is present.
-- PoC: a SHARING_ALL machine killed in the middle of hash_tree::update (after page hashes reached
-- the shared dense tree but before inner nodes / sparse tree were recomputed and the dirty tree
-- cleaned) reloads with a permanently wrong root hash, and verify_hash_tree() still says true.
-- The kill point is made deterministic with gdb (breakpoint on hash_tree::update_dense_trees,
-- which update() calls right after update_dirty_pages()), then SIGKILL.
local cartesi = require"cartesi"
local here = arg[0]:match("^(.*)/") or "."
local tmp = os.getenv("TMPDIR_POC") or io.popen("mktemp -d"):read("l")
local dir = tmp .. "/st"
local gdblog = tmp .. "/gdb.log"
local original
local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function sh(c) local ok = os.execute(c); return ok end
sh("rm -rf " .. dir)

-- 1. create and store a small machine
do
    local m = cartesi.machine{ ram = { length = 4 << 20 } }
    original = m:get_root_hash()
    m:store(dir) -- default sharing for store is SHARING_ALL
    m = nil; collectgarbage(); collectgarbage()
end

-- reference: what the root hash must be after the child's writes (computed on a private copy)
local expected
do
    local m = cartesi.new()
    m:load(dir, nil, cartesi.SHARING_NONE)
    local page = string.rep("\xAB", 4096)
    for p = 0, 63 do m:write_memory(0x80000000 + p * 4096 * 7, page) end
    expected = m:get_root_hash()
    m = nil; collectgarbage(); collectgarbage()
end

-- 2. run the child under gdb; when update() reaches update_dense_trees inside cm_get_root_hash, SIGKILL it
local gdb = table.concat({
    "timeout 120 gdb -q -batch -nx",
    "-ex 'set breakpoint pending on'",
    "-ex 'set print thread-events off'",
    "-ex 'break cm_get_root_hash'",
    "-ex run",
    "-ex 'break cartesi::hash_tree::update_dense_trees'",
    "-ex continue",
    "-ex 'bt 4'",
    "-ex 'python import os,signal; os.kill(gdb.selected_inferior().pid, signal.SIGKILL)'",
    "-ex 'echo KILLED-IN-UPDATE-DENSE-TREES\\n'",
    "-ex continue",
    "--args lua5.4", here .. "/child.lua", dir,
    "> " .. gdblog .. " 2>&1",
}, " ")
sh(gdb)
local log = io.open(gdblog):read("a")
if not log:find("update_dense_trees", 1, true) or not log:find("KILLED-IN-UPDATE-DENSE-TREES", 1, true) then
    io.stderr:write(log)
    print("SETUP ERROR: did not stop/kill the child at update_dense_trees")
    os.exit(2)
end
if log:find("not killed?", 1, true) then print("SETUP ERROR: child finished"); os.exit(2) end
print("child SIGKILLed inside hash_tree::update (in update_dense_trees)")

-- 3. restart: reload the directory and compare with a full rebuild
local results = {}
-- first reload in place (SHARING_ALL) and hash: shows the damage is persistent, not just a one-off
do
    local m = cartesi.new()
    m:load(dir, nil, cartesi.SHARING_ALL)
    print(string.format("SHARING_ALL reload: root=%s (hash tree written back to disk)", hex(m:get_root_hash())))
    m = nil; collectgarbage(); collectgarbage()
end
for _, mode in ipairs{ { "SHARING_NONE", cartesi.SHARING_NONE } } do
    local m = cartesi.new()
    local ok, err = pcall(m.load, m, dir, nil, mode[2])
    if not ok then print("BUG: reload failed: " .. tostring(err)); os.exit(1) end
    local h = m:get_root_hash()
    local v = m:verify_hash_tree()
    m:clear_hash_tree()
    local rebuilt = m:get_root_hash()
    print(string.format("%s reload: root=%s verify_hash_tree=%s", mode[1], hex(h), tostring(v)))
    print(string.format("full rebuild:        root=%s", hex(rebuilt)))
    print(string.format("expected:            root=%s", hex(expected)))
    print(string.format("pre-write original:  root=%s%s", hex(original), h == original and "  (reloaded root is the stale pre-write root)" or ""))
    if h ~= rebuilt then
        print(string.format("BUG: reloaded machine reports a wrong root hash (differs from a full rebuild)%s",
            v and " while verify_hash_tree() returns true" or ""))
        os.exit(1)
    end
end
print("OK: reloaded root hash matches full rebuild")
os.exit(0)
