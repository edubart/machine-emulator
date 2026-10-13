# Angle `sol-pristine-replay`: end-to-end on-chain replay of honest runs with the pristine uarch

Scope: do honest runs agree end to end? The official (pristine) uarch image interprets real big-machine
instructions, and each uarch cycle plus the uarch reset is proven with `MetaStep.step` from machine-solidity-step
**PR #104** (v0.16.0-test2, prod `AccessLogs`), pinned to emulator **v0.22.0-test2**. Until now the PR's Solidity
tests replayed only the custom `rv64ui-uarch` programs (through `UArchStep.step`, final root only) and three reset
logs. This angle replays, through `MetaStep`, every uarch cycle of real big-machine mcycles from bare-metal guests, the
Cartesi ISA tests and a Linux boot. That includes the halted tail of each span and the reset meta-step.

Work dir: `<SCRATCH>/work/sol-pristine-replay/` (`<SCRATCH>` =
`<SCRATCH>`). Every log comes from the
**upstream** v0.22.0-test2 library (`<SCRATCH>/sol/upstream/root/usr`). Its pristine uarch hash `fa022ea7…` is the
Solidity `UARCH_PRISTINE_STATE_HASH`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| SOL-PRISTINE-REPLAY-1 | Honest runs: `MetaStep` replay of every uarch cycle + reset == emulator log root == `cm_run` (1 mcycle) | REJECTED (no divergence: 856 mcycles, 1.44M uarch-step records + 884 reset meta-steps, 518/518 forge batches PASS) | - |
| SOL-PRISTINE-REPLAY-2 | An honest mcycle needs >= 2^20 uarch cycles (uarch not halted at the reset meta-step) | REJECTED (worst case built: 46,761 uarch cycles, about 22x below 2^20; replayed on-chain) | - |
| SOL-PRISTINE-REPLAY-3 | A shadow / address-range access pattern of the image is unprovable on-chain | REJECTED (all classes replayed: 0x6fe0..0x6ff8, 0xfe0, uarch RAM tail, 4 MiB reset region, PMA table, CMIO, DTB, 16 drives up to 0xffffffffffeff8) | - |
| SOL-PRISTINE-REPLAY-4 | The rx-rejected reset (revert root hash substitution) disagrees on-chain | REJECTED (realistic revert hash after `send_cmio_response` and the zero revert hash: both agree) | - |
| SOL-PRISTINE-REPLAY-5 | An honest meta-step costs more gas than a block holds | REJECTED (max 1,392,918 gas per uarch step, 507,419 per reset meta-step) | - |

No defect was found on the honest pristine path. There is no `BUG REPRODUCED` reproducer. `run.sh` is a regression
check: it prints `NO DIVERGENCE` and exits 0, and would print `BUG REPRODUCED` and exit 1 on any revert, any root
mismatch or any uarch-vs-`cm_run` divergence. `control.sh` shows that the harness flags planted defects.

## Method

For every selected big-machine mcycle `M`, `gen.lua` keeps two twin machines (A = uarch path, B = `cm_run` path).
Both are brought to `M` with `cm_run` and must have equal roots. Then:

1. A runs `cm_log_step_uarch` on every uarch cycle until `uarch_halt` (MetaStep counters `j = 1..N`), then one halted
   no-op step (counter `N+1`, a leaf of the halted tail of the span). Then it logs the halted step plus
   `cm_log_reset_uarch` as **one meta-step with counter 2^20** (`MetaStep` runs `UArchStep.step` then
   `UArchReset.reset`). Every record carries its own root before and after, so files are small and can be split
   anywhere. For the reset record, the root after is what the emulator's own `verify_reset_uarch` computes from the
   log: the revert root hash after an rx-rejected yield, otherwise the physical root.
2. B runs `cm_run(M+1)`. The reset record also carries B's root as the reference (B's revert root hash after an
   rx-rejected yield). A's physical root after the reset must equal B's physical root.
3. Records go to binary batch files of at most 40 MB. At most 3 exist at a time, and each is deleted right after
   replay. Each batch is replayed by `PristineReplay.t.sol`, a forge test added to a copy of PR #104 (`mss/`). Every
   record goes through `MetaStep.step(counter, …)` and must not revert. MetaStep itself `require`s exact consumption of
   the proof buffer. The record must end at the emulator's root after. A reset meta-step must also end at the `cm_run`
   reference. Roots must chain within a file. `gasleft()` around the call measures gas per meta-step.

