# Angle `interp-priv`: privileged architecture in the interpreter

Scope: `src/interpret.cpp` (CSR read/write, trap and interrupt raising and delivery, xRET, WFI, SFENCE.VMA,
privilege checks, main loop interrupt sampling), `riscv-warl.hpp`, `riscv-constants.hpp`, `shadow-registers.hpp`,
`machine-reg.hpp`, `processor-state.hpp`, and the CLINT/PLIC/HTIF interactions with mip/mtime.

PoC directory: `<SCRATCH>/work/interp-priv/`, where `<SCRATCH>` = `<SCRATCH>`.
Common helpers:
- `cmp.c` / `cmp` is a divergence harness. It runs a bare-metal RAM image to halt in four ways and compares mcycle, exit code, a0..a5 and the root hash:
  - (A) a single `cm_run`
  - (B) `cm_run(mcycle+1)` per cycle
  - (C) uarch (`cm_run_uarch` plus `cm_reset_uarch`) per mcycle, which is what the on-chain step verifies
  - (D) `cm_log_step(N)` plus `cm_verify_step`
- `build.sh` assembles `dir/prog.S` into `dir/prog.bin`.

Summary:
| ID | Title | Status | Severity |
|---|---|---|---|
| interp-priv-1 | Interrupt priority ignores the destination mode, which leaves an M-destined interrupt pending. The fast interpreter defers it to the next RTC tick (up to 8191 cycles), while uarch/step take it on the next cycle. Result: root-hash divergence and run-chunking dependence | PROVEN | Critical (precondition: M-mode firmware with partial S-interrupt delegation) |
| interp-priv-2 | Data TLB is not flushed when the effective data privilege changes through an M→M trap or an M→M MRET with MPRV=1 | PROVEN | Low |
| interp-priv-3 | minstret under-counts by 1 for every interrupt taken | PROVEN | Low |
| interp-priv-4 | sip.STIP and sip.SEIP are writable from S-mode (the spec makes them read-only in sip) | PROVEN | Low |
| interp-priv-5 | `mtimecmp * RTC_FREQ_DIV` wraps and a 0 product is treated as "disabled". Result: spurious MTI for huge mtimecmp, and none for mtimecmp=0 | PROVEN | Low |

---

### interp-priv-1: Interrupt priority ignores the destination mode, so an M-destined interrupt stays pending after a delegated one is taken; the fast interpreter and uarch/step then diverge
- Status: PROVEN
- Area: interpreter (interrupt delivery and main-loop sampling); divergence between cm_run / collect-hashes / log_step and uarch / on-chain step
- Category: divergence, nondeterminism (results depend on how `cm_run` is chunked), spec-violation
- Where:
  - `src/interpret.cpp:559-580` `get_highest_priority_irq_num()`: fixed order MEI, MSI, MTI, SEI, SSI, STI, applied to the mask of *all* enabled interrupts regardless of `mideleg`.
  - `src/interpret.cpp:5721-5730` `raise_interrupt_if_any()`: raises exactly one interrupt.
  - `src/interpret.cpp:5763-5792` `interpret_loop()`: interrupts are sampled only at the top of the outer loop. That happens at every RTC tick (`RTC_FREQ_DIV` = 8192 cycles) or when an instruction returns `success_and_serve_interrupts`.
  - `src/interpret.cpp:5697-5714` `assert_no_brk()`: was relaxed (fuzzer "Bug 4", `tests/lua/spec-fuzzer-bugs.lua:266-295`) to explicitly allow "non-delegated interrupts may remain pending ... serviced by the outer interpreter loop". That relaxation is exactly the divergence.
