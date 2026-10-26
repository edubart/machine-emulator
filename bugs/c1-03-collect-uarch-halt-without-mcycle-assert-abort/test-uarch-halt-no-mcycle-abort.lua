-- BUG: collect_uarch_cycle_root_hashes aborts the process (assert(mcycle_reached == mcycle_target),
-- src/machine.cpp) when the uarch image halts without completing a main-interpreter mcycle,
-- whereas run_uarch / log_step_uarch handle the same machine normally.
-- Each probe runs in a child process; an abnormal termination of the child is the defect.
-- Fixed behavior: collect_uarch_cycle_root_hashes raises a catchable error (or returns), process survives.
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/c1-03-collect-uarch-halt-without-mcycle-assert-abort/test-uarch-halt-no-mcycle-abort.lua
local mode = arg[1]
local IMG = arg[2] or os.tmpname()

local function le32(x) return string.pack("<I4", x) end
-- li a7,1 (addi x17,x0,1) ; ecall   -> UARCH_ECALL_FN_HALT immediately, no mcycle executed
local code = le32(0x00100893) .. le32(0x00000073)

local function cfg() return { ram = { length = 4096 }, uarch = { ram = { backing_store = { data_filename = IMG } } } } end
local TAIL = { string.rep("\0", 32), string.rep("\0", 32) }

if mode then
    local cartesi = require("cartesi")
    local m = cartesi.machine(cfg())
    if mode == "run_uarch" then
        local br = m:run_uarch(cartesi.UARCH_CYCLE_MAX)
        print(string.format("CHILD run_uarch: break=%s uarch_halt=%d uarch_cycle=%d mcycle=%d", tostring(br),
            m:read_reg("uarch_halt"), m:read_reg("uarch_cycle"), m:read_reg("mcycle")))
    elseif mode == "log_step_uarch" then
        local before = m:get_root_hash()
        local log = m:log_step_uarch()
        local after = m:get_root_hash()
        local ok, err = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, before, log, after)
        print(string.format("CHILD log_step_uarch: ok, uarch_halt=%d mcycle=%d verify_step_uarch ok=%s", m:read_reg("uarch_halt"),
            m:read_reg("mcycle"), tostring(ok)))
    elseif mode == "collect" then
        -- revert tail must end with the revert root hash (= current root for a fresh machine)
        local t = { string.rep("\0", 32), m:read_revert_root_hash() }
        local ok, r = pcall(m.collect_uarch_cycle_root_hashes, m, 1, 0, t)
        print("CHILD collect: ok=" .. tostring(ok) .. " " .. (ok and ("hashes=" .. #r.hashes) or tostring(r)))
    elseif mode == "bundle" then
        local t = { string.rep("\0", 32), m:read_revert_root_hash() }
        local ok, r = pcall(m.collect_uarch_cycle_bundle, m, 0, 0, t)
        print("CHILD bundle: ok=" .. tostring(ok) .. " " .. (ok and "returned" or tostring(r)))
    elseif mode == "remote" then
        local jsonrpc = require("cartesi.jsonrpc")
        local server = assert(jsonrpc.spawn_server())
        server:set_cleanup_call(jsonrpc.SHUTDOWN)
        local rm = server:create(cfg())
        local t = { string.rep("\0", 32), rm:read_revert_root_hash() }
        local ok, r = pcall(rm.collect_uarch_cycle_root_hashes, rm, 1, 0, t)
        print("CHILD remote collect: ok=" .. tostring(ok) .. " " .. (ok and "returned" or tostring(r)))
        local alive, e2 = pcall(rm.read_reg, rm, "mcycle")
        if not alive then
            print("CHILD remote: cartesi-jsonrpc-machine server died: " .. tostring(e2))
            server:set_cleanup_call(jsonrpc.NOTHING)
            os.exit(5)
        end
        pcall(function() server:close() end)
    end
    os.exit(0)
end

local f = assert(io.open(IMG, "wb"))
f:write(code .. string.rep("\0", 4096 - #code))
f:close()

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local fails = 0
for _, case in ipairs({ "run_uarch", "log_step_uarch", "collect", "bundle", "remote" }) do
    local p = io.popen("timeout 60 lua5.4 " .. sh_quote(arg[0]) .. " " .. case .. " " .. sh_quote(IMG) .. " 2>&1")
    local out = p:read("a")
    local ok, how, rc = p:close()
    io.write(out)
    if not ok then
        print(string.format("BUG: %s: child process terminated abnormally (%s %s) instead of returning/raising an error",
            case, tostring(how), tostring(rc)))
        fails = fails + 1
    else
        print("OK: " .. case .. " returned normally")
    end
end
os.remove(IMG)
if fails > 0 then os.exit(1) end
print("PASS")
