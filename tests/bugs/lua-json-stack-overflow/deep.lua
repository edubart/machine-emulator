-- Converts a deeply nested value with the Lua bindings and checks that the process survives with a correct
-- result or a clean Lua error.
-- Usage: lua5.4 deep.lua <mode> <depth>
--   mode = tojson-array  : cartesi.tojson({{{...}}})          (depth nested arrays)
--          tojson-object : cartesi.tojson({a={a={...}}})      (depth nested objects)
--          fromjson      : cartesi.fromjson("[[[...]]]")      (depth nested arrays)
-- Prints "RESULT ok <detail>" or "RESULT error <message>", then "DONE" after exercising the GC (heap corruption
-- caused by writes past the Lua stack usually shows up there as an abort, a crash or a hang).
local cartesi = require("cartesi")
local mode, depth = arg[1], assert(tonumber(arg[2]))

local function report(ok, detail) io.stdout:write("RESULT ", ok and "ok " or "error ", tostring(detail), "\n") end

if mode == "tojson-array" or mode == "tojson-object" then
    local t = {}
    local cur = t
    for _ = 2, depth do
        local x = {}
        if mode == "tojson-array" then cur[1] = x else cur.a = x end
        cur = x
    end
    local ok, s = pcall(cartesi.tojson, t)
    if ok then
        -- verify the output really has `depth` levels
        local expected
        if mode == "tojson-array" then
            expected = string.rep("[", depth) .. string.rep("]", depth)
            if s ~= expected then report(false, "WRONG OUTPUT " .. s:sub(1, 80)) os.exit(3) end
        else
            local _, n = s:gsub('"a":', "")
            if n ~= depth - 1 then report(false, "WRONG OUTPUT " .. s:sub(1, 80)) os.exit(3) end
        end
    end
    report(ok, ok and (#s .. " bytes") or s)
elseif mode == "fromjson" then
    local ok, t = pcall(cartesi.fromjson, string.rep("[", depth) .. string.rep("]", depth))
    if ok then
        local n, cur = 0, t
        while type(cur) == "table" do
            n = n + 1
            cur = cur[1]
        end
        if n ~= depth then report(false, "WRONG DEPTH " .. n) os.exit(3) end
        report(true, n .. " levels")
    else
        report(false, t)
    end
else
    error("unknown mode " .. tostring(mode))
end
-- exercise the allocator and the GC
for _ = 1, 3 do
    local junk = {}
    for i = 1, 20000 do junk[i] = { i, tostring(i) } end
    collectgarbage("collect")
end
io.stdout:write("DONE\n")
os.exit(0)
