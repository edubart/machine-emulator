-- Proves evmu ABI decoder accepts non-canonical encodings (dirty address bits, dirty bytesN/bytes/string padding)
local evmu = require("cartesi.evmu")
local fails = 0
local function z(n) return ("\0"):rep(n) end
local function u(n) return z(31) .. string.char(n) end
local function check(desc, spec, data, fn)
    local ok, v = pcall(fn or evmu.decode_abi, spec, data)
    if ok then
        local shown = type(v) == "table" and tostring(v[1]) or tostring(v)
        print(("BUG: %s accepted (decoded %q)"):format(desc, shown))
        fails = fails + 1
    else
        print(("ok: %s rejected: %s"):format(desc, tostring(v)))
    end
end
-- sanity: strict types reject dirty words
check("(bool) value 2 [control]", "(bool)", u(2))
check("(uint8) value 256 [control]", "(uint8)", z(30) .. "\1\0")
-- address with dirty upper 12 bytes
local addr = ("\x11"):rep(20)
local clean = evmu.decode_abi("(address)", z(12) .. addr)[1]

print("clean address:", clean)
check("(address) with 0xff upper 12 bytes", "(address)", ("\xff"):rep(12) .. addr)
-- bytes4 with dirty low 28 bytes
check("(bytes4) with non-zero padding", "(bytes4)", "\xde\xad\xbe\xef" .. ("\x01"):rep(28))
-- string with non-zero padding: offset=32, length=1, data 'a' + 31 bytes of 0xff
check("(string) with non-zero padding", "(string)", u(32) .. u(1) .. "a" .. ("\xff"):rep(31))
-- bytes with non-zero padding
check("(bytes) with non-zero padding", "(bytes)", u(32) .. u(1) .. "a" .. ("\xff"):rep(31))
-- same via decode_calldata on a Notice
local sel = evmu.encode_calldata("Notice(bytes)", {"0x61"}):sub(1, 4)
check("decode_calldata Notice(bytes) dirty padding", "Notice(bytes)", sel .. u(32) .. u(1) .. "a" .. ("\xff"):rep(31),
    function(s, d) return evmu.decode_calldata(s, d, "raw") end)
-- Malleability: different byte strings decoding to same value
local a = evmu.decode_abi("(bytes)", u(32) .. u(1) .. "a" .. z(31), "raw")[1]
local b = evmu.decode_abi("(bytes)", u(32) .. u(1) .. "a" .. ("\xff"):rep(31), "raw")[1]
if a == b then print("BUG: two distinct encodings decode to the same bytes value " .. ("%q"):format(a)) fails = fails + 1 end
if fails > 0 then print(("BUG: decoder accepted %d non-canonical encodings"):format(fails)); os.exit(1) end
print("PASS"); os.exit(0)
