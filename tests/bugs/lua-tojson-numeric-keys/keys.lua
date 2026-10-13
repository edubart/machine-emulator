-- cartesi.tojson on tables that are not pure arrays but have numeric keys.
-- clua_push_managed_toclose_json_ref (src/clua-i-machine.cpp) walks such tables as JSON objects with lua_next and
-- calls lua_tostring on the key slot, which converts a numeric key into a string in place. The Lua manual forbids
-- this during a traversal: the next lua_next call gets a key that is not in the table.
-- A fixed implementation may either serialize the numeric key (as the field "1", "0.5", ...) or reject the table
-- with an error; it must not raise "invalid key to 'next'", drop fields or loop forever.
-- Exit 1 if any case shows the corrupted traversal, 0 otherwise.
local cartesi = require("cartesi")

local bad = 0
local function check(name, t, expected_fields)
    local ok, res = pcall(cartesi.tojson, t)
    if not ok then
        if tostring(res):find("invalid key to 'next'", 1, true) then
            bad = bad + 1
            print(string.format("%-28s -> CORRUPTED TRAVERSAL: %s", name, res))
        else
            print(string.format("%-28s -> rejected: %s", name, res))
        end
    else
        local decoded = cartesi.fromjson(res)
        local missing = {}
        for _, k in ipairs(expected_fields) do
            if decoded[k] == nil then missing[#missing + 1] = k end
        end
        if #missing > 0 then
            bad = bad + 1
            print(string.format("%-28s -> %s (fields missing: %s)", name, res, table.concat(missing, ", ")))
        else
            print(string.format("%-28s -> %s", name, res))
        end
    end
    io.stdout:flush()
end

-- Both cases are deterministic: the converted key ("1" or "0.5") is not in the table, so the next lua_next call
-- always raises "invalid key to 'next'". (When the converted key is also in the table, e.g. {[1]='a', ['1']='b', x=3},
-- the traversal resumes from the wrong slot and, depending on the per-process string hash seed, drops fields or never
-- ends; that variant is left out to keep the test deterministic.)
check("{[1]='a', x='b'}", { [1] = "a", x = "b" }, { "1", "x" })
check("{x='a', [0.5]='b'}", { x = "a", [0.5] = "b" }, { "x", "0.5" })

os.exit(bad > 0 and 1 or 0)
