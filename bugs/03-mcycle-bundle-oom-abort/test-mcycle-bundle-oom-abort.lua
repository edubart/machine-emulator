#!/usr/bin/env lua5.4
-- Regression test: collect_mcycle_bundle on an already-halted machine must not abort the process.
--
-- Run (from the repo root, after sourcing bugs/env/env.sh):
--   lua5.4 test-mcycle-bundle-oom-abort.lua            -- local machine (Lua binding / C API)
--   lua5.4 test-mcycle-bundle-oom-abort.lua jsonrpc    -- remote machine (cartesi-jsonrpc-machine server)
--
-- A halted machine asked for collect_mcycle_bundle(0, 0, 20) returns 2^20 copies of its root hash without
-- executing anything (32 MiB of hashes, ~320 MiB peak once serialised to JSON and parsed back). The test runs
-- the process under test with an address-space limit of (measured baseline + 120 MiB), so the reserve of the
-- hashes succeeds but the JSON serialisation runs out of memory. The bad_alloc then reaches the destructor of
-- the partially built nlohmann::json array, which allocates (json_value::destroy reserves a stack the size of
-- the array) and throws out of a noexcept destructor -> std::terminate -> SIGABRT. The expected behaviour is a
-- clean error (or a refusal of the oversized bundle), with the process/server still alive.
-- The limit keeps the test's footprint at a few hundred MiB, so it is safe on a shared machine.
local mode = arg[1] or "local"
assert(mode == "local" or mode == "jsonrpc", "usage: lua5.4 test-mcycle-bundle-oom-abort.lua [local|jsonrpc]")

local LOG2_BUNDLE = 20
local HEADROOM_KB = 120 * 1024
local CONFIG = "{ ram = { length = 4096 } }"

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function vm_peak_kb(pid)
    for line in io.lines("/proc/" .. pid .. "/status") do
        local kb = line:match("^VmPeak:%s+(%d+)")
        if kb then return tonumber(kb) end
    end
    error("VmPeak not found")
end

local function report(bug, msg)
    if bug then
        print("BUG REPRODUCED: " .. msg)
        os.exit(1, true)
    end
    print("OK: " .. msg)
    os.exit(0, true)
end

-- Child body (local mode): halted machine, then collect a bundle of 2^log2 hashes; print VmPeak when asked
if mode == "local" and arg[2] == "child" then
    local cartesi = require("cartesi")
    local m = cartesi.machine({ ram = { length = 4096 } })
    m:write_reg("iflags_H", 1)
    m:get_root_hash()
    local ok, r = pcall(m.collect_mcycle_bundle, m, 0, 0, tonumber(arg[3]))
    print(ok and ("returned " .. #r .. " hashes") or ("returned error: " .. tostring(r)))
    if arg[4] == "peak" then print("VMPEAK " .. vm_peak_kb("self")) end
    os.exit(0, true)
end

if mode == "local" then
    local lua = arg[-1] or "lua5.4"
    local self = arg[0]
    -- Baseline: same process with a 1-hash bundle, unlimited
    local p = assert(io.popen(sh_quote(lua) .. " " .. sh_quote(self) .. " local child 0 peak"))
    local out = p:read("a")
    p:close()
    local base_kb = assert(tonumber(out:match("VMPEAK (%d+)")), "baseline failed: " .. out)
    local limit_kb = base_kb + HEADROOM_KB
    print(string.format("baseline VmPeak %d kB, running bundle 2^%d under ulimit -v %d", base_kb, LOG2_BUNDLE, limit_kb))
    local ok, how, code = os.execute(string.format("ulimit -v %d; exec %s %s local child %d", limit_kb,
        sh_quote(lua), sh_quote(self), LOG2_BUNDLE))
    if how == "signal" or (how == "exit" and code ~= 0 and code >= 128) then
        report(true, string.format("process died (%s %d) instead of returning an error", how, code))
    end
    report(not ok, string.format("process ended normally (%s %d)", how, code))
end

-- jsonrpc mode: memory-limited server, unlimited client
local jsonrpc = require("cartesi.jsonrpc")
local server_bin = os.getenv("CARTESI_JSONRPC_MACHINE") or "src/cartesi-jsonrpc-machine"

local function start_server(limit_kb)
    local port = 20000 + (os.time() * 7919 + math.random(0, 9999)) % 20000
    local address = "127.0.0.1:" .. port
    local cmd = string.format("%s exec %s --server-address=%s >/dev/null 2>&1 & echo $!",
        limit_kb and ("ulimit -v " .. limit_kb .. ";") or "", sh_quote(server_bin), address)
    local p = assert(io.popen("sh -c " .. sh_quote(cmd)))
    local pid = assert(tonumber(p:read("l")))
    p:close()
    for _ = 1, 100 do
        local ok, conn = pcall(jsonrpc.connect_server, address)
        if ok and conn then return conn, pid end
        os.execute("sleep 0.05")
    end
    error("could not connect to server at " .. address)
end

local function alive(pid) -- dead servers may linger as zombies when nobody reaps them
    local f = io.open("/proc/" .. pid .. "/status")
    if not f then return false end
    local status = f:read("a")
    f:close()
    return not status:match("\nState:%s+[ZX]")
end

local function halted_remote_machine(conn)
    local m = conn:create(load("return " .. CONFIG)())
    m:write_reg("iflags_H", 1)
    m:get_root_hash()
    return m
end

math.randomseed(os.time())
-- Baseline server footprint with a 1-hash bundle
local base_kb
do
    local conn, pid = start_server(nil)
    local m = halted_remote_machine(conn)
    assert(#m:collect_mcycle_bundle(0, 0, 0) == 1)
    base_kb = vm_peak_kb(pid)
    pcall(conn.shutdown_server, conn)
    os.execute("kill " .. pid .. " 2>/dev/null")
end
local limit_kb = base_kb + HEADROOM_KB
print(string.format("baseline server VmPeak %d kB, bundle 2^%d under ulimit -v %d", base_kb, LOG2_BUNDLE, limit_kb))
local conn, pid = start_server(limit_kb)
local m = halted_remote_machine(conn)
local ok, r = pcall(m.collect_mcycle_bundle, m, 0, 0, LOG2_BUNDLE)
print(ok and ("returned " .. #r .. " hashes") or ("returned error: " .. tostring(r)))
os.execute("sleep 0.3")
local is_alive = alive(pid)
if is_alive then
    pcall(conn.shutdown_server, conn)
    os.execute("kill " .. pid .. " 2>/dev/null")
end
report(not is_alive, is_alive and "server survived the oversized bundle request" or
    "cartesi-jsonrpc-machine server process died instead of returning an error")
