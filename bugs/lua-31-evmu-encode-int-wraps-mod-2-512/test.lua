-- Proof: evmu integer ABI encoding wraps values >= 2^512 instead of rejecting them
local evmu = require("cartesi.evmu")
local failures = 0
local function check(desc, spec, args, is_abi)
    local ok, res = pcall(function()
        if is_abi then return evmu.encode_hex(evmu.encode_abi(spec, args)) end
        return evmu.encode_calldata_hex(spec, args)
    end)
    if ok then
        print("BUG: " .. desc .. " was accepted and encoded as " .. res)
        failures = failures + 1
    else
        print("ok: " .. desc .. " rejected: " .. tostring(res))
    end
end
-- 2^512 + 5 (does not fit in uint256)
local two512p5 = "0x1" .. ("0"):rep(127) .. "5"
check("uint256 2^512+5 (hex string), encode_abi", "(uint256)", { two512p5 }, true)
check("uint256 2^512+5 (hex string), encode_calldata", "f(uint256)", { two512p5 }, false)
-- 2^512 as decimal string
local dec2_512 = "13407807929942597099574024998205846127479365820592393377723561443721764030073546976801874298166903427690031858186486050853753882811946569946433649006084096"
check("uint256 2^512 (decimal string)", "(uint256)", { dec2_512 }, true)
check("uint8 2^512+5", "(uint8)", { two512p5 }, true)
-- int256: 2^512-1 written as 128 f's -> wraps to -1
check("int256 2^512-1 (hex string)", "(int256)", { "0x" .. ("f"):rep(128) }, true)
-- bint object beyond 2^512 also cannot be represented: show bint.new itself wraps
local b = evmu.bint.new(two512p5)
print("bint.new(2^512+5) =", tostring(b))
if failures > 0 then os.exit(1) end
print("PASS")
