# Angle `sol-onchain-impact`: on-chain consequences of the emulator findings

Scope: for every emulator finding in `coord/status.md` that touches an execution path or proof
generation, determine the consequence against **machine-solidity-step PR #104** (release
v0.16.0-test2, pinned to emulator v0.22.0-test2): `MetaStep.step` → `UArchStep.step`
(transpiled `src/uarch-step.cpp`) + `UArchReset.reset` (from `src/uarch-reset-state.cpp`) +
`SendCmioResponse.sendCmioResponse` (from `src/send-cmio-response.cpp`), all reading/writing
through `AccessLogs` Merkle proofs.

Work dir: `<SCRATCH>/work/sol-onchain-impact/`  (`<SCRATCH>` =
`<SCRATCH>`).
Private mss copy: `<SCRATCH>/work/sol-onchain-impact/mss` (branch pr104, `src="src"`). One-command
reproducer: `<SCRATCH>/work/sol-onchain-impact/run.sh` (prints `BUG REPRODUCED`, exits 1). Logs for
Solidity are produced with the **upstream** library `<SCRATCH>/sol/upstream/root/usr` so the
pristine uarch hash equals the Solidity constant `UARCH_PRISTINE_STATE_HASH`
(`fa022ea7…` — verified identical). Forge test: `mss/test/OnchainImpact.t.sol`
(+ `mss/test/HarnessCheck.t.sol`, which validates the replay harness against the committed
`rv64ui-uarch-simple` log).

## The decisive mechanism (applies to every divergence finding)

The on-chain arbiter runs the machine **one uarch cycle at a time**: `MetaStep.step` calls
`UArchStep.step` once, and on every counter that is a multiple of `2^ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE`
(= `2^20`) it also calls `UArchReset.reset`. `UArchStep.sol` is a byte-identical transpile of
`src/uarch-step.cpp` (the coordinator verified `generate_UArchStep.sh` reproduces the committed
file), and the uarch executes one big-machine mcycle as `interpret(a, mcycle+1)`. Therefore:

- **On-chain MetaStep == the per-mcycle uarch path == `cm_run` of exactly one mcycle at a time.**
- It is **not** `cm_run(N)` in one call, nor `collect_mcycle_root_hashes` with a period > 1, nor
  `cm_log_step(N)` — those are the *host fast path*, which the chain never executes.
- `UArchReset.reset` → `EmulatorCompat.resetState` writes `UARCH_PRISTINE_STATE_HASH` over the whole
  uarch subtree **unconditionally** (it does not read the current uarch). So the chain's reset
  equals `cm_reset_uarch` / `cm_log_reset_uarch`, and is **not** the partial reset of
  `collect_uarch_cycle_root_hashes`.

So for any finding where the host fast path (`cm_run`, `collect_mcycle_root_hashes`, `cm_log_step`,
`collect_uarch_cycle_root_hashes`) diverges from the per-cycle uarch / canonical reset, **the chain
sides with the uarch / canonical reset, and a commitment built from the fast path loses on-chain.**

## Summary