The task suggested a JSON catalog. A binary format replaced it, with the same per-step granularity (initial and final
hash per entry). The Dave/`AccessLogJsonParse.sol` buffer layout is re-implemented in `lib.lua:encode`.

Mcycle selection (`gen.lua`):
- `cover`: step one mcycle at a time and log the first mcycle of every new key. The key combines:
  - instruction class (opcode/funct3/funct7; FP op and rounding mode; compressed quadrant and funct; CSR number;
    SYSTEM function);
  - the memory region accessed (shadow, PMA table, uarch, CLINT, HTIF, PLIC, rx/tx, DTB, RAM, each flash/NVRAM, last
    word, TLB slot 255, unmapped);
  - the event (exception or interrupt cause and target privilege, privilege change, satp change, halt, X/Y yield, mip
    change);
  - the MMU mode, fetch from a non-RAM range, fetch from page slot 255, and page-straddling instructions.

  `EVONLY=1|2` restricts selection to events and rare classes. `HEAVYMAX` caps the TLB-flushing mcycles.
- `list` and `rand` pick explicit or random mcycles. `find_mcycles.lua` turns code labels into mcycles.

Workloads (`guest/*.S` are built by `guest/build.sh`; `prog:` configs are in `lib.lua`). RAM is 2 MiB. Flash 0 is at
2^55. The highest flash drive the emulator accepts is 0xfffffffff00000..0xfffffffffff000. CMIO buffers are private.
- `g_isa`: RV64I/M/A (every AMO op in W and D, LR/SC), C, Zcb, Zicsr, Zifencei. Traps: misaligned load/store/AMO,
  illegal, ecall, ebreak, access faults. Accesses to the flash drives (incl. AMO on the highest word), the PMA table,
  CMIO and the DTB. TLB slot 255 of every set.
- `g_fp`: F/D soft-float. Subnormals, qNaN/sNaN, inf, -0, extremes. Every static rounding mode, dynamic rounding with
  every `frm`, invalid rounding modes. NaN-boxing, every conversion, FMA (all 4 ops, S and D), compares/classify,
  FP loads/stores incl. compressed, `fcsr` accrual, FS=Off traps. All 26 OP-FP funct7 values and all 8 FMA variants
  were replayed.
- `g_mmu`:
  - Sv39 and Sv48, plus an Sv57 attempt (see Observations).
  - satp written from M and from S with ASID changes.
  - S and U accesses through 4K/mega/giga pages with hardware A/D updates.
  - Delegated page faults: invalid, misaligned superpage, reserved bits, W-only, X-only with and without MXR, SUM,
    store to read-only, fetch from non-X, non-canonical VA.
  - `sfence.vma` variants, mappings of device/flash/CMIO/PMA pages, U ecall to S, S ecall to M, `sret`/`mret`
    into U.
- `g_dev`:
  - CLINT mtime/mtimecmp/msip; timer and software interrupts in M and delegated to S; WFI (and WFI in U: illegal);
    PLIC.
  - HTIF console putchar; automatic yields (progress, tx-output, tx-report); counters and counteren.
  - CMIO tx writes and rx reads; a final rx-accepted manual yield.

  `g_rej` is the same guest ending with rx-rejected before any input, so the revert hash is still the initial zero.
- `g_adv`: a realistic rejected input. The guest yields rx-accepted. The driver sends a 64-byte advance-state
  `send_cmio_response` with `revert_root_hash` = current root (as a node does). The guest reads the rx buffer, writes
  an output, raises a tx-output automatic yield, then yields rx-rejected.
- `g_edge`: guest accesses to non-PMA state must fault: revert-hash leaf 0xfe0, shadow TLB 0x6ff8, TLB padding 0x7000,
  uarch state, uarch RAM tail 0x7ffff8. AMO/LR on HTIF, CLINT, the PMA table and rx. Page-straddling instructions
  inside RAM, at the end of RAM, and at the end of the highest flash drive. Fetch from flash, rx and tx (X=0: fault).
- `g_tlbhit`: hits on slot 255 of every TLB set. The uarch verifies the cold slot by reading 0x6fe0..0x6ff8, the
  last words before 0x7000.
- `g_nv` (`,nv` config: 8 flash drives with #7 read-only, and 8 NVRAMs with the last ending at 0xfffffffffff000;
  24 PMAs): loads/stores/AMO/LR/SC on NVRAM incl. the top word; stores/AMO to read-only flash; fetch from NVRAM;
  accesses above every PMA (full PMA-table scan).
