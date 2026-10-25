-- Proof for rpc-04: JSON-RPC protocol version not bumped although the branch
-- adds machine.clear_hash_tree and runtime_config.clear_hash_tree.
--
-- Usage (env.sh sourced):
--   CARTESI_JSONRPC_MACHINE=<path to a cartesi-jsonrpc-machine built from origin/main> lua5.4 test.lua
--
-- The branch client (cartesi.jsonrpc from this tree) spawns the OLD server.
-- Expected (fixed): the version handshake refuses the old server, because the
-- client needs a protocol the old server does not implement.
-- Actual (bug): the handshake passes (both say 0.8), create() with
-- runtime {clear_hash_tree=true} silently succeeds, the option is dropped
-- (get_runtime_config().clear_hash_tree == false), and only a later explicit
-- clear_hash_tree() call fails with "method not found".

local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")

local old = os.getenv("CARTESI_JSONRPC_MACHINE")
if not old then
    io.stderr:write("set CARTESI_JSONRPC_MACHINE to a server built from origin/main\n")
    os.exit(2)
end
print("client library version:", cartesi.VERSION)
print("server binary:", old)

local ok, m = pcall(function()
    return jsonrpc.spawn_server("127.0.0.1:0", 10000):set_cleanup_call(jsonrpc.SHUTDOWN)
end)
if not ok then
    print("spawn_server refused old server: " .. tostring(m))
    if tostring(m):find("version", 1, true) then
        print("OK: version handshake rejects a server lacking clear_hash_tree")
        os.exit(0)
    end
    print("unexpected error")
    os.exit(3)
end
m:set_timeout(10000)
local sv = m:get_server_version()
print(string.format("handshake accepted, server protocol version %d.%d.%d", sv.major, sv.minor, sv.patch))

local bugs = 0
local ok2, err2 = pcall(function()
    m:create({ ram = { length = 0x10000 } }, { clear_hash_tree = true })
end)
if not ok2 then
    print("create with clear_hash_tree refused: " .. tostring(err2))
else
    local rc = m:get_runtime_config()
    print("create({...}, {clear_hash_tree=true}) succeeded; get_runtime_config().clear_hash_tree =", rc.clear_hash_tree)
    if rc.clear_hash_tree ~= true then
        print("BUG: runtime option clear_hash_tree=true silently ignored by a server that passed the version handshake")
        bugs = bugs + 1
    end
    local ok3, err3 = pcall(function() m:clear_hash_tree() end)
    if not ok3 then
        print("clear_hash_tree() failed only now: " .. tostring(err3))
        print("BUG: client accepted a server (same protocol 0.8) that does not implement machine.clear_hash_tree")
        bugs = bugs + 1
    end
end
pcall(function() m:shutdown_server() end)
os.exit(bugs == 0 and 0 or 1)
