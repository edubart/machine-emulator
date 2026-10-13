# Findings: sol-cmio-revert (on-chain input delivery and rejection)

Scope: `SendCmioResponse.sol` (machine-solidity-step PR #104) vs emulator `src/send-cmio-response.cpp` through
`record_send_cmio_state_access` / `replay_send_cmio_state_access`; `UArchReset.sol` vs `src/uarch-reset-state.cpp`
and `collect_uarch_cycle_root_hashes` on rx-rejected states; who binds `revertRootHash`.
All emulator data come from the UPSTREAM v0.22.0-test2 library (`<SCRATCH>/sol/upstream`), whose pristine uarch
hash equals the Solidity `UARCH_PRISTINE_STATE_HASH`.

PoC directory: `<SCRATCH>/work/sol-cmio-revert/` — one command `./run.sh` (quick, about 5 min) or `FULL=1 ./run.sh`
(whole grid and all rejection scenarios, 19 min on the shared host). It prints `BUG REPRODUCED` and exits 1.
The outputs of the last runs are in `out/full-run.txt` (FULL=1) and `out/quick-run.txt`. Bulky generated logs were deleted
afterwards; `run.sh` regenerates them. `SKIP_GEN=1` works for the quick mode only.

## Summary

| ID | Title | Status | Severity |
|---|---|---|---|
| SOL-CMIO-REVERT-1 | `SendCmioResponse.sol` and `log/verify_send_cmio_response` accept any `revertRootHash`. A later `UArchReset` then proves the machine into a state that `cm_send_cmio_response` never records. Only the caller binds it, and Dave's `CartesiStateTransition` does. | PROVEN (interface level) | Low |
| SOL-CMIO-REVERT-2 | dataHash contract: SendCmioResponse vs the emulator over the grid of reasons × lengths × machine states | REJECTED (0 mismatches in 1180 + 48 + 52 points, with two independent dataHash helpers) | - |
| SOL-CMIO-REVERT-3 | No-op responses (Y clear, advance to a non-rx-accepted yield, oversize data up to 2^32-1) consume a different log on-chain | REJECTED (300 + 48 no-op points consume exactly the emulator log) | - |
| SOL-CMIO-REVERT-4 | imcyclemax saturation near mcycle 2^64 | REJECTED (4 boundary states × 5 reasons × 18 lengths) | - |
| SOL-CMIO-REVERT-5 | UArchReset on rx-rejected states vs the collector reset leaf, and the spans that follow a rejection | REJECTED (adv / no-advance / after-inspect / foreign-revert scenarios all equal) | - |
| SOL-CMIO-REVERT-6 | All-zero revert hash (rejection before any advance) and the stale revert hash after an inspect rejection | REJECTED (consistent across emulator and chain; not reachable through conforming templates or Dave) | - |

## Reasoning

`send_cmio_response` is the one CMIO transition that is proven on-chain. Its Solidity form gets only a `dataHash`, and
it writes that hash as the Merkle root of a `2^writeLengthLog2Size` region at the rx buffer. Here
`writeLengthLog2Size = max(5, ceil(log2(len)))`, the write is skipped when `len == 0`, and the call is a no-op above
2^21. The emulator writes the raw bytes zero-padded to the same size, so the hash tree root of that region is the keccak
tree of 32-byte leaves of the padded payload. The two sides agree if and only if the caller computes the dataHash the
same way, the length tiers are identical (in particular `uint32Log2`, the extra `+1` for a non power of two, and the 32-byte minimum), and every no-op
branch reads the same words in the same order. The revert hash is written as a value only. Nothing in the transition
relates it to the pre-response root. `machine::send_cmio_response` adds that check (`machine.cpp:1970-1986`), but the
recorded and replayed paths and the transpiled Solidity do not. So whoever calls the library must bind it.

The rejection path has a single on-chain consumer: `UArchReset.reset` substitutes `readRevertRootHash` when
`iflags.Y` is set and `tohost` reads manual/rx-rejected. That substitution happens only at the end of a uarch span. Inside the
span the leaves are the physical roots of the rejecting machine. Three revert-hash sources are possible: a real
advance (pre-advance root), no advance yet (the initial all-zero value), and an inspect after an accepted advance (the
stale hash of the earlier advance). A fourth is any value a caller passed to an unbound `SendCmioResponse`.

Hypotheses examined:
1. A dataHash or length-tier mismatch at the boundaries 31/32/33, 2^k±1, 2^21, 2^21+1 (wrong padding, minimum leaf, tree height).
2. No-op branches that read a different set of words, so the proof is not fully consumed or is over-consumed.
3. uint32 edge lengths (2^31, 2^32-1) that overflow `uint32ShiftLeft` / `uint32Log2` differently.
4. imcyclemax saturation mismatch (`mcycle > 2^64-1-(2^48-1)`).
5. Reason domain: reasons other than advance should skip the tohost check and the revert/imcyclemax writes. Tested with 0xffff, 0x20, 2 and inspect.
6. UArchReset on rejected states differs from the collector leaf, or the period that follows a rejection is not provable.
7. revertRootHash is unbound in Solidity and in log/verify, so a foreign value is accepted and later "reverted to" (task focus).
8. The zero and stale revert hashes produce unprovable or wrong states.

## Method

- `gen/guest.S`: a bare-metal rollup-like guest. It yields manually (rx-accepted by default, rx-rejected first with
  `FIRST_REASON=2`). The first word of each input selects accept / reject / exception / halt / spin / tx-output / an unknown
  manual reason. A RAM counter changes on every input.
- `gen/grid.lua` (Lua, upstream library) builds 16 machine states:
  - `acc0`: first rx-accepted yield, revert=0.
  - `acc1`: after an accepted 2 MiB advance, so the rx buffer is dirty.
  - `rej`, `exc`, `weird` (reason 3).
  - `rej0`: the first yield is rx-rejected.
  - `insprej`: rx-rejected after an inspect.
  - `accovf`: mcycle == imcyclemax at an accepted yield.
  - `mcA..mcD`: mcycle = 2^64-1-(2^48-1) -1/0/+1 and 2^64-1.
  - Y clear: `halt`, `run` (mid-execution), `auto` (automatic yield), `ovf` (imcyclemax reached).

  For each state × reason {advance, inspect, 2, 0x20, 0xffff} × length
  {0, 1, 31, 32, 33, 63, 64, 65, 4095, 4096, 4097, 2^20-1, 2^20, 2^20+1, 2^21-1, 2^21, 2^21+1, 2^22}, it emits
  `log_send_cmio_response` JSON plus metadata (reason, payload file, initial root, final root, the `cm_send_cmio_response`
  root, the `verify_send_cmio_response` root, revert = pre-response root). 1180 points; the quick variant has 52.
  The payload bytes are all nonzero, so the zero padding is observable.
- `gen/big.c` + `gen/bigrun.lua` use the C API for lengths the Lua binding cannot carry: 2^22+1, 2^31, 2^31+1 and 2^32-1, for
  4 states × 3 reasons (48 points). The data pointer is a never-touched 4 GiB PROT_READ mapping.
- `gen/reset.lua` produces rejection scenarios at the mcycle whose instruction performs the rx-rejected yield. It writes
  every `log_step_uarch` of that mcycle (2000 uarch cycles), the closing halted step + `log_reset_uarch` (as Dave's
  closing transition fuses them), `collect_uarch_cycle_root_hashes` over the same mcycle with the revert uarch tail,
  and the on-chain logs of the reverted machine's following span (`tail`, `ztail`).
- `mss/test/CmioGrid.t.sol` (forge) runs these checks:
  - `testGrid` / `testQuickGrid` / `testGridOversize`: `SendCmioResponse.sendCmioResponse(initialRoot, log, reason,
    dataHash, len, revertRoot)`. The dataHash comes from an independent Solidity helper (`PaddedMerkle`) that zero-pads the raw
    payload to 2^max(5,ceil(log2 len)) and builds the keccak tree. The test asserts the final root == the emulator root, and that the proof
    buffer is consumed exactly. A no-op must keep the root.
  - `testGridDaveProvider` / `testQuickGridDaveProvider`: the same grid with the dataHash computed by the deployed caller's
    algorithm. That is the body of `DaveConsensus.provideMerkleRootOfInput`, using `LibBinaryMerkleTree.merkleRoot` / `LibKeccak256` /
    `LibMath` from cartesi-rollups-contracts 3.0.0-alpha.10. They are copied verbatim (the soldeer zip's sha256 matches Dave's lock) and built
    with via_ir under `davehash/`.
  - `testDataHashHelpersAgree`: both helpers agree for 19 lengths, from 0 to 2^21+1.
  - `testNegativeControlNaiveHash`: a flat `keccak256(payload)` must mismatch, which shows the harness can fail
    (28 of 52 points mismatch: exactly the applied responses with data).
  - `testRejectAdvanceReset` / `testRejectAfterInspectReset` / `testRejectWithoutAdvanceReset`: replay all uarch steps
    with `UArchStep.step` (adv), then the closing `UArchStep.step`+`UArchReset.reset` on one fully consumed buffer, and assert == the collector
    reset leaf == the recorded revert hash != the physical root. Then the following span is replayed on-chain and asserted equal to the
    collector's appended period.
  - `testArbitraryRevertHash`: see SOL-CMIO-REVERT-1.

---

### SOL-CMIO-REVERT-1: revertRootHash is bound neither by SendCmioResponse.sol nor by log/verify_send_cmio_response; only the caller binds it
- Status: PROVEN (interface level). The deployed caller (Dave `CartesiStateTransition`) and the reference referee
  (`doc/recipes/prt.lua`) bind it, so this is not exploitable through them. It is the on-chain counterpart of the emulator-side
  R-1 in `findings/step-proof.md` (REJECTED there as documented behaviour).
- Area: CMIO / step-log / Solidity interface (SendCmioResponse, UArchReset)
- Category: proof-soundness (caller contract), input-validation
- Where:
  - Solidity: `src/SendCmioResponse.sol:95` (`EmulatorCompat.writeRevertRootHash(a, revertRootHash)` writes the caller's
    value; nothing compares it with `a.currentRootHash` at entry). `src/UArchReset.sol` / `EmulatorCompat.revertState`
    later sets `currentRootHash` to it.
  - Emulator: `src/machine.cpp:1995-2025` (`machine::log_send_cmio_response`, `machine::verify_send_cmio_response`) pass the
    caller's `revert_root_hash` straight into `send_cmio_response`. Only `machine::send_cmio_response` calls
    `check_cmio_response_revert_root_hash` (`machine.cpp:1970-1993`). `cm.h:1077` documents that log does not check it.
  - Binding caller: Dave `prt/contracts/src/state-transition/CartesiStateTransition.sol:88-94` passes `machineState`
    (the root at which the proof starts) as `revertRootHash`. `doc/recipes/prt.lua:277-283` passes `root_hash_before`.
- Problem: when the response is applied (advance at an rx-accepted yield), the only value the honest machine can hold
  in the revert slot is the pre-response root, because `cm_send_cmio_response` refuses anything else. But the transition
  function itself, in C++ record/replay and in the transpiled Solidity, treats `revertRootHash` as a free input. The
  emulator's `log_send_cmio_response` produces a valid log for any X, `verify_send_cmio_response(..., X)` accepts it, and
  `SendCmioResponse.sendCmioResponse(..., X)` reproduces the same post-state root on-chain. If the guest later rejects the
  input, `UArchReset` (and `collect_uarch_cycle_root_hashes`, `log_step`) "revert" to X. X can be the root of any
  machine, including a real, runnable one that differs from the pre-input state, and every later span is provable on-chain from it. So the
  soundness of rejection rests on a caller-side equality that neither the library nor its README states. The README
  says only that it "takes the revert root hash to restore".
- Scenario: Dave is safe. It hard-wires `revertRootHash = machineState`, and the test shows that the log made with X
  is then rejected. Any other integrator of `SendCmioResponse` is exposed: a different dispute contract, a ZK/fraud-proof
  wrapper, or an off-chain referee that uses `cm_verify_send_cmio_response` and takes the revert hash from the prover's
  message. With an unbound value, a dishonest prover delivers an input with revert = X. The input is crafted to be rejected, for
  example an input the app is known to reject, and the next span's closing reset proves the machine into X. X is a forged application
  state (balances, outputs root) that no honest node computes, and every later step from X is provable. An honest node running
  `cm_send_cmio_response` would reject X, so it disagrees with the on-chain state and cannot win a dispute based on the forged
  prefix, while the attacker can prove every step after it.
- Evidence: `cd <SCRATCH>/work/sol-cmio-revert && ./run.sh`. The emulator part (`gen/reset.lua`, scenario `bind`) and the
  forge part (`test/CmioGrid.t.sol:testArbitraryRevertHash`) cover these steps:
  1. X = root of the first-yield machine with its input counter forged to 1,000,000 (a real machine).
  2. `cm_send_cmio_response(advance, reject-command, revert=X)` refused.
  3. `log_send_cmio_response(..., X)` accepted and `verify_send_cmio_response(..., X)` accepted. The same log verified with
     revert = root_hash_before is rejected.
  4. On-chain, `SendCmioResponse` with X + that log gives exactly the emulator's post root. With `revertRootHash = pre` (Dave's
     binding), it reverts.
  5. The guest rejects. The closing `UArchStep`+`UArchReset` gives X == the collector reset leaf.
  6. The following span (43 uarch steps + reset) of the machine with root X replays on-chain == the collector's appended period.

  Actual output:
  ```
  bind: cm_send_cmio_response(revert = X) refused: revert root hash does not match the machine root hash
  bind: log_send_cmio_response(revert = X) accepted, verify_send_cmio_response(revert = X) accepted
  bind: same log verified with revert = root_hash_before: rejected
  bind  mcycle 38: 2000 uarch steps, revert 0xdbc1c5fc3b49a183, collector reset leaf 0xdbc1c5fc3b49a183, collector next period 44 entries
  [PASS] testArbitraryRevertHash() (gas: 2990)
  bind: UArchReset root: 0xdbc1c5fc3b49a18302722e81652000557f17034d6c61661978829664d6be8c92
  bind: collector reset leaf: 0xdbc1c5fc3b49a18302722e81652000557f17034d6c61661978829664d6be8c92
  bind: following span (43 uarch steps + reset) replayed on-chain == collector's appended period
  pre-response root (only value cm_send_cmio_response accepts): 0x4f36a710aec446ada3a9ebaabf01e971e3efa11c76edea893ad4bf60ea012aa9
  revert hash X passed to SendCmioResponse: 0xdbc1c5fc3b49a18302722e81652000557f17034d6c61661978829664d6be8c92
  root proven after the rejection reset: 0xdbc1c5fc3b49a18302722e81652000557f17034d6c61661978829664d6be8c92
  >> revertRootHash is bound neither by SendCmioResponse.sol nor by log/verify_send_cmio_response:
  >> an arbitrary value X is accepted, and the later rejection reset proves the machine into X
  BUG REPRODUCED: see .../work/sol-cmio-revert/out/forge.txt (grid/reset properties) and the revert-hash binding section
  (quick mode: real 4m10s, exit=1)
  ```