- `g_heavy` / `g_heavy2`: the most expensive mcycles we could build (SOL-PRISTINE-REPLAY-2).
- `g_gaps` (generated by `gen_gaps.py` from a first coverage pass):
  - CSR accessors never reached before; an unimplemented CSR.
  - Zcb `c.lh/c.not/c.sext.b/c.sext.h/c.zext.h/c.zext.w/c.mul`, `c.nop`.
  - Every load/store width (LB..LD, LBU/LHU/LWU, FLW/FLD, SB..SD, FSW/FSD) x {TLB miss on a fresh page, device
    (CLINT), unmapped (access fault), misaligned, store to the read-only rx buffer}.
- Linux boot (`linux.bin` + `rootfs.ext2`, `ls /bin | head -5; echo done`, 61,370,464 mcycles to halt), sampled in
  windows:
  - OpenSBI (0-1.5M, 2-4M): DTB and CLINT accesses, straddling 2- and 4-byte instructions;
  - kernel (10M);
  - user space (34M-40M): syscall ecall U->S; instruction/load/store page faults delegated to S; `sret`; two
    `sfence.vma` forms; a machine-timer interrupt into OpenSBI; AMO/LR/SC; S-mode CSRs;
  - shutdown (61.37M);
  - 12 random mcycles.
- Cartesi ISA tests (`tests/build/machine`): one random mcycle each of 34 tests.

## Results

| group | jobs | mcycles | uarch steps | max uarch cycles in one mcycle |
|---|---|---|---|---|
| g_isa | isa | 191 | 155,836 | 3,668 |
| g_fp | fp fp2 | 149 | 116,578 | 4,412 |
| g_mmu | mmu mmu2 mmu-ev | 114 | 257,757 | 17,996 |
| g_dev | dev dev-ev | 68 | 138,908 | 17,647 |
| g_rej (zero revert hash) | rej | 3 | 3,740 | 2,660 |
| g_adv (real revert hash) | adv | 17 | 19,645 | 2,663 |
| g_edge | edge | 35 | 60,356 | 4,020 |
| g_tlbhit | tlbhit | 9 | 7,758 | 2,640 |
| g_nv | nv | 46 | 103,644 | 8,064 |
| g_heavy, g_heavy2 | heavy heavy2 | 6 | 133,573 | **46,761** |
| g_gaps | gaps | 95 | 151,231 | 3,666 |
| Linux boot | lx-sbi/kern/user/end/rand/ev1/ev2/ev3 | 89 | 210,584 | 17,909 |
| ISA/Cartesi tests | 34 x 1 random mcycle | 34 | 38,534 | 17,479 |
| **total** | | **856** | **1,398,144** | 46,761 |

Forge totals (`out/replay.log`, `summarize.py`): **518 batches, 518 PASS, 0 FAIL**. They hold **1,436,327 uarch-step
meta-steps** (including one halted no-op step per mcycle) and **884 reset meta-steps**. 883 reset meta-steps matched
the `cm_run` reference; the remaining one is the zero-revert reset, checked against the emulator log only. The forge
totals are a little higher than the table because two interrupted runs were redone. Emulator side: 0 uarch-vs-`cm_run`
mismatches. Every reset log of the jobs after the restart was also accepted by the emulator's own
`verify_reset_uarch`, which supplied the expected root.

Events replayed on-chain (exceptions/interrupts: target):
- Exceptions: 1, 2, 3, 4, 5, 6, 7, 11 -> M; 9 (S ecall) -> M; 2 from U (WFI, S-CSR) -> M; 8 (U ecall) -> S; 12, 13,
  15 -> S (Linux and `g_mmu`).
- Interrupts: 1 -> S; 3 and 7 -> M.
- SYSTEM: `mret` into S and U, `sret` into U, `wfi`, `sfence.vma` (3 forms).
- satp writes from M (MMU enable; MODE/ASID change); translations under Sv39 and Sv48 with A/D updates.
- HTIF halt, X yields (progress, tx-output, tx-report), Y yields (rx-accepted, rx-rejected).
- CSRs: 37 distinct CSR numbers via cover keys, plus 20 more accessors in `g_gaps`.
- AMO: all 11 AMO/LR/SC ops, W and D.

The S-timer and S/M-external interrupts (5, 9, 11) were only checked by the `cm_run`/uarch differential, not
on-chain. They differ from the replayed interrupts only in the cause number.

