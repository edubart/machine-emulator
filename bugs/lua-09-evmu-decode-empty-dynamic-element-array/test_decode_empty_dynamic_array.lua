-- Repro: evmu decode_abi/decode_calldata reject canonical data with an empty T[] where T is dynamic.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua
-- Exits 1 while the bug is present, 0 once fixed.
local evmu = require("cartesi.evmu")
local fails = 0
local function check(kind, spec, value)
  local ok, res
  if kind == "abi" then
    local data = evmu.encode_abi(spec, value)
    ok, res = pcall(evmu.decode_abi, spec, data)
  else
    local data = evmu.encode_calldata(spec, value)
    ok, res = pcall(evmu.decode_calldata, spec, data)
  end
  if ok then print("ok:  " .. kind .. " " .. spec)
  else fails = fails + 1; print("BUG: " .. kind .. " " .. spec .. " round trip with empty dynamic-element array fails: " .. tostring(res)) end
end
-- control: non-empty works
check("abi", "(bytes[])", {{"0x01"}})
check("abi", "(bytes[])", {{}})
check("abi", "(string[])", {{}})
check("abi", "(uint256,string[])", {7, {}})
check("abi", "((uint256,bytes)[])", {{}})
check("abi", "(bytes[][])", {{{}}})       -- nested: inner empty propagates nil
check("calldata", "f(bytes[])", {{}})
check("calldata", "f(string[],uint256)", {{}, 1})
os.exit(fails == 0 and 0 or 1)
