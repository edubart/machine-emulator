-- Proof: clone_stored hard-links read-only backing files (the PMAs file is always
-- stored read-only) and does not fall back to a copy when link() fails with EMLINK.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua
-- (the directory must be on ext4 or another filesystem with a per-inode link limit; needs python3)
local cartesi = require("cartesi")
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local base = here .. "/tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(1 << 30))
assert(os.execute("mkdir -p '" .. base .. "'"))
local function cleanup() os.execute("rm -rf '" .. base .. "'") end

local ok, err = pcall(function()
    local template = base .. "/template"
    local root_hash
    do
        local m <close> = cartesi.machine({ ram = { length = 0x1000 }, hash_tree = { phtc_size = 32 } })
        root_hash = m:get_root_hash()
        m:store(template)
    end
    -- find read-only (hard-linked) files in the stored dir
    local p = io.popen("cd '" .. template .. "' && find . -maxdepth 1 -type f ! -perm -u+w -printf '%f\\n'")
    local ro = {}
    for f in p:lines() do ro[#ro + 1] = f end
    p:close()
    assert(#ro > 0, "expected at least one read-only file in stored dir")
    print("read-only files in stored dir: " .. table.concat(ro, ", "))

    -- sanity: a normal clone works and the read-only file is shared (hard-linked)
    local c1 = base .. "/c1"
    cartesi.machine:clone_stored(template, c1)
    local f = ro[1]
    local q = io.popen("stat -c %i '" .. template .. "/" .. f .. "' '" .. c1 .. "/" .. f .. "'")
    local i1, i2 = q:read("l"), q:read("l"); q:close()
    print(string.format("inode template=%s clone=%s (shared=%s)", i1, i2, tostring(i1 == i2)))

    -- Simulate many live descendants: link the shared inode until the fs link limit (EMLINK)
    local linkdir = base .. "/links"
    assert(os.execute("mkdir -p '" .. linkdir .. "'"))
    local py = [[
import os,sys,errno
src,d=sys.argv[1],sys.argv[2]
n=0
while True:
    try:
        os.link(src, os.path.join(d, str(n))); n+=1
    except OSError as e:
        if e.errno==errno.EMLINK: print("hit EMLINK after", n, "extra links; st_nlink=", os.stat(src).st_nlink); sys.exit(0)
        raise
]]
    local pf = io.open(base .. "/fill.py", "w"); pf:write(py); pf:close()
    assert(os.execute("timeout 120 python3 '" .. base .. "/fill.py' '" .. template .. "/" .. f .. "' '" .. linkdir .. "'"))

    -- Now clone from a descendant (c1) and from the template: both must succeed (fallback to copy)
    local failures = 0
    for _, src in ipairs({ c1, template }) do
        local dst = base .. "/c-from-" .. src:match("[^/]+$")
        local cok, cerr = pcall(cartesi.machine.clone_stored, cartesi.machine, src, dst)
        if not cok then
            print("clone_stored(" .. src:match("[^/]+$") .. ") failed: " .. tostring(cerr))
            failures = failures + 1
        else
            local m <close> = cartesi.machine(dst)
            assert(m:get_root_hash() == root_hash, "cloned machine root hash differs")
            print("clone_stored(" .. src:match("[^/]+$") .. ") ok")
        end
    end
    if failures > 0 then
        error("BUG: clone_stored fails with EMLINK once the shared read-only inode reaches the filesystem link limit; no fallback to copy", 0)
    end
end)
cleanup()
if not ok then
    print(err)
    os.exit(tostring(err):match("^BUG:") and 1 or 2)
end
print("OK: clone_stored fell back to copying")
os.exit(0)
