-- Repro: clone_stored / filesystem.clone_file fail with EINVAL instead of falling back to copy
-- when FICLONE is rejected by btrfs for a NODATACOW mismatch (chattr +C on destination dir).
-- Usage (from the repo root): eval $(make -s env); lua5.4 bugs/u1-01-clone-file-reflink-einval-eagain-no-copy-fallback/test.lua [btrfs_dir]
-- Without an argument it needs root and btrfs-progs: it creates a 300M btrfs image in a fresh mktemp -d
-- directory, loop-mounts it, runs the checks, then unmounts it and removes the temporary directory.
-- With an argument, it uses the given directory, which must be on btrfs.
-- Exits 1 while the bug is present, 0 once clone_file falls back to a regular copy.
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")

local function sh(cmd) return os.execute("timeout 60 " .. cmd) end
local base = arg[1]
local mounted, tmpdir
if not base then
    local p = assert(io.popen("mktemp -d"))
    tmpdir = assert(p:read("l"), "mktemp -d failed")
    p:close()
    base = tmpdir .. "/mnt"
    assert(sh("mkdir -p " .. base))
    assert(sh("truncate -s 300M " .. tmpdir .. "/btrfs.img"), "truncate failed")
    assert(sh("mkfs.btrfs -q -f " .. tmpdir .. "/btrfs.img >/dev/null"), "mkfs.btrfs failed (need root/btrfs-progs)")
    assert(sh("mount -o loop " .. tmpdir .. "/btrfs.img " .. base), "mount failed (need root)")
    mounted = true
end
local function cleanup()
    if mounted then sh("umount " .. base) end
    if tmpdir then sh("rm -rf " .. tmpdir) end
end

local A, B = base .. "/A", base .. "/B"
assert(sh("rm -rf " .. A .. " " .. B))
assert(sh("mkdir -p " .. A .. " " .. B))
assert(sh("chattr +C " .. B), "chattr +C failed")

-- sanity: cp --reflink=auto succeeds on this pair of dirs
assert(sh("dd if=/dev/urandom of=" .. A .. "/f bs=4096 count=4 status=none"))
assert(sh("cp --reflink=auto " .. A .. "/f " .. B .. "/f_cp"), "cp --reflink=auto failed")

local failures = 0

-- 1. low-level cartesi.filesystem.clone_file (file is writable -> reflink path)
local ok, err = pcall(fs.clone_file, A .. "/f", B .. "/f_clone")
if not ok then
    print("BUG: cartesi.filesystem.clone_file failed where cp --reflink=auto succeeds: " .. tostring(err))
    failures = failures + 1
else
    print("ok: filesystem.clone_file fell back")
end

-- 2. clone_stored of a small machine from normal dir into a +C dir
local expected
do
    local m <close> = cartesi.machine({ ram = { length = 0x10000 } })
    m:write_memory(0x80000000, "hello world")
    expected = m:get_root_hash()
    m:store(A .. "/m")
end
ok, err = pcall(cartesi.machine.clone_stored, cartesi.machine, A .. "/m", B .. "/m")
if not ok then
    print("BUG: cartesi.machine:clone_stored failed where cp --reflink=auto succeeds: " .. tostring(err))
    local exists = fs.exists(B .. "/m")
    print("     partial clone left behind: " .. tostring(exists))
    failures = failures + 1
else
    local m <close> = cartesi.machine(B .. "/m")
    if m:get_root_hash() ~= expected then
        print("BUG: cloned machine has wrong root hash")
        failures = failures + 1
    else
        print("ok: clone_stored succeeded with matching root hash")
    end
end

cleanup()
if failures > 0 then os.exit(1) end
print("PASS")
os.exit(0)
