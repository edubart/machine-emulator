# Angle `interp-isa`: unprivileged instruction semantics of the main interpreter

Scope: `src/interpret.cpp` (unprivileged RV64IMAC + Zcb + Zifencei, A extension, fetch, loads and stores), the
jump-table generator `tools/gen-interpret-jump-table.lua` / `interpret-jump-table.hpp`, and the helpers they use:
`shadow-tlb.hpp`, `find-pma.hpp`, `address-range.hpp`, `translate-virtual-address.hpp`, and `uint128.hpp`/flang Int128.
FP and CSR/privilege semantics belong to other angles.

PoC directory: `<SCRATCH>/work/interp-isa/`, where `<SCRATCH>` = `<SCRATCH>`.
- `run.c` / `run` is a C-API runner. It loads a bare-metal RAM image (4 MiB RAM) and runs it with `cm_run` (interp), with
  `cm_run_uarch`+`cm_reset_uarch` per mcycle (uarch), or both. In `both` mode it compares the root hashes.
- `build.sh` assembles with `riscv64-unknown-elf-gcc -march=rv64gc_zcb ... -Wl,--no-relax`.
- `run_poc.sh <poc>.S` does everything with one command. Exit 1 prints `BUG REPRODUCED`; exit 0 means spec behaviour.
- `README.txt` lists every PoC and check.

## Summary

| ID | Title | Status | Severity |
|---|---|---|---|
| interp-isa-1 | SC.W/SC.D to a misaligned address raises no exception and silently "fails" (rd=1) | PROVEN | Low |
| interp-isa-2 | PTE read from a non-memory physical address raises a page fault instead of an access fault | PROVEN | Low |
| interp-isa-3 | minstret under-counts by one per interrupt taken | PROVEN (DUPLICATE of interp-priv-3) | Low |
| interp-isa-4 | Data TLB stale after an M→M MRET or M→M trap with MPRV=1, so the architectural result depends on TLB contents | PROVEN (DUPLICATE of interp-priv-2) | Low |

Bottom line: no divergence and no memory-safety issue was found in the unprivileged interpreter paths. The decoder, ALU,
M, A, C and Zcb semantics, fetch (including page and PMA crossing), and load/store exception behaviour all match the
spec (see "Checked and found solid" below). The interpreter and the uarch agreed bit-for-bit, including root hash, in
every experiment.

---

### interp-isa-1: SC.W/SC.D to a misaligned address raises no exception and silently "fails" (rd=1)
- Status: PROVEN
- Area: interpreter (A extension)
- Category: spec-violation (deterministic, identical in interpret, uarch and step)
- Where: `src/interpret.cpp:1277-1296` `execute_SC()`. The reservation check `if (a.read_ilrsc() == vaddr)` comes
  before any alignment check. The alignment check only exists inside `write_virtual_memory_slow`, which runs only when
  the reservation matches. Since LR never sets a reservation on a misaligned address, a misaligned SC always takes the
  `val = 1` path.
- Problem: unprivileged spec, A/Zalrsc chapter: "For LR and SC, the Zalrsc extension requires that the address held
  in rs1 be naturally aligned to the size of the operand ... If the address is not naturally aligned, an
  address-misaligned exception or an access-fault exception will be generated." LR does raise it, via
  `read_virtual_memory_slow`. SC does not; it just writes 1 to rd.
  - The existing test `tests/machine/src/csr_counters.S:173-176` expects `sc.w t0,t0,(t0)` with t0=-1 to trap. It only
    passes by coincidence: -1 equals the "no reservation" sentinel `ILRSC_INIT = UINT64_C(-1)`, so the store path is
    taken and the misalignment is caught. Any other misaligned address (e.g. -2) does not trap (see `sc_sentinel.S`).
- Scenario: guest code (or a sanitizer or emulation layer in the guest) relies on SC trapping on misaligned pointers,
  for example to detect bugs or to emulate misaligned atomics in a trap handler. It instead sees a normal SC failure
  (rd=1). A typical LR/SC retry loop then spins forever, because the LR traps while the SC never does. It is
  deterministic, so there is no consensus impact.