- Possible solution: make the binding intrinsic so no caller can get it wrong.
  - Solidity: in `sendCmioResponse`, use the root at entry. Either drop the parameter and write `a.currentRootHash`
    captured before any access, or `require(revertRootHash == rootAtEntry)` on the applied-advance path. Because
    `SendCmioResponse.sol` is generated, this needs the C++ source to express it. Add a `readRootHashBefore(a)`-style compat
    primitive: `record`/`replay` state accesses return their `root_hash_before`, `state_access` returns
    `machine::get_root_hash()`. Then `send_cmio_response.cpp` writes that instead of the parameter.
  - Emulator API (cheaper, no transpiler change): in `machine::verify_send_cmio_response`, require
    `revert_root_hash == root_hash_before` whenever the replay writes the revert slot. In `machine::log_send_cmio_response`, call
    `check_cmio_response_revert_root_hash` like `send_cmio_response` does.
  - At least, document in the `SendCmioResponse` NatSpec/README that callers MUST pass the pre-response root (the
    `AccessLogs.Context` initial root), as Dave does.
- Severity: Low. Neither the deployed on-chain caller (Dave) nor the reference referee is affected: both bind
  `revertRootHash` to the pre-response root, and the forge test shows that the binding rejects the foreign-revert log. The risk is for
  future integrators of the library or of `cm_verify_send_cmio_response`, where an unbound value would let a rejection "revert" to an
  arbitrary provable state (Critical in such an integration).