- Problem:
  - In S- or U-mode with SIE=1, `get_pending_irq_mask()` returns both delegated and non-delegated pending interrupts. `get_highest_priority_irq_num()` then picks purely by interrupt number.
  - Suppose a delegated S-level interrupt (e.g. SEI, mideleg bit set) and a lower-numbered but *non-delegated* S-level interrupt (e.g. STI, mideleg bit clear, so it goes to M) are both pending. The emulator first takes the S-destined SEI: trap to S, SIE←0.
  - The M-destined STI is still pending and enabled, because M-destined interrupts are always enabled in S-mode. The two execution engines now behave differently:
    - Fast interpreter (`cm_run`, `cm_collect_mcycle_root_hashes`, `cm_log_step(N>1)`/`cm_verify_step`): keeps executing S-mode handler instructions in the inner loop. It only re-samples at the next RTC tick, up to 8191 cycles later, or at the next serve-interrupts instruction.
    - uarch / one-cycle step: every call is `interpret(mcycle+1)` (`uarch/uarch-run.cpp:43`). It calls `raise_interrupt_if_any()` at the start of the very next mcycle and takes STI after exactly one handler instruction.
  - So the state committed by `cm_run` is not the state the uarch (and the Solidity/uarch step) produces for the same mcycle.
  - It also makes the fast path itself depend on how execution is split into `cm_run` calls (every call boundary re-samples interrupts). As a result, `collect_mcycle_root_hashes` with different `log2_mcycle_period` values, node restarts/snapshots, and different chunking all give different states.
  - It is also a spec violation. The spec rule is "Multiple simultaneous interrupts destined for different privilege modes are handled in decreasing order of destined privilege mode" (Priv. spec; the emulator's own comment at line 560 states "Interrupts for higher privilege modes must be serviced before interrupts for lower privilege modes"). So STI (to M) should have been taken first.
- Scenario:
  - The guest's M-mode firmware delegates only some S-level interrupts, e.g. `mideleg = SEIP` with STIP or SSIP left to M. A custom bare-metal or custom-firmware template could do this, or a malicious app developer could plant it so it looks like a harmless interrupt configuration. The stock OpenSBI used by Cartesi images delegates all three (measured `mideleg=0x222` after booting the test Linux image), so the standard Linux stack is not affected.
  - Once such a template is deployed:
    - Honest validators compute PRT commitments with the fast path (`cm_collect_mcycle_root_hashes` / `cm_run`).
    - The dispute bisection ends at an mcycle where the honest claim cannot be proven with the uarch step, while an adversary who computes uarch-consistent hashes wins. An attacker can then finalize a false claim.
    - Different nodes, or the same node with different chunk sizes or snapshot points, also compute different root hashes for the same input.
- Evidence:
  - PoC: `<SCRATCH>/work/interp-priv/irqprio/` (`prog.S`, `run.sh`; harness `../cmp.c`).
  - What the PoC does:
    - M-mode sets `mideleg=SEIP`, `mie=SEIE|STIE`, `mip.SEIP=mip.STIP=1`, `mstatus.SIE=1`, then MRETs to S.
    - The S handler just counts instructions in `s1`.
    - The M handler halts with exit code = `s1`.
  - Run: `sh <SCRATCH>/work/interp-priv/irqprio/run.sh` (exit 1 = bug).
  - Output:
    ```
    (A) cm_run(max) [fast, one call]   mcycle=8200     exit=4084   a0..a5=8000000000000005,8000000000000009,ff4,80000072,1fe9,0 root=8ac235312694efb5
    (B) cm_run(mcycle+1) per cycle     mcycle=34       exit=1      a0..a5=8000000000000005,8000000000000009,1,80000072,3,0 root=99a9150d80e429af
    (C) uarch per mcycle [on-chain]    mcycle=34       exit=1      a0..a5=8000000000000005,8000000000000009,1,80000072,3,0 root=99a9150d80e429af
    (D) cm_log_step(max)+cm_verify_step OK mcycle=8200     exit=4084   a0..a5=8000000000000005,8000000000000009,ff4,80000072,1fe9,0 root=8ac235312694efb5
    BUG REPRODUCED: fast interpreter (A) diverges from uarch/step semantics (C)
    ```
  - Interpretation:
    - The fast run executes 4084 S-mode instructions with an enabled M interrupt pending and halts at mcycle 8200 with a different root hash.
    - Per-cycle and uarch execution take the interrupt after 1 instruction.
    - A step log over the whole range still verifies (D). So `cm_log_step`/`cm_verify_step` and the uarch step disagree on the same transition.
  - Spec-correct behaviour would be mcause=STI with s1=0. Neither path does this.
  - Fix validated: the compatibility-preserving patch below was built in a private copy (`<SCRATCH>/work/interp-priv/build/src/libcartesi.so`). With it:
    - `./cmp_patched irqprio/prog.bin 20000` gives identical results in all four modes (mcycle=34, root=99a9150d…, equal to the current uarch).
    - The test Linux boot (`boot.c`) produces the identical root hash before and after the patch: `bc9b7dc2…d3c7`, mcycle 55395187.
- Possible solution:
  1. Compatibility-preserving fix for the host fast path only. It reproduces the current uarch/on-chain semantics, so no root hash or uarch-image change is needed. In `interpret_loop`, after `raise_interrupt_if_any`:
     ```cpp
     uint64_t mcycle_tick_end = mcycle + std::min(mcycle_end - mcycle, RTC_FREQ_DIV - (mcycle % RTC_FREQ_DIV));
     if (get_pending_irq_mask(a) != 0) { // another interrupt still pending/enabled
         mcycle_tick_end = mcycle + 1;     // re-sample after one instruction, like interpret(mcycle+1)
     }
     ```
     Guard it with `#ifndef MICROARCHITECTURE` if the uarch image must stay byte-identical. Also restore the strict `assert_no_brk` for the inner loop.
  2. Spec fix, for a breaking release: choose by destination first. Let `m_dest = (prv==M) ? mask : (mask & ~mideleg)`; pick from `m_dest` if it is non-zero, otherwise from `mask`. This also restores the invariant "no pending and enabled interrupt inside the inner loop".
- Severity: Critical (by the campaign definition: fast path vs uarch/on-chain step divergence and chunking nondeterminism). Practical precondition: the machine template's M-mode software must use partial S-interrupt delegation. It is not reachable from Linux user or kernel code under the stock OpenSBI.
- Risks:
  - If left unfixed, any template with partial delegation makes honest fast-path commitments unprovable, and nodes disagree depending on chunking.
  - Fix (1) changes no hashes for machines that never hit the condition (verified with the Linux boot) and matches the uarch for those that do.
  - Fix (2) changes semantics, so it requires regenerating the uarch RAM image and pristine hash and updating the on-chain step and templates.

---

### interp-priv-2: Data TLB not flushed when the effective data privilege changes through an M→M trap or an M→M MRET while MPRV=1
- Status: PROVEN
- Area: interpreter / MMU (privilege transitions)
- Category: spec-violation (deterministic across paths)
- Where:
  - `src/interpret.cpp:477-489` `raise_exception()`: M-mode branch writes `mstatus.MPP←prv`. `set_prv` (which flushes all TLBs) is called only `if (prv != PRV_M)`.
  - `src/interpret.cpp:2795-2813` `execute_MRET()`: writes `MPP←U` and keeps MPRV when `mpp==M`. `set_prv` is called only if `prv != mpp`.
  - Compare `write_csr_mstatus` (`src/interpret.cpp:2288-2294`), which correctly flushes read/write TLBs when MPP changes while MPRV=1.
- Problem: with MPRV=1, data accesses use privilege MPP. These events change MPP without changing the current privilege, so no TLB flush happens:
  - A trap taken from M to M sets MPP=M, so the effective privilege becomes M.
  - An MRET with MPP=M stays in M, sets MPP=U and keeps MPRV=1, so the effective privilege becomes U.

  The read/write TLB entries installed under the previous effective privilege keep being hit:
  - After the trap, M-mode loads are translated through the S/U page tables.
  - After the MRET, effective-U loads bypass translation and page permissions completely, using stale identity entries.

  Both changes are written straight to mstatus inside the trap/xRET code, not through `write_csr_mstatus`. The `mmu-tlb` agent listed MPRV/MPP flushes as OK, but only checked the CSR path.
- Scenario: M-mode firmware performs MPRV-based unprivileged accesses (e.g. emulation of misaligned accesses or SBI calls) and takes a trap, or MRETs to itself, while MPRV is still set. It then reads the wrong physical memory, and an effective-U access is not permission-checked. The stock OpenSBI pattern (csrrs MPRV; one access; csrw mstatus) does not hit it, so impact is limited to custom M-mode code. The behaviour is identical in the fast path, uarch and step, so there is no divergence.
- Evidence:
  - PoC: `<SCRATCH>/work/interp-priv/mprvtlb/` (`prog.S`, `run.c`, `run.sh`). Sv39 megapage maps VA 0x80280000 to PA 0x80080000 (holds B=0xbbbb); PA 0x80280000 holds A=0xaaaa.
  - Run: `sh <SCRATCH>/work/interp-priv/mprvtlb/run.sh` (exit 1 = bug).
  - Output:
    ```
    case1 (M->M trap, MPRV=1, MPP becomes M): handler load of 0x80280000 = 0xbbbb (expected 0xaaaa = physical)
    case2 (MRET M->M, MPRV=1, MPP becomes U): load of VA 0x80280000 = 0xaaaa (expected 0xbbbb = translated)
    BUG REPRODUCED: stale data TLB entries used after effective privilege change (MPRV)
    ```
  - `RAMLEN=4194304 ./cmp mprvtlb/prog.bin 1000` confirms that all four execution paths agree, so this is not a divergence.
- Possible solution: in both places, if MPRV=1 and MPP changed, flush the read and write TLB sets:
  - In `raise_exception` (M-mode branch): `if ((mstatus & MSTATUS_MPRV_MASK) && old_mpp != prv) { flush_tlb_set<TLB_READ>(a); flush_tlb_set<TLB_WRITE>(a); }`
  - In `execute_MRET` when `mpp == PRV_M`: the same check and flush.
- Severity: Low. M-mode only and deterministic, but it is a real permission-check bypass for effective-U accesses after MRET.
- Risks: changes root hashes (TLB contents are in the shadow state, and the uarch image changes) only for machines that hit the condition. It requires the usual uarch and on-chain regeneration.

---

### interp-priv-3: minstret under-counts by one for every interrupt taken
- Status: PROVEN
- Area: interpreter (counters)
- Category: spec-violation (deterministic)
- Where: `src/interpret.cpp:452-453` `raise_exception()`, which increments `icycleinstret` for every trap including interrupts. Interrupts are raised from `raise_interrupt_if_any` without consuming an mcycle, and `minstret = mcycle - icycleinstret` (`read_csr_minstret`/`read_csr_instret`, lines 1751-1758 and 1906-1910).
- Problem: for exceptions, the faulting instruction consumes an mcycle without retiring, so the increment is correct. An interrupt consumes no mcycle and retires nothing, yet still increments `icycleinstret`. So minstret drops by 1 per interrupt (it does not go backwards, but under-counts permanently).
- Evidence:
  - Run: `sh <SCRATCH>/work/interp-priv/instret/run.sh` (exit 1 = bug).
  - Output: `minstret delta across 4 retired instructions + 1 interrupt = 3 (expected 4)`.
- Possible solution: increment `icycleinstret` only for exceptions, i.e. `if (!(cause & MCAUSE_INTERRUPT_FLAG))`, or pass a flag.
- Severity: Low. Guest-visible counter inaccuracy only, and instret is not exposed to U-mode by stock Linux (`scounteren=0x2`).
- Risks: changes `icycleinstret` (hashed state), so it changes root hashes and the uarch image.

---

### interp-priv-4: sip.STIP and sip.SEIP are writable from S-mode
- Status: PROVEN
- Area: interpreter (CSR)
- Category: spec-violation
- Where: `src/interpret.cpp:2180-2187` `write_csr_sip()`, which uses `mask = mideleg`, so every delegated bit is writable.
- Problem: the Priv. spec (sip/sie section) says: "If implemented, STIP is read-only in sip" and "SEIP is read-only in sip". Only SSIP is S-writable. The emulator lets S-mode set STIP (self-inject timer interrupts) and clear an M-set or PLIC-set SEIP.
- Evidence:
  - Run: `sh <SCRATCH>/work/interp-priv/sipwr/run.sh` (exit 1 = bug).
  - Output: `S-mode 'csrs sip, STIP' set mip.STIP` / `S-mode 'csrc sip, SEIP' cleared mip.SEIP set by M-mode`.
- Possible solution: `const uint64_t mask = a.read_mideleg() & MIP_SSIP_MASK;` in `write_csr_sip`.
- Severity: Low. Only S-mode can do this, and it only affects S-mode's own interrupts.
- Risks: semantics change, so root hashes and the uarch image change for affected programs.

---

### interp-priv-5: mtimecmp comparison done as `mtimecmp*8192 <= mcycle` with 64-bit wrap; 0 treated as disabled
- Status: PROVEN
- Area: interpreter / CLINT
- Category: spec-violation (deterministic)
- Where:
  - `src/interpret.cpp:586-592` `set_rtc_interrupt()`: `timecmp_cycle = rtc_time_to_cycle(mtimecmp)` (`rtc.hpp`: `time * RTC_FREQ_DIV`), then `if (timecmp_cycle <= mcycle && timecmp_cycle != 0)`.
  - The same wrap affects WFI's `mcycle_max` (interactive only).
- Problem: MTIP must be pending iff `mtime >= mtimecmp`, an unsigned 64-bit compare. Any mtimecmp ≥ 2^51 wraps. For example, mtimecmp = 2^51+1 becomes 8192, so a spurious MTI fires at mtime=1. Also, any value whose product is 0 (mtimecmp=0, 2^51, …) never fires, although with mtimecmp=0 the interrupt should be pending immediately. The zero case looks intentional (MTIMECMP_INIT=0).
- Evidence:
  - Run: `sh <SCRATCH>/work/interp-priv/mtimecmp/run.sh` (exit 1 = bug).
  - Output: `BUG REPRODUCED: MTI taken at mtime=1 although mtimecmp=2^51+1`, with `mcause=0x8000000000000007 mtime_at_trap=1`.
- Possible solution: compare in time units, `rtc_cycle_to_time(mcycle) >= mtimecmp`. Optionally keep the "0 = disabled" convention explicitly if it is intended.
- Severity: Low. Only M-mode writes mtimecmp. Linux and OpenSBI use small values or −1 (which only fires at mcycle ≥ 2^64−8192).
- Risks: semantics change, so root hashes and the uarch image change for affected programs.

---

## Checked and found OK, or intentional (not reported)
- CSR permission and read-only checks:
  - `csr_prv(addr) > iprv` is checked on read and on write.
  - Read-only CSRs (bits [11:10]=3) trap only on an actual write. CSRRS/CSRRC with rs1=x0 and CSRRSI/CSRRCI with uimm=0 never write. CSRRW/CSRRWI always write, and skip the read when rd=x0.
  - The write happens before rd is updated, and illegal-instruction exceptions use tval = instruction bits (compressed instructions truncated to 16 bits).
- WARL legalization is applied on both read and write in `i_state_access` for every WARL register:
  - mstatus: MPP=HS becomes U; FS is forced Dirty when not Off; SD is computed; UXL/SXL/xBE/VS/TVM/TW/TSR masks are correct.
  - medeleg[11] (ECALL from M) is read-only zero. mideleg is restricted to S bits. mie/mip are restricted to the 6 standard bits.
  - mtvec/stvec are forced to direct mode. mepc/sepc have bit0=0. mcounteren/scounteren keep only CY/TM/IR. menvcfg/senvcfg keep only FIOM. fcsr is masked to 8 bits.
  - satp: a write with an unsupported MODE (incl. Sv57) leaves satp unchanged. ASIDLEN=0.
- sstatus is a correct view and write-mask of mstatus. sie/sip are masked by mideleg (except interp-priv-4). mip writes from M are limited to the S bits.
- Counters:
  - cycle/time/instret are gated by mcounteren (from S) and by mcounteren plus scounteren (from U).
  - minstret writes take effect after the instruction.
  - mcycle writes raise illegal instruction. This is intentional and documented in `write_csr_mcycle`.
  - The HPM counters, mcountinhibit and tselect/tdata are hardwired to zero, with writes ignored.
- fflags/frm/fcsr trap when FS=Off.
- Traps:
  - Cause values, epc, delegation (only for prv ≤ S), and the xPIE/xIE/xPP stacking are all correct.
  - MRET/SRET set xPP to U, set xPIE=1, and clear MPRV when returning below M.
  - `set_prv` flushes all TLBs and the LR reservation, and the fetch cache is invalidated on every privilege change.
- Instruction checks:
  - WFI is illegal in U-mode, and illegal in S-mode when TW=1. It is a NOP otherwise, and only advances mcycle in unreproducible mode.
  - SRET is illegal in U-mode, and illegal in S-mode when TSR=1.
  - SFENCE.VMA is illegal in U-mode, and illegal in S-mode when TVM=1; the encoding check is correct.
  - satp is illegal to access in S-mode when TVM=1.
  - URET and other non-exact SYSTEM encodings decode as illegal.
- Interrupt enable logic:
  - In M-mode, only non-delegated interrupts are taken, and only when MIE=1.
  - In S-mode, M-destined interrupts are always taken; delegated ones are taken when SIE=1.
  - In U-mode, all enabled interrupts are taken.
- MTIP is set only at RTC ticks, at the top of the outer loop. This happens at identical points in the fast path and the per-cycle uarch/step paths, so there is no divergence from that alone.
- CLINT msip-set and PLIC complete-with-pending return `success_and_serve_interrupts`. Every CSR write that can enable or raise an interrupt (mstatus/sstatus SIE/MIE, mie, sie, mip, sip, mideleg) and MRET/SRET also return it.
- No other path was found that can leave a pending, enabled interrupt inside the inner loop. Exceptions only shrink the enabled set. interp-priv-1 is the only invariant break found.
