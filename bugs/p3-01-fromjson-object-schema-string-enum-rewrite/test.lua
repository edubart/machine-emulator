-- Proof: cartesi.fromjson rewrites a JSON string into schema internals whenever the
-- string's position has an object (struct/tuple) schema that has a key equal to the string.
local cartesi = require("cartesi")
local bugs = 0
local function check(label, got, expected)
    local same = got == expected
    if not same then
        bugs = bugs + 1
        print(string.format("BUG: %s: expected %q, got %s (%s)", label, tostring(expected),
            type(got) == "table" and cartesi.tojson(got, -1) or tostring(got), type(got)))
    else
        print("ok: " .. label)
    end
end

-- 1. round trip with a field typed by a built-in struct schema ("Proof")
local d1 = { S = { p = "Proof" } }
local j1 = cartesi.tojson({ p = "target_hash" }, -1, "S", d1)
print("tojson wrote: " .. j1)
check("tojson->fromjson round trip of string in Proof-typed field",
    cartesi.fromjson(j1, "S", d1).p, "target_hash")

-- 2. string at a Base64Array-typed position equal to "items"
check("fromjson '\"items\"' at Base64Array-typed field",
    cartesi.fromjson('{"x":"items"}', "S", { S = { x = "Base64Array" } }).x, "items")

-- 3. user tuple schema: string "items" becomes a Lua table copy of the items list
local d3 = { Ev = { operation = "Default", arguments = "Args" }, Args = { items = { "Base64", "ArrayIndex" } } }
local j3 = cartesi.tojson({ operation = "move", arguments = "items" }, -1, "Ev", d3)
check("tojson->fromjson round trip of string in tuple-typed field",
    cartesi.fromjson(j3, "Ev", d3).arguments, "items")

-- 4. user struct schema at top level: arbitrary attacker string becomes a type name
local d4 = { Claim = { root = "Base64", owner = "Default" } }
check("fromjson top-level string equal to Claim field name",
    cartesi.fromjson('"root"', "Claim", d4), "root")

-- 5. built-in machine struct schema at top level, no user dict at all
check("fromjson '\"sibling_hashes\"' with schema Proof",
    cartesi.fromjson('"sibling_hashes"', "Proof"), "sibling_hashes")

if bugs > 0 then
    print(string.format("BUG: %d case(s) where fromjson replaced a string with schema internals", bugs))
    os.exit(1)
end
print("PASS")
