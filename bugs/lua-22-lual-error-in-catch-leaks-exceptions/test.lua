-- Proves luaL_error inside C++ catch handlers leaks the exception object (and its message buffer)
-- because longjmp skips __cxa_end_catch. Measures VmRSS growth across many failing pcalls.
local cartesi = require("cartesi")
local ok_fs, fs = pcall(require, "cartesi.filesystem")

local function rss_kib()
    local f = assert(io.open("/proc/self/status"))
    for line in f:lines() do
        local v = line:match("^VmRSS:%s+(%d+)")
        if v then f:close(); return tonumber(v) end
    end
    f:close()
end

local N = 200000
local function measure(name, fn)
    for _ = 1, 1000 do fn() end -- warm up
    collectgarbage("collect"); collectgarbage("collect")
    local before = rss_kib()
    for _ = 1, N do fn() end
    collectgarbage("collect"); collectgarbage("collect")
    local after = rss_kib()
    local per_call = (after - before) * 1024 / N
    print(string.format("%-40s RSS %d KiB -> %d KiB (+%d KiB, %.1f bytes/failed call)",
        name, before, after, after - before, per_call))
    return per_call
end

-- Control: a plain Lua error raised via luaL_argerror (no C++ exception) must not leak.
local control = measure("control: cartesi.fromhex(non-string)", function()
    pcall(cartesi.fromhex, {})
end)

local results = {}
local long = ("x"):rep(200)
results[#results+1] = {"cartesi.fromjson('{bad')", measure("cartesi.fromjson('{bad')", function()
    local ok = pcall(cartesi.fromjson, "{bad" .. long)
    assert(not ok)
end)}
results[#results+1] = {"cartesi.fromhex('zz')", measure("cartesi.fromhex('zz')", function()
    local ok = pcall(cartesi.fromhex, "zz" .. long)
    assert(not ok)
end)}
if ok_fs and fs and fs.create_directory then
    results[#results+1] = {"filesystem.create_directory(bad)", measure("filesystem.create_directory(bad)", function()
        local ok = pcall(fs.create_directory, "/nonexistent/x/" .. long)
        assert(not ok)
    end)}
else
    print("note: cartesi.filesystem not loadable: " .. tostring(fs))
end

local bug = false
for _, r in ipairs(results) do
    if r[2] > 100 and r[2] > 10 * math.max(control, 1) then
        print(string.format("BUG: %s leaks ~%.0f bytes per failed call (luaL_error longjmps out of C++ catch handler; exception never freed)", r[1], r[2]))
        bug = true
    end
end
if bug then os.exit(1) end
print("OK: no per-call leak detected")
os.exit(0)