## SOL-PRISTINE-REPLAY-1: honest end-to-end agreement (REJECTED, no divergence)
- Status: REJECTED (the property holds on everything tested)
- Area: uarch / step-log / on-chain step (MetaStep, UArchStep, UArchReset, prod AccessLogs)
- Category: divergence
- Where: emulator `src/uarch-step.cpp`, `src/uarch-reset-state.cpp`, `src/uarch-record-state-access.hpp`, and the
  pristine `uarch-ram.bin`, vs PR #104 `src/MetaStep.sol`, `src/UArchStep.sol`, `src/UArchReset.sol`,
  `src/EmulatorCompat.sol`, `src/AccessLogs.sol`.
- Problem (hypothesis): an instruction class or machine event that the pristine uarch interprets yields a step log that
  `MetaStep.step` rejects. Or the log proves a root other than the emulator's root after, or other than `cm_run`.
- Evidence:
  - The tables above: 518/518 forge batches `[PASS]`, with 0 reverts, 0 root mismatches against the emulator log, 0
    against `cm_run`, and 0 chain breaks.
  - A broad differential without logging, root compared **after every mcycle** (`diff.lua`: pristine uarch
    `run_uarch` + `reset_uarch` vs `cm_run`):
    - all 272 built ISA/Cartesi tests (`out/diff_all_tests.log`: 272 `DIFF OK`);
    - every guest above (`DIFF OK`);
    - the whole Linux boot, 61,370,464 mcycles and about 3.57e10 uarch cycles, run mcycle by mcycle through the uarch
      and compared every 10^6 mcycles and at halt: `DIFF OK linux: mcycles=61370464 ucycles=… H=1 Y=0
      root=0x10c1e1638f2d6789…` (`out/diff_linux.log` 0-40M, `out/diff_linux2.log` 40M-halt).
- Severity: n/a.

## SOL-PRISTINE-REPLAY-2: the 2^20 uarch-cycle span (REJECTED)
- Status: REJECTED
- Area: uarch / meta-step layout. Category: divergence (liveness of the honest proof)
- Problem (hypothesis): `MetaStep` resets the uarch at every counter multiple of 2^20. If an honest mcycle needed
  >= 2^20 - 1 uarch cycles, the reset would hit a running uarch, and the on-chain state would diverge from `cm_run`
  and from `collect_uarch_cycle_root_hashes`.
  - Per mcycle the uarch runs `raise_interrupt_if_any`, then one instruction (`interpret_loop`).
  - A full TLB flush costs about 17.5k uarch cycles (768 slots). It happens on a privilege change (`set_prv`), a
    satp MODE/ASID change, or `sfence.vma`.
  - In a page walk, every PTE read and A/D write runs `find_pma`, which scans the PMA table at about 334 uarch cycles
    per entry.
  - A straddling instruction walks twice for the fetch.
- Evidence:
  - `g_heavy`: Sv48 tables live in the CMIO tx buffer, PMA index 18 of 24. One S-mode `ld` straddles a page (two
    fetch walks with A-bit writes), its load walks to an X-only leaf (load page fault), and the trap to M flushes all
    TLBs. Total: **33,619** uarch cycles.
  - `g_heavy2`: the same mcycle also starts with a delegated supervisor software interrupt taken from U (U->S, first
    flush). The handler sits on a fresh page (fetch walk) and loads through an X-only leaf (data walk, fault, trap to
    M, second flush). Total: **46,761** uarch cycles, about 22x below 2^20. Both heavy mcycles and their neighbors were
    replayed through `MetaStep` (heavy: 69,274 steps; heavy2: 64,299; all PASS).
  - No deeper walk or larger PMA table is possible here. Sv57 is compiled out (`NO_SATP_MODE_SV57`). Virtio devices
    make a machine unreproducible.
  - Largest values elsewhere: 17,996 (`g_mmu`) and 17,909 (Linux), both single TLB flushes.
- Severity: n/a (one mcycle allows at most 2 flushes plus 3 walks).

## SOL-PRISTINE-REPLAY-3: shadow and address-range access patterns (REJECTED)
- Status: REJECTED
- Area: Solidity `Memory`/`AccessLogs` vs emulator record state access. Category: proof-completeness
- Problem (hypothesis): some address the image touches hits an off-by-one in `Memory.regionFromStride` or
  `AccessLogs.readWord`/`writeWord`/`writeRegion`/`readLeaf`, or a proof the emulator encodes differently. Candidates:
  the last slot of the shadow TLB next to 0x7000, the revert-hash leaf 0xfe0, the uarch RAM tail and stack, the PMA
  table, flash/NVRAM near 2^56, and the 4 MiB uarch reset region.