| ID | On-chain consequence | Which side Solidity takes | Honest proof producible? | Dishonest acceptance? | Re-rated (on-chain) |
|----|----|----|----|----|----|
| SOL-ONCHAIN-1 (crafted-state-1 / verify-uarch-NEW-1 / uarch-1) | non-pristine uarch in s[0]: MetaStep executes the committed uarch; cm_run diverges | **uarch path** (proven: MetaStep=`9c93372e`, cm_run=`c0d3b180`) | yes, via uarch; a cm_run commitment is rejected | **yes, iff attacker controls s[0]'s uarch** | High (Critical iff the system does not pin a canonical uarch hash at s[0]) |
| SOL-ONCHAIN-2 (HT-7) | collect_uarch_cycle_root_hashes partial reset vs on-chain pristine reset | **cm_reset_uarch / UArchReset** (full pristine) | collect leaf (`28a53684`) ≠ chain (`9c93372e`) → rejected | no (honest-tooling liveness) | Medium (needs non-pristine uarch; template-controlled) |
| SOL-ONCHAIN-3 (STEP-PROOF-1 / HT-11) | non-power-of-two range tail | n/a (proof generation) | **big-step `cm_log_step` ABORTS** (ZK path); per-uarch-cycle path is sound (MetaStep safe) | no | High for the ZK/big-step dispute path; **no effect on MetaStep** |
| SOL-ONCHAIN-4 (PORTABILITY-1 / ASSERTS-1) | misaligned uarch pc / uarch load-store | Solidity **reverts** (`UArchStep.sol:51`) | packaged C++ **aborts**; release C++ **accepts** → 3-way split | release build accepts a step the chain reverts (off-chain≠on-chain) | High (verifier DoS + build-flag soundness split); chain itself stays sound |
| interp-priv-1 | partial-mideleg firmware, multi-mcycle chunking | **per-mcycle uarch** (= MetaStep) | only a per-mcycle commitment matches; cm_run(N)/collect(period>1) rejected | no (honest-node liveness / self-inconsistent commitment) | Critical-conditional (pristine uarch; needs only custom firmware) |
| COORD-1 / STEP-PROOF-2 | risc0 wraps mcycle_end | ZK `CartesiStepVerifier` only | — | risc0 accepts a false 0-cycle step | Medium; **MetaStep unaffected** (no mcycle_end arithmetic) |
| ROLLUP-FLOW-1 | N-mcycle step log stops at automatic yield | ZK/big-step `verify_step` only | — | big-step verifier accepts a short transition | Critical for the ZK/step-log path; **MetaStep unaffected** |
| STEP-PROOF-5 / HT-10 | wrong word proof in pow2 padding | API only | per-uarch-cycle logs never request padding words | no | Low on-chain (MetaStep never asks for padding words) |
| CONC-2 / HT-3 | stale page-hash-cache after shared-ht reload / replace | n/a (proof generation) | `log_step_uarch` / `log_send_cmio_response` FAIL or emit a log AccessLogs rejects | no (liveness) | High for the node that hit it; config-controlled |
| mmu-tlb-1 | replace_memory_range stale hot TLB | **committed root / uarch** (hot TLB not hashed) | node's cm_run diverges from its own root → crash or wrong continuation | no | host-side; chain follows the committed root |
| SendCmioResponse (tail/padding) | — | — | rx buffer is power-of-two (log2=21), writes are pow2-aligned | — | **not affected by STEP-PROOF-1** (negative result) |

---

## SOL-ONCHAIN-1: the on-chain MetaStep executes the committed (possibly adversarial) uarch, not `cm_run`
- Status: **PROVEN** (forge test through `MetaStep.step`)
- Area: uarch / Solidity MetaStep / divergence / proof-soundness
- Covers the on-chain impact of: crafted-state-1 = verify-uarch-NEW-1 (non-pristine uarch RAM /
  registers), and uarch-1 (WRITE_TLB out-of-range index — see note below).
- What was built: a template with a non-pristine uarch RAM image
  (`gen/uprog.S`: the uarch writes `mcycle=1` and corrupts big-machine `x5`, then `ecall HALT`).
  `gen/genlog.lua` (run against the upstream lib) produces a per-uarch-cycle `log_step_uarch` for
  each of the 11 cycles, a halted-step log and a `log_reset_uarch`, plus reference hashes.
  `mss/test/OnchainImpact.t.sol` replays the 11 steps through `MetaStep.step(counter=j+1)` and the
  final `[halted step ++ reset]` through `MetaStep.step(counter=2^20)` (so `UArchReset` runs), then
  compares the final root to the honest references.
- Result (`run.sh` section A):
  ```
  [crafted_uarch] MetaStep final root:          0x9c93372e…585916a1
  [crafted_uarch] refUarch (uarch path):        0x9c93372e…585916a1   (cm_run_uarch-to-halt + cm_reset_uarch)
  [crafted_uarch] refCmrun (cm_run 1 mcycle):   0xc0d3b180…b7fa8e84
  BUG REPRODUCED: on-chain MetaStep follows the committed uarch and DIVERGES from cm_run
  ```
  Pristine control (`testPristineControl`): MetaStep == refUarch == refCmrun == `0x59f8aaac…` — the
  three agree when the uarch is pristine, so the harness is sound.
