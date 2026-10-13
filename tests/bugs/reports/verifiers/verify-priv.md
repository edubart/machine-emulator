# Verification report: verify-priv (candidates interp-priv-1 .. interp-priv-5)

`<V>` = `<SCRATCH>/verify/verify-priv`.
All line numbers refer to the unmodified tree `/home/user/machine-emulator/src` (v0.22.0).

| id | verdict | severity (mine) | hunter's rating |
|---|---|---|---|
| interp-priv-1 | CONFIRMED | **Critical (conditional)**. It needs M-mode firmware with partial S-interrupt delegation. The stock Linux+OpenSBI stack cannot reach it: shown by proof and by measurement. | Critical |
| interp-priv-2 | CONFIRMED | Low | Low |
| interp-priv-3 | CONFIRMED | Low | Low |
| interp-priv-4 | CONFIRMED (hunter PoC re-run + code/spec review; no separate reproducer written) | Low | Low |
| interp-priv-5 | CONFIRMED (the "mtimecmp=0 never fires" half is an intentional convention) | Low | Low |

---

### interp-priv-1: interrupt selection ignores destination privilege, so an M-destined interrupt is left pending. The fast interpreter defers it; uarch / per-cycle execution do not.

- **Verdict: CONFIRMED.**
  - I re-derived the defect from the code, re-ran the hunter's PoC, wrote two independent reproducers, and enumerated the full trigger set.
  - I measured the stock Linux stack (not reachable) and validated two fix variants in a private build.

- **Root cause** (code read independently):
  - `get_pending_irq_mask()` (`interpret.cpp:506-549`): in S-mode with SIE=1 (and in U-mode) it returns *all* pending&enabled bits, both delegated (S-destined) and non-delegated (M-destined).
  - `get_highest_priority_irq_num()` (`interpret.cpp:559-580`) picks from that mask using the fixed order MEI, MSI, MTI, SEI, SSI, STI. It ignores `mideleg`, although its own comment (line 560) says higher-privilege destinations must come first.
  - `raise_interrupt_if_any()` (`5721-5731`) raises exactly one interrupt. If that interrupt is delegated, `raise_exception()` (`437-470`) traps to S and clears SIE. Any non-delegated S-level interrupt that was also pending is still pending and enabled, because M-destined interrupts are always enabled below M.
  - The fast interpreter samples interrupts only at the top of the outer loop (`5763-5792`). That happens at every RTC tick (8192 cycles), at every `success_and_serve_interrupts` instruction, and at every `interpret()` call boundary.
  - The uarch runs `interpret(a, mcycle+1)` for each mcycle (`uarch/uarch-run.cpp:43`), so it re-samples every cycle.
  - `cm_collect_mcycle_root_hashes` runs one `interpret()` per period (`machine.cpp:2373`), so it re-samples at every period boundary.
  - `cm_log_step(N)`/`cm_verify_step` (and the ZKARCHITECTURE replay) run one `interpret(N)`.
  - The debug `assert_no_brk` (`5697-5715`) was explicitly relaxed to tolerate exactly this leftover state ("fuzzer bug 4", `tests/lua/spec-fuzzer-bugs.lua:266-295`). The divergence it permits was not considered.
  - This is not documented or intentional anywhere I could find (doc/, CHANGELOG, tests).

