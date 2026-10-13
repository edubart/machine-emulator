-- cm_log_step has no reproducibility guard: it runs, logs and "verifies" steps of unreproducible machines.
--
-- Usage: lua5.4 logstep.lua <case> <work-dir>
--   case = control | wfi | virtio-write | virtio-notify   (run one case, see below)
--        | gen-notify <out.bin>                            (write the queue-notify guest as a raw RAM image)
--
-- Policy in src/machine.cpp: no proofs or hashes from unreproducible machines (iunrep=1). log_step_uarch, run_uarch,
-- collect_mcycle_root_hashes, the bundle collectors and store refuse such machines; machine::log_step does not.
-- Consequences:
--   wfi:           the record accessor is not interactive, so WFI is a NOP in the logged step, while cm_run on the
--                  same unreproducible machine fast-forwards mcycle with host time. verify_step accepts a transition
--                  that cm_run never performs.
--   virtio-write:  the replay has no mock for VirtIO ranges, so the self-check fails, but only after interpret() has
--                  already run on the live machine: the call fails and leaves the machine changed.
--   virtio-notify: the queue notify makes the device read guest memory through record_step_state_access, which
--                  throws across the noexcept VirtIO MMIO callback: std::terminate aborts the process.
--   control:       the same wfi guest on a reproducible machine (iunrep=0): log_step and verify_step must work (checks
--                  that the cases below do not pass merely because log_step is broken).
-- Property checked (what a fix restores): log_step on an unreproducible machine fails up front, with the machine
-- unchanged (root hash, mcycle) and no step log written.
--
-- Exit codes: 0 = refused up front (fixed) / control passed, 10 = log_step proceeded (bug), anything else = test error.
-- The process abort of virtio-notify is detected by run.sh (the script prints a marker right before the call).
local cartesi = require("cartesi")

local EXIT_OK, EXIT_BUG, EXIT_SETUP = 0, 10, 2
local RAM = 0x80000000

-- RV64 encoders (hand-encoded guests, no assembler needed)
local function itype(op, f3, rd, rs1, imm)
    return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
