# Findings: sol-metastep-layout (on-chain meta-step indexing/composition vs the emulator's computation-hash leaves)

Work dir: `<SCRATCH>/work/sol-metastep-layout/` (`<SCRATCH>` = `<SCRATCH>`).
Emulator side: the upstream v0.22.0-test2 library (`<SCRATCH>/sol/upstream`, pristine uarch hash `fa022ea7…` = the
Solidity constant). Solidity side: machine-solidity-step PR #104 (branch `pr104`, v0.16.0-test2), lean copy in
`mss/` (src/, lib/, foundry.toml) with the new harness `mss/test/MetaLayout.t.sol`.
Also read (read-only, shallow clone in `ext/dave`): cartesi/dave `prt/contracts/src/state-transition/CartesiStateTransition.sol`,
`cartesi-rollups/contracts/src/DaveConsensus.sol` (`provideMerkleRootOfInput`), `cartesi-rollups/node/src/engine/machine_stf.rs`,
`docs/computation-hash.md`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| SOL-METASTEP-LAYOUT-1 | `collect_uarch_cycle_root_hashes` throws ("uarch reached its maximum cycle…") for an mcycle span that the on-chain step defines and proves (halting ECALL landing on uarch cycle 2^20-1, where `UArchStep` reports overflow; a uarch that never halts takes the same code path); reachable only with a non-pristine uarch in the template | PROVEN | Low |
| L-1 | Leaf layout: for 3475 sampled transitions over 20 scenarios, `SendCmioResponse.sendCmioResponse` + `MetaStep.step(counter = index + 1)` reproduces every leaf of `collect_uarch_cycle_root_hashes` (bundle log2 0, expanded per the spec); so does the Dave-style 0-based dispatch | REJECTED (no divergence) | - |
| L-2 | Conventions: doc 0-based `uarch_cycle == UARCH_CYCLE_MAX` and MetaStep 1-based `counter % 2^20 == 0` differ by exactly one; passing the 0-based index unchanged to MetaStep fails exactly on the input and reset transitions (counter 0 also resets) | REJECTED (by design, documented in MetaStep natspec) | - |
| L-3 | Fixed-point (idle) spans are idempotent on-chain: halted, manual yield (accepted / exception / unknown reason), mcycle overflow, imcyclemax exhausted, reverted machine after a rejection, template halted with a pending yield | REJECTED (no divergence) | - |
| L-4 | Seam 1 / seam 2 (rx-rejected / rx-accepted yield exactly on `mcycle == imcyclemax`), with and without `MCYCLE_MAX` saturation: reset reverts and next input is delivered identically on-chain and in the v0.22 collector (the v0.21 seam-1 collector divergence documented by Dave is fixed) | REJECTED (no divergence) | - |
| L-5 | Bundled forms: `collect_uarch_cycle_root_hashes` with bundle log2 1,2,3,5,10,19,20, `collect_uarch_cycle_bundle`, and `collect_mcycle_root_hashes` (period 1) agree with the expanded per-uarch-cycle leaves | REJECTED (no divergence) | - |
| L-6 | Dave's `CartesiStateTransition` (counter = 0-based leaf index, input on `counter & (2^68-1) == 0` gated on a nonzero input root, reset on `counter & (2^20-1) == 2^20-1`, `revertRootHash = machineState`, `dataHash` = zero-padded power-of-two keccak Merkle root with 32-byte leaves) matches the emulator's logs and leaves; Dave does not call `MetaStep` | REJECTED (no divergence) | - |

## Method

`gen.lua <scenario> <outdir>` (Lua, upstream library) builds the leaf model of each input window from the emulator:
the window's start state `B` (built with `cm_run`, reverting to the pre-feed machine after a rejection),
`send_cmio_response(advance, data, revert = root(B))`, then `collect_uarch_cycle_root_hashes(MCYCLE_MAX, 0, tail)`
(resumed after automatic yields), with `tail` = the idle period of the machine a rejection reverts to. Each mcycle
group `e[1..k+1]` is expanded to the 2^20 leaves the on-chain meta-step defines:
`leaf(m, u) = e[min(u+1, k)]` for `u < 2^20-1`, `leaf(m, 2^20-1) = e[k+1]` (reset); groups past the last collected
one repeat the last group (the fixed-point period, or the revert tail). Leaves beyond the window chain into the next
window's start state (checked).

