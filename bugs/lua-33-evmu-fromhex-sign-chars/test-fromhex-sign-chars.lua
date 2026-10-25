local evmu = require("cartesi.evmu")
local bugs = 0
local function bug(fmt, ...) bugs = bugs + 1; print("BUG: " .. string.format(fmt, ...)) end

-- 1) '+' sign accepted as a hex digit group
local ok, r, e = pcall(evmu.decode_hex, "0x+f")
print("decode_hex('0x+f') ->", ok, r and string.format("%q", r), e)
if ok and r ~= nil then bug("decode_hex accepted '0x+f' as %q (should return nil,err)", r) end

-- 2) '-0' accepted
ok, r, e = pcall(evmu.decode_hex, "0x-0")
print("decode_hex('0x-0') ->", ok, r and string.format("%q", r), e)
if ok and r ~= nil then bug("decode_hex accepted '0x-0' as %q (should return nil,err)", r) end

-- 3) '-1' raises instead of nil,err
ok, r, e = pcall(evmu.decode_hex, "0x-1")
print("decode_hex('0x-1') ->", ok, r, e)
if not ok then bug("decode_hex('0x-1') raised %s instead of returning nil,err", tostring(r)) end

-- 4) the same through encode of a hex-typed argument (address)
local addr = "0x" .. string.rep("+f", 20)
ok, r = pcall(evmu.encode_calldata_hex, "f(address)", { addr })
print("encode_calldata_hex('f(address)', {"..addr.."}) ->", ok, r)
if ok then bug("encode_calldata accepted malformed address %s, encoded as %s", addr, r) end

os.exit(bugs == 0 and 0 or 1)
