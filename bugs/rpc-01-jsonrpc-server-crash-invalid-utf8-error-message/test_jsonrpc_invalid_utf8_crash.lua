-- Proof: cartesi-jsonrpc-machine dies when a JSON-RPC error message contains invalid UTF-8.
local jsonrpc = require("cartesi.jsonrpc")
local socket = require("socket")
local unpack = table.unpack

local function alive(addr)
    local ok, m = pcall(jsonrpc.connect_server, addr)
    if not ok then return false, m end
    local ok2, err = pcall(function() return m:is_empty() end)
    pcall(function() m:set_cleanup_call(jsonrpc.SHUTDOWN) end)
    return ok2, err
end

local function shutdown(addr)
    pcall(function()
        local m = jsonrpc.connect_server(addr)
        m:shutdown_server()
    end)
end

local failures = 0

-- Scenario 1: raw 2-byte POST body "\xff\xfe"
do
    local srv, addr = jsonrpc.spawn_server()
    srv:set_cleanup_call(jsonrpc.NOTHING)
    srv = nil
    collectgarbage()
    assert(alive(addr), "server not alive before test")
    local host, port = addr:match("^(.*):(%d+)$")
    local c = assert(socket.tcp())
    c:settimeout(5)
    assert(c:connect(host, tonumber(port)))
    local body = "\xff\xfe"
    c:send("POST / HTTP/1.1\r\nHost: " .. addr .. "\r\nContent-Type: application/json\r\nContent-Length: " ..
        #body .. "\r\nConnection: close\r\n\r\n" .. body)
    local resp, err, partial = c:receive("*a")
    c:close()
    resp = resp or partial or ""
    print("scenario 1 response: " .. string.format("%q", resp:sub(1, 300)) .. " err=" .. tostring(err))
    socket.sleep(0.3)
    local ok, e = alive(addr)
    if ok then
        print("scenario 1: server still alive")
        shutdown(addr)
    else
        print("BUG: scenario 1: server at " .. addr .. " died after POST body \\xff\\xfe: " .. tostring(e))
        failures = failures + 1
    end
end

-- Scenario 2: machine:load() of a directory whose config.json has a non-UTF-8 byte
do
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p " .. dir))
    local f = assert(io.open(dir .. "/config.json", "wb"))
    f:write('{"a":\xff}')
    f:close()
    -- local behaviour for reference
    local cartesi = require("cartesi")
    local lok, lerr = pcall(function() return cartesi.machine(dir) end)
    print("local load: ok=" .. tostring(lok) .. " err=" .. string.format("%q", tostring(lerr)))

    local m, addr = jsonrpc.spawn_server()
    local ok, err = pcall(function() return m:load(dir) end)
    print("remote load: ok=" .. tostring(ok) .. " err=" .. string.format("%q", tostring(err)))
    local ok2, e2 = pcall(function() return m:is_empty() end)
    if ok2 then
        print("scenario 2: server still alive")
        pcall(function() m:shutdown_server() end)
    else
        print("BUG: scenario 2: server at " .. addr .. " died after load() of corrupted config.json: " .. tostring(e2))
        failures = failures + 1
        pcall(function() m:set_cleanup_call(jsonrpc.NOTHING) end)
    end
    os.execute("rm -rf " .. dir)
end

if failures > 0 then os.exit(1) end
print("OK: server survived both scenarios")
os.exit(0)
