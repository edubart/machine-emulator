-- Rejects <n> inputs through one Lua conversion helper of the cartesi module, each under pcall.
-- usage: lua5.4 cases.lua <case> <n>    (prints "<rejected>" to stdout)
local cartesi = require("cartesi")
local case, n = arg[1], tonumber(arg[2])
local calls = {
    fromjson = function() return cartesi.fromjson("{") end, -- truncated JSON
    tojson = function() return cartesi.tojson("\255") end, -- invalid UTF-8: nlohmann dump() throws
    frombase64 = function() return cartesi.frombase64("@@@@") end,
    fromhex = function() return cartesi.fromhex("zz") end,
    -- control: the C API catches the exception itself and returns an error code; the binding raises afterwards
    capi_error = function() return cartesi.machine({ ram = { length = 4097 } }) end,
}
local f = assert(calls[case], "unknown case")
local rejected = 0
for _ = 1, n do
    if not pcall(f) then rejected = rejected + 1 end
end
print(rejected)
