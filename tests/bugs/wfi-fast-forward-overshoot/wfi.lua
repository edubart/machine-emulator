-- Unreproducible WFI fast-forward lands one mcycle past its deadline.
--
-- Usage: lua5.4 wfi.lua <case>     case = run-target | timer
--
-- On an unreproducible machine (iunrep=1), execute_WFI (src/interpret.cpp) waits for host events and
-- machine::poll_external_interrupts (src/machine.cpp) advances mcycle with the elapsed host time, clamped to
-- mcycle_max = min(rtc_time_to_cycle(mtimecmp), mcycle_end). The interpreter loop then still adds 1 for the WFI
-- itself, so the WFI retires at mcycle_max + 1:
--   run-target: run(N) on a "wfi; j -4" loop with the timer far away ends at mcycle N+1 instead of N (a repeated
--               run(N) then fails with "mcycle is past"). Assert-enabled builds abort on
--               assert(a.read_mcycle() == effective_mcycle_end) in interpret(); run.sh counts that abort as the bug.
--   timer:      with the timer deadline on an RTC tick (mtimecmp*8192), mcycle jumps over the tick, and the timer
--               interrupt (raised only on ticks) is taken one RTC period (8192 mcycles) late. Reference: the same
--               guest on a reproducible machine (WFI is a NOP there) takes it at the deadline.
-- N and the deadline are multiples of 128 (cycles per microsecond) and the first WFI runs at mcycle 0, so the host
-- wait always reaches mcycle_max and the result does not depend on host timing.
-- Property checked (what a fix restores): the fast-forward never passes mcycle_max: run(N) ends exactly at N, and the
-- timer interrupt is taken at the deadline, as on a reproducible machine.
--
-- Exit codes: 0 = fixed, 10 = bug reproduced, anything else = test error.
local cartesi = require("cartesi")

local EXIT_OK, EXIT_BUG, EXIT_SETUP = 0, 10, 2
local RAM = 0x80000000
local HANDLER = 0x40 -- offset of the timer handler in RAM
local RTC_PERIOD = 8192 -- mcycles per mtime tick

local function code(words)
    local t = {}
    for i, w in ipairs(words) do
        t[i] = string.pack("<I4", w)
    end
    return table.concat(t)
end

-- RAM+0: wfi; j -4   (idle loop)
-- RAM+HANDLER: csrr s2, mcycle; halt via HTIF (tohost = 1)
local function new_machine(iunrep)
    local m = cartesi.machine({ ram = { length = 1 << 16 }, processor = { registers = { iunrep = iunrep } } },
        { console = { output_destination = "to_null" } })
    local loop = code({
        0x10500073, -- wfi
        0xffdff06f, -- j -4
    })
    local handler = code({
        0xb0002973, -- csrr s2, mcycle
        0x400082b7, -- lui  t0, 0x40008      (HTIF)
        0x00100713, -- addi a4, zero, 1
        0x00e2b023, -- sd   a4, 0(t0)        (tohost = 1: halt)
        0x0000006f, -- j    .
    })
    m:write_memory(RAM, loop .. string.rep("\0", HANDLER - #loop) .. handler)
    return m
end

local case = arg[1]
if case == "run-target" then
    -- control: on a reproducible machine run(N) ends at N
    local c = new_machine(0)
    c:write_reg("clint_mtimecmp", 1 << 40)
    c:run(1024)
    print(string.format("  (control) reproducible run(1024): mcycle=%d", c:read_reg("mcycle")))
    if c:read_reg("mcycle") ~= 1024 then os.exit(EXIT_SETUP) end
    for _, n in ipairs({ 1024, 4096, 128000 }) do
        local m = new_machine(1)
        m:write_reg("clint_mtimecmp", 1 << 40) -- timer far away: mcycle_max = mcycle_end
        print(string.format("  calling run(%d) on the unreproducible machine", n))
        io.stdout:flush()
        local br = m:run(n)
        local mc = m:read_reg("mcycle")
        local ok, err = pcall(m.run, m, n)
        print(string.format("  unreproducible run(%d): break=%d mcycle=%d ; repeated run(%d): %s", n, br, mc, n,
            ok and "ok" or err))
        if mc ~= n then
            print(string.format("  run(%d) ended at mcycle %d, past mcycle_end", n, mc))
            os.exit(EXIT_BUG)
        end
    end
    os.exit(EXIT_OK)
elseif case == "timer" then
    local deadline = 30
    local taken = {}
    for _, iunrep in ipairs({ 0, 1 }) do
        local m = new_machine(iunrep)
        m:write_reg("mtvec", RAM + HANDLER)
        m:write_reg("mie", 1 << 7) -- MTIE
        m:write_reg("mstatus", m:read_reg("mstatus") | 8) -- MIE
        m:write_reg("clint_mtimecmp", deadline) -- deadline at mcycle 30*8192 = 245760
        m:run(10000000)
        local halted = m:read_reg("iflags_H") == 1
        taken[iunrep] = halted and m:read_reg("x18") or nil
        print(string.format("  iunrep=%d: %s (deadline at mcycle %d)", iunrep,
            halted and ("timer handler entered at mcycle " .. taken[iunrep]) or "timer handler never entered",
            deadline * RTC_PERIOD))
    end
    if taken[0] ~= deadline * RTC_PERIOD then
        print("  control (reproducible machine) did not take the timer interrupt at the deadline")
        os.exit(EXIT_SETUP)
    end
    if not taken[1] or taken[1] - taken[0] >= RTC_PERIOD // 2 then
        print(string.format("  unreproducible WFI wake-up skipped the RTC tick: timer interrupt %s",
            taken[1] and string.format("taken %d mcycles late", taken[1] - taken[0]) or "never taken"))
        os.exit(EXIT_BUG)
    end
    os.exit(EXIT_OK)
else
    error("unknown case " .. tostring(case))
end