- **Independent reproducer 1:** `<V>/irq1/run.sh` (`prog.S` + `repro.c`).
  - Configuration differs from the hunter's: `mideleg=SSIP` only, entry from U-mode, and an S handler of about 600 instructions with no CSR access.
  - It runs to the same mcycle N=16384 along 11 paths.
  - Actual output (stock lib):
    ```
    A  cm_run(N) once                        root=919c54df39f62dc9  [STI taken at mcycle s4=627, S-loop iterations before it s8=200]
    B  cm_run(mcycle+1) x N                  root=056d5ccc4b101aa9  [s4=25, s8=0]
    C  uarch big-steps x N (on-chain)        root=056d5ccc4b101aa9  [s4=25, s8=0]
    D  collect_mcycle_root_hashes p=2^0      root=056d5ccc4b101aa9
    D  collect_mcycle_root_hashes p=2^2      root=056d5ccc4b101aa9
    D  collect_mcycle_root_hashes p=2^5      root=ab2f516465a0c1b3  [s4=33, s8=3]
    D  collect_mcycle_root_hashes p=2^6      root=3b47203bc2eff717  [s4=65, s8=13]
    D  collect_mcycle_root_hashes p=2^10     root=919c54df39f62dc9
    D  collect_mcycle_root_hashes p=2^14     root=919c54df39f62dc9
    E  cm_log_step(N)+cm_verify_step         root=919c54df39f62dc9
    F  cm_run in chunks of 7 cycles          root=408094dcef979686  [s4=29, s8=1]
    N=16384: 5 distinct root hashes across 11 execution paths
    BUG REPRODUCED: root hash at mcycle 16384 depends on the execution path / chunking
    ```
  - There are five different root hashes for the same machine at the same mcycle.
  - The PRT commitment builder (`collect_mcycle_root_hashes`) produces different hashes for different `log2_mcycle_period` values. So an honest node's coarse-level and fine-level commitments are mutually inconsistent.
  - `cm_log_step(N)`+`cm_verify_step` accepts the fast-path transition (E), but the uarch step that the chain verifies produces C. The two step-proof systems disagree on the same transition.

- **Independent reproducer 2:** `<V>/enum/run.sh` (`enum.c`), an exhaustive enumeration that runs in under 1 s.
  - Search space: 5 privilege contexts (U, S/SIE=0, S/SIE=1, M/MIE=0, M/MIE=1) × 8 legal `mideleg` values (only SSIP/STIP/SEIP are delegatable, `riscv-warl.hpp:58`) × 63 non-empty pending sets, with all six bits enabled in `mie`.
  - For each configuration it compares `cm_run(64)` against 64 × `cm_run(+1)`.
  - Result: `2520 configurations, 18 diverge, prediction mismatches: 0`.
  - The trigger set is exactly the following:
    - The context is U-mode, or S-mode with SIE=1.
    - The highest-priority pending interrupt in the fixed order is delegated.
    - At least one non-delegated interrupt is also pending.

    Because MEI/MSI/MTI can never be delegated and are first in the order, the left-over interrupt is always a *non-delegated S-level* interrupt that ranks below a delegated one. The 9 (`mideleg`, pending) pairs, each in both contexts, are:

    | mideleg | pending | taken (to S) | left pending (M-destined) |
    |---|---|---|---|
    | 0x002 | SSIP+STIP | SSI | STI |
    | 0x200 | SEIP+SSIP | SEI | SSI |
    | 0x200 | SEIP+STIP | SEI | STI |
    | 0x200 | SEIP+SSIP+STIP | SEI | SSI, STI |
    | 0x202 | SEIP+STIP | SEI | STI |
    | 0x202 | SSIP+STIP | SSI | STI |
    | 0x202 | SEIP+SSIP+STIP | SEI | STI |
    | 0x220 | SEIP+SSIP | SEI | SSI |
    | 0x220 | SEIP+SSIP+STIP | SEI | SSI |

    `mideleg` ∈ {0, 0x020, 0x022, **0x222**} can never trigger. Any pending MEI/MSI/MTI is always taken first; after a trap to M, MIE=0 and nothing remains enabled.
  - Who can create the condition:
    - Non-delegated SSIP/STIP can only be set by M-mode software writing `mip`. S-mode `sip` writes are masked by `mideleg`.
    - SEIP is set by the PLIC, together with MEIP.
    - So the trigger requires M-mode software that keeps SSIP or STIP undelegated, sets it, and returns to S/U while a higher-ranked delegated interrupt is pending.

