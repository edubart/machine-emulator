-- Rollback (revert_fork in cartesi-machine.lua, machine_pair:revert in prt.lua) shuts down the
-- working server (releasing its ephemeral port A) and then asks the forked backup to rebind to A.
-- Anything that binds A in that gap makes the rollback fail with EADDRINUSE.
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")

local m0 = assert(jsonrpc.spawn_server("127.0.0.1:0"))
m0:set_cleanup_call(jsonrpc.SHUTDOWN)
m0:create({ ram = { length = 1 << 20 } })
local machine = m0
local h0 = machine:get_root_hash()

-- snapshot
local backup = assert(machine:fork_server())
backup:set_cleanup_call(jsonrpc.SHUTDOWN)
machine:write_reg("x1", 5)
assert(machine:get_root_hash() ~= h0)

-- revert, exactly as revert_fork.__index:revert() / machine_pair_methods:revert()
local address = machine:get_server_address()
print("working server address:", address)
machine:shutdown_server()
-- In the gap, another JSON-RPC server on the host (e.g. another validator node) gets port A.
local squatter = assert(jsonrpc.spawn_server(address))
squatter:set_cleanup_call(jsonrpc.SHUTDOWN)
print("squatter bound to:", squatter:get_server_address())
machine:swap(backup)
backup = nil
local ok, err = pcall(machine.rebind_server, machine, address)
print("rebind_server:", ok, err)
print("machine address after revert:", machine:get_server_address(),
    "root hash restored:", machine:get_root_hash() == h0)
squatter:shutdown_server()
if machine:get_server_address() ~= address then machine:shutdown_server() end
if not ok then
    print("BUG: rollback could not rebind the backup to the released ephemeral port " .. address .. ": " .. tostring(err))
    os.exit(1)
end
machine:shutdown_server()
print("OK")