- Risks: an intrinsic binding changes the C++ that the Solidity is transpiled from. It does not change the uarch image or any root hash,
  because the honest value is unchanged. Callers that today pass a different value (none known) would break. The emulator-API-only fix
  changes no hashes.

---

### SOL-CMIO-REVERT-2: dataHash contract and length tiers (REJECTED, no mismatch)
- Status: REJECTED.
- Property 1 holds on every grid point. Two dataHash helpers were used: an independent zero-padding keccak tree, and Dave's exact
  `provideMerkleRootOfInput` algorithm. With either one, SendCmioResponse reproduces the emulator log's final root, and that root equals
  the `cm_send_cmio_response` root and the `verify_send_cmio_response` root.
- Lengths 0, 1, 31, 32, 33, 63, 64, 65, 4095-4097, 2^20±1, 2^21-1, 2^21, 2^21+1, 2^22 (Lua grid) and 2^22+1, 2^31, 2^31+1,
  2^32-1 (C API) were tested with reasons advance, inspect, 2, 0x20 and 0xffff. 0 mismatches: `grid cmio: 1180 points, 0 mismatches` (PaddedMerkle and Dave
  provider), `grid cmiobig: 48 points, 0 mismatches`, `grid cmioq: 52 points, 0 mismatches`. The negative control (flat keccak)
  mismatches on all 28 applied-with-data points of the quick grid, so the harness detects a wrong dataHash.
