-- Proves evmu.decode_abi end-offset/trailing-data check defects
local evmu = require("cartesi.evmu")
local function w(n) return string.rep("\0", 24) .. string.pack(">I8", n) end
local function pad(s) return s .. string.rep("\0", (32 - #s % 32) % 32) end
local function bytes(s) return w(#s) .. pad(s) end
local bugs = 0
local function bug(msg) bugs = bugs + 1; print("BUG: " .. msg) end

-- 1) aliasing: both offsets point to same tail -> must be rejected by a strict decoder
local alias = w(0x40) .. w(0x40) .. bytes("\xcd")
local ok, v = pcall(evmu.decode_abi, "(bytes,bytes)", alias)
if ok then bug(("aliased tails accepted: {%s,%s} (%d bytes, only one tail)"):format(v[1], v[2], #alias))
else print("ok: aliased rejected: " .. tostring(v)) end

-- 2) garbage gap between head and tail accepted
local gap = w(0x40) .. string.rep("\xff", 32) .. bytes("\xcd")
ok, v = pcall(evmu.decode_abi, "(bytes)", gap)
if ok then bug("32-byte garbage gap before tail accepted: " .. tostring(v[1]))
else print("ok: gap rejected: " .. tostring(v)) end

-- 3) valid encoding with reversed tails (no trailing data) rejected
local rev = w(0x80) .. w(0x40) .. bytes("\xef") .. bytes("\xcd")
ok, v = pcall(evmu.decode_abi, "(bytes,bytes)", rev)
if not ok then bug("valid out-of-order tails rejected: " .. tostring(v))
else print("ok: reversed accepted {" .. v[1] .. "," .. v[2] .. "}") end

-- 4) valid canonical empty array of dynamic elements: (string[]) = []
local empty = w(0x20) .. w(0)
ok, v = pcall(evmu.decode_abi, "(string[])", empty)
if not ok then bug("canonical empty string[] rejected: " .. tostring(v))
else print("ok: empty string[] accepted") end

-- 5) same via decode_calldata (pre-existing API): Foo(bytes[]) with []
local sel_ok, cd = pcall(function()
  local enc = evmu.encode_calldata and evmu.encode_calldata("Foo(bytes[])", { {} })
  return enc
end)
if sel_ok and cd then
  ok, v = pcall(evmu.decode_calldata, "Foo(bytes[])", cd)
  if not ok then bug("decode_calldata rejects its own encode_calldata output for empty bytes[]: " .. tostring(v))
  else print("ok: decode_calldata empty bytes[]") end
else print("note: encode_calldata unavailable: " .. tostring(cd)) end

-- 6) round trip via encode_abi if available
if evmu.encode_abi then
  local okE, enc = pcall(evmu.encode_abi, "(string[])", { {} })
  if okE then
    ok, v = pcall(evmu.decode_abi, "(string[])", enc)
    if not ok then bug("decode_abi rejects encode_abi output for empty string[]: " .. tostring(v)) end
  else print("note: encode_abi failed: " .. tostring(enc)) end
end

if bugs > 0 then os.exit(1) end
print("PASS")
