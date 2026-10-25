-- Proof: os::clone_file (cartesi.filesystem.clone_file, cm_clone_stored) does not fall back to a
-- copy when link() fails with EMLINK (filesystem hard-link limit, 65000 on ext4). Every read-only
-- backing file of a stored machine is hard linked by clone_stored, so a template machine that has
-- been cloned ~65000 times can no longer be cloned at all.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/lua-08-clone-file-emlink-no-fallback/test.lua
-- Work dir defaults to the script directory (override with BUG_WORK_DIR); it must be on ext4
-- or another filesystem with a small LINK_MAX, otherwise the test is skipped.
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local base = (os.getenv("BUG_WORK_DIR") or here) .. "/run-" .. tostring(os.time())
assert(os.execute("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "'"))
local function cleanup() os.execute("rm -rf '" .. base .. "'") end

local p = io.popen("getconf LINK_MAX '" .. base .. "'")
local link_max = tonumber(p:read("l")); p:close()
print("LINK_MAX for work dir:", link_max)
if not link_max or link_max > 200000 then
    print("SKIP: filesystem has no small hard link limit")
    cleanup(); os.exit(0)
end

local bugs = 0

-- Part 1: cartesi.filesystem.clone_file of a read-only file, repeated
do
    local src = base .. "/ro.bin"
    local f = assert(io.open(src, "wb")); f:write("read-only data"); f:close()
    assert(os.execute("chmod 0444 '" .. src .. "'"))
    local d = base .. "/links"; fs.create_directory(d)
    local failed_at, err
    for i = 1, link_max + 10 do
        local ok, e = pcall(fs.clone_file, src, d .. "/c" .. i)
        if not ok then failed_at, err = i, e break end
    end
    if failed_at then
        print(string.format("BUG: clone_file of read-only file failed at iteration %d: %s", failed_at, tostring(err)))
        bugs = bugs + 1
    else
        print("ok: clone_file kept working past the link limit")
    end
    assert(os.execute("rm -rf '" .. d .. "'"))
end

-- Part 2: cm_clone_stored of a stored template whose read-only files already have many links
-- (as they would after many earlier clone_stored calls from the same template / clone chain)
do
    local tmpl = base .. "/template"
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    m:store(tmpl)
    -- find read-only files in the stored machine (those clone_stored hard links)
    local ro = {}
    local pp = io.popen("find '" .. tmpl .. "' -type f ! -perm -u+w")
    for l in pp:lines() do ro[#ro + 1] = l end
    pp:close()
    print("read-only files in stored machine:", #ro)
    for _, r in ipairs(ro) do print("  " .. r) end
    assert(#ro > 0)
    -- first a real clone_stored to show it works and links the same inode
    m:clone_stored(tmpl, base .. "/clone-first")
    -- simulate ~65000 earlier clones by adding links to the first read-only file
    local target = ro[1]
    local d = base .. "/prior"; fs.create_directory(d)
    local p2 = io.popen("stat -c %h '" .. target .. "'"); local n = tonumber(p2:read("l")); p2:close()
    print("link count after one clone_stored:", n)
    local i = 0
    while n < link_max do
        i = i + 1
        fs.clone_file(target, d .. "/l" .. i)
        n = n + 1
    end
    local ok, e = pcall(m.clone_stored, m, tmpl, base .. "/clone-last")
    if not ok then
        print("BUG: clone_stored failed once read-only backing file reached link limit: " .. tostring(e))
        bugs = bugs + 1
    else
        print("ok: clone_stored still works at link limit")
    end
    -- also via cartesi.machine() loading is unaffected; only cloning breaks
end

cleanup()
if bugs > 0 then os.exit(1) end
print("PASS")
os.exit(0)
