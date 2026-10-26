-- Proof: uarch WRITE_TLB ECALL with slot_index >= TLB_SET_SIZE (256).
-- log_step_uarch (record path) throws "TLB slot index out of bounds", but
-- verify_step_uarch (replay path, mirrors Solidity step) accepts a log for
-- the same transition, writing the slot at shadow_tlb_get_abs_addr(0,256),
-- i.e. TLB_READ set slot 0. Record and replay disagree on the state transition.
local cartesi = require"cartesi"

local ECALL_ADDR = cartesi.UARCH_RAM_START_ADDRESS + 0x100000
local SHADOW_TLB_START = 0x1000
local SLOT_SIZE, SET_SIZE = 32, 256
local SLOT_ADDR = SHADOW_TLB_START + 0 * SET_SIZE * SLOT_SIZE + 256 * SLOT_SIZE -- = 0x3000

local function mk(a0, a1)
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    -- non-pristine uarch RAM: a single ecall instruction
    m:write_memory(ECALL_ADDR, string.pack("<I4", 0x00000073))
    m:write_reg("uarch_pc", ECALL_ADDR)
    m:write_reg("uarch_x17", cartesi.UARCH_ECALL_FN_WRITE_TLB) -- a7 = WRITE_TLB
    m:write_reg("uarch_x10", a0) -- set_index
    m:write_reg("uarch_x11", a1) -- slot_index
    m:write_reg("uarch_x12", 0x1000) -- vaddr_page
    m:write_reg("uarch_x13", 0x80000000 - 0x1000) -- vp_offset
    m:write_reg("uarch_x14", 0) -- pma_index
    return m
end

-- 1. Record path: the honest node cannot log the step.
local m = mk(0, 256)
local root_before = m:get_root_hash()
local ok, err = pcall(m.log_step_uarch, m)
print("log_step_uarch(set=0, slot=256):", ok, err)
local ok_run, err_run = pcall(m.run_uarch, m, 1)
print("run_uarch(1)                    :", ok_run, err_run)
assert(m:get_root_hash() == root_before, "unexpected state change")
assert(m:read_reg("uarch_cycle") == 0)

-- 2. Template log with the same access structure: set=1, slot=0 writes the same address 0x3000
local tmpl = mk(1, 0):log_step_uarch()
assert(tmpl.accesses[11].type == "write" and tmpl.accesses[11].address == SLOT_ADDR)

-- 3. Hand-build the log for (set=0, slot=256) against machine m's real state.
local function prove(addr, log2)
    local p = m:get_proof(addr & ~31, log2 < 5 and 5 or log2)
    return p
end
local log = { log_type = tmpl.log_type, accesses = {} }
for i = 1, 10 do -- reads in state S0
    local t = tmpl.accesses[i]
    local p = prove(t.address, t.log2_size)
    local read = t.read
    if (t.address & ~31) == 0x400060 then -- word with x9..x12: patch x10=0, x11=256
        read = read:sub(1, 8) .. string.pack("<I8I8", 0, 256) .. read:sub(25)
    end
    log.accesses[i] = { type = "read", address = t.address, log2_size = t.log2_size,
        read = read, read_hash = p.target_hash, sibling_hashes = p.sibling_hashes }
end
-- the write to tlb slot at shadow_tlb_get_abs_addr(0, 256)
do
    local t = tmpl.accesses[11]
    local p = prove(SLOT_ADDR, 5)
    log.accesses[11] = { type = "write", address = SLOT_ADDR, log2_size = 5,
        read_hash = p.target_hash, written_hash = t.written_hash, sibling_hashes = p.sibling_hashes }
end
-- produce state S1 (slot at 0x3000 written) on m by executing the equivalent (set=1, slot=0) ecall,
-- then restoring pc/cycle/a0/a1
m:write_reg("uarch_x10", 1); m:write_reg("uarch_x11", 0)
m:run_uarch(1)
m:write_reg("uarch_pc", ECALL_ADDR); m:write_reg("uarch_cycle", 0)
m:write_reg("uarch_x10", 0); m:write_reg("uarch_x11", 256)
do -- pc write
    local t = tmpl.accesses[12]
    local p = prove(t.address, t.log2_size)
    assert(p.target_hash == t.read_hash)
    log.accesses[12] = { type = "write", address = t.address, log2_size = t.log2_size, read = t.read,
        read_hash = t.read_hash, written = t.written, written_hash = t.written_hash, sibling_hashes = p.sibling_hashes }
end
m:write_reg("uarch_pc", ECALL_ADDR + 4)
do -- cycle write
    local t = tmpl.accesses[13]
    local p = prove(t.address, t.log2_size)
    assert(p.target_hash == t.read_hash)
    log.accesses[13] = { type = "write", address = t.address, log2_size = t.log2_size, read = t.read,
        read_hash = t.read_hash, written = t.written, written_hash = t.written_hash, sibling_hashes = p.sibling_hashes }
end
m:write_reg("uarch_cycle", 1)
do -- final halt read
    local t = tmpl.accesses[14]
    local p = prove(t.address, t.log2_size)
    log.accesses[14] = { type = "read", address = t.address, log2_size = t.log2_size, read = t.read,
        read_hash = p.target_hash, sibling_hashes = p.sibling_hashes }
end
local root_after = m:get_root_hash()

-- 4. Replay path: verify_step_uarch accepts the transition the logger refused to produce.
local vok, obtained = pcall(cartesi.machine.verify_step_uarch, cartesi.machine, root_before, log)
print("verify_step_uarch(hand-built log):", vok, vok and "accepted" or obtained)

if not ok and vok and obtained == root_after then
    print("BUG: WRITE_TLB with slot_index=256: log_step_uarch/run_uarch throw ('" .. tostring(err) ..
        "') but verify_step_uarch accepts a log writing tlb slot at 0x3000 (TLB_READ slot 0); "
        .. "record and replay (Solidity-equivalent) disagree")
    os.exit(1)
end
if ok and not vok then print("OK: both paths reject"); os.exit(0) end
if ok then print("OK: record path logs the step") os.exit(0) end
print("OK: verifier rejects the out-of-range slot: " .. tostring(obtained))
os.exit(0)