- **Hunter PoC:** re-run from a copy (`<V>/hunter/irqprio`). It reproduces exactly as documented (A/D: mcycle 8200, root 8ac23531…; B/C: mcycle 34, root 99a9150d…). The PoC is sound.

- **Stock Linux + OpenSBI (`linux.bin` + `rootfs.ext2`): not reachable.**
  - Proof:
    - OpenSBI writes `mideleg=0x222` once. It is already set at mcycle ≤ 20 000 and never changes (`<V>/linux/linux regs`, sampled every 20k and every 1M cycles). `mie` = 0x2a8 (MSIE|MTIE|STIE|SEIE).
    - With full delegation there is no non-delegated S-level bit. Every M-destined interrupt (MSI, MTI, MEI) outranks every S-destined one, so it is always taken first. After that, M-mode with MIE=0 has nothing enabled.
    - Linux cannot change `mideleg`, because it is an M-only CSR. Neither can cmio inputs.
    - OpenSBI's MTI→STIP and MSI→SSIP forwarding sets delegated bits only.
  - Measurement:
    - I built a private libcartesi (`<V>/build`, patch `<V>/instrumentation-and-fix.diff`). It flags (a) every "leftover" event (an interrupt still pending and enabled after one is raised) and (b) every inner-loop instruction that starts with a pending and enabled interrupt. Any (b) event means `cm_run(N)` differs from per-cycle/uarch execution.
    - Four workloads with stock semantics:
      - `true`: 55.4M cycles
      - `sleep 0.3`: 94.3M cycles
      - a busy shell loop: 106.6M cycles
      - `ls -R /usr; dd ...; sync`: 123.2M cycles, with 120 `riscv-timer` interrupts in `/proc/interrupts`
    - All four gave `divergent_insns=0 leftover_events=0`, and their root hashes were identical to the stock library (e.g. `true` → `bc9b7dc2…d3c7` @ 55 395 187).
    - The chunked-run cross-check (single run vs chunks of 4093 / 100003 / per-cycle window) is in `<V>/linux/chunk_all.out`; see the addendum at the end of this section.
  - Conclusion:
    - The bug cannot be triggered by dapp inputs or by Linux user/kernel code under the stock firmware.
    - It requires a template whose M-mode software uses partial S-interrupt delegation: a custom/bare-metal firmware, or a deliberately planted configuration.

- **Severity: Critical (conditional), keeping the hunter's rating.**
  - Why Critical: when triggered, the fast path (cm_run, collect_mcycle_root_hashes, log_step/verify_step) and the uarch/on-chain step disagree, and the result depends on how execution is split into calls. The guide defines that as Critical.
  - Concretely:
    - An honest node's commitments at different PRT levels are mutually inconsistent, and the fast-path state cannot be proven with the uarch step. The node therefore loses disputes, which can let an adversary finalize a claim.
    - Different nodes or snapshot points compute different hashes.
  - Practical exposure is limited to templates with non-standard M-mode firmware. I would treat the stock-stack risk as nil, but it is a latent consensus bug for any custom-firmware or bare-metal template. A malicious template author could hide a fraud-proof-breaking trigger in innocuous-looking firmware.