- Evidence: `<SCRATCH>/work/interp-isa/run_poc.sh sc_misaligned.S` runs `sc.d` and `sc.w` on `buf+2` and expects 2 traps:
  ```
  [interp] halted=1 exit=1 ... a3=0x1 a4=0x1 a5=0x1      (no trap, rd=1 for both SCs)
  [uarch]  halted=1 exit=1 ... (identical)
  root hashes match
  BUG REPRODUCED: sc_misaligned (identical in interpreter and uarch)
  ```
  `sc_sentinel.S` shows the sentinel coincidence: `sc.w` at -1 traps, `sc.w` at -2 does not (1 trap total, a2=1).
- Possible solution: at the start of `execute_SC<T>`:
  ```cpp
  if ((vaddr & (sizeof(T) - 1)) != 0) [[unlikely]] {
      pc = raise_exception(a, pc, MCAUSE_STORE_AMO_ADDRESS_MISALIGNED, vaddr);
      return advance_to_raised_exception(a, pc);
  }
  ```
  Optionally, translate and PMA-check the address even when the reservation is invalid, as Spike does. The spec allows
  either ("a failed SC may be treated like a store").
- Severity: Low. Guest-visible spec deviation, with no cross-implementation impact.
- Risks: changes semantics, and therefore root hashes, for programs that execute misaligned SCs. It requires
  regenerating the uarch RAM image and pristine hash and updating the on-chain verifier and templates.

---

### interp-isa-2: PTE read from a non-memory physical address raises a page fault instead of an access fault
- Status: PROVEN
- Area: interpreter / MMU (load, store and fetch exception causes)
- Category: spec-violation (deterministic)
- Where: `src/translate-virtual-address.hpp:86-95` `read_ram_uint64()` returns false when the PTE address is not
  readable memory. `translate_virtual_address()` (line 171: `if (!read_ram_uint64(a, pte_addr, &pte)) return false;`) then makes
  the caller raise `MCAUSE_{LOAD,STORE_AMO,FETCH}_PAGE_FAULT`. The `read_ram_uint64`/`write_ram_uint64` result is not
  distinguished from a real page fault.
- Problem: privileged spec, Sv39 translation algorithm step 2: "If accessing pte violates a PMA or PMP check, raise an
  access-fault exception corresponding to the original access type." The emulator raises a page fault (12/13/15)
  instead of an access fault (1/5/7).
  - Related, not separately proven: `write_ram_uint64()` for the A/D update (line 240) has a "Can't fail" comment, but it does fail
    silently when the PTE lives in readable but non-writable memory. Examples are the CMIO rx buffer or a read-only
    flash drive. The translation then succeeds without setting A/D, where the spec requires an access fault. This is
    only reachable with page tables placed in host-provided read-only memory.
- Scenario: a guest kernel with a corrupted or malicious non-leaf PTE pointing outside RAM gets a page-fault cause.
  The kernel then routes the trap through its page-fault/demand-paging handler instead of the access-fault path. On
  Linux/RISC-V, access faults are reported directly as SIGSEGV/SEGV_ACCERR or an oops, while page faults go to
  `do_page_fault`. So the handler can misdiagnose or retry. Deterministic.
- Evidence: `<SCRATCH>/work/interp-isa/run_poc.sh pte_access_fault.S`. L1[2] is set to a non-leaf PTE pointing to PA
  0x10000000 (no PMA there), and an MPRV(S) load from VA 0x400000 is performed:
  ```
  [interp] a2=0x000000000000000d   (mcause 13 = load page fault; expected 5 = load access fault)
  [interp] a3=0x0000000000400000
  [uarch]  identical
  BUG REPRODUCED: pte_access_fault (identical in interpreter and uarch)
  ```
- Possible solution: make the walk return a tri-state result (ok / page fault / access fault). Return "access fault"
  when `read_ram_uint64` fails, or when `write_ram_uint64` fails for the A/D update. Map that to
  `MCAUSE_INSN_ACCESS_FAULT`, `MCAUSE_LOAD_ACCESS_FAULT` or `MCAUSE_STORE_AMO_ACCESS_FAULT` in the three callers
  (`read_virtual_memory_slow`, `write_virtual_memory_slow`, `fetch_translate_pc_slow`).
- Severity: Low. Guest-visible exception-cause deviation in a malformed page-table situation, deterministic.
- Risks: changes mcause and trap behaviour, and therefore root hashes, only for machines that hit it. It requires the
  usual uarch and on-chain regeneration. The not-update-A/D variant must not be "fixed" by silently ignoring
  failures in other implementations.

