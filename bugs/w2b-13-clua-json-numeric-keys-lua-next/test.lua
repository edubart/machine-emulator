-- Reproduces: cartesi.tojson corrupts lua_next traversal on numeric keys (lua_tostring on key),
-- and expands sparse positive-integer-keyed tables into huge arrays.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/w2b-13-clua-json-numeric-keys-lua-next/test.lua
-- Exits 1 when the bug reproduces (prints BUG: lines), 0 with "OK" when fixed. Takes ~30 s.
local cartesi = require("cartesi")
local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end

-- 1) mixed integer + string keys
local cases = {
  { name = "{1, x=2}", t = {1, x = 2} },
  { name = "{[1.5]=1, x=2}", t = {[1.5] = 1, x = 2} },
  { name = "{[0]=1, [1]=2, [2]=3}", t = {[0] = 1, [1] = 2, [2] = 3} },
  { name = "{[-1]=7, a=1}", t = {[-1] = 7, a = 1} },
}
for _, c in ipairs(cases) do
  local ok, res = pcall(cartesi.tojson, c.t)
  print(c.name, ok, res)
  if not ok and tostring(res):find("invalid key to 'next'") then
    bug("cartesi.tojson(" .. c.name .. ") failed with traversal corruption: " .. tostring(res))
  end
end

-- 2) sparse integer key: converter should not emit 2^N nulls. Use a child process with timeout+memlimit.
local script = [[local c=require'cartesi'; local s=c.tojson({[1<<24]=1}); io.write(#s)]]
local p = io.popen("ulimit -v 2000000; timeout 20 lua5.4 -e \"" .. script .. "\" 2>&1; echo \" rc=$?\"")
local out = p:read("a"); p:close()
print("sparse {[1<<24]=1} -> json length / rc:", out)
local len = tonumber(out:match("^(%d+)"))
if len and len > 1000 then
  bug("cartesi.tojson({[1<<24]=1}) produced a " .. len .. "-byte JSON array of nulls (2^24 entries)")
end
local p2 = io.popen("ulimit -v 2000000; timeout 20 lua5.4 -e \"local c=require'cartesi'; local s=c.tojson({[1<<40]=1}); io.write(#s)\" 2>&1; echo \" rc=$?\"")
local out2 = p2:read("a"); p2:close()
print("sparse {[1<<40]=1} ->", out2)
if out2:find("rc=124") or out2:find("not enough memory") or out2:find("bad_alloc") or out2:find("rc=13[47]") then
  bug("cartesi.tojson({[1<<40]=1}) hangs or exhausts memory: " .. out2:gsub("\n", " "))
end

if bugs > 0 then os.exit(1) end
print("OK")
