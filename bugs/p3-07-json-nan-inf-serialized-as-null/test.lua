local cartesi = require("cartesi")
local bad = false
for _, case in ipairs({ {"nan", 0/0}, {"inf", math.huge}, {"-inf", -math.huge} }) do
    local name, v = case[1], case[2]
    local ok, s = pcall(cartesi.tojson, { a = v, b = 1 })
    if not ok then
        print(("OK: tojson rejects %s: %s"):format(name, s))
    else
        local t = cartesi.fromjson(s)
        print(("%s -> %s -> a=%s"):format(name, s, tostring(t.a)))
        if t.a == nil then
            print(("BUG: tojson serialized non-finite %s as null without error; fromjson round-trip loses field 'a'"):format(name))
            bad = true
        end
    end
end
-- also array: a NaN element becomes nil, turning into a hole
local ok, s = pcall(cartesi.tojson, { 1, 0/0, 3 })
if ok then
    local t = cartesi.fromjson(s)
    print("array {1,nan,3} -> " .. s .. " -> #t=" .. #t .. " t[2]=" .. tostring(t[2]))
    if t[2] == nil then print("BUG: NaN array element silently becomes null/nil hole"); bad = true end
end
os.exit(bad and 1 or 0)