- **Fix assessment:**
  1. Hunter's minimal fix: after `raise_interrupt_if_any`, `if (get_pending_irq_mask(a) != 0) mcycle_tick_end = mcycle + 1;`
     - **Validated.** I implemented it as `CM_VP_FIX=1` in the private build, plus a variant (`CM_VP_FIX=2`) that checks only when more than one interrupt was pending and enabled.
     - With either variant:
       - `irq1/run.sh` shows all 11 paths agree, with root `056d5ccc…`, equal to the *current* uarch.
       - The hunter's PoC shows all 4 paths agree (99a9150d…).
       - The enumeration shows `0 diverge` across 2520 configurations.
       - The Linux boot hash is unchanged (`chunk_all.out`). It cannot change for those workloads anyway, because they have zero leftover events and the fix only acts on a leftover.
     - Because it reproduces the current uarch semantics, no on-chain change is needed and no uarch image or root-hash change is needed, **provided that**:
       - (a) The change is guarded with `#ifndef MICROARCHITECTURE`. This is mandatory, not optional: without the guard the uarch binary gains instructions, and since uarch RAM is part of the state hash, *every* machine's root hash and every uarch-cycle count would change.
       - (b) The ZKARCHITECTURE build (`replay_step_state_access`, the zk prover of `cm_log_step` logs) *does* include the fix, and any deployed zk guest is rebuilt. Otherwise, in trigger cases, a fixed host log will not replay on the old guest.
     - Step logs for normal workloads are unchanged. The logs are page-based (`record-step-state-access.hpp` `touch_page`), and the extra reads of mip/mie/mstatus/iprv/mideleg hit the shadow-register page, which is always touched.
     - Cost: one extra mask computation per outer-loop iteration. Variant 2 makes even that conditional.
     - Correction to the hunter's note "restore the strict assert_no_brk for the inner loop": with the fix, the single deferred instruction still runs with the leftover interrupt pending. A strict per-iteration assert would therefore fire. The assert must allow the first iteration when `mcycle_tick_end == mcycle+1`, or check only from the second iteration on.
  2. Spec-correct fix: choose by destination first (M-destined = `prv==M ? mask : mask & ~mideleg`).
     - It also restores the invariant (no leftover is possible).
     - But it changes which interrupt is taken in the 18 trigger configurations, so the uarch interpreter binary must change. That changes the pristine uarch RAM, hence **every** root hash, every template hash, and the uarch-step / computation-hash test vectors.
     - It belongs in a breaking release. Ship fix 1 now, and if fix 2 is adopted later, ship it together with a uarch regeneration.
  3. Root-cause hardening: also consider making `assert_no_brk` strict again in fuzz/debug builds, so this class of invariant break is caught.

- **Addendum: Linux chunking cross-check** (stock lib, `sleep 0.3`; filled in from `<V>/linux/chunk_all.out`). See the end of this file.

---

### interp-priv-2: data TLB not flushed when MPRV's effective privilege changes via an M→M trap or an M→M MRET

- **Verdict: CONFIRMED.**
- **Root cause:**
  - `raise_exception()` (`interpret.cpp:477-489`) writes `MPP←prv` (M) and calls `set_prv` (which flushes all TLBs) only when `prv != PRV_M`.
  - `execute_MRET()` (`2789-2815`) with `MPP==M` stays in M, writes `MPP←U`, keeps `MPRV=1`, and does not flush.
  - In both cases, with MPRV=1, the privilege used for loads and stores changes (S/U→M, or M→U) while the read/write TLB sets keep entries from the old one.
  - `write_csr_mstatus` (`2288-2294`) handles the same change correctly when it comes through the CSR path.
- **Spec basis** (Priv. ISA, mstatus.MPRV): "When MPRV=1, load and store memory addresses are translated and protected, and endianness is applied, as though the current privilege mode were set to MPP." MRET sets MPP to the least-privileged mode and clears MPRV only if the new privilege is not M.
- **Independent reproducer:** `<V>/priv2/run.sh`.
  - Different from the hunter's PoC: it uses MPP=S, and the M→M trap is caused by a faulting MPRV *load page fault*, the same shape as OpenSBI's "unprivileged access + expected trap".
  - Case 2 checks that an effective-U access to an **S-only page** faults.
  - Output:
    ```
    exit=3 a0=0x2222 a1=0x1111 a2=0x0 ...
    case1: M-mode handler (MPRV=1,MPP=M after M->M trap) read stale translated value instead of physical memory
    case2: after MRET M->M (MPRV=1,MPP=U) an effective-U load of an S-only page did not fault (stale identity TLB entry)
    BUG REPRODUCED
    ```
  - The hunter's PoC also reproduces (`<V>/hunter/mprvtlb`).
