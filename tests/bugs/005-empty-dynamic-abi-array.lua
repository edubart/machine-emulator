-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Independent canonical input and successful controls, not just an encoder round trip.
local e = require('cartesi.evmu')
local canonical = string.rep('\0', 31) .. '\32' .. string.rep('\0', 32)
for _, spec in ipairs({ '(string[])', '(bytes[])', '(string[][])', '((uint256,string)[])' }) do
    assert(e.encode_abi(spec, { {} }) == canonical)
    local ok, err = pcall(e.decode_abi, spec, canonical)
    print(spec, 'decoded:', ok, err)
    assert(not ok and tostring(err):find('ABI data too long', 1, true))
end
local integers = e.decode_abi('(uint256[])', canonical)
assert(type(integers[1]) == 'table' and #integers[1] == 0)
local strings = e.decode_abi('(string[])', e.encode_abi('(string[])', { { 'hello', '' } }))
assert(strings[1][1] == 'hello' and strings[1][2] == '')
local signature = 'f(string[])'
local calldata = e.encode_calldata(signature, { {} })
assert(calldata:sub(5) == canonical)
local ok, err = pcall(e.decode_calldata, signature, calldata)
print(signature, 'decoded:', ok, err)
assert(not ok and tostring(err):find('calldata too long', 1, true))
print('controls passed: empty uint256[] and nonempty string[]')
print('BUG 005 reproduced: canonical empty dynamic-element arrays are rejected')
