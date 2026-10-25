-- Proves: the Lua JSON layer (fromjson/tojson) emits negative integers for uint64 fields >= 2^63.
-- Run from the repo root:
--   eval $(make -s env); timeout 120 lua5.4 bugs/p3-08-tojson-uint64-written-as-negative/test.lua
-- Exit status 1 means the bug reproduced, 0 means it is fixed.
local cartesi = require("cartesi")
local fail = false

local function negative_fields(s)
    local t = {}
    for k, v in s:gmatch('"([%w_]+)"%s*:%s*(%-%d+)') do t[#t + 1] = k .. "=" .. v end
    return t
end

-- 1) Library level: config obtained from the C API, written back with cartesi.tojson
local m = cartesi.machine({ ram = { length = 1 << 20 } })
local cfg = m:get_initial_config()
local negs = negative_fields(cartesi.tojson(cfg, 2))
print("tojson(get_initial_config()) negative fields: " .. (#negs > 0 and table.concat(negs, ", ") or "none"))
print("Lua value of processor.registers.ilrsc = " .. tostring(cfg.processor.registers.ilrsc) ..
    " (C API value is 2^64-1 = 18446744073709551615)")
if #negs > 0 then fail = true end

-- 2) CLI level: cartesi-machine --store-config=...,format:json
local out = os.tmpname()
os.remove(out)
out = out .. ".json"
local ok = os.execute("timeout 60 cartesi-machine.lua --ram-length=1Mi --no-init-splash --max-mcycle=0 "
    .. "--store-config=" .. out .. ",format:json >/dev/null 2>&1")
if not ok then
    os.execute("timeout 60 cartesi-machine.lua --ram-length=64Mi --max-mcycle=0 --store-config="
        .. out .. ",format:json >/dev/null 2>&1")
end
local f = io.open(out, "r")
if f then
    local s = f:read("a"); f:close()
    os.remove(out)
    local cn = negative_fields(s)
    print("cartesi-machine --store-config JSON negative fields: " .. (#cn > 0 and table.concat(cn, ", ") or "none"))
    if #cn > 0 then fail = true end
else
    print("note: CLI did not produce " .. out)
end

if fail then
    print("BUG: Lua tojson writes uint64 fields >= 2^63 as negative JSON integers (violates UnsignedInteger schema)")
    os.exit(1)
end
print("OK: no negative values for unsigned fields")
os.exit(0)