- Notes:
  - Dave's `LibMath.ceilLog2(0) = 0`, so the length-0 dataHash is the hash of one zero leaf. It is irrelevant anyway because
    `dataLength == 0` skips the region write on both sides.
  - On-chain inputs are capped at `CanonicalMachine.INPUT_MAX_SIZE = 2^16` by the InputBox, so the oversize no-op
    branch (> 2^21) is unreachable through Dave. It is still consistent for direct library users.
  - `CartesiStateTransition` uses `SafeCast.toUint32`, so a length ≥ 2^32 reverts rather than truncates.

### SOL-CMIO-REVERT-3: no-op responses consume exactly the emulator log (REJECTED)
- Status: REJECTED. Property 2 holds: 300 no-op points of the Lua grid (Y clear: halted / running / automatic yield /
  imcyclemax overflow; advance to rx-rejected, exception, unknown-reason yields and to the first-yield-rejected machine;
  data > 2^21) and the 48 C-API oversize points all consume exactly the log (`a.buffer.offset == proofs.length`) and
  keep the root. Responses with reasons other than advance to a rejected / exception yield are applied, not no-ops,
  identically on both sides.

### SOL-CMIO-REVERT-4: imcyclemax saturation near 2^64 (REJECTED)
- Status: REJECTED. States `mcA..mcD` (mcycle = 2^64-2^48-1, 2^64-2^48, 2^64-2^48+1, 2^64-1) × 5 reasons × 18 lengths
  and `mcmax` × 3 reasons × 4 oversize lengths: the written imcyclemax (saturating at 2^64-1) and the final roots are identical
  on-chain and in the emulator.

