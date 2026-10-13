# Findings: sol-provability-budget (resource limits that could stop an honest party from proving a correct transition)

Scope: (1) the uarch-cycle budget of one big-machine mcycle (official uarch of the upstream v0.22.0-test2 library) against
`UARCH_CYCLE_MAX = 2^20-1`, which `collect_uarch_cycle_root_hashes` (`src/machine.cpp:2747`) and the on-chain overflow
fixed point (`UArchStep.sol`, `EmulatorConstants.UARCH_CYCLE_MAX = 0xfffff`) depend on; (2) the gas, calldata and memory
of honest worst-case on-chain proofs (`MetaStep.step` incl. reset and revert, `SendCmioResponse`, Dave's input-window
opening) against 30M / 36M block limits and the EIP-7825 per-transaction cap of 2^24 = 16,777,216 gas.

**Result: no defect. Every candidate is REJECTED with measured margins (negative result).**

| ID | Candidate | Status | Severity |
|---|---|---|---|
| SOL-PROVABILITY-BUDGET-1 | some mcycle needs >= 2^20-1 uarch cycles (collector throws; on-chain overflow fixed point + reset leave the instruction half-executed) | REJECTED (max 44,545 uarch cycles, margin x23.5) | - |
| SOL-PROVABILITY-BUDGET-2 | worst-access uarch step (WRITE_TLB ECALL, 14 accesses) does not fit a transaction | REJECTED (1.31M tx gas; 2.71M without optimizer) | - |
| SOL-PROVABILITY-BUDGET-3 | span-closing `MetaStep` (halted step + reset + revert) too expensive | REJECTED (0.51M; 1.24M without optimizer) | - |
| SOL-PROVABILITY-BUDGET-4 | `SendCmioResponse` with a 2 MiB rx-buffer write too expensive | REJECTED (0.87M, flat in data length) | - |
| SOL-PROVABILITY-BUDGET-5 | Dave input-window opening (input bytes + on-chain Merkle root + CMIO + step) too expensive | REJECTED for every reachable input (max 5.36M at the 2^16 InputBox cap); inputs > ~250 KiB would not fit 2^24 (informational) | - |
| SOL-PROVABILITY-BUDGET-6 | `Buffer.peekRoot` per-level allocations make memory cost quadratic in accesses per step | REJECTED as a provability risk (190 KB, ~69k gas quadratic term); optional optimization: 3.7x less execution gas, same roots | - |
| SOL-PROVABILITY-BUDGET-7 | proof calldata exceeds the 128 KiB txpool limit | REJECTED (max 94,148 bytes calldata) | - |

Reproduce: `bash <SCRATCH>/work/sol-provability-budget/run.sh` (~4 min loaded; exit 0 = negative result, prints
`BUG REPRODUCED` and exits 1 if any budget is exceeded) or `run.sh --full` (+ full FP survey over 5 rounding modes,
Linux boot sample, allocation-free `peekRoot` comparison; ~10 min). Last outputs: `run.out`, `run-full.out`, `out/`.

## Reasoning

**Uarch cycles per mcycle.** The pristine uarch runs `interpret(a, mcycle+1)` (`uarch/uarch-run.cpp`), i.e. one
outer-loop iteration: an optional interrupt (`raise_interrupt_if_any`, `src/interpret.cpp:5721`), one fetch (up to two
translations when a 4-byte instruction straddles a page), one execute. The uarch is RV64I (`-march=rv64i`,
`AVOID_NATIVE_UINT128_T=1`), so the variable costs are: M-extension through libgcc, soft-float through the flang `Int128`
bit-serial `/` and `%` (at most 128 iterations), page walks (at most 4 levels: `NO_SATP_MODE_SV57` is defined
unconditionally in `src/riscv-constants.hpp:32`), PMA scans (`find_pma`, at most 19 PMAs in a reproducible machine:
11 fixed + `CM_FLASH_DRIVE_MAX = 8`; virtio is refused for reproducible machines), and TLB flushes
(`flush_all_tlb`, `src/interpret.cpp:901`: 3 x 256 slots, one `WRITE_TLB` ECALL each). A full flush happens on
`set_prv` (privilege change on trap / xRET, `:375`), `satp` MODE/ASID change (`:2190`), and `SFENCE.VMA` (`:3524`). In one
mcycle at most two full flushes can occur: the interrupt trap, plus one flush or privilege-changing exception from the
fetched instruction (the instruction either completes or raises one exception; an xRET or CSR write never also traps).
Trap vectors are 4-byte aligned, so the instruction fetched after an interrupt cannot straddle a page: at most 2 walks
(fetch + data) in the two-flush case, at most 3 walks in the one-flush case. Analytic bound: ~2 x 17.6k (flush) +
2 x ~8k (walks with full PMA scans) + ~0.6k base, about 50k uarch cycles, ~20x below 2^20-1.

