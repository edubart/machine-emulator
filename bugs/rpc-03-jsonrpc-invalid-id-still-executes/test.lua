-- Repro: a JSON-RPC request with an invalid "id" (not string/number/null) is answered with an
-- "invalid request" error, yet the method is still executed. In a batch, the single request gets
-- two responses (the error and the method result).
--
-- Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua
-- Requires curl and the cartesi-jsonrpc-machine server in PATH. Exits 1 when the bug reproduces.
local jsonrpc = require("cartesi.jsonrpc")

local reqfile = os.tmpname()

local function curl(addr, body)
    local f = assert(io.open(reqfile, "w"))
    f:write(body)
    f:close()
    local p = assert(
        io.popen(
            "timeout 10 curl -s -X POST -H 'Content-Type: application/json' --data-binary @"
                .. reqfile
                .. " http://"
                .. addr
        )
    )
    local out = p:read("a")
    p:close()
    return out
end

local m = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
m:create({ ram = { length = 1 << 20 } }, {})
local addr = m:get_server_address()
assert(m:read_reg("x1") == 0)

local status = 0
-- 1) Single request with invalid id (boolean)
local resp = curl(addr, '{"jsonrpc":"2.0","method":"machine.write_reg","id":true,"params":["x1",77]}')
print("single response: " .. resp)
local x1 = m:read_reg("x1")
print("x1 after rejected request: " .. x1)
if resp:find("invalid field") and x1 == 77 then
    print("BUG: request rejected as invalid (bad id) but write_reg was executed anyway (x1=77)")
    status = 1
end

-- 2) Batch with one invalid-id request: count responses
resp = curl(addr, '[{"jsonrpc":"2.0","method":"machine.write_reg","id":{},"params":["x2",55]}]')
print("batch response: " .. resp)
local n = select(2, resp:gsub('"jsonrpc"', ""))
local x2 = m:read_reg("x2")
print("responses in batch for 1 request: " .. n .. ", x2=" .. x2)
if n ~= 1 then
    print("BUG: batch with one invalid-id request produced " .. n .. " responses")
    status = 1
end
if x2 == 55 then
    print("BUG: batch request with invalid id executed (x2=55)")
    status = 1
end
os.remove(reqfile)
if status == 0 then print("OK: bug not reproduced") end
os.exit(status)