### SOL-CMIO-REVERT-5: UArchReset on rx-rejected states and the spans that follow (REJECTED)
- Status: REJECTED. Property 3 holds in all four scenarios. The on-chain closing transition (`UArchStep.step` on the halted uarch
  + `UArchReset.reset`, one fully consumed buffer) equals the `collect_uarch_cycle_root_hashes` reset leaf, equals the recorded
  revert hash, and differs from the physical root:
  - `adv`: rejection of an advance. All 2000 uarch steps of the rejecting mcycle were replayed with UArchStep, root by root
    == the collector entries. Reset → pre-advance root `0x4f36a710…`.
  - `insp`: rejection of an inspect after an accepted advance. Reset → the stale `0x4f36a710…`, which is the root before the
    earlier advance.
  - `zero`: first yield rx-rejected, no advance ever. Reset → `0x00…00`.
  - `bind`: revert hash X from SOL-CMIO-REVERT-1. Reset → X.

  The period the collector appends after the rejection (the reverted machine's span of 43 uarch steps + reset, or the
  `ztail` span for X) replays on-chain step by step == the collector entries. Rejection is detected only at the span end on both
  sides. The leaves inside the rejecting span are physical roots on both sides.

### SOL-CMIO-REVERT-6: all-zero and stale revert hashes (REJECTED)
- Status: REJECTED (consistent everywhere; not reachable through conforming templates or Dave).
- A rejection before any advance reverts to `0x00…00` on-chain and in the collector. No `UArchStep` proof exists from root 0
  (the test checks this). Afterwards the collector accepts any caller tail ending in 0. The CLI's `--assert-rolling-template` refuses
  templates whose first manual yield is not rx-accepted (also noted in rollup-flow R-4), so a conforming Dave template cannot
  reach it.
