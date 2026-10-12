-- Regression test: rpc.discover's info.version must match the JSON-RPC protocol version the server
-- reports via get_version (and that clients check on connect).
-- Run (from repo root, after sourcing bugs/env/env.sh):  lua5.4 test-discover-version.lua
-- Prints "BUG REPRODUCED" and exits 1 on mismatch, "OK" and exits 0 when they match. Needs curl.
local jsonrpc = require("cartesi.jsonrpc")

local server <close>, address = jsonrpc.spawn_server("127.0.0.1:0")
server:set_cleanup_call(jsonrpc.SHUTDOWN)

local v = server:get_server_version()
local server_version = string.format("%d.%d.%d", v.major, v.minor, v.patch)

local body = '{"jsonrpc":"2.0","id":1,"method":"rpc.discover","params":[]}'
local f = assert(io.popen(
    string.format("curl -s -X POST -H 'Content-Type: application/json' --data '%s' http://%s/", body, address)
))
local out = f:read("a")
f:close()
-- Extract result.info.version (the first "version" key in the document is info.version)
local discover_version = out:match('"info"%s*:%s*{.-"version"%s*:%s*"([^"]*)"')
assert(discover_version, "could not parse rpc.discover response: " .. out:sub(1, 200))

print("get_version:                " .. server_version)
print("rpc.discover info.version:  " .. discover_version)
if discover_version ~= server_version then
    print("BUG REPRODUCED: rpc.discover advertises a different protocol version than get_version")
    os.exit(1, true)
end
print("OK")
os.exit(0, true)