- Three questions:
  1. **Which side does Solidity agree with?** The uarch path (`MetaStep` reproduced `refUarch`
     bit-for-bit). `cm_run` never executes the uarch and is the odd one out.
  2. **Can an honest node still produce an accepted proof?** Yes — by stepping the uarch
     (`cm_log_step_uarch` + `cm_log_reset_uarch`), which is exactly what MetaStep replays. An honest
     node that instead commits the `cm_run` result commits `c0d3b180…`, which the chain rejects.
  3. **Can a dishonest node get a wrong transition accepted?** **Yes, but only if it controls the
     uarch committed in the initial state `s[0]`.** The committed uarch is Merkle-bound; MetaStep
     executes whatever it is. A non-pristine uarch makes the chain accept the adversary's transition
     (here `x5=0xDEADBEEF`, `mcycle` bumped) while `cm_run` computes the RISC-V-correct result.
- uarch-1 note (WRITE_TLB out-of-range `set_index`): `EmulatorCompat.writeTlbECALL` computes
  `paddress = AR_SHADOW_TLB_START + setIndex*8192 + slotIndex*32` with **no bound on `setIndex`**,
  exactly like `uarch-step.cpp` → `write_unverified_tlb`. For `set_index=3` both write to `0x7000`
  (shadow-state padding); the emulator produces a log and Solidity applies the same write, so the
  OOB write is faithfully mirrored on-chain (soundness within the crafted-uarch envelope). For
  `set_index≥4` the host native array write is out of the shadow mmap → crash → the honest node
  cannot even produce the log (liveness/DoS). Both only arise from an attacker-supplied uarch, i.e.
  the SOL-ONCHAIN-1 envelope. A shared `EmulatorCompat`/`uarch-step.cpp` bound check fixes host and
  chain identically.
- Severity (on-chain): **High**, with a **Critical** ceiling. By the campaign definition this is
  "divergence between implementations that must agree (interpret vs uarch vs on-chain step)" and the
  divergent transition is on-chain-provable. The precondition is a non-canonical uarch in `s[0]`.
  In the canonical Cartesi rollups flow `s[0]` is the hash of a template built with the canonical
  uarch, and `UArchReset` forces the uarch pristine at every mcycle boundary, so an honest `cm_run`
  node and the chain agree there. It escalates to Critical for any party that **loads an untrusted
  snapshot/template** and then both `cm_run`s and disputes it, and the emulator gives C-API callers
  no supported pristine-uarch check (Lua exposes `UARCH_PRISTINE_STATE_HASH`; C does not). So this is
  primarily "a precondition the template controls", which caps it at High on-chain.

## SOL-ONCHAIN-2: a `collect_uarch_cycle_root_hashes` commitment diverges from the on-chain uarch reset (HT-7)
- Status: **PROVEN** (`run.sh` section B, `misc/ht7.lua`)
- `UArchReset.reset` writes the pristine hash over the whole uarch subtree unconditionally; the
  emulator's `collect_uarch_cycle_root_hashes` restores only the words written during the run, so for
  a non-pristine uarch it leaves residue. Result on the SOL-ONCHAIN-1 template:
  ```
  canonical (cm_reset_uarch)      : 0x9c93372e…585916a1   == MetaStep's reset result (section A)
  collect_uarch_cycle_root_hashes : 0x28a53684…44e88d29   DIVERGENT
  ```
- Which side does Solidity take? `cm_reset_uarch` / `cm_log_reset_uarch` (full pristine reset). A
  node that builds its uarch-cycle commitment with `collect_uarch_cycle_root_hashes` commits
  `28a53684…`, which the chain rejects (the chain computes `9c93372e…`). Honest-tooling liveness.
- Severity (on-chain): **Medium** — needs a non-pristine uarch (template-controlled), same envelope
  as SOL-ONCHAIN-1; the collector should reject a non-pristine uarch rather than produce a third value.

## SOL-ONCHAIN-3: STEP-PROOF-1 breaks the ZK big-step prover but NOT the MetaStep uarch path
- Status: **PROVEN** (both directions; `run.sh` section C, `proofgen/probe2.lua`, `proofgen/probe3.lua`)
- Set-up: 5-page RAM (0x5000, power-of-two span 8 pages; pages 5–7 are pristine padding), a
  bare-metal store to the last real page `0x80004000`.
