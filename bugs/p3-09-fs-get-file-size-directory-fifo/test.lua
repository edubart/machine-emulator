-- Proof: cartesi.filesystem.get_file_size misbehaves on directories and FIFOs.
local fs = require("cartesi.filesystem")
local bug = false

-- 1. Directory: should error (not a regular file), must not return a bogus size.
local dir = os.tmpname(); os.remove(dir)
assert(os.execute("mkdir " .. dir))
local ok, res = pcall(fs.get_file_size, dir)
os.execute("rmdir " .. dir)
print("get_file_size(directory) ->", ok, res)
if ok then
    print(string.format("BUG: get_file_size on a directory returned %s instead of failing", tostring(res)))
    bug = true
end
-- PRT-style check: a directory passes `get_file_size(path) >= committed_size`
if ok and res >= 1 << 40 then
    print("BUG: assert(fs.get_file_size(dir) >= outputs_log_size) would pass for any size")
end

-- 2. FIFO: get_file_size must not block. Run it in a child with a timeout.
local fifo = os.tmpname(); os.remove(fifo)
assert(os.execute("mkfifo " .. fifo))
local cmd = string.format(
    "timeout 3 lua5.4 -e 'local fs=require\"cartesi.filesystem\"; print(pcall(fs.get_file_size, %q))' 2>&1; echo rc=$?",
    fifo)
local p = assert(io.popen(cmd)); local out = p:read("a"); p:close()
os.remove(fifo)
print("get_file_size(fifo) child output:", (out:gsub("\n", " ")))
if out:match("rc=124") then
    print("BUG: get_file_size on a FIFO blocked (killed by 3s timeout)")
    bug = true
end

os.exit(bug and 1 or 0)
