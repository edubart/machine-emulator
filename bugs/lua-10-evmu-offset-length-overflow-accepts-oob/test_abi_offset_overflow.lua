-- evmu ABI decoder: integer overflow in offset/length bounds checks accepts out-of-bounds offsets/lengths
-- Run from repo root: eval $(make -s env); lua5.4 bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua
-- Exits 1 while the bug is present, 0 once every malformed encoding is rejected.
local evmu = require("cartesi.evmu")

local function word(n) return string.rep("\0", 24) .. string.pack(">I8", n) end
local pad31 = string.rep("\0", 31)

local bugs = 0
local function check(name, spec, data, decode)
    decode = decode or evmu.decode_abi
    local ok, v = pcall(decode, spec, data)
    if ok then
        local parts = {}
        for i = 1, #v do parts[#parts + 1] = tostring(v[i]) end
        print(string.format("BUG: %s: decode accepted malformed data, returned {%s}", name, table.concat(parts, ", ")))
        bugs = bugs + 1
    else
        print(string.format("ok: %s: rejected (%s)", name, tostring(v)))
    end
end

-- sanity: valid encoding round trips
local good = evmu.encode_abi("(bytes,bytes)", { "0xab", "0xcd" })
local gv = evmu.decode_abi("(bytes,bytes)", good)
assert(gv[1] == "0xab" and gv[2] == "0xcd", "sanity failed")

-- Case 1: first offset near 2^63 (far beyond data); read_word's offset+32 wraps negative
local d1 = word(0x7ffffffffffffff0) .. word(0x40) .. word(1) .. "\xcd" .. pad31
check("(bytes,bytes) offset 0x7ffffffffffffff0", "(bytes,bytes)", d1)

-- Case 2: first bytes length 0x7fffffffffffffff; ceil32(len) wraps negative
local d2 = word(0x40) .. word(0x60) .. word(0x7fffffffffffffff) .. word(1) .. "\xcd" .. pad31
check("(bytes,bytes) length 0x7fffffffffffffff", "(bytes,bytes)", d2)

-- Case 3: same via string type
local d3 = word(0x7ffffffffffffff0) .. word(0x40) .. word(1) .. "x" .. pad31
check("(string,string) offset 0x7ffffffffffffff0", "(string,string)", d3)

-- Case 4: dynamic array element offset overflow, via decode_calldata
local sel = select(2, evmu.parse_func_sig("f(bytes[],bytes)"))
local d4 = sel .. word(0x40) .. word(0xa0) .. word(1) .. word(0x7fffffffffffffd0) .. word(0) .. word(1) .. "\xcd" .. pad31
check("decode_calldata f(bytes[],bytes) element offset overflow", "f(bytes[],bytes)", d4, evmu.decode_calldata)

-- Case 5: Voucher-like output (address,uint256,bytes) followed by a dummy bytes using bad offset
local d5 = string.rep("\0", 12) .. string.rep("\x11", 20) .. word(5) .. word(0x7fffffffffffffe0) .. word(0x80) .. word(0)
check("(address,uint256,bytes,bytes) payload offset overflow", "(address,uint256,bytes,bytes)", d5)

if bugs > 0 then
    print(string.format("BUG: %d malformed encodings decoded without error (Solidity abi.decode reverts)", bugs))
    os.exit(1)
end
print("PASS: all malformed encodings rejected")
os.exit(0)