- **Severity: Low.**
  - It is deterministic and identical in every path (it is the same code), so there is no divergence.
  - It needs M-mode code that keeps MPRV set across a trap or an MRET-to-M. M-mode is fully trusted, so the case-2 "permission bypass" crosses no trust boundary.
  - Stock OpenSBI is not affected:
    - The `csrrs MPRV` step flushes the TLB first.
    - A faulting access installs no entry.
    - The expected-trap handler only stores to M-mode memory, through the write set, which was just flushed.
    - `csrw mstatus` flushes again afterwards.
- **Fix:** in both places, flush the TLB_READ and TLB_WRITE sets when MPRV=1 and the effective MPP changes. This changes the hash (the TLB is in the shadow state) and requires uarch regeneration, but it only alters behaviour for programs that hit the case.

---

### interp-priv-3: minstret loses one count per interrupt

- **Verdict: CONFIRMED.**
- **Root cause:**
  - `raise_exception()` (`interpret.cpp:452-453`) increments `icycleinstret` for every trap.
  - `minstret = mcycle - icycleinstret` (`read_csr_minstret`).
  - Exceptions consume an mcycle without retiring, which is correct. Interrupts raised by `raise_interrupt_if_any` consume no mcycle, so each one subtracts one from minstret.
  - Corner case: an interrupt raised at mcycle 0 makes the handler's first `csrr minstret` return 2^64-1.
- **Independent reproducer:** `<V>/priv3/run.sh`.
  - Invariant-based, using timer interrupts: with no exceptions, minstret must equal the number of executed mcycles.
  - Output: `minstret lost 3 counts over 3 interrupts with no exceptions (expected 0)` / `BUG REPRODUCED`.
  - The hunter's MSIP PoC also reproduces.
- **Severity: Low.** It is a guest-visible counter inaccuracy only, deterministic in all paths. Per the hunter's measurement (I did not re-measure it), Linux does not expose instret to U (scounteren=TM only).
- **Fix:** skip the increment when `cause & MCAUSE_INTERRUPT_FLAG`. This changes `icycleinstret`, hence hashes and the uarch image.

---

### interp-priv-4: sip.STIP and sip.SEIP writable from S-mode

