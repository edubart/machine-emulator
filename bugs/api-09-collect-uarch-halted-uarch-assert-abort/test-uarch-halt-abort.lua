-- BUG: collect_uarch_cycle_root_hashes / collect_uarch_cycle_bundle check only uarch_cycle == 0.
-- With uarch_halt == 1 (and uarch_cycle == 0) the first uarch_interpret returns "halted" without
-- executing anything, mcycle does not advance, and assert(mcycle_reached == mcycle_target) in
-- src/machine.cpp aborts the host process (local Lua/C client, or cartesi-jsonrpc-machine server).
-- Each case runs in a child process; a crash (signal / abnormal exit) is the defect.
-- Fixed behavior: a catchable error (e.g. "microarchitecture is not reset"), process survives.
--
-- Run (repo root): eval $(make -s env); lua5.4 bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua
local mode = arg[1]
local ZERO_TAIL = { string.rep("\0", 32), string.rep("\0", 32) }

if mode then
    local cartesi = require("cartesi")
    local m
    if mode == "config" then
        -- reachable via machine config (e.g. a stored snapshot / misconfigured config)
        m = cartesi.machine({ ram = { length = 4096 }, uarch = { processor = { registers = { halt = 1 } } } })
    else
        m = cartesi.machine({ ram = { length = 4096 } })
        m:write_reg("uarch_halt", 1)
    end
    assert(m:read_reg("uarch_cycle") == 0 and m:read_reg("uarch_halt") == 1)
    local ok, err
    if mode == "bundle" then
        ok, err = pcall(m.collect_uarch_cycle_bundle, m, 0, 0, ZERO_TAIL)
    else
        ok, err = pcall(m.collect_uarch_cycle_root_hashes, m, 3, 0, ZERO_TAIL)
    end
    if ok then
        -- Under NDEBUG the call would return a bogus extra halt+reset group
        print("CHILD: returned without error (bogus result): offsets=" .. table.concat(err.mcycle_hash_offsets or {}, ","))
        os.exit(3)
    end
    print("CHILD: got catchable error: " .. tostring(err))
    os.exit(0)
end

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local self = arg[0]
local failures = 0

for _, case in ipairs({ "write_reg", "config", "bundle" }) do
    local cmd = "timeout 60 lua5.4 " .. sh_quote(self) .. " " .. case .. " 2>&1"
    local p = io.popen(cmd)
    local out = p:read("a")
    local ok, how, code = p:close()
    io.write(out)
    if not ok then
        print(string.format("BUG: local %s case: child terminated abnormally (%s %s) instead of raising an error", case,
            tostring(how), tostring(code)))
        failures = failures + 1
    else
        print("OK: local " .. case .. " case raised a catchable error")
    end
end

-- Remote: the cartesi-jsonrpc-machine server process aborts
do
    local jsonrpc = require("cartesi.jsonrpc")
    local server, address = jsonrpc.spawn_server()
    assert(server, "failed to spawn server")
    server:set_cleanup_call(jsonrpc.SHUTDOWN)
    local m = server:create({ ram = { length = 4096 } })
    m:write_reg("uarch_halt", 1)
    local ok, err = pcall(m.collect_uarch_cycle_root_hashes, m, 3, 0, ZERO_TAIL)
    print("remote collect: ok=" .. tostring(ok) .. " err=" .. tostring(err))
    local alive, err2 = pcall(m.read_reg, m, "mcycle")
    if not alive then
        print("BUG: remote case: cartesi-jsonrpc-machine server died after collect_uarch_cycle_root_hashes: " ..
            tostring(err2))
        failures = failures + 1
        server:set_cleanup_call(jsonrpc.NOTHING)
    else
        print("OK: remote server survived")
    end
    pcall(function() server:close() end)
end

if failures > 0 then os.exit(1) end
print("PASS")
os.exit(0)