**Gas.** A uarch step touches at most 14 state words (WRITE_TLB ECALL: cycle, halt, pc, insn, a7, a0..a4, TLB slot
write, pc, cycle, halt); sub-word stores take 10 (read + write of the word). Each word access carries 32 + 59 x 32 =
1,920 bytes. The span-closing reset adds 4 accesses (uarch subtree write of 43 x 32 bytes, iflags.Y, tohost, revert
leaf + raw revert hash). `SendCmioResponse` takes 8 accesses whatever the data length (the data only enters as its
Merkle root; the rx-buffer region proof gets shorter as the region grows). Only Dave's input opening carries the input
bytes, bounded by the InputBox cap of `1 << 16` encoded bytes (`CanonicalMachine.INPUT_MAX_SIZE`,
cartesi-rollups-contracts 3.0.0-alpha.10, the version Dave pins; largest reachable encoding 65,508 bytes).

## Hypotheses tested

### SOL-PROVABILITY-BUDGET-1: an mcycle that needs >= 2^20-1 uarch cycles
- Status: REJECTED (unreachable with the pristine uarch; measured maximum 44,545 uarch cycles, margin x23.5)
- Area: uarch / collect-hashes vs on-chain step
- Category: proof-liveness (DoS of the honest prover)
- Where: `src/machine.cpp:2747` (`collect_uarch_cycle_root_hashes` throws on `uarch_cycle_overflow`);
  `src/uarch-step.cpp` / `UArchStep.sol` overflow fixed point; `MetaStep.sol` reset at `counter % 2^20 == 0`
- Problem (hypothesis): if one big-machine instruction needed 2^20-1 or more uarch cycles, the collector would throw
  and on-chain the span would stall in the overflow fixed point, then the reset would discard a half-executed
  instruction (the emulator's `cm_run` would not agree).
- Scenario: any guest program (application code or Linux) choosing the most expensive instruction sequence.
- Evidence: `progs/` guests driven by `ucount/ucount.c` (one `cm_run_uarch(UARCH_CYCLE_MAX)` + `cm_reset_uarch` per
  mcycle, upstream library, per-pc maxima). From `run.out`:
  ```
  [intm] MAX uarch cycles per mcycle: 2624 (UARCH_CYCLE_MAX 1048575, margin x399.6)
  [mmu] MAX uarch cycles per mcycle: 36241 (UARCH_CYCLE_MAX 1048575, margin x28.9)
  [mmu-flash] MAX uarch cycles per mcycle: 44545 (UARCH_CYCLE_MAX 1048575, margin x23.5)
  [fpsurvey-rm0] MAX uarch cycles per mcycle: 4817 (UARCH_CYCLE_MAX 1048575, margin x217.7)
  [mmu-flash] collect over mcycle 24769: 44546 leaves returned (uarch halted after 44545 cycles); last leaf == cm_run(mcycle+1)
  [mmu] collect over mcycle 24753: 36242 leaves returned (uarch halted after 36241 cycles); last leaf == cm_run(mcycle+1)
  ```
  Per-component maxima (uarch cycles for the whole mcycle; an idle instruction costs ~540):
  | Component | Max | Guest |
  |---|---|---|
  | worst combined: U-mode mcycle takes a delegated SSIP (U->S, full flush), fetches the S handler on a fresh page (4-level walk, A update), which is an AMO to a read-only fresh page (4-level walk, store page fault, not delegated -> S->M, full flush); page tables in the last of 8 flash drives (19 PMAs, every PTE lookup scans all) | **44,545** | `mmu.S -DFLASHPT` |
  | same with page tables in RAM (11 PMAs) | 36,241 | `mmu.S` |
  | one full TLB flush (`csrw satp` MODE change, `sfence.vma`, `mret` M->S/U, `ecall` S->M) | 17,479-17,639 | `mmu.S` |
  | `mstatus.MPRV` toggle (read + write sets) | 11,960 | `mmu.S` |
  | AMO / store / load to a fresh page, Sv48 walk + A/D + TLB fill (RAM PTs / flash PTs) | 1,749 / 8,154 | `mmu.S` |
  | 4-byte instruction straddling a page (two fetch walks; RAM / flash PTs) | 1,598 / 8,003 | `mmu.S` |
  | `fdiv.d` / `fsqrt.d` / `fmadd.d` family / `fdiv.s` (special + subnormal + random operands, all `frm`) | 4,819 / 4,349 / 1,697 / 1,462 | `fpsurvey.c` (full run: 5.38M FP-heavy mcycles) |
  | `mulh`, `mulhsu` / `mulhu` / `div`,`rem` (edge + random operands) | 2,624 / 1,391 / 1,204 | `intm.c` |
  | real workload: Linux boot sample, 6 windows x 200k mcycles | 17,912 (one trap with privilege change) | `linux/sample.lua` |

  Note: Sv57 is compiled out (`satp` MODE 10 is ignored as WARL), so the walk depth is 4.
- Possible solution: none needed. Optional defence in depth for the collector is SOL-METASTEP-LAYOUT-1's fix (treat
  overflow like a halt), relevant only to non-pristine uarch templates.
