local cartesi = require("cartesi")
local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end

local function tojson_where(w)
  local ok, s = pcall(cartesi.tojson, { brackets = { { type = "begin", where = w, text = "x" } } }, -1, "AccessLog")
  return ok, s
end
local function fromjson_where(js)
  local ok, t = pcall(cartesi.fromjson, '{"brackets":[{"type":"begin","where":' .. js .. ',"text":"x"}]}', "AccessLog")
  if ok then return ok, t.brackets[1].where end
  return ok, t
end

-- sanity
local ok, s = tojson_where(1)
assert(ok and s:find('"where":0'), s)
local ok2, w = fromjson_where("0")
assert(ok2 and w == 1, tostring(w))

-- 1) tojson with math.mininteger: v -= 1 overflows int64 (UB), emits INT64_MAX
ok, s = tojson_where(math.mininteger)
print("tojson(where=math.mininteger) ->", ok, s)
if ok and s:find('"where":9223372036854775807') then
  bug("tojson: Lua where=math.mininteger (index 0-based -9223372036854775809) serialized as where=9223372036854775807 (signed overflow wrap)")
end

-- 2) fromjson with UINT64_MAX: cast to int64 -1, +1 -> 0
ok, w = fromjson_where("18446744073709551615")
print("fromjson(where=18446744073709551615) ->", ok, w)
if ok and w == 0 then
  bug("fromjson: JSON where=18446744073709551615 became Lua where=0 (uint64->int64 cast + 1 wrap)")
end

-- 3) fromjson with INT64_MAX: +1 overflows int64 (UB), becomes negative
ok, w = fromjson_where("9223372036854775807")
print("fromjson(where=9223372036854775807) ->", ok, w)
if ok and math.type(w) == "integer" and w < 0 then
  bug("fromjson: JSON where=9223372036854775807 became negative Lua where=" .. w .. " (signed overflow wrap)")
end

-- 4) fromjson with 9223372036854775808 (number_unsigned > INT64_MAX) -> negative
ok, w = fromjson_where("9223372036854775808")
print("fromjson(where=9223372036854775808) ->", ok, w)
if ok and math.type(w) == "integer" and w < 0 then
  bug("fromjson: JSON where=9223372036854775808 became negative Lua where=" .. w)
end

if bugs > 0 then os.exit(1) end
print("OK: no ArrayIndex overflow/wrap")
os.exit(0)