end
local function stype(op, f3, rs1, rs2, imm)
    return (((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1f) << 7) | op
end
local function addi(rd, rs1, imm) return itype(0x13, 0, rd, rs1, imm) end
local function lui(rd, imm20) return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37 end
local function sw(rs2, imm, rs1) return stype(0x23, 2, rs1, rs2, imm) end
local function sd(rs2, imm, rs1) return stype(0x23, 3, rs1, rs2, imm) end
local function csrr(rd, csr) return itype(0x73, 2, rd, 0, csr) end
local WFI = 0x10500073
local SPIN = 0x0000006f -- jal x0, 0
local T0, T1, A0, A4 = 5, 6, 10, 14
local MCYCLE = 0xb00

local function code(...)
    local t = {}
    for _, list in ipairs({ ... }) do
        for _, w in ipairs(list) do
            t[#t + 1] = string.pack("<I4", w)
        end
    end
    return table.concat(t)
end

-- HTIF halt with exit code 0 (tohost = 1)
local HALT = { lui(T0, 0x40008), addi(A4, 0, 1), sd(A4, 0, T0), SPIN }
-- wfi; a0 = mcycle; halt
local WFI_PROG = code({ WFI, csrr(A0, MCYCLE) }, HALT)
-- VirtIO STATUS = DRIVER_OK; halt
local VIRTIO_WRITE_PROG = code({ lui(T0, 0x40010), addi(T1, 0, 4), sw(T1, 0x70, T0) }, HALT)
-- Minimal VirtIO driver bring-up (as every Linux virtio-mmio driver does), then a queue notify; halt
local VIRTIO_NOTIFY_PROG = code({
    lui(T0, 0x40010), -- first VirtIO MMIO window
    addi(T1, 0, 4),
    sw(T1, 0x70, T0), -- STATUS = DRIVER_OK
    sw(0, 0x30, T0), -- QUEUE_SEL = 0
    addi(T1, 0, 1),
    sw(T1, 0x44, T0), -- QUEUE_READY = 1
    sw(0, 0x50, T0), -- QUEUE_NOTIFY = 0
}, HALT)

local function hex(h)
    return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 16)
end
local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local case, wd = arg[1], arg[2]
if case == "gen-notify" then
    local f = assert(io.open(assert(wd), "wb"))
    f:write(VIRTIO_NOTIFY_PROG)
    f:close()
    os.exit(EXIT_OK)
end
assert(wd, "usage: logstep.lua <case> <work-dir>")
local runtime = { console = { output_destination = "to_null" } }

local function new_machine(iunrep, prog, with_p9fs)
    local config = { ram = { length = 1 << 20 }, processor = { registers = { iunrep = iunrep } } }
    if with_p9fs then config.virtio = { { type = "p9fs", tag = "vfs0", host_directory = wd .. "/hostdir" } } end
    local m = cartesi.machine(config, runtime)
    m:write_memory(RAM, prog)
    m:write_reg("clint_mtimecmp", 10) -- timer deadline at mcycle 10*8192
    return m
end

-- Calls log_step on m and checks that it was refused up front. Returns EXIT_OK or EXIT_BUG (plus the log path if
-- log_step succeeded).
local function check_refused(m, count)
    local log = wd .. "/" .. case .. ".log"
    os.remove(log)
    local h0, mc0 = m:get_root_hash(), m:read_reg("mcycle")
    print(string.format("  calling machine:log_step(%d) on the unreproducible machine (mcycle=%d root=%s)", count, mc0,
        hex(h0)))
    io.stdout:flush()
    local ok, ret = pcall(m.log_step, m, count, log)
    local h1, mc1 = m:get_root_hash(), m:read_reg("mcycle")
    local size = file_size(log) or 0
    print(string.format("  log_step: %s", ok and ("returned, break reason " .. tostring(ret)) or ("error: " .. ret)))
    print(string.format("  after: mcycle=%d root=%s, step log written: %d bytes", mc1, hex(h1), size))
    if ok then
        print("  log_step proceeded: it logged a step of an unreproducible machine")
        return EXIT_BUG, log
    end
    if h1 ~= h0 or mc1 ~= mc0 or size > 0 then
        print("  log_step failed only after running the step: the machine (or the log file) changed")
        return EXIT_BUG
    end
    return EXIT_OK
end

if case == "control" then
    local m = new_machine(0, WFI_PROG)
    local h0 = m:get_root_hash()
    local log = wd .. "/control.log"
    os.remove(log)
    local br = m:log_step(100, log)
    local h1 = m:get_root_hash()
    local hv = cartesi.machine:verify_step(h0, log, 100)
    print(string.format("  reproducible machine: log_step(100) break=%d halted=%d, verify_step %s", br,
        m:read_reg("iflags_H"), hv == h1 and "accepted (matches)" or "MISMATCH"))
    os.exit((hv == h1 and m:read_reg("iflags_H") == 1) and EXIT_OK or EXIT_SETUP)
elseif case == "wfi" then
    -- Twin machines from the same initial state: one runs with cm_run, the other is logged
    local run_m, step_m = new_machine(1, WFI_PROG), new_machine(1, WFI_PROG)
    assert(run_m:get_root_hash() == step_m:get_root_hash())
    local ok_c, err_c = pcall(step_m.collect_mcycle_root_hashes, step_m, 1000, 10, 0)
    print("  (for comparison) collect_mcycle_root_hashes: " .. (ok_c and "accepted" or ("refused: " .. err_c)))
    local h0 = step_m:get_root_hash()
    local rc, log = check_refused(step_m, 200000)
    if rc == EXIT_BUG and log then
        -- Show why accepting it is wrong: the "verified" transition is not the one cm_run performs
        run_m:run(200000)
        local hv = cartesi.machine:verify_step(h0, log, 200000)
        print(string.format("  verify_step accepts the log: root after=%s (a0=mcycle after wfi=%d)", hex(hv),
            step_m:read_reg("x10")))
        print(string.format("  cm_run from the same root:   root after=%s (a0=mcycle after wfi=%d)",
            hex(run_m:get_root_hash()), run_m:read_reg("x10")))
    end
    os.exit(rc)
elseif case == "virtio-write" then
    os.exit((check_refused(new_machine(1, VIRTIO_WRITE_PROG, true), 100)))
elseif case == "virtio-notify" then
    -- control: the same guest under machine:run completes normally
    local c = new_machine(1, VIRTIO_NOTIFY_PROG, true)
    c:run(100)
    print(string.format("  (control) machine:run(100): halted=%d mcycle=%d", c:read_reg("iflags_H"), c:read_reg("mcycle")))
    if c:read_reg("iflags_H") ~= 1 then os.exit(EXIT_SETUP) end
    c = nil
    collectgarbage()
    os.exit((check_refused(new_machine(1, VIRTIO_NOTIFY_PROG, true), 100)))
else
    error("unknown case " .. tostring(case))
end