- Evidence: access classes over all replayed logs (`stats_summary.py`, counts from the completed jobs):

  | class (address:type:log2 size) | count |
  |---|---|
  | write-TLB slot 255, 0x6fe0:write:5 (+ read sets 0..2, slot 255) | 34 (+ 38/36/34 writes, 60/15/13 reads per set) |
  | 0x6fe0:read:3 / 0x6ff8:read:3 (cold-slot verification, last words before 0x7000) | 5 / 2 |
  | revert-hash leaf 0xfe0:read:5 (rx-rejected resets) | 2 |
  | uarch RAM last page (stack), incl. 0x7ffff8:write:3 | 121,811 reads, 100,018 writes (659 at 0x7ffff8) |
  | uarch reset region 0x400000:write:22 | 659 |
  | PMA table 0x10000.. :read:3 | 2,375 |
  | flash 0..7, NVRAM, top flash/NVRAM word 0xffffffffffeff8 | 3/3, 1-2 each, 4/4, 7/6 |
  | CMIO rx read / tx read+write, DTB read+write | 5 / 20+8, 6+1 |
  | shadow registers (incl. device state of CLINT/HTIF/PLIC) | 16,730 reads, 2,864 writes |
  | all TLB sets, slot 0 and others | 3,717 word reads, 22,096 slot writes |

  Every class was replayed without failure. Device registers are shadow words under the uarch (mock ranges), so
  CLINT/HTIF/PLIC accesses appear as shadow-register accesses. The TLB padding page (0x7000-0x7fff) is never accessed:
  guest accesses fault before the uarch touches it. SOL-PROOF-CODEC-1, the last 32-byte leaf of the 2^64 space, is
  unreachable here because no PMA can map the last page.
- Severity: n/a.

## SOL-PRISTINE-REPLAY-4: rx-rejected reset (REJECTED)
- Status: REJECTED
- Area: UArchReset / revert root hash. Category: divergence
- Problem (hypothesis): after an rx-rejected manual yield, `uarch_reset_state` substitutes the revert root hash. The
  Solidity reads it as value + leaf hash + siblings of the 32-byte leaf at 0xfe0 (`EmulatorCompat.readRevertRootHash`).
  The two could disagree on the substituted root or on the encoding.
- Evidence:
  - `adv`: the revert hash is the real root at the rx-accepted yield, set by `send_cmio_response`. All 17 reset
    meta-steps were checked against `cm_run`/revert (17/17), 0 failures. The rejected reset costs 507,419 gas.
  - `rej`: no input ever delivered, so the revert hash is the initial zero hash. Emulator and chain both make the
    canonical root `0x00…00`.
- Severity: n/a.

## SOL-PRISTINE-REPLAY-5: gas (REJECTED)
- Status: REJECTED
- Evidence: gas of a single `MetaStep.step` (`gasleft()` around the call inside the test; calldata excluded). The
  uarch-step maximum is **1,392,918** (a WRITE_TLB ecall step); the distribution across all 518 batches tops out at
  1,392,838..1,392,918. Reset meta-steps cost 346,700 normally, 427,323 at an rx-accepted manual yield, and
  **507,419** with the revert substitution. All are a few percent of an L1 block.

## Coverage of the uarch image by the replayed mcycles

The upstream image has no symbols. As a proxy, `cov/trace.lua` re-runs exactly the replayed mcycles on the **local**
library and records every uarch pc. The local uarch image is built from the same sources by a different GCC, and
`cov/build/uarch` rebuilds it with `-O2 -g`, **byte-identical** to `uarch/uarch-ram.bin`. `cov/report.py` maps the pcs
to source lines and inline frames (`addr2line -i`).

- **16,578 of 27,974 instructions executed (59.3%; 61.7% excluding the 1,101-instruction `printf.c` debug code).**
- **862 of 963 `interpret.cpp` source lines with code (89.5%).**
- **385 of 392 `interpret.cpp` functions.** Never executed:
  - 5 `address_range` base-class virtuals, which are unreachable under the uarch (devices are mock ranges);
  - `read_csr_fail`, an inline 2-line helper whose code is attributed to its callers (illegal-CSR reads were executed);
  - `write_csr_mip` (`g_gaps` used `csrc mip, zero`, which does not write; `csrs mip` runs in `g_heavy2` outside the
    replayed mcycles).
