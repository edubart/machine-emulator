-- Proves: os::clone_file hard-links the symlink inode (link(2) does not follow symlinks)
-- when the read-only source is reached through a symlink.
local fs = require("cartesi.filesystem")
local cartesi = require("cartesi")

local function sh(cmd) local ok = os.execute(cmd); return ok end
local function out(cmd) local p = io.popen(cmd); local s = p:read("a"); p:close(); return (s:gsub("%s+$", "")) end
local base = out("mktemp -d")
local bug = false
local function report(fmt, ...) print(string.format(fmt, ...)); bug = true end

-- Part 1: cartesi.filesystem.clone_file with a relative symlink to a read-only file
sh(string.format("cd %q && mkdir data caller epoch epoch/inputs && printf X > data/in.bin && chmod 444 data/in.bin && ln -s ../data/in.bin caller/in.bin", base))
fs.clone_file(base .. "/caller/in.bin", base .. "/epoch/inputs/0.bin")
print("ls -l epoch/inputs: " .. out(string.format("ls -l %q/epoch/inputs", base)))
if sh(string.format("test -L %q/epoch/inputs/0.bin", base)) then
    report("BUG: clone_file produced a symlink, not a link to the data: epoch/inputs/0.bin -> %s",
        out(string.format("readlink %q/epoch/inputs/0.bin", base)))
end
local f = io.open(base .. "/epoch/inputs/0.bin", "rb")
if not f then
    report("BUG: cloned file epoch/inputs/0.bin is unreadable (dangling symlink)")
else
    local d = f:read("a"); f:close()
    if d ~= "X" then report("BUG: cloned file has wrong contents %q", tostring(d)) end
end
local ok, err = pcall(fs.sync_file, base .. "/epoch/inputs/0.bin")
if not ok then report("BUG: sync_file of the clone failed: %s", tostring(err)) end

-- Part 2: absolute symlink: clone is just a pointer into caller storage
sh(string.format("cd %q && mkdir abs && ln -s %q/data/in.bin caller/abs.bin", base, base))
fs.clone_file(base .. "/caller/abs.bin", base .. "/abs/0.bin")
if sh(string.format("test -L %q/abs/0.bin", base)) then
    -- replace the caller's data file; an independent clone should keep "X"
    sh(string.format("cd %q && rm -f data/in.bin && printf Y > data/in.bin", base))
    local g = io.open(base .. "/abs/0.bin", "rb"); local d = g and g:read("a"); if g then g:close() end
    report("BUG: absolute-symlink clone is a symlink; after caller replaced its file, clone reads %q (expected \"X\")", tostring(d))
end

-- Part 3: machine:clone_stored on a symlink-farm copy (cp -rs) of a stored machine
local m = cartesi.machine({ ram = { length = 1 << 20 } })
m:store(base .. "/stored")
m:destroy()
print("stored modes: " .. out(string.format("ls -l %q/stored | head -5", base)))
sh(string.format("cp -rs %q/stored %q/farm", base, base))
local okc, errc = pcall(cartesi.machine.clone_stored, cartesi.machine, base .. "/farm", base .. "/cloned")
if not okc then
    print("clone_stored error: " .. tostring(errc))
else
    local links = out(string.format("find %q/cloned -type l | wc -l", base))
    print("symlinks in cloned dir: " .. links)
    if tonumber(links) > 0 then
        report("BUG: clone_stored produced %s symlink(s) in the clone (e.g. %s)", links,
            out(string.format("find %q/cloned -type l | head -1 | xargs ls -l", base)))
    end
    local okl, errl = pcall(cartesi.machine, base .. "/cloned")
    if not okl then report("BUG: loading the cloned machine failed: %s", tostring(errl)) end
end

sh(string.format("chmod -R u+w %q; rm -rf %q", base, base))
if bug then os.exit(1) end
print("OK: no defect")
os.exit(0)