- Severity: - (rejected). Margin x23.5 measured, about x20 analytic.
- Risks: the margin would shrink if the uarch image becomes much slower (e.g. a compiler change or a debug uarch build),
  if more flushes per mcycle become possible, or if more PMAs are allowed. A regression test with `mmu.S -DFLASHPT` and
  an assertion such as `uarch_cycle < 2^17` would catch that early.

### SOL-PROVABILITY-BUDGET-2: worst-access uarch step does not fit a transaction
- Status: REJECTED
- Area: on-chain step (UArchStep / AccessLogs), proof size
- Category: proof-liveness
- Where: `UArchStep.sol` + `AccessLogs.sol` (`readWord`/`writeWord`/`write4Words`), `MetaStep.step`
- Problem (hypothesis): the largest honest uarch step proof does not fit a block or the per-transaction gas cap.
- Evidence: `gen/gasgen.lua` logs all 36,241 uarch steps of the worst mcycle with `log_step_uarch` (upstream library),
  encodes them with Dave's chain encoder, and `mss/test/GasBudget.t.sol` replays them through an external
  `Verifier.metaStep(root, counter, bytes calldata)` call (exact consumption, post-root checked):
  ```
  A. worst mcycle 24753 ...: 36241 uarch steps; max accesses/step 14; max proof 26880 bytes
      6 accesses: 30 | 7: 3230 | 8: 30400 | 9: 1009 | 10: 32 | 14: 1540 steps
  label | accesses | proof bytes | calldata bytes | exec gas | memory | calldata gas | tx gas (2028) | tx gas (7623)
  (Dave profile: via-IR, optimizer 200, prague)
  uarch step u=291 (14 accesses) | 14 | 26880 | 27012 | 865816 | 190528 | 425928 | 1312744 | 1312744
  (default profile of the step repo, no optimizer)
  uarch step u=291 (14 accesses) | 14 | 26880 | 27012 | 2259162 | 190528 | 425928 | 2706090 | 2706090
  ```
  The 14-access steps are the WRITE_TLB ECALLs (TLB fills and the 768-slot flushes).
- Possible solution: none needed.
- Severity: - (rejected). Headroom vs the 2^24 tx cap 15.46M (optimized) / 14.07M (unoptimized).
- Risks: none.

### SOL-PROVABILITY-BUDGET-3: span-closing MetaStep (halted step + uarch reset + revert)
- Status: REJECTED
- Area: on-chain step (MetaStep / UArchReset / EmulatorCompat.revertState)
- Category: proof-liveness
- Where: `MetaStep.step` (counter multiple of 2^20), `UArchReset.reset`, `EmulatorCompat.readRevertRootHash`
- Problem (hypothesis): the closing transition with revert does not fit a transaction.
- Evidence: because no mcycle reaches 2^20-1 uarch cycles (BUDGET-1), the step at the closing counter is always a
  halted no-op (2 accesses). The worst case is the rx-rejected yield (`progs/yield.S`), whose reset reads iflags.Y,
  tohost and the revert-hash leaf:
  ```
  B. closing step+reset+revert: 6 accesses, 11008 proof bytes
  close: halted step + reset + revert | 6 | 11008 | 11140 | 313920 | 73088 | 175264 | 510184 | 510184   (Dave profile)
  close: halted step + reset + revert | 6 | 11008 | 11140 | 1041000 | 73088 | 175264 | 1237264 | 1237264 (no optimizer)
  close: halted step + reset (plain)  | 4 |  7136 |  7268 | 214011 | 49952 | 113756 | 348767 | 348767   (Dave profile)
  ```
  The replay ends at the recorded revert root hash (asserted in `gasgen.lua` and on-chain).
- Possible solution: none needed.
- Severity: - (rejected).
- Risks: none.

