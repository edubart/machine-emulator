local cartesi = require("cartesi")
local bug = false
-- Lua -> JSON
local ok, s = pcall(cartesi.tojson, { ["a\0b"] = 1, a = 2 })
print("tojson:", ok, s)
if ok then
  local cnt = 0
  for _ in s:gmatch('"a[^"]*"%s*:') do cnt = cnt + 1 end
  if cnt ~= 2 then
    print("BUG: tojson truncated key 'a\\0b' at NUL, merged with key 'a' (got " .. s .. ")")
    bug = true
  end
end
local ok1, s1 = pcall(cartesi.tojson, { ["a\0b"] = 1 })
print("tojson single:", ok1, s1)
if ok1 and not s1:find("\\u0000", 1, true) then
  print("BUG: tojson({['a\\0b']=1}) dropped the bytes after NUL in key: " .. s1)
  bug = true
end
-- JSON -> Lua
local ok2, t = pcall(cartesi.fromjson, '{"a\\u0000b":1,"a":2}')
if ok2 then
  local keys = {}
  for k, v in pairs(t) do keys[#keys + 1] = string.format("%q=%s", k, tostring(v)) end
  print("fromjson keys:", table.concat(keys, ", "))
  if t["a\0b"] ~= 1 or t.a ~= 2 then
    print("BUG: fromjson truncated key \"a\\u0000b\" at NUL; t['a\\0b']=" .. tostring(t["a\0b"]) .. " t.a=" .. tostring(t.a))
    bug = true
  end
else
  print("fromjson error:", t)
end
os.exit(bug and 1 or 0)