---

### interp-isa-3: minstret under-counts by one per interrupt taken (DUPLICATE of interp-priv-3)
- Status: PROVEN (independently). DUPLICATE of interp-priv-3; no severity change.
- Area: interpreter (counters)
- Category: spec-violation (deterministic)
- Where: `src/interpret.cpp:453` (`raise_exception` increments `icycleinstret` for interrupts too) and
  `raise_interrupt_if_any` (`5721-5730`), which consumes no mcycle. This contradicts `doc/README.md` ("icycleinstret
  holds the difference between mcycle and the architectural instruction count").
- Evidence: `<SCRATCH>/work/interp-isa/run_poc.sh minstret_irq.S`. `csrr minstret` is followed by `csrsi mstatus,MIE`,
  which takes a pending SSIP into M; the handler reads minstret. Expected delta 2, got 1 (`a2=0x1`, mcause
  0x8000000000000001), identical in interp and uarch.
- Possible solution: only increment `icycleinstret` when `!(cause & MCAUSE_INTERRUPT_FLAG)`.
- Severity: Low. Risks: root-hash and uarch-image change for any run that takes interrupts.

---

### interp-isa-4: Data TLB stale after an M→M MRET or M→M trap with MPRV=1 (DUPLICATE of interp-priv-2)
- Status: PROVEN (independently). DUPLICATE of interp-priv-2; no severity change.
- Area: interpreter / MMU
- Category: spec-violation (deterministic)
- Where: `src/interpret.cpp:2789-2816` `execute_MRET` (MPP←U, MPRV kept, no flush when `prv == mpp`) and
  `src/interpret.cpp:477-489` `raise_exception` (MPP←M, no flush when already in M).
- Evidence:
  - `run_poc.sh mret_mprv_tlb.S`: after MRET M→M with MPRV=1, a load of VA 0x80200000 that should be translated
    (U, maps to PA 0x80300000 = 0x2222) returns the stale untranslated value 0x1111 (`a2=0x1111`, mstatus=0xa00020080).
  - `run_poc.sh mret_mprv_tlb_control.S` is identical except the load before MRET is removed. It gets the correct
    0x2222. So the architectural result depends on prior TLB contents.
  - `run_poc.sh trap_mprv_tlb.S`: after an M→M `ecall` with MPRV=1 (MPP S→M), the handler's load returns the stale
    S-translation 0x2222 instead of physical 0x1111.
  - All three agree between interp and uarch (root hashes match).
- Additional note: stock OpenSBI is not affected. Every unprivileged access toggles MPRV through `csrw mstatus`, which
  flushes, and its `__sbi_expected_trap` handler only stores while the write TLB holds no MPRV entry.
- Severity: Low.

---

## Rejected hypotheses (checked and found not to be bugs)

- Odd PC via `csrw mepc`/`mtvec`/`sepc`/`stvec` then MRET or trap, which would break the "pc is 2-byte aligned"
  invariant of `fetch_insn` and make uarch `lhu` fault. REJECTED: `DEFINE_SA_WARL_READ/WRITE` in
  `i-state-access.hpp` mask these on every read and write. `dbg_mepc.S` reads back `...100/...100/...104/...104` for
  odd writes, and `odd_pc_mepc.S` returns to the even address. The only other source of odd PCs is the API, which is
  handled at `interpret_loop` entry.
- Guest access to the "uarch RAM" range (0x600000, listed as R/W/X in `get_address_ranges`). REJECTED: it is not in
  the big machine's PMA table. A guest load gets a load access fault (`uarch_ram_rw.S`).
- Portable `Fortran::common::Int128` (risc0 build: `-DAVOID_NATIVE_UINT128_T=1`, rv32im) vs native `__int128`.
  REJECTED for MULH/MULHSU/MULHU: `mulh128.cpp` compared all edge values and 5M random pairs with 0 mismatches. Also
  REJECTED for the soft-float mul/div/sqrt/fma/add paths that use uint128: `sfcheck.cpp` built native, portable, and
  portable with `-DMICROARCHITECTURE` remainder gave identical hashes over 1M random edge-biased inputs per op, for f32
  and f64. This is consistent with fp-4.
- Zcb `c.sext.b/c.zext.h/c.sext.h` (need Zbb) and `c.zext.w` (needs Zba) execute although Zbb/Zba are not
  implemented. REJECTED: these encodings are reserved without Zbb/Zba, and the unprivileged spec makes reserved
  encodings UNSPECIFIED (platform choice). The behaviour is identical in every implementation.
- AMO/LR/SC on device PMAs (CLINT, PLIC, HTIF) are performed as device read+write. REJECTED: AMO and reservability
  support is a platform PMA choice. Read-only memory (CMIO rx) correctly gives store/AMO access faults (`amo_exc.S`).
- Failed SC (no reservation) to an unmapped or read-only address raises no page or access fault. REJECTED: the spec
  says "a failed SC may be treated like a store".
- Reservation kept across M→M traps and MRET, and not cleared by ordinary stores from the same hart. REJECTED: the
  spec allows both.
- Stale fetch-cache translation in `interpret_loop`, which would make `cm_run` diverge from per-mcycle uarch or step
  replay. REJECTED: TLB_CODE slots are only replaced by fetches, and every TLB_CODE flush returns a status that
  invalidates the fetch cache: `set_prv` → failure/serve_interrupts, SFENCE.VMA and satp → `success_and_flush_fetch`.
  The page-crossing path updates the cache coherently.
- TLB sentinel pages (`-1`, `-2`) hitting `tlb_is_hit<T>` for some misaligned vaddr. REJECTED: the masked comparison
  always clears bits 11..log2(sizeof T), which are set in both sentinels.
- C++ UB in the integer, fetch and decode paths (shifts by ≥ width, signed overflow, evaluation order of state
  accesses). REJECTED: overflows use `__builtin_*_overflow`, shifts are masked, and there are no multi-access
  full-expressions. The UBSan/ASan build runs all PoCs and the ALU fuzz cleanly.

## Checked and found solid (evidence)

- Immediate decoders. `immtest.cpp` / `immtest2.cpp` exhaustively check all 2^16 compressed encodings, also with
  random garbage in the upper halfword, plus 20M random 32-bit words for I/S/B/U/J: 0 mismatches.
- Jump-table decode, reviewed against the spec:
  - Covers every RV64IMAC + Zcb + Zifencei opcode/funct3/funct7 path and the rd=0 specialization.
  - Reserved compressed encodings trap: C.ADDI4SPN imm=0, all-zero, C.ADDIW rd=0, C.LUI and C.ADDI16SP with imm=0,
    C.LWSP and C.LDSP with rd=0, C.JR rs1=0, Zcb reserved encodings.
  - HINTs execute as NOPs.
  - `gen_decode.py`/`decode.S` runs 51 tricky encodings (reserved, HINT, shamt[5] in W shifts, funct6/funct7 reserved
    bits, LR rs2≠0, FENCE/FENCE.I with nonzero fields, AMOCAS/Zabha/CBO/48- and 64-bit opcodes, ECALL rd≠0,
    SFENCE.VMA rd≠0). 0 mismatches vs spec in both interp and uarch.
- Integer semantics. `alufuzz.py` checks 6 seeds × 2-3k vectors of all RV64I/M register and immediate ops, W variants,
  shifts by 0/31/32/63/64, DIV/REM by zero and INT_MIN/-1, MULH*, rd==rs aliasing, and Zcb arithmetic/unary ops
  against a Python reference. 0 mismatches in interp and uarch, and under UBSan.
- Fetch:
  - A 32-bit instruction crossing a page or RAM end gives mepc = instruction start and mtval = address of the second
    half: page fault (12) for an invalid or non-X 2nd page, access fault (1) for a non-executable PMA or past RAM
    end (`fetch_cross_sv39.S`, `fetch_cross_ram_end.S`).
  - A compressed instruction in the last 2 bytes executes without touching the next page.
- AMO/LR exception causes (`amo_exc.S`):
  - Misaligned AMO → 6, AMO to read-only PMA or unmapped → 7, LR misaligned → 4, LR unmapped → 5.
  - AMO*.W sign-extends.
- Interp vs uarch random-instruction fuzz (`fuzz_iu.lua`, 95 programs × 2-3k mcycles, random compressed and
  uncompressed instructions with trap-and-skip): 0 root-hash mismatches. `rv64u{i,m,a,c}-p-*` ISA tests pass under
  `run_uarch`; only the documented baseline `-v-` mcycle mismatches fail.
