-- Regression test: out-of-range log2 bundle counts passed to collect_mcycle_bundle /
-- collect_uarch_cycle_bundle must be rejected, not silently truncated to 32 bits.
-- Covers: Lua local binding, Lua remote binding (cartesi.jsonrpc), and raw JSON-RPC requests (curl).
-- Run (from repo root, after sourcing bugs/env/env.sh):  lua5.4 test-bundle-log2-truncation.lua
-- Prints "BUG REPRODUCED" and exits 1 on buggy behaviour, "OK" and exits 0 when fixed. Needs curl.
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")

local config = { ram = { length = 0x1000 } }
local TWO32 = 1 << 32
-- 2^32+1 truncates to 1 and 2^32+2 truncates to 2 (both valid), so a buggy build accepts them
local cases = {
    { name = "collect_mcycle_bundle", args = { 0, 0, TWO32 + 1 } },
    { name = "collect_uarch_cycle_bundle", args = { 0, TWO32 + 2 }, tail = true },
}
-- collect_uarch_cycle_bundle needs a revert uarch tail; its contents do not matter for this test
local function args_of(m, case)
    if case.tail then
        local h = m:read_revert_root_hash()
        return case.args[1], case.args[2], { h, h }
    end
    return table.unpack(case.args)
end

local bugs = 0
local function check(label, machine, case, call)
    local mcycle_before = machine:read_reg("mcycle")
    local ok, res = pcall(call)
    local mcycle_after = machine:read_reg("mcycle")
    if ok then
        bugs = bugs + 1
        print(
            string.format(
                "%s %s(%s): accepted, %d hashes returned, mcycle %d -> %d",
                label,
                case.name,
                table.concat(case.args, ", "),
                type(res) == "table" and #res or -1,
                mcycle_before,
                mcycle_after
            )
        )
    else
        print(string.format("%s %s: rejected: %s", label, case.name, tostring(res)))
        if mcycle_after ~= mcycle_before then
            bugs = bugs + 1
            print("  ... but machine advanced")
        end
    end
end

-- Lua local and Lua remote bindings
local server <close>, address = jsonrpc.spawn_server("127.0.0.1:0")
server:set_cleanup_call(jsonrpc.SHUTDOWN)
for _, case in ipairs(cases) do
    local m <close> = cartesi.machine(config)
    check("lua-local ", m, case, function() return m[case.name](m, args_of(m, case)) end)
    local r = server:create(config)
    check("lua-remote", r, case, function() return r[case.name](r, args_of(r, case)) end)
    r:destroy()
end

-- Raw JSON-RPC requests (bypass the client-side Lua/C API, exercise the server handler parsing)
local function rpc(method, params)
    local body = string.format('{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}', method, params)
    local f = assert(io.popen(string.format("curl -s -X POST -H 'Content-Type: application/json' --data '%s' http://%s/", body, address)))
    local out = f:read("a")
    f:close()
    return out
end
local Z = '"' .. string.rep("A", 43) .. '="'
local raw_cases = {
    { name = "collect_mcycle_bundle", params = string.format("[0,0,%d]", TWO32 + 1) },
    { name = "collect_uarch_cycle_bundle", params = string.format("[0,%d,[%s,%s]]", TWO32 + 2, Z, Z) },
}
for _, case in ipairs(raw_cases) do
    local r = server:create(config)
    local mcycle_before = r:read_reg("mcycle")
    local out = rpc("machine." .. case.name, case.params)
    local mcycle_after = r:read_reg("mcycle")
    if out:find('"result"', 1, true) then
        bugs = bugs + 1
        print(string.format("raw-rpc    %s%s: accepted, mcycle %d -> %d: %s", case.name, case.params, mcycle_before, mcycle_after, out))
    else
        print(string.format("raw-rpc    %s%s: rejected: %s", case.name, case.params, out))
        if mcycle_after ~= mcycle_before then
            bugs = bugs + 1
            print("  ... but machine advanced")
        end
    end
    r:destroy()
end

if bugs > 0 then
    print("BUG REPRODUCED: out-of-range log2 bundle counts silently truncated (" .. bugs .. " cases)")
    os.exit(1, true)
end
print("OK")
os.exit(0, true)
