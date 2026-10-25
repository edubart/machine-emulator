-- Repro: mapped_memory::clear() punches holes in shared dense-hash-tree backing files.
-- After cm_clear_hash_tree on a SHARING_ALL machine, if the freed blocks are consumed
-- (full filesystem), the next get_root_hash rewrites dht nodes through MAP_SHARED and
-- the process is killed by SIGBUS instead of getting an error.
--
-- Requires root (mounts a 96 MiB tmpfs at <this dir>/mnt and unmounts it afterwards).
-- Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua
-- Exit 1 = bug reproduced (SIGBUS), 0 = fixed, 77 = skipped (not root), 2 = unexpected.
local cartesi = require("cartesi")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local mnt = here .. "/mnt"
local stored = mnt .. "/m"

local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    return ok, how, code
end

local function fill(name)
    -- fill filesystem to ENOSPC
    sh("dd if=/dev/zero of=" .. mnt .. "/" .. name .. " bs=4096 2>/dev/null; sync")
end

local function avail()
    local p = io.popen("df -B1 --output=avail " .. mnt .. " | tail -1")
    local v = tonumber(p:read("a"))
    p:close()
    return v
end

if arg[1] == "child" then
    -- arg[2]: "refill" to consume blocks freed by clear_hash_tree, "norefill" control
    local m <close> = cartesi.machine(stored, {}, cartesi.SHARING_ALL)
    -- First root hash computation writes every dense node through the shared mapping,
    -- allocating all dht blocks while the filesystem still has space.
    local before = m:get_root_hash()
    -- Now the filesystem becomes full (another process / logs / snapshots consume space).
    fill("filler")
    io.stderr:write(string.format("child: avail after fill:   %d\n", avail()))
    -- Sanity: with a full filesystem the machine still works, because dht blocks are allocated.
    assert(m:get_root_hash() == before)
    io.stderr:write("child: get_root_hash ok on full filesystem before clear\n")
    m:clear_hash_tree()
    io.stderr:write(string.format("child: avail after clear:  %d (blocks freed by PUNCH_HOLE)\n", avail()))
    if arg[2] == "refill" then
        fill("filler2")
        io.stderr:write(string.format("child: avail after refill: %d\n", avail()))
    end
    io.stderr:flush()
    local ok, after = pcall(m.get_root_hash, m)
    if not ok then
        io.stderr:write("child: get_root_hash raised error: " .. tostring(after) .. "\n")
        os.exit(3)
    end
    if after ~= before then
        io.stderr:write("child: root hash mismatch after clear\n")
        os.exit(4)
    end
    io.stderr:write("child: get_root_hash after clear ok\n")
    os.exit(0)
end

-- parent
sh("umount " .. mnt .. " 2>/dev/null")
sh("mkdir -p " .. mnt)
local ok = sh("mount -t tmpfs -o size=96m tmpfs " .. mnt)
if not ok then
    print("SKIP: cannot mount tmpfs (need root)")
    os.exit(77)
end
local function cleanup()
    sh("umount " .. mnt .. " 2>/dev/null")
end

do
    local m <close> = cartesi.machine({
        ram = { length = 16 << 20 },
        processor = { registers = { mvendorid = -1 } },
    })
    m:store(stored, cartesi.SHARING_ALL)
end

local lua = "lua5.4"
local function run_child(mode)
    local okc, how, code = sh("timeout 60 " .. lua .. " " .. arg[0] .. " child " .. mode)
    return okc, how, code
end

-- control: no refill -> should succeed
local c_ok, c_how, c_code = run_child("norefill")
print(string.format("control (no refill): %s %s %s", tostring(c_ok), c_how, tostring(c_code)))

-- reset filesystem state: remove second filler if any, refill
sh("rm -f " .. mnt .. "/filler " .. mnt .. "/filler2")

local b_ok, b_how, b_code = run_child("refill")
print(string.format("refill case: %s %s %s", tostring(b_ok), b_how, tostring(b_code)))
cleanup()

-- SIGBUS = 7; timeout reports 128+7=135 when child died of signal under timeout
if not (c_how == "exit" and c_code == 0) then
    print("UNEXPECTED: control run failed")
    os.exit(2)
end
local sigbus = (b_how == "signal" and b_code == 7) or (b_how == "exit" and b_code == 135)
if sigbus then
    print("BUG: get_root_hash after clear_hash_tree on a full filesystem killed the process with SIGBUS "
        .. "(fallocate PUNCH_HOLE freed dht blocks that must be re-allocated from a page fault)")
    os.exit(1)
end
if b_how == "exit" and b_code == 0 then
    print("OK: no crash")
    os.exit(0)
end
if b_how == "exit" and b_code == 3 then
    print("OK: error reported instead of crash")
    os.exit(0)
end
print("UNEXPECTED child result")
os.exit(2)