- Per file (executed/total instructions):
  - `interpret.cpp` 5,839/9,379, `soft-float.hpp` 2,701/5,395, `shadow-tlb.hpp` 1,587/2,124;
  - `translate-virtual-address.hpp` 143/149, `find-pma.hpp` 197/239, `riscv-warl.hpp` 969/1,370;
  - `htif`/`clint`/`plic` ranges 88/120, 53/60, 54/178.
- The remaining gaps are mostly per-width inlined slow paths (for example, `execute_LB` device/fault copies) and
  soft-float rounding/special branches. The `cm_run`/uarch differential over all 272 tests covers them, but not
  on-chain.
- Directly observed in the upstream logs (post-restart jobs only): 11,206 distinct upstream uarch pcs.

## Observations (not defects)
- **Sv57 is compiled out** (`src/riscv-constants.hpp:32 #define NO_SATP_MODE_SV57`). A satp write with MODE=10 is
  ignored as WARL on every path ("the entire write has no effect"), so `g_mmu`'s Sv57 phase keeps Sv48. The task's
  "Sv39/48/57" means Sv39/48 in this version. All paths agree.
- **Flash drives and NVRAMs are not executable** (`X = false`, `src/machine-address-ranges.cpp`). Neither are the
  CMIO buffers. A fetch faults with cause 1 on every path.
- **Rejecting before any input reverts to the zero root.** A fresh machine's revert root hash is `0x00…00`. A
  template whose guest yields rx-rejected before any `send_cmio_response` gets a canonical root of `0x00…00` after
  the uarch reset (`MetaStep` and the emulator agree). No further step can be proven from that root. This is
  application-level (a broken template), so it is not reported.
- **The PR's own replay test** (`templates/UArchReplay.t.sol.template`) calls `UArchStep.step` directly and checks only
  the final root of each `rv64ui-uarch` program. `PristineReplay.t.sol` checks every step root, the halted tail, the
  reset meta-step through `MetaStep`, exact buffer consumption and the `cm_run` reference. It could be adopted by the
  PR with a small generated corpus, such as the quick mode below.
- The SOL-PROOF-CODEC-1 and SOL-TRANSPILE-EQUIV-1 defects need a non-pristine uarch. They were never triggered by the
  pristine image in this campaign.

## Harness validation (`control.sh`)
One mcycle of `g_tlbhit` (609 records) is replayed four ways. Unmodified: `[PASS]`. One sibling byte flipped in a
step proof: `[FAIL]` (`MetaStep.step reverted`). Wrong `cm_run` reference: `[FAIL]` (`reset meta-step root … !=
cm_run(1 mcycle) root`). Reset record with counter 2^20+1: `[FAIL]` (revert: no reset, buffer not fully consumed).
Output: `CONTROLS OK`.

## Reproducers / files
- `bash <SCRATCH>/work/sol-pristine-replay/run.sh`: quick regression, about 11 min on this host. Last run
  (`run_quick.out`): 11/11 `DIFF OK`; `forge batches=72 pass=72 fail=0 uarch-steps=168103 reset-metasteps=74
  cm_run-checked=73 max-gas-step=1392918 max-gas-reset=507419`; `NO DIVERGENCE`, exit 0.
  - Builds the guests and the forge project.
  - Runs the per-mcycle differential of every guest.
  - Replays through `MetaStep` the edge, rej, adv, tlbhit, heavy2, nv-subset and 3 random Linux mcycles.
  - Prints `NO DIVERGENCE` and exits 0; on any defect, prints `BUG REPRODUCED` and exits 1. Add `--controls` to also
    run `control.sh`.
- `bash run.sh --full`: the whole campaign (`jobs_isa.txt`, `jobs1_tab.txt`, `jobs_final.txt`, `jobs_extra*.txt`),
  plus the differential over all ISA tests and the whole Linux boot. Several hours.
- Files:
  - `gen.lua`: twin machines, mcycle selection, logging, batching.
  - `lib.lua`: encoder, record writer, `log_mcycle`, configs, the `adv` input preparation.
  - `PristineReplay.t.sol`: the forge `MetaStep` replay.
  - Job running and reporting: `replay2.sh`, `run_jobs.sh`, `summarize.py`, `stats_summary.py`.
  - `diff.lua`: the no-log differential. `find_mcycles.lua`: maps code labels to mcycles.
  - `guest/*.S`, `guest/gen_gaps.py`, `guest/build.sh`.
  - `cov/`: `trace.lua`, `trace_all.sh`, `report.py`, `coverage.txt`.
  - `out_campaign/`: the logs of this campaign (replay.log, gen logs, stats).
- Disk: every generated step log was deleted right after replay (peak about 120 MB on disk).
