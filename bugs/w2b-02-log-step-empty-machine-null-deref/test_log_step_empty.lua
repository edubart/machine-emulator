-- machine:log_step on an empty (cartesi.new()) or destroyed local machine must raise
-- a Lua error ("no machine"), like get_root_hash does, not crash the process.
-- Each case runs in a child lua5.4 process so a SIGSEGV can be observed.
-- Usage: lua5.4 test_log_step_empty.lua [scratch-dir]
local tmp = arg[1] or os.getenv("TMPDIR") or "/tmp"
local log = tmp .. "/empty-machine-step-lua.log"

local cases = {
    { name = "control: get_root_hash on destroyed machine", code = [[
local m = cartesi.machine{ram={length=1<<20}}
m:destroy()
local ok, err = pcall(m.get_root_hash, m)
print("  ok=" .. tostring(ok) .. " err=" .. tostring(err))
os.exit(ok and 3 or 0)]] },
    { name = "log_step on cartesi.new() machine", code = [[
local m = cartesi.new()
local ok, err = pcall(m.log_step, m, 1, LOG)
print("  ok=" .. tostring(ok) .. " err=" .. tostring(err))
os.exit(ok and 3 or 0)]] },
    { name = "log_step on destroyed machine", code = [[
local m = cartesi.machine{ram={length=1<<20}}
m:destroy()
local ok, err = pcall(m.log_step, m, 1, LOG)
print("  ok=" .. tostring(ok) .. " err=" .. tostring(err))
os.exit(ok and 3 or 0)]] },
}

local bad = 0
for i, c in ipairs(cases) do
    local child = tmp .. "/empty-machine-child-" .. i .. ".lua"
    local f = assert(io.open(child, "w"))
    f:write('local cartesi = require"cartesi"\nlocal LOG = ' .. string.format("%q", log) .. "\n" .. c.code .. "\n")
    f:close()
    print(c.name .. ":")
    local ok, how, code = os.execute("timeout 20 lua5.4 " .. child)
    if how == "signal" or (how == "exit" and code >= 128) then
        print(string.format("BUG: %s crashed the process (%s %d) instead of raising an error", c.name, how, code))
        bad = 1
    elseif not ok then
        print(string.format("BUG?: %s child failed (%s %d)", c.name, how, code))
        bad = 1
    else
        print("OK: " .. c.name .. " raised an error")
    end
    os.remove(child)
end
os.remove(log)
os.exit(bad)
