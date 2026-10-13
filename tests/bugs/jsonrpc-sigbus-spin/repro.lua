-- Independent reproducer for CONC-3 (verify-conc).
-- The JSON-RPC server puts SIGBUS into its Boost.Asio signal_set. A *guest load* from a flash drive whose
-- (default, private) backing image was truncated underneath raises a synchronous SIGBUS; Asio's handler
-- returns, the faulting instruction re-executes forever. The server neither answers nor dies, and SIGTERM
-- has no effect. A local machine in the same situation dies with SIGBUS (fail-fast).
-- Usage: lua5.4 repro.lua <tmpdir>      (bounded: 3 s RPC timeout, server SIGKILLed at the end)
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")
local dir = assert(arg[1])
local img = dir .. "/flash.img"
local FLASH = 1 << 55
local function le32(...) local t = {} for _, v in ipairs({...}) do t[#t+1] = string.pack("<I4", v) end return table.concat(t) end
-- addi t0,x0,1 ; slli t0,t0,55 ; lui t1,0x10 ; add t0,t0,t1 ; ld t2,0(t0) ; j .
local prog = le32(0x00100293, 0x03729293, 0x00010337, 0x006282b3, 0x0002b383, 0x0000006f)
local function make_image() local f = assert(io.open(img, "wb")); f:write(string.rep("\x5a", 1 << 20)); f:close() end
local function truncate_image() local f = assert(io.open(img, "wb")); f:close() end -- O_TRUNC, size 0
local config = { ram = { length = 1 << 20 },
    flash_drive = { { start = FLASH, length = 1 << 20, backing_store = { data_filename = img } } } }
local function stat(pid)
    local f = io.open("/proc/" .. pid .. "/stat"); if not f then return "gone", 0 end
    local s = f:read("a"); f:close()
    local rest = s:match("%) (.*)$"); local fields = {}
    for w in rest:gmatch("%S+") do fields[#fields + 1] = w end
    return fields[1], tonumber(fields[12]) + tonumber(fields[13]) -- state, utime+stime
end
local function sleep(s) os.execute("sleep " .. s) end

-- control: local machine in a child process (lua forks via os.execute of a tiny script)
make_image()
local ok_ctl, how, code = os.execute(string.format([[lua5.4 -e '
local cartesi = require("cartesi")
local m = cartesi.machine(%s)
m:write_memory(0x80000000, %q)
local f = io.open(%q, "wb"); f:close()
m:run(100)' 2>/dev/null]], "cartesi.fromjson(" .. string.format("%q", cartesi.tojson(config)) .. ")", prog, img))
print("local machine (control): ", ok_ctl and "ran to completion" or
    (how .. " " .. tostring(code) .. ((how == "exit" and code == 128 + 7) and " (killed by SIGBUS: fail-fast, expected)" or "")))

-- server
make_image()
local m, addr, pid = jsonrpc.spawn_server()
m:set_cleanup_call(jsonrpc.NOTHING)
m:create(config)
m:write_memory(0x80000000, prog)
m:set_timeout(3000)
truncate_image()
local ok, err = pcall(m.run, m, 100)
print("server pid " .. pid .. ": run ->", ok and "returned" or ("error: " .. tostring(err)))
local s1, t1 = stat(pid); sleep(2); local s2, t2 = stat(pid)
print(string.format("server state %s -> %s, cpu ticks %d -> %d in 2 s", s1, s2, t1, t2))
os.execute("kill -TERM " .. pid); sleep(1)
local s3, t3 = stat(pid); sleep(1); local s4, t4 = stat(pid)
print(string.format("after SIGTERM: state %s -> %s, cpu ticks %d -> %d in 1 s", s3, s4, t3, t4))
local hung = not ok and s2 ~= "gone" and t2 > t1 and s4 ~= "gone" and t4 > t3
os.execute("kill -KILL " .. pid .. " 2>/dev/null")
if hung then
    print("BUG REPRODUCED: server spins on a re-raised SIGBUS; no reply, no exit, SIGTERM ignored")
    os.exit(1)
end
print("NOT REPRODUCED"); os.exit(0)
