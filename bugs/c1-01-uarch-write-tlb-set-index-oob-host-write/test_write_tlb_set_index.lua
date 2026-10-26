-- Proof: uarch WRITE_TLB ECALL never range-checks set_index (a0).
-- Usage (repo root): eval $(make -s env); lua5.4 bugs/c1-01-uarch-write-tlb-set-index-oob-host-write/test_write_tlb_set_index.lua
-- Exits 1 and prints BUG: lines while the defect is present; prints OK once out-of-range set_index is handled.
-- Generated uarch RAM images and snapshots go to a fresh temporary directory (removed at the end).
local cartesi = require("cartesi")

-- tiny RV64I assembler
local function addi(rd, rs1, imm) return ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13 end
local function lui(rd, imm20) return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37 end
local ECALL = 0x73
local A0, A1, A2, A3, A4, A7 = 10, 11, 12, 13, 14, 17

local function make_uram(set_index_insn, path)
    local prog = {
        addi(A7, 0, 4), -- a7 = UARCH_ECALL_FN_WRITE_TLB
        set_index_insn, -- a0 = set_index
        addi(A1, 0, 0), -- a1 = slot 0
        lui(A2, 1), -- a2 = vaddr_page 0x1000
        addi(A3, 0, 0), addi(A4, 0, 0), ECALL,
        addi(A7, 0, 1), ECALL, -- halt
    }
    local f = assert(io.open(path, "wb"))
    for _, w in ipairs(prog) do f:write(string.pack("<I4", w)) end
    f:close()
end

local function new_machine(uram)
    return cartesi.machine({
        ram = { length = 0x100000 },
        uarch = { ram = { backing_store = { data_filename = uram } } },
    })
end

-- child mode: perform one operation and exit 0 if it returns normally
if arg[1] == "child" then
    local m = new_machine(arg[2])
    local op = arg[3]
    local ok, err = pcall(function()
        if op == "run" then m:run_uarch()
        elseif op == "log" then m:run_uarch(6); m:log_step_uarch() -- step the ECALL (7th instruction)
        elseif op == "collect" then
            local tail = { string.rep("\0", cartesi.HASH_SIZE), string.rep("\0", cartesi.HASH_SIZE) }
            m:collect_uarch_cycle_root_hashes(1, 0, tail)
        end
    end)
    print(op, ok, ok and "" or tostring(err))
    os.exit(0)
end

local DIR = os.tmpname()
os.remove(DIR)
assert(os.execute("mkdir -p " .. string.format("%q", DIR)))

local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end

-- Case 1: huge set_index (0x40000) -> wild host write
local big = DIR .. "/uram_big.bin"
make_uram(lui(A0, 0x40), big) -- a0 = 0x40000
for _, op in ipairs({ "run", "log", "collect" }) do
    local cmd = string.format("timeout 60 lua5.4 %q child %q %s 2>&1", arg[0], big, op)
    local p = io.popen(cmd)
    local out = p:read("a")
    local _, _, code = p:close()
    io.write(string.format("[set_index=0x40000] %-8s exit=%s out=%s\n", op, tostring(code), out:gsub("\n", " ")))
    if code ~= 0 or not out:find(op .. "\ttrue") then
        bug(string.format("%s with uarch WRITE_TLB set_index=0x40000 did not complete normally (exit %s, 139=SIGSEGV)", op, tostring(code)))
    end
end

-- Case 2: set_index = 3 -> writes shadow.tlb_padding_ (state 0x7000) and penumbra past its end;
-- the resulting machine cannot be stored+loaded, and verify_step_uarch accepts the step.
local s3 = DIR .. "/uram_s3.bin"
make_uram(addi(A0, 0, 3), s3)
do
    local m = new_machine(s3)
    m:run_uarch(6) -- stop right before the WRITE_TLB ECALL
    local before = m:get_root_hash()
    local log = m:log_step_uarch()
    local after = m:get_root_hash()
    local wr
    for _, a in ipairs(log.accesses) do if a.type == "write" and a.log2_size == 5 then wr = a end end
    print(string.format("[set_index=3] logged write at 0x%x (log2 %d); shadow TLB is [0x%x,0x%x)", wr.address, wr.log2_size,
        cartesi.AR_SHADOW_TLB_START, cartesi.AR_SHADOW_TLB_START + cartesi.AR_SHADOW_TLB_LENGTH))
    local ok, res = pcall(cartesi.machine.verify_step_uarch, m, before, log)
    print("[set_index=3] verify_step_uarch:", ok, ok and (res == after and "accepted (hash matches)" or "hash mismatch") or res)
    if ok and res == after and wr.address >= cartesi.AR_SHADOW_TLB_START + cartesi.AR_SHADOW_TLB_LENGTH then
        bug("verify_step_uarch accepts a WRITE_TLB with set_index=3 that wrote outside the shadow TLB (shadow padding)")
    end
    -- finish the uarch run and try store/load round trip
    m:run_uarch()
    local sdir = DIR .. "/snap_s3"
    os.execute("rm -rf " .. sdir)
    local sok, serr = pcall(function() m:store(sdir) end)
    print("[set_index=3] store:", sok, serr or "")
    if sok then
        local lok, lerr = pcall(cartesi.machine, sdir)
        print("[set_index=3] load stored machine:", lok, lok and "" or lerr)
        if not lok then
            bug("machine stored after WRITE_TLB set_index=3 cannot be loaded back: " .. tostring(lerr))
        end
    end
    os.execute("rm -rf " .. sdir)
end

os.execute("rm -rf " .. string.format("%q", DIR))
if bugs > 0 then os.exit(1) end
print("OK: set_index out of range is rejected/handled")
os.exit(0)