- `cm_log_step(2, file)` over that mcycle (the big-step / risc0 / `CartesiStepVerifier` path) **aborts**
  on the official packaged upstream library:
  `hash-tree.cpp:567: … get_dense_node_hash(…): Assertion 'ar.contains_absolute(address, HASH_TREE_WORD_SIZE)…' failed`
  (the packaged lib keeps asserts live — demonstrated, so STEP-PROOF-1 is confirmed on the shipped
  binary). An honest prover therefore cannot produce the ZK step proof for that mcycle.
- `cm_log_step_uarch` for **every uarch cycle** of the same mcycle produces valid logs with **0
  `verify_step_uarch` failures and no abort**. So the per-uarch-cycle dispute path that
  `MetaStep` consumes is sound for non-power-of-two range tails.
- Which side / severity (on-chain): this is a liveness defect of the **ZK/big-step verifier
  (`CartesiStepVerifier`)** — High for deployments whose disputes settle with `cm_log_step` big-step
  proofs. It has **no effect on MetaStep** (PR #104's per-uarch-cycle contracts). Flash drives
  (rootfs/app ext2) routinely have non-power-of-two lengths, so this is easy to hit for the ZK path.

## SOL-ONCHAIN-4: misaligned uarch pc — abort (C++ packaged) / revert (Solidity) / accept (C++ release) (PORTABILITY-1, ASSERTS-1)
- Status: **PROVEN** (abort executed; Solidity revert proven by source; release-accept proven by the
  portability/asserts agents)
- `UArchStep.sol:51` `require((paddr & 3) == 0, "misaligned readUint32 address")` → clean **revert**.
  The same `require` in `src/uarch-step.cpp` is `assert` via `uarch-solidity-compat.hpp:253`, so the
  behaviour depends on build flags.
- Demonstrated (`run.sh` section D, `misc/misaligned_pc.lua`): with `uarch_pc=0x600002`,
  `cm_log_step_uarch` on the **official packaged upstream library** aborts:
  `uarch-solidity-compat.hpp:253: … Assertion '(condition) && (message)' failed`.
  A `release=yes` build instead executes a shifted instruction word and `cm_verify_step_uarch`
  **accepts** the step (shown by the asserts/portability agents). Solidity **reverts**.
- Consequence: a release-built off-chain verifier accepts a uarch step the on-chain MetaStep reverts
  (off-chain ≠ on-chain), and any packaged `cartesi-jsonrpc-machine` / `cm_verify_step_uarch`
  endpoint can be aborted by one crafted (root, log) pair. The chain itself stays sound (revert =
  clean reject). Fix: make `require` a `throw`/runtime error in every host build (matches Solidity).
- Severity (on-chain): **High** (verifier DoS reachable from untrusted logs + build-flag soundness
  split between off-chain C++ and the chain).

## Findings whose on-chain consequence is reasoned (not separately re-executed)

### interp-priv-1 — Critical-conditional, MetaStep = per-mcycle uarch
The chain computes each mcycle as `interpret(mcycle+1)` (= the uarch, = `cm_run` of a single mcycle).
`cm_run(N)` in one call, `collect_mcycle_root_hashes` with period > 1, and `cm_log_step(N)`
re-sample interrupts at different points for partial-`mideleg` firmware, giving up to 5 distinct
root hashes for the same mcycle window (verify-priv/irq1, enum). The chain sides with the per-mcycle
path. So an honest node that builds its computation-hash commitment with any coarser chunking (for
efficiency) commits hashes the chain's per-mcycle MetaStep recomputation rejects, and its PRT levels
are mutually inconsistent. Unlike SOL-ONCHAIN-1/2, the uarch here is **pristine**: the trigger is
only custom M-mode firmware (partial S-interrupt delegation), not a non-canonical uarch — so the
template-control defence does not apply. A full multi-mcycle MetaStep replay (many mcycles × ~hundreds
of uarch cycles each) was out of budget to execute end-to-end; the per-mcycle = chain equivalence is
certain from the byte-identical transpile, and the emulator-side divergence is already PROVEN
(verify-priv). On-chain severity: **Critical-conditional** (needs partial-mideleg firmware; the stock
OpenSBI stack, `mideleg=0x222`, is unaffected).

### COORD-1 / STEP-PROOF-2, ROLLUP-FLOW-1 — ZK/big-step path only, MetaStep unaffected
Both live in the big-step verifier (`machine::verify_step` / `risc0_replay_steps` /
`CartesiStepVerifier`): COORD-1 wraps `mcycle_end`; ROLLUP-FLOW-1 stops an N-mcycle step log at the
first automatic yield. `MetaStep` has no `mcycle_end` arithmetic and runs one uarch cycle per call,
so neither reaches it. They matter if/when the ZK/step-log dispute path is deployed. COORD-1 needs an
initial mcycle within `mcycle_count` of 2^64 (template-controlled); ROLLUP-FLOW-1 needs only an
output/report/progress yield inside the batch (easy).

### STEP-PROOF-5 / HT-10 — API only, MetaStep unaffected
Wrong word proofs in power-of-two padding. The per-uarch-cycle logs never request padding words
(SOL-ONCHAIN-3 showed `log_step_uarch` logs verify), so `MetaStep` is unaffected; this is a wrong
API result for an uncommon query. Low on-chain.

### CONC-2 / HT-3 — proof-generation liveness, config-controlled
A stale persisted page-hash-cache (shared hash tree + private ranges, or `replace_memory_range` with
imported hash files) makes `cm_log_step_uarch` / `cm_log_send_cmio_response` fail their own check or
emit a log whose siblings do not reconstruct the committed root (proven: hash-tree/t12,
concurrency/shared-ht-reload). On-chain: `AccessLogs` would reject such a log (`Read word root
doesn't match`), so the honest party cannot advance that dispute leaf. High for the node that hit it;
needs a non-default sharing config. The fix (validate a cache hit against the dense page node) is
cheap and changes no root hash.

### mmu-tlb-1 — host-side; chain follows the committed root
The hot TLB holds raw host pointers and is **not** part of the Merkle root; `MetaStep`/`UArchStep`
only ever touch the *shadow* TLB (hashed, handled correctly by `writeTlbECALL`). After
`replace_memory_range` the stale hot pointer makes `cm_run` crash or execute memory not reflected in
the root, i.e. the node's executed trajectory diverges from its own committed root. The chain follows
the committed root (what an honest recomputation and the uarch see), so this is a node-side crash /
self-inconsistency, not a MetaStep soundness break. The fix (`init_hot_tlb_contents()` after replace)
changes no root hash.

### SendCmioResponse tail/padding — negative result
`cm_log_send_cmio_response` cannot hit STEP-PROOF-1: the CMIO rx buffer is a power-of-two range
(`AR_CMIO_RX_BUFFER_LOG2_SIZE = 21`) and `SendCmioResponse.sol` writes a power-of-two-aligned region
(`writeLengthLog2Size`), so no sibling ever falls in a non-power-of-two tail. The only way
`log_send_cmio_response` fails is the stale-cache path (CONC-2), already covered.

## Reproducers (all one-command; `run.sh` prints `BUG REPRODUCED`, exits 1)
- Top: `<SCRATCH>/work/sol-onchain-impact/run.sh` (sections A–D).
- A: `gen/genlog.lua` (upstream lib) + `mss/test/OnchainImpact.t.sol` (forge). Harness validated by
  `mss/test/HarnessCheck.t.sol` against the committed `rv64ui-uarch-simple` log.
- B: `misc/ht7.lua`.
- C: `proofgen/probe3.lua` (big-step abort) and `proofgen/probe2.lua` (per-uarch-cycle sound).
- D: `misc/misaligned_pc.lua`.

## Notes / fixes that do not change any legitimate root hash
- SOL-ONCHAIN-1/2 and uarch-1: either pin a canonical uarch-subtree hash at `s[0]` (system level) or,
  in the emulator, expose a C-API pristine-uarch predicate and guard the equivalence-dependent entry
  points (`run`, `log_step`, the collectors) with it; and bound `set_index` in the shared
  `uarch-step.cpp`/`EmulatorCompat` WRITE_TLB path.
- SOL-ONCHAIN-3 (STEP-PROOF-1): in `hash_tree::get_dense_node_hash`, return the pristine hash for a
  node that lies entirely in a range's padding instead of asserting.
- SOL-ONCHAIN-4: make `uarch-solidity-compat.hpp::require` throw a runtime error in every host build,
  matching Solidity's revert.
