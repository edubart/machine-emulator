-- bint shift/rotate count wraps modulo 2^64 when given as a bint >= 2^63
local evmu = require("cartesi.evmu")
local bint = evmu.bint
local fails = 0
local function check(name, got, expected)
  if got ~= bint(expected) then
    print(string.format("BUG: %s = %s, expected %s", name, tostring(got), tostring(expected)))
    fails = fails + 1
  else
    print(string.format("ok: %s = %s", name, tostring(got)))
  end
end
local function check_err_or(name, f, expected)
  local ok, got = pcall(f)
  if not ok then print("ok: " .. name .. " raised: " .. tostring(got)) return end
  check(name, got, expected)
end
local two64 = bint(1) << 64
local two64m1 = two64 - 1
-- realistic path: shift count decoded from ABI data
local data = evmu.encode_abi("(uint256)", { two64m1 })
local decoded = evmu.decode_abi("(uint256)", data)[1]
print("decoded count:", tostring(decoded), "type bint:", bint.isbint(decoded))
check_err_or("bint(5) << bint(2^64)", function() return bint(5) << two64 end, 0)
check_err_or("bint(5) << bint(2^64+1)", function() return bint(5) << (two64 + 1) end, 0)
check_err_or("bint(5) << bint(2^64-1)", function() return bint(5) << two64m1 end, 0)
check_err_or("bint(5) >> bint(2^64-1)", function() return bint(5) >> two64m1 end, 0)
check_err_or("bint(5) << decoded_uint256(2^64-1)", function() return bint(5) << decoded end, 0)
check_err_or("bint(1) << bint(2^63) (min int)", function() return bint(1) << (bint(1) << 63) end, 0)
-- trunc of a hex string wider than 64 bits
check_err_or("bint.trunc('0x10000000000000005')", function() return bint.trunc("0x10000000000000005") end,
  bint.new("0x10000000000000005"))
-- tointeger of a big bint silently wraps instead of failing
local ti = bint.tointeger(two64 + 5)
print("bint.tointeger(2^64+5) =", ti)
if fails > 0 then print(string.format("BUG: %d shift-count/conversion wraps detected", fails)) os.exit(1) end
print("no bug")