### SOL-PROVABILITY-BUDGET-4: SendCmioResponse with a 2 MiB rx-buffer write
- Status: REJECTED
- Area: on-chain CMIO (SendCmioResponse)
- Category: proof-liveness
- Where: `SendCmioResponse.sol` (`writeRegion` of the rx buffer by its Merkle root)
- Problem (hypothesis): a full 2 MiB response is too expensive to prove.
- Evidence: the data enters only as `dataHash`; 8 accesses for every length, and the region proof shrinks as the
  region grows:
  ```
  SendCmioResponse 32 bytes      | 8 | 15360 | 15524 | 641467 | ... | 907071
  SendCmioResponse 2097152 bytes | 8 | 14848 | 15012 | 614824 | ... | 872236   (Dave profile; 1,839,125 without optimizer)
  ```
- Possible solution: none needed.
- Severity: - (rejected).
- Risks: none.

### SOL-PROVABILITY-BUDGET-5: Dave input-window opening (input bytes + on-chain Merkle root + CMIO + first step)
- Status: REJECTED for all reachable inputs; informational size limit for future InputBox changes
- Area: interface (emulator CMIO capacity vs Dave/InputBox), on-chain input Merkleization
- Category: proof-liveness
- Where: Dave `CartesiStateTransition.transitionState` (`counter & INPUT_MASK == 0`), `DaveConsensus.provideMerkleRootOfInput`
  (`LibKeccak256.hashBytes` + `LibBinaryMerkleTree.merkleRoot`, cartesi-rollups-contracts 3.0.0-alpha.10),
  `CanonicalMachine.INPUT_MAX_SIZE = 1 << 16`
- Problem (hypothesis): the opening of an input window is the only proof that carries the input; a large input could
  make the honest opening unprovable.
