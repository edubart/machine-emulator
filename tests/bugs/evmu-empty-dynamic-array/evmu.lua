-- cartesi.evmu.decode_calldata must decode valid ABI calldata whose argument is an empty dynamic array of dynamic
-- elements (bytes[], string[], (uint256,bytes)[]). In src/cartesi/evmu.lua decode_array only assigns the end offset
-- (last_offset) inside the element loop, so for an empty array it returns nil; decode_tuple propagates it and
-- decode_calldata fails its final length check with "calldata too long".
-- The calldata is built by hand, one 32-byte ABI word at a time, with the selector from cartesi.keccak256, so the
-- decision does not depend on the evmu encoder. Calldata produced by evmu.encode_calldata is decoded as well.
-- usage: lua5.4 evmu.lua     exit 0 = fixed, 1 = bug reproduced, 2 = test error
local cartesi = require("cartesi")
local evmu = require("cartesi.evmu")

local function sel(sig) return cartesi.keccak256(sig):sub(1, 4) end
local function w(n) return string.rep("\0", 24) .. string.pack(">I8", n) end -- one 32-byte ABI word

-- check(v) validates the decoded arguments
local function empty_first(v) return type(v[1]) == "table" and #v[1] == 0 end
local cases = {
    -- f(bytes[]) with []: head = offset 0x20; tail = length 0
    { sig = "f(bytes[])", cd = sel("f(bytes[])") .. w(32) .. w(0), check = empty_first },
    -- f(string[],uint256) with ([], 5): head = offset 0x40, 5; tail = length 0
    {
        sig = "f(string[],uint256)",
        cd = sel("f(string[],uint256)") .. w(64) .. w(5) .. w(0),
        check = function(v) return empty_first(v) and tostring(v[2]) == "5" end,
    },
    -- f((uint256,bytes)[]) with []: head = offset 0x20; tail = length 0
    { sig = "f((uint256,bytes)[])", cd = sel("f((uint256,bytes)[])") .. w(32) .. w(0), check = empty_first },
    -- the same three values, encoded by evmu itself (round trip)
    { sig = "f(bytes[])", args = { {} }, check = empty_first },
    { sig = "f(string[],uint256)", args = { {}, 5 }, check = empty_first },
    { sig = "f((uint256,bytes)[])", args = { {} }, check = empty_first },
    -- controls: an empty array of static elements, a non-empty array of dynamic elements, and an empty array of
    -- dynamic elements followed by another dynamic argument (which hides the missing end offset)
    { sig = "f(uint256[])", cd = sel("f(uint256[])") .. w(32) .. w(0), check = empty_first, control = true },
    {
        sig = "f(bytes[])",
        cd = sel("f(bytes[])") .. w(32) .. w(1) .. w(32) .. w(0),
        check = function(v) return #v[1] == 1 end,
        control = true,
    },
    {
        sig = "f(bytes[],bytes)",
        cd = sel("f(bytes[],bytes)") .. w(64) .. w(96) .. w(0) .. w(0),
        check = empty_first,
        control = true,
    },
}

local bad = 0
for _, c in ipairs(cases) do
    local cd = c.cd
    local how = "hand-built"
    if c.args then
        cd = evmu.encode_calldata(c.sig, c.args)
        how = "evmu-encoded"
    end
    local ok, v = pcall(evmu.decode_calldata, c.sig, cd)
    local good = ok and c.check(v)
    print(string.format("  %-22s %-12s %3d bytes%-10s: %s", c.sig, how, #cd, c.control and " (control)" or "",
        good and "decoded" or (ok and "WRONG VALUE" or ("REJECTED: " .. tostring(v)))))
    if not good then
        if c.control then
            print("ERROR: control case failed: the test itself is broken")
            os.exit(2)
        end
        bad = bad + 1
    end
end
if bad > 0 then
    print("BUG REPRODUCED: evmu.decode_calldata rejects " .. bad .. " valid calldata with an empty array of dynamic elements")
    os.exit(1)
end
print("OK: evmu.decode_calldata decodes empty arrays of dynamic elements")
os.exit(0)
