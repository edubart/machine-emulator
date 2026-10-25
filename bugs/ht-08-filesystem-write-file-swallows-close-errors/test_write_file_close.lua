-- Proves cartesi.filesystem.write_file swallows errors from the final flush/fclose.
-- Writing to /dev/full: fwrite of small data only buffers (succeeds); the actual write()
-- happens at fclose (via the <close> handler) and fails with ENOSPC, but Lua 5.4's io
-- library __close ignores the result, so write_file returns normally.
local fs = require("cartesi.filesystem")

local function check_full()
    local f = io.open("/dev/full", "wb")
    if not f then return false end
    f:close()
    return true
end
if not check_full() then
    print("SKIP: /dev/full not available")
    os.exit(0)
end

-- Sanity: explicit close does report the error
do
    local f = assert(io.open("/dev/full", "wb"))
    assert(f:write(string.rep("h", 32)))
    local ok, err = f:close()
    print("explicit f:close() on /dev/full ->", ok, err)
    assert(not ok, "expected explicit close to fail on /dev/full")
end

local data = string.rep("h", 32) -- e.g. a root hash as written by --final-hash
local ok, err = pcall(fs.write_file, data, "/dev/full")
print("fs.write_file(32 bytes, /dev/full) ->", ok, err)
if ok then
    print("BUG: cartesi.filesystem.write_file reported success although the data could not be written (ENOSPC on fclose was swallowed)")
    os.exit(1)
end
print("OK: write_file propagated the write error")
os.exit(0)