It then walks a physical machine through the sampled transitions following the referee semantics
(`run_uarch`, `log_send_cmio_response(revert = root before)` on `m == 0, u == 0` with an input, `log_step_uarch`,
`log_reset_uarch` on `u == 2^20-1`, switch to the reverted machine after a rejecting reset), checks the physical
root before each transition against the model, re-verifies each log with the C++ `verify_*` chain, and writes the
JSON access logs plus a manifest. Sampled mcycles per window: `0, 1, n/2, n-3 .. n+1` (n = collected groups: the
fixed point / rejection boundary and the first idle spans) and the window's last two sub-spans `2^48-2, 2^48-1`.
Sampled uarch cycles per mcycle: `0, 1, 2, k-3 .. k+1` (around the uarch halt at cycle k), `2^20-3, 2^20-2, 2^20-1`.

`mss/test/MetaLayout.t.sol` replays each sample through the Solidity code, for transition
`t = (w << 68) | (m << 20) | u`: `sendCmioResponse(ctx, ADVANCE, inputMerkleRoot(data), len, rootBefore)` when
`t & (2^68-1) == 0` and the window has an input, then (mode 0) `MetaStep.step(t + 1, ctx)`, (mode 1)
`MetaStep.step(t, ctx)`, (mode 2) `UArchStep.step` + `UArchReset.reset` when `t & (2^20-1) == 2^20-1` with the
full-consumption check (Dave's dispatch). It asserts mode 0 and mode 2 reproduce every leaf, that the last
transition of every idle span returns the span's start state, and documents mode 1. `inputMerkleRoot` is computed
in Solidity from the raw input (zero-padded to `2^max(5, ceil(log2 len))` bytes, keccak of 32-byte leaves), i.e. the
convention of `DaveConsensus.provideMerkleRootOfInput`.

Scenarios (bare-metal guests `guest/rollup.S` = rollup-flow guest, `guest/halt.S`): `accept`, `reject`,
`outreject` (tx-output automatic yield then reject), `outaccept` (+ window without input), `exception`, `halt`,
`weird` (unknown manual reason), `spin` (imcyclemax exhausted, budget saturated at MCYCLE_MAX), `rejectlast` /
`acceptlast` (yield exactly at the saturated budget's last cycle), `rejectover` (yield one cycle past the budget:
overflow wins), `rejectnone` (rejection then a window without input), `haltedyield` (template halted with an
rx-accepted yield pending: the send applies, the machine stays halted), `seam1` / `seam2` (template already fed, its
`imcyclemax` cut so that the reject / accept lands exactly on `mcycle == imcyclemax` without saturation; seam 2's next
input is delivered with a renewed budget and rejected), `biginput` (1000-byte and 65536-byte inputs), `bare`
(halting guest, no inputs), `bareover` (bare guest reaching mcycle overflow), plus `uarch_at_max` /
`uarch_before_max` (see SOL-METASTEP-LAYOUT-1).

Reproduce everything: `bash <SCRATCH>/work/sol-metastep-layout/run.sh [--regen]` (exit 0 = layouts agree; prints
`BUG REPRODUCED` and exits 1 on any disagreement; ~3 min). Without `--regen` it unpacks the logs generated by this run
from `metalayout-logs.tgz` (4 MB; 89 MB unpacked into `mss/test/uarch-log/metalayout/`, delete afterwards); with
`--regen` it recomputes them with `gen_all.sh` + `gen_uarchmax.lua` (~20-40 min on the loaded host). Last run:
`run2.out` / `forge.log` (20 tests passed, exit 0).

### SOL-METASTEP-LAYOUT-1: `collect_uarch_cycle_root_hashes` throws for a uarch span that the on-chain meta-step defines (halting ECALL on uarch cycle 2^20-1 / uarch that never halts)
- Status: PROVEN
- Area: uarch / collect-hashes vs on-chain step (interface)
- Category: divergence (emulator collector refuses a span the Solidity step proves), DoS of collector-based nodes
- Where: `src/machine.cpp:2746-2748` (`collect_uarch_cycle_root_hashes`: `if (uarch_break_reason ==
  uarch_cycle_overflow) throw std::runtime_error{"uarch reached its maximum cycle and cannot advance more uarch
  cycles"}`), vs `src/uarch-step.cpp:1092-1108` / `UArchStep.sol:1320-1338` (overflow is an identity fixed point and has
  precedence over the halt reported by the same ECALL) and `MetaStep.sol` / `CartesiStateTransition.sol` (the span's
  last transition steps and resets regardless).
- Problem: the on-chain state transition is total over a 2^20-transition uarch span: a uarch that reaches
  `uarch_cycle == UARCH_CYCLE_MAX` (2^20-1), either because it never halts or because its halting ECALL is the
  2^20-1-th instruction (then `UArchStep` returns `UArchCycleOverflow`, with `uarch_halt` already 1), keeps the state
  unchanged on every further step and the span closes with the usual reset. The emulator's step/reset loggers agree
  (`log_step_uarch`, `log_reset_uarch`, `run_uarch` return/log the overflow normally), but the computation-hash
  collector treats overflow as "catastrophic" and throws, so the leaves of that span (and every later leaf of the
  commitment) cannot be obtained from `cm_collect_uarch_cycle_root_hashes` / `cm_collect_uarch_cycle_bundle`, which
  the CLI (`--uarch-cycle-computation-hash`) and Dave's tall-leaf builder use. A related shape with the halt landing
  before the limit but without advancing `mcycle` aborts on `assert(mcycle_reached == mcycle_target)` (= ASSERTS-2).
- Scenario: only reachable when the template carries a non-pristine uarch (custom uarch RAM / registers), because
  every span's closing reset installs the pristine uarch, whose interpreter halts after one big-machine instruction
  (about 40 uarch cycles on an idle span and up to ~1,750 in the bare-metal guests here; the worst case over all
  instructions was not measured; it is bounded and expected to be far below 2^20-1). The template is chosen by the application developer and is trusted;
  Dave's node refuses templates whose uarch reset changes the root, and Dave's docs list this exact gap as known
  ("a uarch cycle overflow or a uarch halting at `UARCH_CYCLE_MAX` throws where the step defines an identity step (no
  upstream fix yet)"). The honest node can still compute the leaves by stepping (`run_uarch` / `log_step_uarch`), as the
  PoC does. Same precondition as crafted-state-1 / ASSERTS-2 / HT-7.
- Evidence: `bash <SCRATCH>/work/sol-metastep-layout/run-uarchmax.sh` (template = `guest/halt.bin` + uarch RAM
  `guest/uarch_at_max.S`: `nop; li t0,524285; 1: addi t0,t0,-1; bnez t0,1b; li a7,1; ecall`, i.e. the halting
  ECALL is uarch instruction 2^20-1). Output:
  ```
  [uarch_at_max] collect_uarch_cycle_root_hashes: THROWS: uarch reached its maximum cycle and cannot advance more uarch cycles
  [uarch_at_max] transition u=1048574: uarch_cycle before 1048574, after 1048575, halt 1
  [uarch_at_max] transition u=1048575: uarch_cycle before 1048575, after 0, halt 0
  [PASS] testUarchAtMax() ...
    counter=index+1 (MetaStep 1-based)        : ok 5 mismatch 0 reverted 0
    dave-style (0-based, reset on mask)       : ok 5 mismatch 0 reverted 0
  BUG REPRODUCED: the on-chain meta-step proves every transition of the span (MetaStep(counter=index+1) reproduces the
    log/verify leaves), but collect_uarch_cycle_root_hashes throws instead of returning the span's leaves
  ```
  (exit 1). Control `uarch_before_max` (ECALL on cycle 2^20-3: two halted padding transitions, then step+reset) is also
  reproduced on-chain (`testUarchBeforeMax`), while its collector call aborts the process (ASSERTS-2, since that uarch
  halts without advancing mcycle).
- Possible solution: make the collector follow the step semantics instead of throwing: treat
  `uarch_cycle_overflow` like `uarch_halted` (the state after the overflowing step is the span's "halt" leaf, repeated
  up to position 2^20-2, then the reset leaf); and replace `assert(mcycle_reached == mcycle_target)` by an error or by
  accepting a span that did not advance mcycle. Alternatively, refuse non-pristine uarch state up front (in
  `collect_*`, and ideally in machine creation for rollup templates) with a clear error, which is what Dave already
  does at node startup.
- Severity: Low — template-only (trusted application developer), already out of model for Dave and covered by the
  higher-severity crafted-state-1 (cm_run vs uarch divergence for the same templates); stepping remains available.
- Risks: leaving it means collector-based tooling (CLI computation hashes, Dave bulk path) cannot produce commitments
  for such templates. Following the step semantics changes no root hash of canonical (pristine-uarch) executions.

### L-1: leaf layout of the on-chain meta-step vs `collect_uarch_cycle_root_hashes` (REJECTED, no divergence)
For every scenario, mode 0 (`MetaStep.step(counter = index+1)`) and mode 2 (Dave-style) reproduce every sampled
leaf; the emulator-side walk found 0 position/verify mismatches (`gen.log`: `0 emulator-side problems` everywhere).
Kinds covered: the first transition of an input (send then step: applied, and no-op because the machine is halted,
at an exception / unknown-reason yield, at mcycle overflow, or in a window without input), the transitions around the
uarch halt (`k-3..k+1`), halted padding transitions (`k+1`, `2^20-3`, `2^20-2`), the last transition (step then reset;
reset with revert substitution after rx-rejected), and the window's last sub-spans `m = 2^48-2, 2^48-1` followed by
the next window's input transition. forge output (`forge.log`), e.g.:
```
scenario reject: 220 sampled transitions
  counter=index+1 (MetaStep 1-based)        : ok 220 mismatch 0 reverted 0
  counter=index   (doc 0-based, unchanged)  : ok 180 mismatch 0 reverted 40
  dave-style (0-based, reset on mask)       : ok 220 mismatch 0 reverted 0
  idle sub-spans checked for on-chain idempotence: 10, not idempotent: 0
scenario seam2: 330 sampled transitions
  counter=index+1 (MetaStep 1-based)        : ok 330 mismatch 0 reverted 0
  counter=index   (doc 0-based, unchanged)  : ok 270 mismatch 0 reverted 60
  dave-style (0-based, reset on mask)       : ok 330 mismatch 0 reverted 0
```
Full results (`run.sh`, `forge.log`; columns: sampled transitions, leaves reproduced by MetaStep(counter=index+1) / by
the 0-based index unchanged (reverts) / by the Dave-style dispatch, idle spans checked):

| scenario | samples | MetaStep(index+1) | MetaStep(index): ok / reverted | Dave-style | idle spans (not idempotent) |
|---|---|---|---|---|---|
| accept | 220 | 220 | 180 / 40 | 220 | 10 (0) |
| acceptlast | 165 | 165 | 135 / 30 | 165 | 9 (0) |
| bare | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| bareover | 110 | 110 | 90 / 20 | 110 | 5 (0) |
| biginput | 330 | 330 | 270 / 60 | 330 | 15 (0) |
| exception | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| halt | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| haltedyield | 110 | 110 | 90 / 20 | 110 | 9 (0) |
| outaccept | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| outreject | 220 | 220 | 180 / 40 | 220 | 10 (0) |
| reject | 220 | 220 | 180 / 40 | 220 | 10 (0) |
| rejectlast | 220 | 220 | 180 / 40 | 220 | 10 (0) |
| rejectnone | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| rejectover | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| seam1 | 220 | 220 | 180 / 40 | 220 | 10 (0) |
| seam2 | 330 | 330 | 270 / 60 | 330 | 15 (0) |
| spin | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| uarch_at_max | 5 | 5 | 3 / 2 | 5 | 0 (0) |
| uarch_before_max | 5 | 5 | 3 / 2 | 5 | 0 (0) |
| weird | 165 | 165 | 135 / 30 | 165 | 10 (0) |
| **total** | **3475** | **3475** | 2841 / 634 | **3475** | 183 (0) |


### L-2: 0-based vs 1-based counter (REJECTED, by design)
doc/README.md resets on the 0-based `uarch_cycle == UARCH_CYCLE_MAX` (= 2^20-1) and sends the input on
`input_mcycle_offset == 0 and uarch_cycle == 0`; `MetaStep.step` resets when `counter % 2^20 == 0`. With
`counter = index + 1` (MetaStep's natspec: "number of meta-steps performed, counting this one … callers that number
transitions by their source state must pass counter as that number plus one") they coincide on every sample. Passing
the 0-based index unchanged reverts on exactly the `u == 0` and `u == 2^20-1` samples (2 per sampled sub-span; e.g.
40 of 220): at `u == 0` MetaStep resets (counter 0 included) without a reset log, at `u == 2^20-1` it skips the reset
and the full-consumption check fails. No silent wrong leaf was produced (the consumption check turns every
convention error into a revert). Dave does not use MetaStep (it dispatches on the 0-based leaf index itself, mode 2).

### L-3: idempotence of fixed-point spans (REJECTED, no divergence)
For every idle sub-span sampled (big machine halted, at a manual yield, at mcycle overflow / exhausted imcyclemax,
reverted machine after a rejection, halted template with a consumed yield), the on-chain result of the span's last
transition (step + reset) equals the span's start state (`idle sub-spans … not idempotent: 0` in every scenario), and
the collector's fixed-point period ends with the same state. The uarch "churn" on an idle span (≈40-44 uarch cycles
of the emulated interpreter declining to execute) is part of the leaves and is reproduced on-chain.

### L-4: seam 1 / seam 2 (REJECTED, no divergence in v0.22.0-test2)
`rejectlast`, `acceptlast` (saturated budget) and `seam1`, `seam2` (unsaturated: template already fed, `imcyclemax`
cut to land the yield on `mcycle == imcyclemax`): an rx-rejected yield on the budget's last cycle is reverted by the
closing reset on-chain and in the collector; an rx-accepted yield there takes the next input (budget renewed: seam 2's
second input runs 29 mcycles and is rejected back to the window start). Dave's docs record a v0.21.0 collector
divergence at seam 1; it does not reproduce with v0.22.0-test2.

### L-5: bundled representations (REJECTED, no divergence)
`bundles.lua <scenario>` checks, against Merkle roots computed from the expanded per-uarch-cycle leaves:
`collect_uarch_cycle_root_hashes` with bundle log2 1, 2, 3, 5, 10, 19, 20 (execution bundles, the all-halt pad
entry, the final reset bundle; the pad entry is emitted even when it is repeated 0 times, as documented),
`collect_uarch_cycle_bundle(offset, b)` for b in {0,1,4,20} at offsets around the halt and at the end, and
`collect_mcycle_root_hashes(period 1)` == the last leaf of each uarch span. Run with `bash bundles_all.sh accept reject outreject spin rejectlast seam1 seam2 bare`
(`bundles1.log`, `bundles-seam.log`): `bundle checks: CONSISTENT` for all 8 scenarios. Side note (by contract, not a
defect): the collector only checks that `revert_uarch_tail` has >= 2 entries and ends with the recorded revert root
hash; a caller passing a placeholder tail (e.g. `{rv, rv}`) for a window that does reject gets a period that the chain
does not reproduce (seen while debugging this checker). The CLI and Dave both compute the tail as the idle period of
the pre-feed machine, which is what the chain reverts to.

### L-6: Dave PRT contracts (REJECTED, no divergence; read-only review)
`CartesiStateTransition.transitionState(machineState, counter, proofs, provider)`: counter is the 0-based output
leaf index (`machineState` is its predecessor); `counter & INPUT_MASK == 0` (INPUT_MASK = 2^68-1) opens an input
window: `SendCmioResponse.sendCmioResponse(ctx, ADVANCE, inputMerkleRoot, len, machineState)` only when the provider
returns a nonzero root, then `UArchStep.step`; `counter & (2^20-1) == 2^20-1` runs `UArchStep.step` + `UArchReset.reset`;
every branch requires full proof consumption. `DaveConsensus.provideMerkleRootOfInput` returns the keccak Merkle root
of the input over `max(ceilLog2(len), 5)` with 32-byte leaves (0 beyond the epoch's inputs). This is exactly mode 2 of
the harness and the `inputMerkleRoot` it uses, so Dave's dispatch reproduces all emulator leaves above (including
the 65536-byte input). Notes (not defects): Dave pins solidity-step v0.15.0 (`23765c8`, emulator v0.21, `CM_MARCHID`
21), PR #104 moves to `CM_MARCHID` 22 / new `UARCH_PRISTINE_STATE_HASH`, so both must be bumped together; `MetaStep`
computes an unused `machineState` local (cosmetic).

### Other hypotheses considered (REJECTED by reasoning)
- Window end not at a fixed point: `sendCmioResponse` sets `imcyclemax = mcycle + 2^48 - 1`, so the last of the 2^48
  sub-spans of a window is always idle and the next window's input transition starts at a span boundary.
- Reset at a non-halted, non-overflowed uarch: impossible on the last transition (after 2^20-1 steps the uarch is
  halted or at `UARCH_CYCLE_MAX`).
- Rejected state as a leaf: every span's closing reset substitutes the revert root hash, and the revert root hash is
  only written by an applied advance response (machine at rx-accepted), so no leaf other than a crafted genesis
  template is at an rx-rejected yield.
