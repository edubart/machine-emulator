-- Reproduces: one transient accept() error (EMFILE) permanently closes the
-- cartesi-jsonrpc-machine listening socket, making its machine unreachable.
-- Usage (from the repo root): eval $(make -s env); lua5.4 bugs/w2b-06-jsonrpc-accept-error-kills-server/test.lua
-- Exits 1 when the bug reproduces, 0 when the server is still reachable after EMFILE.
-- Requires prlimit (util-linux) and lua-socket.
local socket = require("socket")
local jsonrpc = require("cartesi.jsonrpc")
local cartesi = require("cartesi")

-- server log goes to a temporary file (removed at exit)
local log = os.tmpname()

-- pick a free port
local s = assert(socket.bind("127.0.0.1", 0))
local _, port = s:getsockname()
s:close()
local address = "127.0.0.1:" .. port

-- spawn the server with a low open-file limit
local cmd = string.format(
    "exec prlimit --nofile=32:32 cartesi-jsonrpc-machine --server-address=%s --log-level=info >%s 2>&1 & echo $!",
    address, log)
local p = io.popen(cmd)
local pid = assert(tonumber(p:read("l")))
p:close()

local function cleanup() os.execute("kill -9 " .. pid .. " 2>/dev/null") os.remove(log) end

-- wait for server
local ok
for _ = 1, 100 do
    local c = socket.tcp()
    c:settimeout(0.1)
    if c:connect("127.0.0.1", port) then c:close() ok = true break end
    c:close()
    socket.sleep(0.05)
end
if not ok then cleanup() print("ERROR: server did not start") os.exit(2) end

-- Create a small machine in the server (the "validator state")
do
    local m = jsonrpc.connect_server(address)
    m:create({ ram = { length = 1 << 20 }, processor = { registers = { x10 = 0x1234 } } })
    print("created remote machine, root hash ok:", #m:get_root_hash() == 32)
end

-- Flood: open many connections at once so accept() hits EMFILE
local conns = {}
for i = 1, 60 do
    local c = socket.tcp()
    c:settimeout(1)
    local r = c:connect("127.0.0.1", port)
    if r then conns[#conns + 1] = c else c:close() end
end
print("opened", #conns, "client connections")
socket.sleep(0.5)
for _, c in ipairs(conns) do c:close() end
conns = nil
collectgarbage()
socket.sleep(1.0)  -- let the server close the sessions and free its fds

-- Now an ordinary client (e.g. a validator) tries to use its machine again
local okc, err = pcall(function()
    local m = jsonrpc.connect_server(address)
    return m:read_reg("x10")
end)
local f = io.open(log) local logtxt = f:read("a") f:close()
local alive = os.execute("kill -0 " .. pid .. " 2>/dev/null")
cleanup()
io.write("---- server log tail ----\n", logtxt:sub(-600), "\n-------------------------\n")
if not okc or err ~= 0x1234 then
    print("server process still alive:", alive and "yes" or "no")
    print("BUG: after transient accept() EMFILE the JSON-RPC server stopped listening; machine unreachable: " .. tostring(err))
    os.exit(1)
end
print("OK: server still reachable after EMFILE, x10=" .. string.format("0x%x", err))
os.exit(0)
