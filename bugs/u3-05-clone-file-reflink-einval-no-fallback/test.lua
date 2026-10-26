-- Repro: os::clone_file (cartesi.filesystem.clone_file / machine:clone_stored) does not fall back
-- to copying when FICLONE fails with EINVAL (btrfs: COW source -> NOCOW (+C) destination).
-- Requires root, mkfs.btrfs and chattr (loop-mounts a 160 MiB btrfs image next to this script).
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/u3-05-clone-file-reflink-einval-no-fallback/test.lua
-- Exit 1 = bug reproduced, 0 = fixed, 2/3 = setup/unexpected error.
local cartesi = require("cartesi")
local filesystem = require("cartesi.filesystem")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local img = here .. "/btrfs.img"
local mnt = here .. "/mnt"

local function sh(cmd)
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end
local function must(cmd) if not sh(cmd) then io.stderr:write("SETUP FAILED: " .. cmd .. "\n"); os.exit(2) end end

sh("umount " .. mnt .. " 2>/dev/null")
must("rm -f " .. img .. " && mkdir -p " .. mnt)
must("truncate -s 160M " .. img .. " && mkfs.btrfs -q " .. img)
must("mount -o loop " .. img .. " " .. mnt)

local failures = 0
local ok, err = pcall(function()
    -- 1) cartesi.filesystem.clone_file on a writable file, COW source, NOCOW destination dir
    must("mkdir " .. mnt .. "/cow " .. mnt .. "/nocow && chattr +C " .. mnt .. "/nocow")
    local src = mnt .. "/cow/data.bin"
    local f = assert(io.open(src, "wb")); f:write(string.rep("x", 65536)); f:close()
    must("chmod 0644 " .. src)
    -- sanity: plain copy into the NOCOW dir works
    local dst = mnt .. "/nocow/data.bin"
    local ok1, err1 = pcall(filesystem.clone_file, src, dst)
    if not ok1 then
        print("BUG: cartesi.filesystem.clone_file failed instead of falling back to copy: " .. tostring(err1))
        failures = failures + 1
    else
        local g = assert(io.open(dst, "rb")); local d = g:read("a"); g:close()
        assert(d == string.rep("x", 65536), "clone content mismatch")
        print("OK: clone_file fell back to copy")
    end

    -- 2) machine:clone_stored, the validator snapshot scenario: stored machine (COW), then the
    --    parent directory gets chattr +C, so the new clone directory/files inherit NOCOW.
    local epochs = mnt .. "/epochs"
    must("mkdir " .. epochs)
    local stored = epochs .. "/epoch0"
    local machine = cartesi.machine({ ram = { length = 1 << 20 } })
    machine:store(stored)
    machine = nil
    collectgarbage()
    must("chattr +C " .. epochs)
    local ok2, err2 = pcall(function() cartesi.machine:clone_stored(stored, stored .. ".revert") end)
    if not ok2 then
        print("BUG: machine:clone_stored failed instead of falling back to copy: " .. tostring(err2))
        failures = failures + 1
    else
        local m2 = cartesi.machine(stored .. ".revert")
        local m1 = cartesi.machine(stored)
        assert(m1:get_root_hash() == m2:get_root_hash(), "cloned root hash mismatch")
        print("OK: clone_stored fell back to copy")
    end
end)
collectgarbage()
sh("umount " .. mnt)
sh("rm -f " .. img)
sh("rmdir " .. mnt .. " 2>/dev/null")
if not ok then io.stderr:write("ERROR: " .. tostring(err) .. "\n"); os.exit(3) end
os.exit(failures == 0 and 0 or 1)
