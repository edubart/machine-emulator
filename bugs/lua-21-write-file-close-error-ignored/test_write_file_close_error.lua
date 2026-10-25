-- Proof: cartesi.filesystem.write_file ignores errors reported at close (fflush/fclose),
-- so a short write to a full device "succeeds" and the cartesi-machine CLI exits 0 with no hash file contents.
local fs = require("cartesi.filesystem")
local failed = false

-- 1) Library level: write a 32-byte "hash" to /dev/full (every write fails with ENOSPC)
local ok, err = pcall(fs.write_file, ("h"):rep(32), "/dev/full")
print("write_file(32 bytes, /dev/full) ->", ok, err)
if ok then
    print("BUG: filesystem.write_file reported success writing to /dev/full (ENOSPC at close ignored)")
    failed = true
end

-- Control: raw io shows the error is detectable at close
do
    local f = assert(io.open("/dev/full", "wb"))
    assert(f:write(("h"):rep(32)))
    local cok, cerr = f:close()
    print("control: io close on /dev/full ->", cok, cerr)
end

-- 2) CLI level: --final-hash=<symlink to /dev/full>
local dir = assert(io.popen("mktemp -d")):read("l")
local link = dir .. "/final-hash.bin"
os.remove(link)
assert(os.execute("ln -s /dev/full " .. link))
local cmd = "timeout 60 cartesi-machine.lua --max-mcycle=0 --final-hash="
    .. link .. " >/dev/null 2>&1"
local r, how, code = os.execute(cmd)
print("CLI exit:", r, how, code)
os.remove(link)
os.remove(dir)
if r == true then
    print("BUG: cartesi-machine exited 0 after failing to write --final-hash to a full device")
    failed = true
end

os.exit(failed and 1 or 0)
