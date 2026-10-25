-- Proves: (1) access-log JSON parsing truncates 64-bit log2_size to int with no range check,
-- so a step log with log2_size = 2^32+3 verifies; (2) proof JSON parsing checks
-- log2_root_size > INT_MAX twice and never checks log2_target_size (copy-paste), so a
-- 2^32+3 target size wraps to 3 while an equally out-of-range root size is rejected.
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")
io.stdout:setvbuf("no")
local dir = arg[0]:match("^(.*)/[^/]*$") or "."
local tmpdir = io.popen("mktemp -d"):read("l")
local bugs = 0
local function bug(msg) bugs = bugs + 1; print("BUG: " .. msg) end

-- Part 1: access log log2_size truncation via cm_verify_step_uarch (JSON log)
do
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    local before = m:get_root_hash()
    local log = m:log_step_uarch(cartesi.ACCESS_LOG_TYPE_ANNOTATIONS | cartesi.ACCESS_LOG_TYPE_LARGE_DATA)
    local after = m:get_root_hash()
    assert(log.accesses[1].log2_size == 3)
    local ok0, r0 = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, before, log)
    assert(ok0 and r0 == after, "untampered log should verify: " .. tostring(r0))
    log.accesses[1].log2_size = (1 << 32) + 3 -- 4294967299
    local ok, r = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, before, log)
    print("verify_step_uarch with accesses[1].log2_size=4294967299 ->", ok, ok and (r == after) or r)
    if ok then
        bug("verify_step_uarch accepted access log2_size=4294967299 (truncated to int 3, no range check)")
    end
    -- same check on the C JSON path for a non-annotated log via verify_step_uarch already covers
    -- cm_verify_step_uarch; also check verify_reset_uarch-like round-trip is not needed.
end

-- Part 2: proof log2_target_size bound check via a JSON-RPC client receiving get_proof
local function run_cmd(cmd) return os.execute(cmd) end
local base = 20000 + (os.time() % 20000)
local up_port = base
local function try_mode(mode, proxy_port)
    local pidfile = tmpdir .. "/proxy-" .. mode .. ".pid"
    run_cmd(string.format("python3 %s/proxy.py %d %d %s >/dev/null 2>&1 & echo $! > %s",
        dir, proxy_port, up_port, mode, pidfile))
    local m
    local ok, err
    for _ = 1, 50 do
        ok, err = pcall(function() m = jsonrpc.connect_server("127.0.0.1:" .. proxy_port, 2000) end)
        if ok then break end
        run_cmd("sleep 0.1")
    end
    local res_ok, res
    if ok then
        res_ok, res = pcall(function() return m:get_proof(0, 5, 64) end)
    else
        res_ok, res = false, "connect failed: " .. tostring(err)
    end
    run_cmd("kill $(cat " .. pidfile .. ") 2>/dev/null; rm -f " .. pidfile)
    return res_ok, res
end

run_cmd(string.format("timeout 60 cartesi-jsonrpc-machine --server-address=127.0.0.1:%d >/dev/null 2>&1 & echo $! > %s/server.pid",
    up_port, tmpdir))
local server
for _ = 1, 50 do
    local ok = pcall(function() server = jsonrpc.connect_server("127.0.0.1:" .. up_port, 2000) end)
    if ok then break end
    run_cmd("sleep 0.1")
end
assert(server, "could not connect to cartesi-jsonrpc-machine")
server:create({ ram = { length = 1 << 20 } })

local okr, rr = try_mode("root", up_port + 1)
print("get_proof with server log2_root_size=64+2^32   ->", okr, okr and ("log2_root_size=" .. rr.log2_root_size) or rr)
local okt, rt = try_mode("target", up_port + 2)
print("get_proof with server log2_target_size=5+2^32  ->", okt,
    okt and ("log2_target_size=" .. rt.log2_target_size) or rt)
if okr then print("(unexpected: root out-of-range accepted)") end
if okt then
    bug("JSON-RPC client accepted get_proof result with log2_target_size=4294967301 (wrapped to " ..
        tostring(rt.log2_target_size) .. "); bound check tests log2_root_size instead of log2_target_size")
end
pcall(function() server:set_cleanup_call(jsonrpc.SHUTDOWN) end)
server = nil
collectgarbage()
run_cmd("kill $(cat " .. tmpdir .. "/server.pid) 2>/dev/null; rm -rf " .. tmpdir)

if bugs > 0 then os.exit(1) end
print("OK: no bug")
os.exit(0)