- Evidence: `mss/test/GasInput.t.sol` (`VerifierInput.openInput`: keccak + Merkle of the input as DaveConsensus does,
  then `SendCmioResponse` + `UArchStep` on the emulator's `log_send_cmio_response` + `log_step_uarch`):
  ```
  Dave input opening 32 bytes      | 15 | 28800 |   28996 |   1194131 |  249824 |   456856 |   1671987
  Dave input opening 65508 bytes   | 15 | 28448 |   94148 |   3841278 |  377728 |  1498868 |   5361146
  Dave input opening 65536 bytes   | 15 | 28448 |   94148 |   3841092 |  377664 |  1499300 |   5361392
  Dave input opening 131072 bytes  | 15 | 28416 |  159652 |   6572089 |  508448 |  2547352 |   9140441  (informational)
  Dave input opening 262144 bytes  | 15 | 28384 |  290692 |  12231362 |  770304 |  4643896 |  16896258  EXCEEDED 2^24 by 119042
  Dave input opening 1048576 bytes | 15 | 28320 | 1077060 |  51695235 | 2342592 | 17225880 |  68942115
  Dave input opening 2097152 bytes | 15 | 28288 | 2125604 | 118993616 | 4439456 | 34002596 | 153017212
  WORST total tx gas: 5361392 (Dave input opening 65536 bytes)
  headroom vs 30M block: 24638608  vs 36M: 30638608  vs EIP-7825 tx cap 2^24: 11415824
  ```
  The step after the CMIO response is always the uarch's first instruction (7 accesses), so the opening has at most
  15 accesses. With the 2^16 InputBox cap the worst opening needs 5.36M gas (x3.1 below 2^24); Dave's own allocation
  `Gas.WIN_LEAF_MATCH = 5,543,000` (bounded refund, not a cap) is consistent with the measured 3.84M of execution.
  The emulator accepts responses up to the 2 MiB rx buffer, but such an input cannot reach a dispute: the InputBox
  refuses it (and its own calldata alone would cost 34M gas). Openings stop fitting the 2^24 tx cap at about 250 KiB
  and a 30M block at about 0.45 MiB (two calldata-to-memory copies of the input plus ~1.2k gas per 32-byte leaf).
- Possible solution: none needed. If the InputBox cap is ever raised toward the emulator's rx-buffer size, keep it
  below ~200 KiB or pre-Merkleize inputs at submission (Dave GAS-CALIBRATION.md already discusses that option).
- Severity: - (rejected; not reachable with the deployed cap).
- Risks: raising `INPUT_MAX_SIZE` without re-measuring would make large inputs unprovable at their window opening.

### SOL-PROVABILITY-BUDGET-6: Buffer.peekRoot per-level allocation (quadratic memory)
- Status: REJECTED as a provability risk; optional gas optimization
- Area: on-chain Merkle proof checking (Buffer / AccessLogs)
- Category: gas efficiency
- Where: `src/Buffer.sol:77-110` (`peekRoot` allocates a `Buffer.Context` (64 B) and an `abi.encodePacked` buffer (96 B)
  per tree level, 59 levels per word access, never freed); `AccessLogs.writeWord` calls it twice per write
- Problem (hypothesis): memory expansion grows quadratically with the accesses per step and could dominate gas.
- Evidence: the number of accesses per step is bounded (max 14, opening 15), so the memory high-water mark is 190,528
  bytes for the worst step (quadratic term ~69k gas). Measured effect of the allocations (patch
  `peekroot-scratch.patch`: hash each level in scratch space 0x00-0x3f; same reads, all post-roots still match;
  `run.sh --full`, output `out/forge-dave-scratch.log`):
  | Record (Dave profile) | exec gas now | exec gas, scratch-space peekRoot | memory now / patched |
  |---|---|---|---|
  | uarch step, 14 accesses | 865,816 | 234,193 (-73%) | 190,528 / 30,048 B |
  | SendCmioResponse 32 B | 641,467 | 172,664 | 140,096 / 17,376 B |
  | close: step + reset + revert | 313,920 | 90,783 | 73,088 / 12,448 B |
  | Dave input opening 64 KiB | 3,841,092 | 2,869,186 | 377,664 / 164,064 B |
  With the patch the EIP-7623 calldata floor becomes the binding term for step proofs (1.09M tx gas for the
  14-access step, versus 1.31M now).
- Possible solution (optional): in `peekRoot`, read siblings with `mload` and hash in scratch space, as in the patch
  (also `keccak256(abi.encodePacked(leaf))` in `readWord`/`writeWord` can hash from scratch space). This changes only
  gas, not results.
- Severity: - (rejected as a defect; the cost of an honest proof falls but provability does not depend on it).
- Risks of the change: assembly must keep the `isEven(stride >> i)` orientation; the patched version reproduces all
  roots of the records here, and the PR's replay corpus should be rerun before adopting it.

### SOL-PROVABILITY-BUDGET-7: proof calldata exceeds the 128 KiB txpool limit
- Status: REJECTED
- Area: interface (proof size)
- Category: proof-liveness
- Where: Dave proof encoding (8-byte length + input + access logs)
- Evidence: the largest honest calldata measured is 94,148 bytes (64 KiB input opening), so about 37 KB remain under
  geth's 131,072-byte transaction size limit for the tournament arguments; plain step proofs are at most 27,012 bytes.
- Possible solution: none needed (same InputBox-cap caveat as BUDGET-5).
- Severity: - (rejected).
- Risks: none.

## Method and artifacts (`<SCRATCH>/work/sol-provability-budget/`)
- `run.sh`: one command for everything below; `run.out` (default mode), `run-full.out` (`--full`), `out/` (per-guest
  outputs, per-pc maxima, forge logs).
- `ucount/ucount.c`: per-mcycle uarch cycle counter on the upstream library (`UCOUNT_FLASH8=1` adds 8 flash drives,
  `UCOUNT_PCFILE` writes per-pc maxima); `ucount/pcmap.py` joins them with the disassembly.
- `progs/`: `mmu.S` (flush / walk / trap / interrupt scenarios; `-DFLASHPT` page tables in the last flash drive),
  `fpsurvey.c` (every F/D compute instruction, special + subnormal + random operands, all rounding modes),
  `intm.c` (RV64M edge + random), `yield.S` (rx-accepted then rx-rejected yields), `crt0.S`, `link.ld`, `build.sh`.
- `gen/gasgen.lua`: honest logs (upstream library) for all steps of the worst mcycle, step+reset (plain and revert),
  CMIO 32 B..2 MiB and Dave openings, Dave chain encoding, records for forge; `gen/collect_check.lua`.
- `mss/` (copy of the step repo, PR #104): `test/GasRecords.sol`, `test/GasBudget.t.sol`, `test/GasInput.t.sol`,
  `test/rollups/` (verbatim LibBinaryMerkleTree / LibKeccak256 / LibMath from cartesi-rollups-contracts 3.0.0-alpha.10),
  `[profile.dave]` in `foundry.toml` (Dave's settings: via-IR, optimizer 200 runs, prague).
- `peekroot-scratch.patch`: the optional `Buffer.peekRoot` optimization measured in BUDGET-6.
- `linux/sample.lua`: per-mcycle uarch cycles over Linux boot windows (`run.sh --full`).
