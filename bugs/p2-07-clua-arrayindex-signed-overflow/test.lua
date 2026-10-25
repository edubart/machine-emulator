-- Proof for p2-07: ArrayIndex conversion in clua-i-machine.cpp does unchecked
-- signed +1 / -1 on peer-controlled integers (signed overflow UB, silent wrap).
local cartesi = require("cartesi")
local bad = false
local function log_with(where_json)
  return '{"log_type":{"has_annotations":true,"has_large_data":false},"accesses":[],"notes":[],' ..
    '"brackets":[{"type":"begin","where":' .. where_json .. ',"text":"x"}]}'
end

-- 1) JSON -> Lua: where = INT64_MAX ; code computes INT64_MAX + 1 (UB)
local ok, t = pcall(cartesi.fromjson, log_with("9223372036854775807"), "AccessLog")
if ok then
  local w = t.brackets[1].where
  print("fromjson where=INT64_MAX ->", w)
  if w == math.mininteger or w < 1 then
    print("BUG: JSON->Lua ArrayIndex conversion overflowed: INT64_MAX became " .. tostring(w))
    bad = true
  end
else
  print("fromjson rejected INT64_MAX:", t)
end

-- 2) JSON -> Lua: where = UINT64_MAX ; cast to int64 (-1) then +1 -> 0
ok, t = pcall(cartesi.fromjson, log_with("18446744073709551615"), "AccessLog")
if ok then
  local w = t.brackets[1].where
  print("fromjson where=UINT64_MAX ->", w)
  if w < 1 then
    print("BUG: JSON->Lua ArrayIndex conversion wrapped: UINT64_MAX became " .. tostring(w))
    bad = true
  end
else
  print("fromjson rejected UINT64_MAX:", t)
end

-- 3) Lua -> JSON: where = math.mininteger ; code computes INT64_MIN - 1 (UB)
local log = { log_type = { has_annotations = true, has_large_data = false }, accesses = {}, notes = {},
  brackets = { { type = "begin", where = math.mininteger, text = "x" } } }
ok, t = pcall(cartesi.tojson, log, nil, "AccessLog")
if ok then
  print("tojson where=math.mininteger ->", t)
  local w = t:match('"where":(%-?%d+)')
  if w == "9223372036854775807" then
    print("BUG: Lua->JSON ArrayIndex conversion overflowed: math.mininteger became " .. w)
    bad = true
  end
else
  print("tojson rejected math.mininteger:", t)
end

if bad then os.exit(1) end
print("OK: no ArrayIndex overflow")
os.exit(0)
