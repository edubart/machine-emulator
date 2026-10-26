-- Proof: os::clone_file (cartesi.filesystem.clone_file / machine:clone_stored / cm_clone_stored)
-- only falls back to a plain copy on ENOTSUP/EXDEV/EPERM. A reflink refused with EINVAL
-- (btrfs NODATACOW<->COW, XFS rt/DAX) or EAGAIN (OpenZFS block cloning) aborts the clone.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/u2-03-clone-file-no-fallback-einval-eagain/test.lua  (part A needs root + mkfs.btrfs + loop devices)
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")
local W = arg[0]:match("^(.*)/[^/]*$") or "."
local bugs, ran = 0, 0
local function sh(cmd) return os.execute(cmd .. " >/dev/null 2>&1") == true end

-- Part A: real btrfs, destination under a `chattr +C` (NODATACOW) directory
local img, mnt = W .. "/btrfs.img", W .. "/mnt"
local have_btrfs = sh("id -u | grep -qx 0") and sh("command -v mkfs.btrfs") and sh("mkdir -p " .. mnt)
    and sh("truncate -s 256M " .. img) and sh("mkfs.btrfs -q -f " .. img) and sh("mount -o loop " .. img .. " " .. mnt)
if have_btrfs then
    local ok_, err_ = pcall(function()
        assert(sh("mkdir " .. mnt .. "/a " .. mnt .. "/b && chattr +C " .. mnt .. "/b"))
        do
            local m <close> = cartesi.machine({ ram = { length = 0x10000 } })
            m:store(mnt .. "/a/m")
        end
        -- sanity: a plain copy works here (cp --reflink=auto falls back), reflink=always gets EINVAL
        assert(sh("cp --reflink=auto " .. mnt .. "/a/m/config.json " .. mnt .. "/b/cp.json"), "plain copy should work")
        ran = ran + 1
        local ok, err = pcall(fs.clone_file, mnt .. "/a/m/config.json", mnt .. "/b/config.json")
        if not ok then
            bugs = bugs + 1
            print("BUG: [btrfs +C] filesystem.clone_file raised instead of copying: " .. tostring(err))
        else
            print("ok: [btrfs +C] filesystem.clone_file succeeded")
        end
        ran = ran + 1
        ok, err = pcall(cartesi.machine.clone_stored, cartesi.machine, mnt .. "/a/m", mnt .. "/b/m")
        if not ok then
            bugs = bugs + 1
            print("BUG: [btrfs +C] machine:clone_stored raised instead of copying: " .. tostring(err))
        else
            local m <close> = cartesi.machine(mnt .. "/b/m")
            print("ok: [btrfs +C] machine:clone_stored succeeded")
        end
    end)
    sh("umount " .. mnt); os.remove(img); sh("rmdir " .. mnt)
    if not ok_ then error(err_) end
else
    sh("umount " .. mnt); os.remove(img); sh("rmdir " .. mnt)
    print("note: skipping real-btrfs part (needs root, mkfs.btrfs, loop devices)")
end

-- Part B: LD_PRELOAD shim making FICLONE fail with EINVAL (22) / EAGAIN (11); control ENOTSUP (95)
local shim = W .. "/ficlone_shim.so"
assert(sh("gcc -shared -fPIC -O2 -o " .. shim .. " " .. W .. "/ficlone_shim.c -ldl"), "cannot build shim")
local dir = fs.temp_pathname()
assert(sh("mkdir -p " .. dir))
local src = dir .. "/src.bin"
local f = assert(io.open(src, "wb")); f:write("payload"); f:close()
assert(sh("chmod 644 " .. src))
local child = [[local fs=require"cartesi.filesystem"; local ok,e=pcall(fs.clone_file,arg[1],arg[2]);
if not ok then io.write("ERR ",tostring(e)) os.exit(1) end
local f=assert(io.open(arg[2],"rb")); local d=f:read("a"); f:close(); io.write(d=="payload" and "OK" or "BAD") os.exit(d=="payload" and 0 or 1)]]
local cf = dir .. "/child.lua"
f = assert(io.open(cf, "w")); f:write(child); f:close()
for _, c in ipairs({ { 95, "ENOTSUP (control)" }, { 22, "EINVAL" }, { 11, "EAGAIN" } }) do
    local dst = dir .. "/dst" .. c[1]
    local p = assert(io.popen(string.format("timeout 20 env LD_PRELOAD=%s FICLONE_SHIM_ERRNO=%d lua5.4 %s %s %s 2>&1",
        shim, c[1], cf, src, dst)))
    local out = p:read("a"); p:close()
    ran = ran + 1
    if out:match("^OK") then
        print("ok: [shim " .. c[2] .. "] clone_file fell back to copy")
    else
        if c[1] == 95 then error("shim control case failed, shim not working: " .. out) end
        bugs = bugs + 1
        print("BUG: [shim " .. c[2] .. "] clone_file raised instead of copying: " .. out)
    end
end
sh("rm -rf " .. dir)
print(string.format("%d/%d checks failed", bugs, ran))
os.exit(bugs == 0 and 0 or 1)
