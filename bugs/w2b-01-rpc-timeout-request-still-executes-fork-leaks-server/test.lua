-- Repro: JSON-RPC client timeouts do not cancel the server-side request.
--  (A) a run() that reported "timeout" still runs to completion on the server
--  (B) a fork_server() that reported "timeout" still forks a full machine server
--      process the client never learns about; after shutdown_server() one
--      cartesi-jsonrpc-machine process keeps running forever (ppid 1).
-- Run from repo root: eval $(make -s env); lua5.4 bugs/w2b-01-rpc-timeout-request-still-executes-fork-leaks-server/test.lua
-- (exit 1 + "BUG:" lines when defect present, exit 0 once fixed)
local jsonrpc = require("cartesi.jsonrpc")
local img = os.tmpname() -- scratch RAM image, removed at exit
local f = assert(io.open(img, "wb")); f:write(string.pack("<I4", 0x6f)); f:close() -- jal x0,0 ("j .")

local function children_of(ppid)
    local out = {}
    local p = io.popen("ps -eo pid=,ppid=,args=")
    for line in p:lines() do
        local pid, pp, args = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
        if pid and tonumber(pp) == ppid then out[#out + 1] = { pid = tonumber(pid), args = args } end
    end
    p:close()
    return out
end
local function alive(pid) -- alive and not a zombie
    local fh = io.open("/proc/" .. pid .. "/stat", "r")
    if not fh then return false end
    local s = fh:read("a"); fh:close()
    local st = s:match("%) (%a)")
    return st ~= nil and st ~= "Z"
end

local bug = false
local server, address, server_pid = jsonrpc.spawn_server()
print("server", address, "pid", server_pid)
server:create({ ram = { length = 1 << 20, backing_store = { data_filename = img } } })
local TARGET = 300000000 -- ~1.3s of emulation

-- (A) run() with a 300 ms timeout
server:set_timeout(300)
local ok, err = pcall(server.run, server, TARGET)
print("run(" .. TARGET .. ") with 300ms timeout -> ok=", ok, "err=", err)
assert(not ok and tostring(err):find("timeout"), "expected a timeout error from run()")

-- (B) fork_server() while the server is still busy with the "timed out" run
local fok, ferr = pcall(server.fork_server, server)
print("fork_server() with 300ms timeout -> ok=", fok, "err=", ferr)
assert(not fok and tostring(ferr):find("timeout"), "expected a timeout error from fork_server()")

-- Wait (no timeout) until the server is responsive again
server:set_timeout(-1)
local mcycle = server:read_reg("mcycle")
print("mcycle after the timed-out run:", mcycle)
if mcycle == TARGET then
    print("BUG: run() reported a timeout, but the server executed it to completion (mcycle=" .. mcycle .. ")")
    bug = true
end

local kids = children_of(server_pid)
for _, k in ipairs(kids) do print("unexpected child of server:", k.pid, k.args) end
if #kids > 0 then
    print("BUG: fork_server() reported a timeout, but the server forked " .. #kids ..
        " machine server process(es) whose pid/address the client never received")
    bug = true
end

-- Shut down the server through the API; every process involved should go away
server:shutdown_server()
server = nil
collectgarbage(); collectgarbage()
local watch = { server_pid }
for _, k in ipairs(kids) do watch[#watch + 1] = k.pid end
local leaked = {}
for _ = 1, 20 do -- up to 2s
    leaked = {}
    for _, pid in ipairs(watch) do if alive(pid) then leaked[#leaked + 1] = pid end end
    if #leaked == 0 then break end
    os.execute("sleep 0.1")
end
for _, pid in ipairs(leaked) do
    local pp = io.popen("ps -o ppid= -p " .. pid):read("l")
    print(string.format("process %d still running after shutdown_server(), ppid=%s", pid, pp))
end
if #leaked > 0 then
    print("BUG: " .. #leaked .. " cartesi-jsonrpc-machine process(es) leaked (orphaned, listening forever)")
    bug = true
end
for _, pid in ipairs(watch) do os.execute("kill -9 " .. pid .. " 2>/dev/null") end -- cleanup
os.remove(img)
if bug then os.exit(1) end
print("OK: timed-out requests were not executed and nothing leaked")
os.exit(0)