- An inspect rejection reverts to the hash recorded by the earlier advance, so it undoes the accepted advance. Dave only ever
  sends advance responses on-chain, and nodes and the CLI run inspects on a snapshot that is reverted afterwards. Consistent
  across `UArchReset`, the collector and `log_step`.

## Negative results (brief)
- FULL=1 run (`out/full-run.txt`, real 19m13s, exit=1 only because of SOL-CMIO-REVERT-1):
  ```
  grid points 1180 (applied 880, no-op 300), emulator send/log/verify disagreements 0
  oversize points 48, emulator problems 0
  adv   mcycle 38: 2000 uarch steps, revert 0x4f36a710aec446ad, collector reset leaf 0x4f36a710aec446ad, collector next period 44 entries
  zero  mcycle 13: 2000 uarch steps, revert 0x0000000000000000, collector reset leaf 0x0000000000000000, collector next period 2 entries
  insp  mcycle 61: 2000 uarch steps, revert 0x4f36a710aec446ad, collector reset leaf 0x4f36a710aec446ad, collector next period 44 entries
  [PASS] testGrid()                  grid cmio: 1180 points, 0 mismatches
  [PASS] testGridDaveProvider()      grid cmio: 1180 points, 0 mismatches
  [PASS] testGridOversize()          grid cmiobig: 48 points, 0 mismatches
  [PASS] testQuickGrid() / testQuickGridDaveProvider()   grid cmioq: 52 points, 0 mismatches
  [PASS] testDataHashHelpersAgree()  PaddedMerkle == DaveConsensus dataHash for 19 lengths (0..2^21+1)
  [PASS] testNegativeControlNaiveHash()  grid cmioq: 52 points, 28 mismatches
  [PASS] testRejectAdvanceReset()    adv: UArchReset root == collector reset leaf == 0x4f36a710...; following span == collector
  [PASS] testRejectAfterInspectReset()  insp: same (stale hash); following span == collector
  [PASS] testRejectWithoutAdvanceReset()  zero: UArchReset root 0x00..00 == collector leaf; no UArchStep proof from it
  [PASS] testArbitraryRevertHash()   (SOL-CMIO-REVERT-1 demonstration)
  Suite result: ok. 11 passed; 0 failed
  ```
- Emulator self-consistency on every grid point: `log_send_cmio_response` root == `cm_send_cmio_response` root ==
  `verify_send_cmio_response` root. `grid points 1180 (applied 880, no-op 300), emulator send/log/verify disagreements 0`;
  oversize `48 points, 0 problems`.
- The rejecting mcycle really takes 2000 uarch cycles (HTIF yield path; the previous mcycle takes 539), all within one span.
- No grid point, rejection scenario, or following span produced a divergence between the C++ emulator and the PR #104
  Solidity.
