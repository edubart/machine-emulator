-- revert_uarch_tail length is not bounded by 2^ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE (2^20).
-- Case A (in-process, no bundling): call returns an mcycle group with > 2^20 leaves.
-- Case B (child process, log2_bundle=4): assert(execution_bundle_count < bundle_capacity) aborts the process.
-- Case C (jsonrpc server, log2_bundle=4): the remote server process aborts; client loses connection.
-- Exit 0 only if all three cases reject the over-long tail with a normal error.
local cartesi = require("cartesi")
local mode = arg[1]
local LEAVES = 1 << 20

local function make_machine(m)
    m:write_reg("iflags_Y", 1)
    m:write_reg("htif_tohost", (cartesi.HTIF_DEV_YIELD << 56) | (cartesi.HTIF_YIELD_CMD_MANUAL << 48)
        | (cartesi.HTIF_YIELD_MANUAL_REASON_RX_REJECTED << 32))
    local tail = {}
    for i = 1, LEAVES + 8 do tail[i] = string.rep("\1", 32) end
    tail[#tail] = m:read_revert_root_hash()
    return tail
end
local cfg = { ram = { length = 4096 }, htif = { yield_manual = true } }

if mode == "child-bundle" then
    local m = cartesi.machine(cfg)
    local tail = make_machine(m)
    local ok, err = pcall(m.collect_uarch_cycle_root_hashes, m, m:read_reg("mcycle"), 4, tail)
    print("child: call returned", ok, err)
    os.exit(ok and 3 or 0)
elseif mode == "child-jsonrpc" then
    local jsonrpc = require("cartesi.jsonrpc")
    local server, address = jsonrpc.spawn_server()
    local m = server:create(cfg)
    local tail = make_machine(m)
    local ok, err = pcall(m.collect_uarch_cycle_root_hashes, m, m:read_reg("mcycle"), 4, tail)
    print("child-jsonrpc: call returned", ok, err)
    -- check whether the server is still alive
    local alive = pcall(function() return m:read_reg("mcycle") end)
    print("child-jsonrpc: server alive after call:", alive)
    pcall(function() server:shutdown_server() end)
    os.exit((not ok and alive) and 0 or 4)
end

local bugs = 0
-- Case A
do
    local m = cartesi.machine(cfg)
    local tail = make_machine(m)
    local ok, r = pcall(m.collect_uarch_cycle_root_hashes, m, m:read_reg("mcycle"), 0, tail)
    if ok then
        local group = r.mcycle_hash_offsets[2] - r.mcycle_hash_offsets[1]
        print(string.format("case A (log2_bundle=0): accepted tail of %d entries, group has %d leaves (max %d)",
            #tail, group, LEAVES))
        if group > LEAVES then
            print("BUG: over-long revert_uarch_tail accepted; mcycle group has more than 2^20 leaves")
            bugs = bugs + 1
        end
    else
        print("case A: rejected:", r)
    end
end
-- Case B / C in child processes (the defect aborts the process)
local script = arg[0]
for _, c in ipairs({ { "child-bundle", "B (local, log2_bundle=4)" }, { "child-jsonrpc", "C (jsonrpc server, log2_bundle=4)" } }) do
    local cmd = string.format("timeout 120 lua5.4 %q %s 2>&1", script, c[1])
    local p = io.popen(cmd)
    local out = p:read("a")
    local _, _, code = p:close()
    io.write(out)
    print(string.format("case %s: child exit code %s", c[2], tostring(code)))
    if code ~= 0 then
        if out:find("Assertion") or out:find("execution_bundle_count") or code == 134 or code == 6 then
            print("BUG: case " .. c[2] .. ": process aborted on assert(execution_bundle_count < bundle_capacity)")
        else
            print("BUG: case " .. c[2] .. ": over-long tail not rejected cleanly")
        end
        bugs = bugs + 1
    end
end
os.exit(bugs == 0 and 0 or 1)
