-- Repro: os::clone_file hard-links the symlink itself (link() does not follow the last component)
-- when the symlink target is read-only, so a relative symlink cloned into another directory dangles.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/u1-04-clone-file-hardlinks-symlink-instead-of-target/test.lua
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")

-- scratch directory outside the repo (override with BUG_WORKDIR)
local W = os.getenv("BUG_WORKDIR")
if not W then
    local h = assert(io.popen("mktemp -d"))
    W = h:read("l")
    h:close()
end
W = W .. "/tmpwork"
local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok, "command failed: " .. cmd)
end
local function lstat_kind(p)
    local h = io.popen("stat -c %F '" .. p .. "' 2>/dev/null")
    local s = h:read("a")
    h:close()
    return (s:gsub("%s+$", ""))
end
local function read_all(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

sh("rm -rf '" .. W .. "' && mkdir -p '" .. W .. "'")
local bugs = 0

-- Part 1: cartesi.filesystem.clone_file, read-only vs writable symlink targets
sh("mkdir -p '" .. W .. "/images' '" .. W .. "/T' '" .. W .. "/E/deeper'")
sh("printf 'read-only contents' > '" .. W .. "/images/ro.bin' && chmod a-w '" .. W .. "/images/ro.bin'")
sh("printf 'writable contents' > '" .. W .. "/images/rw.bin'")
sh("ln -s ../images/ro.bin '" .. W .. "/T/ro.bin'")
sh("ln -s ../images/rw.bin '" .. W .. "/T/rw.bin'")

fs.clone_file(W .. "/T/rw.bin", W .. "/E/deeper/rw.bin")
fs.clone_file(W .. "/T/ro.bin", W .. "/E/deeper/ro.bin")

local rw_kind = lstat_kind(W .. "/E/deeper/rw.bin")
local ro_kind = lstat_kind(W .. "/E/deeper/ro.bin")
print("writable-target clone kind:  " .. rw_kind .. ", contents: " .. tostring(read_all(W .. "/E/deeper/rw.bin")))
print("read-only-target clone kind: " .. ro_kind .. ", contents: " .. tostring(read_all(W .. "/E/deeper/ro.bin")))
if read_all(W .. "/E/deeper/ro.bin") ~= "read-only contents" then
    print("BUG: clone_file of a symlink to a read-only file produced a '" .. ro_kind ..
        "' that does not resolve to the source contents (link() hard-linked the symlink inode)")
    bugs = bugs + 1
end

-- Part 2: same defect through machine:clone_stored
local S = W .. "/S"
do
    local m <close> = cartesi.machine({ ram = { length = 1 << 20 } })
    m:store(S)
end
local h0
do
    local m <close> = cartesi.machine(S)
    h0 = m:get_root_hash()
end
-- move the read-only PMAs backing file out of the stored dir and replace it with a relative symlink
local pmas = "0000000000010000-1000.bin"
sh("mkdir -p '" .. W .. "/img'")
sh("mv '" .. S .. "/" .. pmas .. "' '" .. W .. "/img/" .. pmas .. "'")
sh("ln -s ../img/" .. pmas .. " '" .. S .. "/" .. pmas .. "'")
do -- the source still loads fine with the symlink in place
    local m <close> = cartesi.machine(S)
    assert(m:get_root_hash() == h0, "source machine with symlink changed hash")
end
sh("mkdir -p '" .. W .. "/deep'")
local C = W .. "/deep/C"
cartesi.machine:clone_stored(S, C)
print("clone_stored PMAs file kind: " .. lstat_kind(C .. "/" .. pmas))
local ok, err = pcall(function()
    local m <close> = cartesi.machine(C)
    return m:get_root_hash()
end)
if not ok then
    print("BUG: clone_stored succeeded but the clone cannot be loaded: " .. tostring(err))
    bugs = bugs + 1
elseif err ~= h0 then
    print("BUG: cloned machine root hash differs from source")
    bugs = bugs + 1
else
    print("clone_stored clone loads with identical hash")
end

sh("chmod -R u+w '" .. W .. "' && rm -rf '" .. W .. "'")
if bugs > 0 then os.exit(1) end
print("OK: no defect")
os.exit(0)
