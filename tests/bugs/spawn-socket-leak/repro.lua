-- Independent reproducer for CONC-4 (verify-conc), deterministic part.
-- A single-threaded client holding an open JSON-RPC connection to server A spawns server B.
-- B (the forked grand-child that keeps serving) owns a duplicate of the client's socket connected to A,
-- because Asio sockets are not CLOEXEC and posix_spawnp is called without file actions.
-- Usage: lua5.4 repro.lua
local jsonrpc = require("cartesi.jsonrpc")
local function self_pid() local f = io.open("/proc/self/stat"); local s = f:read("l"); f:close(); return tonumber(s:match("^(%d+)")) end
local function socket_inodes(pid)
    local set, n = {}, 0
    local p = io.popen("ls -l /proc/" .. pid .. "/fd 2>/dev/null")
    for line in p:lines() do
        local fd, ino = line:match("(%d+) %-> socket:%[(%d+)%]")
        if ino and tonumber(fd) > 2 then set[ino] = tonumber(fd); n = n + 1 end -- ignore stdio
    end
    p:close()
    return set, n
end
local me = self_pid()
local A <close>, addrA, pidA = jsonrpc.spawn_server()
A:get_server_version() -- keep-alive connection client <-> A stays open
local mine, nmine = socket_inodes(me)
print(string.format("client pid %d holds %d socket(s) (its connection to server A %s, pid %d)", me, nmine, addrA, pidA))
local B <close>, addrB, pidB = jsonrpc.spawn_server()
B:get_server_version()
local theirs, ntheirs = socket_inodes(pidB)
print(string.format("server B pid %d (%s) holds %d socket(s)", pidB, addrB, ntheirs))
local leaked = 0
for ino, fd in pairs(mine) do
    if theirs[ino] then
        leaked = leaked + 1
        print(string.format("  client socket inode %s (client fd %d) is also open in server B as fd %d", ino, fd, theirs[ino]))
    end
end
B:shutdown_server(); A:shutdown_server()
if leaked > 0 then
    print("BUG REPRODUCED: spawned server inherited the client's connection to another server")
    os.exit(1, true)
end
print("NOT REPRODUCED"); os.exit(0, true)
