local e = require("cartesi.evmu")
local b = e.bint
local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end

-- 1. bint.new(true) should raise
local ok, r = pcall(b.new, true)
print("bint.new(true):", ok, r)
if ok then bug("bint.new(true) returned " .. tostring(r) .. " instead of raising") end

-- 2. bint.new({}) should raise / not return same table
local t = {}
ok, r = pcall(b.new, t)
print("bint.new({}):", ok, r, ok and rawequal(r, t), ok and b.isbint(r))
if ok then bug("bint.new({}) returned a non-bint table (same ref=" .. tostring(rawequal(r, t)) .. ")") end

-- 3. equality on non-numeric values passes silently
ok, r = pcall(function() return e.bint(true) == e.bint(true) end)
print("bint(true)==bint(true):", ok, r)
if ok and r == true then bug("evmu.bint(true) == evmu.bint(true) is true (malformed values compare equal)") end

-- 4. evmu.hex wrapper as uint argument
local h = e.hex("0x05")
ok, r = pcall(b.new, h)
print("bint.new(evmu.hex('0x05')):", ok, r, ok and rawequal(r, h))
if ok then bug("bint.new(evmu.hex('0x05')) returned the hex wrapper unchanged") end

ok, r = pcall(e.encode_abi, "(uint256)", { h })
print("encode_abi((uint256),{hex}):", ok, r)
if not ok and not tostring(r):find("not an integer") and not tostring(r):find("cannot be represented") then
  bug("encode_abi with hex wrapper fails with unrelated error: " .. tostring(r))
end
ok, r = pcall(e.encode_abi, "(int256)", { true })
print("encode_abi((int256),{true}):", ok, r)
if not ok and not tostring(r):find("not an integer") and not tostring(r):find("cannot be represented") then
  bug("encode_abi with boolean fails with unrelated error: " .. tostring(r))
end

if bugs > 0 then os.exit(1) end
print("OK")
