-- Proof: JSON-RPC client verify_* re-serializes an unvalidated access log
-- (src/json-util.cpp to_json(access)): crash on missing siblings and
-- remote verdict differs from local verdict for malformed logs.
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")

local function deep(t)
    if type(t) ~= "table" then return t end
    local x = {}
    for k, v in pairs(t) do x[k] = deep(v) end
    return x
end

local function make_log()
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    local before = m:get_root_hash()
    local log = m:log_step_uarch()
    local after = m:get_root_hash()
    m = nil
    collectgarbage()
    return before, log, after
end

local function find_read(log)
    for i, a in ipairs(log.accesses) do
        if a.type == "read" then return i end
    end
end

local mode = arg[1]
if mode then
    -- child mode: run one remote verification that may crash
    local before, log = make_log()
    local r, _, pid = jsonrpc.spawn_server("127.0.0.1:0")
    r:set_cleanup_call(jsonrpc.SHUTDOWN)
    local pf = assert(io.open(arg[2], "w")); pf:write(tostring(pid)); pf:close()
    local l = deep(log)
    if mode == "empty" then
        l.accesses[1].sibling_hashes = {}
    else -- "few"
        for _ = 1, 40 do table.remove(l.accesses[1].sibling_hashes) end
    end
    local ok, err = pcall(r.verify_step_uarch, r, before, l)
    print("child remote result:", ok, err)
    r:shutdown_server()
    os.exit(0)
end

local failures = 0
local function bug(msg) print("BUG: " .. msg); failures = failures + 1 end

local before, log, after = make_log()
local r = jsonrpc.spawn_server("127.0.0.1:0")
r:set_cleanup_call(jsonrpc.SHUTDOWN)

-- sanity: honest log accepted both locally and remotely
assert(cartesi.machine:verify_step_uarch(before, log) == after, "local rejects honest log")
assert(r:verify_step_uarch(before, log) == after, "remote rejects honest log")
print("honest log: local and remote accept")

-- case A: one extra sibling hash appended
do
    local l = deep(log)
    local s = l.accesses[1].sibling_hashes
    s[#s + 1] = string.rep("\1", 32)
    local lok, lerr = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, before, l)
    local rok, rres = pcall(r.verify_step_uarch, r, before, l)
    print("extra sibling: local", lok, lok and "" or lerr, "| remote", rok, rok and (rres == after and "== after" or "other hash") or rres)
    if not lok and rok then bug("extra sibling hash: local verifier rejects, remote verifier accepts") end
end

-- case B: written/written_hash on a read access
do
    local l = deep(log)
    local i = assert(find_read(l), "no read access in log")
    l.accesses[i].written_hash = string.rep("\7", 32)
    l.accesses[i].written = string.rep("\7", 1 << l.accesses[i].log2_size)
    local lok, lerr = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, before, l)
    local rok, rres = pcall(r.verify_step_uarch, r, before, l)
    print("written on read access: local", lok, lok and "" or lerr, "| remote", rok, rok and (rres == after and "== after" or "other hash") or rres)
    if not lok and rok then bug("written data on read access: local verifier rejects, remote verifier accepts") end
end
r:shutdown_server()

-- case C/D: missing siblings -> out-of-bounds read in client (run in child)
local self = arg[0]
for _, m in ipairs({ "empty", "few" }) do
    local outf, pidf = os.tmpname(), os.tmpname()
    -- run child with output to a file (an orphaned server would keep a pipe open forever)
    local cmd = string.format("timeout 60 lua5.4 %q %s %q > %q 2>&1 < /dev/null; echo $? >> %q",
        self, m, pidf, outf, outf)
    os.execute(cmd)
    local f = io.open(outf); local out = f:read("a"); f:close(); os.remove(outf)
    local code = tonumber(out:match("(%d+)%s*$"))
    -- kill the server orphaned by a crashed child
    local pf = io.open(pidf); local spid = pf and pf:read("a"); if pf then pf:close() end; os.remove(pidf)
    if spid and spid:match("^%d+$") then os.execute("kill -9 " .. spid .. " 2>/dev/null") end
    io.write(string.format("missing siblings (%s): child exit=%s\n%s", m, tostring(code), out))
    if code ~= 0 then
        bug(string.format("remote verify_step_uarch with %s sibling_hashes crashed the client process (exit %d%s)",
            m == "empty" and "empty" or "truncated", code, code == 139 and ", SIGSEGV" or ""))
    elseif out:match("child remote result:%s+true") then
        bug(string.format("remote verify_step_uarch with %s sibling_hashes did not fail (client read past the vector)", m))
    end
end

if failures > 0 then os.exit(1) end
print("OK: no defect")
os.exit(0)