- **Verdict: CONFIRMED** (code review plus a re-run of the hunter's PoC; no separate reproducer was written).
- **Root cause:** `write_csr_sip()` (`interpret.cpp:2181-2187`) uses `mask = mideleg`, so every delegated S bit is writable through `sip`.
- **Spec basis** (Priv. ISA, sip/sie): "If implemented, STIP is read-only in sip, and is set and cleared by the execution environment." The same holds for SEIP. Only SSIP is writable in sip.
- **Evidence:** the hunter's PoC, re-run from `<V>/hunter/sipwr`:
  `exit=5 … S-mode 'csrs sip, STIP' set mip.STIP / S-mode 'csrc sip, SEIP' cleared mip.SEIP set by M-mode / BUG REPRODUCED`.
  The PoC is sound: `mideleg=0x222` as OpenSBI, SIE=0 so nothing is taken, and the readback is through `sip`.
- **Severity: Low.**
  - Only S-mode can do this, and it only affects S-mode's own interrupts. Self-injecting STI is harmless. Clearing a PLIC-set SEIP would only hurt S itself.
  - It is deterministic in all paths, and stock Linux never writes these bits.
- **Fix:** `mask = a.read_mideleg() & MIP_SSIP_MASK`. This changes semantics, so hashes and the uarch image change for affected programs.

---

### interp-priv-5: mtimecmp compared as `mtimecmp*8192` with 64-bit wrap

- **Verdict: CONFIRMED** for the wrap. PARTIAL for "mtimecmp=0 never fires": that half is a deliberate convention, since `MTIMECMP_INIT=0` and the explicit `!= 0` check exist so a reset machine does not take an immediate MTI.
- **Root cause:**
  - `set_rtc_interrupt()` (`interpret.cpp:586-592`) computes `rtc_time_to_cycle(mtimecmp)` = `mtimecmp*8192` (`rtc.hpp:47`), which wraps for mtimecmp ≥ 2^51.
  - The spec condition is `mtime >= mtimecmp`, an unsigned 64-bit comparison.
- **Independent reproducer:** `<V>/priv5/run.sh`, with mtimecmp = 2^61+3 (a different value from the hunter's).
  Output: `exit=1 a0=0x8000000000000007 a1=0x3 … BUG REPRODUCED: machine timer interrupt taken although mtimecmp=2^61+3 is far in the future`.
  An MTI fires at mtime=3.
- **Severity: Low.**
  - Only M-mode writes mtimecmp.
  - OpenSBI/Linux use small deadlines or −1. −1 wraps to 2^64−8192 cycles, which is effectively never.
  - It is deterministic in all paths.
- **Fix:** compare in time units: `rtc_cycle_to_time(mcycle) >= mtimecmp`, keeping or dropping the 0 convention explicitly. This changes semantics only for huge mtimecmp values, but the uarch image changes.

---

## Artifacts
- interp-priv-1:
  - `<V>/irq1/run.sh`: 11-path same-mcycle comparison. Exit 1 when the bug is present. `LIBDIR=<V>/build/src CM_VP_FIX=1 sh run.sh` exits 0.
  - `<V>/enum/run.sh`: exhaustive trigger enumeration.
  - `<V>/linux/` (`linux.c`, `detect_all.sh`/`.out`, `chunk_all.sh`/`.out`): stock-stack measurements.
  - `<V>/build/`: private libcartesi build with an env-controlled detector and fixes (`CM_VP_DETECT`, `CM_VP_FIX=1|2`). The diff is in `<V>/instrumentation-and-fix.diff`.
- interp-priv-2: `<V>/priv2/run.sh`
- interp-priv-3: `<V>/priv3/run.sh`
- interp-priv-5: `<V>/priv5/run.sh`
- Shared helpers: `<V>/common/{runbin.c,mk.sh}`
- Hunter PoCs re-run from copies: `<V>/hunter/`

---

## Addendum: stock Linux chunking cross-check (`<V>/linux/chunk_all.out`)

The workload is `sleep 0.3`, with timer interrupts throughout. The first four rows use the stock libcartesi; the last two use the private build with `CM_VP_FIX=1`:
```
once halted=1 mcycle=94256803 root=ab36515572b34630b1d3228515211b8259309c2cae6b704dedc46ad66f1824aa
chunk=4093 halted=1 mcycle=94256803 root=ab36515572b34630b1d3228515211b8259309c2cae6b704dedc46ad66f1824aa
chunk=100003 halted=1 mcycle=94256803 root=ab36515572b34630b1d3228515211b8259309c2cae6b704dedc46ad66f1824aa
window[12000000,12300000)/K=1 halted=1 mcycle=94256803 root=ab36515572b34630b1d3228515211b8259309c2cae6b704dedc46ad66f1824aa   (300k per-cycle cm_run calls after Linux enabled timer irqs)
FIX=1 once halted=1 mcycle=94256803 root=ab36515572b34630b1d3228515211b8259309c2cae6b704dedc46ad66f1824aa
FIX=1 true: once halted=1 mcycle=55395187 root=bc9b7dc250d27e80bd295204229514cfec8c70396ef5abeafbc1a7d67bedd3c7   (same as stock boot hash)
```
- Every chunking gives the same hash on the stock stack. This matches the detector's `leftover_events=0`.
- The minimal fix leaves the stock Linux hashes unchanged.
