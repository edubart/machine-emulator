-- Repro: cartesi.fromjson truncates input at first NUL byte
local cartesi = require("cartesi")
local bugs = 0
local function check(desc, s)
    local ok, v = pcall(cartesi.fromjson, s)
    if ok then
        print(string.format("BUG: %s accepted (len=%d), parsed a=%s", desc, #s, tostring(type(v)=="table" and v.a)))
        bugs = bugs + 1
    else
        print("ok: " .. desc .. " rejected: " .. tostring(v))
    end
end
-- control: trailing garbage without NUL is rejected
check("trailing garbage without NUL", '{"a":1} x')
-- with NUL
check("trailing garbage after NUL", '{"a":1}\0{"zzz')
check("zero-filled tail (file extended with NULs)", '{"a":1}' .. string.rep("\0", 4096))
-- with a schema, as used by hash-tree.lua (Base64Array)
local ok, v = pcall(cartesi.fromjson, '["AAAA"]\0["BBBB", garbage', "Base64Array")
if ok then
    print("BUG: Base64Array with trailing NUL+garbage accepted, #v=" .. #v); bugs = bugs + 1
else print("ok: Base64Array rejected: " .. tostring(v)) end
if bugs > 0 then os.exit(1) end
print("PASS")
