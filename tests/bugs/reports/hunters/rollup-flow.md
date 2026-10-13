# Findings: rollup-flow (end-to-end input lifecycle, imcyclemax budget, revert root hash, CMIO responses, CLI driver)

Work dir: `<SCRATCH>/work/rollup-flow/` (`<SCRATCH>` = `<SCRATCH>`).
All PoCs need the environment: `eval $(make -C /home/user/machine-emulator -s --no-print-directory env)`.
Test guest: `guest.S` / `guest.bin` (bare-metal rollup-like guest: manual rx-accepted yield, then per input a
command word `action | loops<<8` read from the rx buffer: 0 accept, 1 reject, 2 exception, 3 halt, 4 spin,
5 tx-output (automatic yield) then accept, 6 tx-output then reject, 7 manual yield with unknown reason 3).
Shared helpers: `lib.lua`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| ROLLUP-FLOW-1 | `log_step(N)`/`verify_step(N)` (and the RISC Zero replay + on-chain `CartesiStepVerifier`) stop at the first automatic yield (tx-output/tx-report/progress), so an N-mcycle step proof attests a state that is NOT the state after N mcycles computed by `cm_run`, the uarch, `collect_mcycle_root_hashes` and `collect_mcycle_bundle` | PROVEN | Critical (for ZK/step-log based disputes) |
| ROLLUP-FLOW-2 | `cartesi-machine --revert-mode=none` (`--no-revert`) aborts with a Lua assertion at the first rejected advance-state input | PROVEN | Low |
| R-1 | imcyclemax budget: all paths agree at the overflow cycle (yield/halt/reject exactly at, one before, one after `imcyclemax`) | REJECTED (no divergence) | - |
| R-2 | revert root hash substitution: run / log_step+verify_step / uarch reset log+verify / collect_mcycle_root_hashes / collect_mcycle_bundle / collect_uarch_cycle_root_hashes / collect_uarch_cycle_bundle / referee emulation agree | REJECTED (no divergence) | - |
| R-3 | `send_cmio_response` vs `log_send_cmio_response` + `verify_send_cmio_response`: same accept/no-op decision and same root hash for 9 machine states x 5 reasons x 9 lengths | REJECTED (no divergence) | - |
| R-4 | Other lifecycle hypotheses (inspect budget, reject without prior advance, continuing past a rejection, oversized inputs in the CLI, uarch tail/bundles, CLI computation hash builders) | REJECTED / by design | - |

(details below; R-x entries are negative results kept short)

### ROLLUP-FLOW-1: N-mcycle step logs stop at the first automatic yield, so `verify_step`, the RISC Zero replay and `CartesiStepVerifier` accept a "state after N mcycles" that no other path computes
- Status: PROVEN
- Area: step-log (log_step / verify_step), ZK verifier (risc0), vs collect-hashes / uarch / cm_run
- Category: divergence, proof-soundness
- Where: `src/machine.cpp:2180` (`machine::log_step`: single `interpret(a, mcycle_end)` call), `src/machine.cpp:2207`
  (`machine::verify_step`: single `interpret(a, mcycle_end)` call), `risc0/cpp/risc0-replay-steps.cpp:39`
  (`risc0_replay_steps`: single `interpret` call), with `src/interpret.cpp:6398` returning
  `yielded_automatically` (the interpreter loop returns on `execute_status::success_and_yield`, `interpret.cpp:6310-6327`).
  Affected entry points: `cm_log_step`/`cm_verify_step`, Lua `machine:log_step`/`verify_step`, JSON-RPC
  `machine.log_step`/`machine.verify_step`, CLI `--log-step`, `cartesi-risc0-cli prove`.
- Problem: `interpret()` returns as soon as the guest issues an automatic yield (HTIF yield automatic: tx-output,
  tx-report, progress). That is fine for `cm_run`, whose caller reads the output and resumes, and for the hash
  collectors, which return and are resumed (`collect_mcycle_bundle` explicitly "continues through automatic yields",
  `machine.hpp:281`; the uarch executes one mcycle per big step and simply clears `iflags.X` at the next mcycle).
  But `log_step(mcycle_count)` and `verify_step(root_hash_before, log, mcycle_count)` call `interpret` once: when an
  automatic yield happens inside the step, they stop there. The log header still records `mcycle_count` = N and
  `root_hash_after` = the state at the yield, and `verify_step` returns that hash. The RISC Zero guest
  (`risc0_replay_steps`) does the same and commits the journal `(root_hash_before, N, root_hash_after)`, which
  `risc0/solidity/src/CartesiStepVerifier.sol::verifyStep(seal, journal, rootHashBefore, mcycleCount, rootHashAfter)`
  accepts as "mcycleCount machine cycles executed". Every other execution path (cm_run resumed after the yield, uarch
  big-steps + reset, `collect_mcycle_root_hashes`, `collect_mcycle_bundle`, i.e. the leaves of the mcycle computation
  hash) gives a different state after N mcycles. There is no way to produce a single step log for N mcycles across an
  automatic yield.
- Scenario: the step log / ZK path exists to prove batches of mcycles ("Added the `cm_log_step` and `cm_verify_step`
  methods to log multiple machine cycles and verify with ZK VMs", "RISC0 zkVM integration for fraud proof
  verification"). In a dispute whose bottom level proves a leaf interval of the mcycle computation hash (2^p mcycles)
  with one step proof, every interval that contains an output, report or progress yield (i.e. almost every input of a
  rollup application, since each voucher/notice/report is an automatic yield) is affected:
  (a) a dishonest claimer that puts S_yield (state at the automatic yield) as the leaf after the agreed S_j obtains a
  perfectly valid step log / ZK proof `S_j --N--> S_yield` from an unmodified emulator (`log_step(N)`), and wins the
  sub-dispute; (b) the honest claimer, whose leaf is the correct S_{j+N}, cannot produce any single step proof for it
  (its own `log_step(N)` also stops at the yield). An invalid transition is provable and the honest party loses.
  Today the documented PRT recipe (`doc/recipes/prt.lua`) still settles the bottom level with uarch steps, so the
  impact materialises when the step-log/ZK verifier is used for disputes as intended (ZK machines use SHA-256 trees,
  and `log_send_cmio_response` is Keccak-only, so a ZK dispute over a rollup epoch also still lacks an input-delivery
  proof; ZK disputes over plain computations are affected by `yield automatic progress` the same way).
- Evidence: `<SCRATCH>/work/rollup-flow/poc-logstep-autoyield.lua` (command at the top:
  `lua5.4 poc-logstep-autoyield.lua`). Input "action 5, loops 6": tx-output automatic yield at boundary+57, accept at
  boundary+69; step N = 64. Output:
  ```
  automatic yield at boundary+57 (inside the 64-mcycle step)
  cm_run (resumed)          	803dac05148a8400
  collect_mcycle_root_hashes	803dac05148a8400
  collect_mcycle_bundle     	803dac05148a8400
  uarch big-steps           	803dac05148a8400
  log_step(64)/verify_step   fdb84a397afaf903  (break=YIELDED_AUTOMATICALLY, machine stopped at boundary+57)
  chained log_step(57)+log_step(7)  803dac05148a8400
  BUG REPRODUCED: verify_step accepts a 64-mcycle step log whose final hash is the state at the automatic yield (boundary+57), not the state after 64 mcycles
  ```
  (exit code 1). The chained pair of logs shows that continuing the replay after the yield reproduces the canonical
  state, i.e. the fix below does not change any root hash.
  C API version: `<SCRATCH>/work/rollup-flow/poc-logstep-autoyield.c` (build/run commands at the top; `./poc-c guest.bin`):
  ```
  cm_run (resumed)             803dac05148a8400
  uarch big-steps              803dac05148a8400
  log_step/verify_step(64)     fdb84a397afaf903
  log_step break reason 3, machine at boundary+57
  BUG REPRODUCED: 64-mcycle step log verifies to the state at the automatic yield
  ```
  Same on a SHA-256 machine (the ZK configuration): `poc-logstep-autoyield-sha256.lua` prints
  `cm_run (resumed) 9f63b519998ec60c`, `collect_mcycle_root_hashes 9f63b519998ec60c`,
  `log_step/verify_step(64) d45426ada1bb9c44 YIELDED_AUTOMATICALLY stopped at boundary+57`, `BUG REPRODUCED`.
  Same with the test Linux image and a real guest command (`yield automatic progress 10`), step of 4096 mcycles
  starting 1000 mcycles before the yield (`poc-logstep-autoyield-linux.lua`):
  ```
  automatic yield at mcycle 53084204; step from 53083204 for 4096 mcycles
  cm_run resumed            	7944d6b5ada398ef	mcycle 53087300
  collect_mcycle_bundle     	7944d6b5ada398ef
  log_step/verify_step(4096)	f04e38efd8d0cc42	YIELDED_AUTOMATICALLY	machine stopped at 53084204
  BUG REPRODUCED (Linux guest, progress yield)
  ```
  Fix verified: `fixbuild/src/libcartesi.so` is a release build of the same sources with only the loop below added
  to `machine::log_step` and `machine::verify_step`; `LD_LIBRARY_PATH=fixbuild/src ./poc-c guest.bin` prints
  `log_step/verify_step(64) 803dac05148a8400 ... machine at boundary+64 ... OK` (exit 0).
- Possible solution: make the step logger and both step verifiers continue through automatic yields, exactly like the
  uarch and the collectors, e.g. in `machine::log_step`, `machine::verify_step` and `risc0_replay_steps`:
  ```cpp
  auto break_reason = interpret(a, mcycle_end);
  while (break_reason == interpreter_break_reason::yielded_automatically) { // not a fixed point
      break_reason = interpret(a, mcycle_end);                              // clears iflags.X and resumes
  }
  ```
  (record and replay must loop identically). Alternatively make `interpret` not return on automatic yields for the
  non-interactive step accessors. Add a test with a tx-output yield strictly inside a multi-cycle step comparing
  `verify_step` against `collect_mcycle_root_hashes` and uarch steps.
- Severity: Critical — an implementation that must agree with the uarch/computation hash (the step-log verifier and
  its ZK/on-chain counterpart) accepts an invalid N-mcycle transition and cannot prove the valid one; only mitigated by
  the step-log/ZK verifier not yet being wired into the documented PRT bottom level (if the coordinator considers
  the ZK/step-log dispute path not deployed, High). Note it is much easier to trigger than COORD-1/STEP-PROOF-2: any
  output, report or progress yield inside a batch suffices, no special template is needed.
- Risks: if left unfixed, ZK fraud proofs over batches are unsound/incomplete for any batch containing an output or
  report. The fix changes no root hash and no uarch/Solidity code; the ZK guest image ID changes (risc0 rebuild).
  Existing step logs that end at an automatic yield (with N greater than the cycles actually executed) would stop
  verifying, which is the intended outcome.

### ROLLUP-FLOW-2: `--revert-mode=none` / `--no-revert` aborts on the first rejected advance-state input
- Status: PROVEN
- Area: CLI (`src/cartesi-machine.lua`)
- Category: input-validation / DoS of the CLI driver
- Where: `src/cartesi-machine.lua:3968-3970` (`computation_hash_check_revert`, used as `check_revert` by every builder,
  including the null builder), called from `run_advance_state_input` (`:4497-4498`) right after `backup:revert()`,
  which is a no-op for `revert_none` (`:3646-3655`).
- Problem: mode `none` is documented ("Mode `none` disables snapshots and never reverts rejected inputs or
  inspect-state queries", doc/README.md ~2483) and is used throughout the CLI tests, but any rejected input makes
  `check_revert` assert `machine:get_root_hash() == revert_root_hash`, which can never hold without a revert, so the CLI
  dies with `rollback did not restore the input boundary` and leaves no outputs/epoch files for the remaining inputs.
- Scenario: a developer debugging a rollup app with `--no-revert` (the only mode that works without a JSON-RPC server
  or a stored machine) gets a Lua traceback as soon as the app rejects an input.
- Evidence: `<SCRATCH>/work/rollup-flow/poc-cli-norevert.sh` (`bash poc-cli-norevert.sh`):
  ```
  lua5.4: /home/user/machine-emulator/src/cartesi-machine.lua:3969: rollback did not restore the input boundary
  ...
  BUG REPRODUCED: --revert-mode=none aborts on the first rejected input
  ```
- Possible solution: skip the check when no snapshot exists (e.g. `if backup:has_snapshot()` before reverting and
  checking, or a `check_revert` no-op for `revert_none`), and document that with `none` the next input is delivered to
  the rejecting machine (a no-op transition), so computation hashes must be refused in that mode.
- Severity: Low — CLI debugging mode only; no effect on the emulator or on proofs.
- Risks: none for hashes; with the check removed, `--revert-mode=none` combined with computation hashes would compute a
  hash that does not follow the PRT semantics, so that combination should be rejected up front.

### R-1: imcyclemax budget at the overflow cycle (REJECTED, no divergence)
Harness `compare.lua <action> <loops> <budget_delta> uarch`: after one accepted input, the boundary `mcycle` is moved
to `MCYCLE_MAX - budget`, so the real `send_cmio_response` path saturates `imcyclemax` to `MCYCLE_MAX` and the input
gets exactly `budget` cycles (`budget = D + delta`, D = cycles until the input's manual yield/halt). For every mcycle
k of the input it compares the canonical hash (revert root hash when rx-rejected) obtained by: (A) `cm_run(M0+k)`,
(B) `log_step(1)` + `verify_step` (hash and break reason), (D) `collect_mcycle_root_hashes(period 1)`, (F)
`collect_mcycle_bundle(k-1, 0, 0)`, (E) `collect_uarch_cycle_root_hashes` (reset entries, with the revert tail),
(C) `run_uarch` + `log_reset_uarch`/`verify_reset_uarch`, (G) `collect_uarch_cycle_bundle` (last bundle).
Results (`budget-run.txt`, `queue2.txt`, `queue3.txt`, `queue4.txt`; 24 runs `ALL PATHS AGREE`, plus tx-output+accept with the accept at `imcyclemax` re-checked for the uarch path with `checkC.lua` after a harness positioning fix): accept,
reject, exception, halt, tx-output+accept, tx-output+reject and unknown-reason manual yield, each with the yield
exactly at `imcyclemax`, one cycle before and one cycle after, and the tx-output automatic yield exactly at, one before
and one after `imcyclemax` (X=1 at the overflow fixed point): all paths agree
(precedence halt > manual yield > overflow; a rejection at the overflow cycle is reverted everywhere; an accepted
yield at the overflow cycle is renewed by the next advance).

### R-2: revert root hash substitution and referee emulation (REJECTED, no divergence)
`prt.lua` emulates `validate_state_transition_response` (doc/README.md): first transition =
`verify_send_cmio_response(root_hash_before, revert = root_hash_before)` + `verify_step_uarch`, every uarch cycle
verified, `verify_reset_uarch` at the end of each mcycle, switching to the reverted machine after a rejection; the
per-mcycle hashes match `collect_uarch_cycle_root_hashes` (with revert tail) and `collect_mcycle_root_hashes`
(`REFEREE AGREES` for: reject with an unconstrained budget, reject exactly at `imcyclemax`, tx-output + reject with the
reject exactly at `imcyclemax`, halt exactly at `imcyclemax`; `prt-run.txt`, `prt-6-2-0.txt`). `bundles.lua` checks
bundled `collect_mcycle_root_hashes` (chunked, partial bundles, periods 1..8, bundles 1..4, fixed-point padding with
the revert root hash) and `collect_mcycle_bundle` against a reference Merkle computation over the step-by-step
canonical hashes (`BUNDLES AGREE` for reject, reject at overflow, tx-output at the overflow cycle, tx-output+reject at
overflow, halt at overflow; `queue2.txt`).

### R-3: CMIO response semantics (REJECTED, no divergence)
`sendcheck.lua`: states {rx-accepted, rx-rejected, tx-exception, unknown manual reason, halted, running (not
yielded), automatic yield, mcycle overflow, rx-accepted at overflow} x reasons {advance, inspect, 2, 0x20, 0xffff} x
lengths {0, 1, 31, 32, 33, 2^21-1, 2^21, 2^21+1, 3*2^20}: `send_cmio_response` (with the revert hash required by the
host API) and `log_send_cmio_response` + `verify_send_cmio_response` never fail and always produce the same final
root hash and the same no-op decision (`problems 0`). `sendcheck-remote.lua` repeats a subset (rx-accepted,
rx-rejected, running x advance/inspect x 0/32/2^21/2^21+1 bytes, plus a following `collect_mcycle_root_hashes`)
on a local machine and on a JSON-RPC machine: `LOCAL AND REMOTE AGREE`. The "cannot fail" no-op policy cannot mislead a node about the
state transition: an oversized/inapplicable advance leaves the machine at its previous yield, which `cm_run` and
`receive_cmio_request` then report, exactly as the on-chain transition does (and on-chain inputs are size-capped by the InputBox anyway).

### R-4: other lifecycle hypotheses (REJECTED / by design / Low)
- Inspect-state responses do not renew `imcyclemax`: an inspect runs with the leftover budget of the last advance
  (2^48-1 minus what that advance used) and overflows immediately only if the advance yielded exactly on its last
  cycle. Inspects are always reverted and not disputed; Low/by design.
- Rejection with no prior advance (template whose first manual yield is rx-rejected): every path substitutes the
  initial (all-zero) revert root hash consistently; the CLI refuses such a template. A rejection during an inspect
  substitutes the last advance's revert hash in every path; harmless because inspects are reverted.
- Continuing past a rejection: `cm_run` keeps returning `YIELDED_MANUALLY`; an advance is a no-op (consistent with
  logged/verified sends); only inspect/GIO responses resume the rejecting machine (not part of disputes).
- `receive_cmio_request` throws when the guest reports a tx length > 2 MiB, so a buggy guest can abort the CLI
  (`get_and_print_yield`) — guest/app-controlled, Low.
- CLI resumable epochs (new in 0.22): a 6-input epoch (accept, reject, tx-output+accept, accept, tx-output+reject,
  accept) run in one invocation and split as `end_epoch:false,resumable:true` (inputs 0..2) +
  `begin_epoch:false` (inputs 3..5) with `--revert-mode=stored` and `--mcycle-computation-hash` (period 4, bundle 2)
  produce the same mcycle computation hash `6dde2f02...583c1c47` (`<SCRATCH>/work/rollup-flow/resum1/`).
- CLI with an input that exhausts its budget (template with `mcycle = 2^64-256` so `imcyclemax` saturates; inputs
  accept, tx-output+accept, spin, accept): reports `Mcycle overflow`, treats it as a sticky fixed point, pads the rest
  of the epoch and prints the computation hash (`<SCRATCH>/work/rollup-flow/ovf1/`).
- CLI computation-hash builders: oversized (no-op) inputs, rejections before/inside/after the uarch target period,
  overflow and exception fixed points, automatic yields inside the target period and resumption all follow the
  collector semantics; no divergence found. `--assert-rolling-template` does not check reproducibility (`iunrep`) or
  the Keccak hash function; such templates fail loudly later (hash collection/uarch refuse them), so Low.
- RISC Zero `mcycle_end` wraparound: already reported (COORD-1 / STEP-PROOF-2); `data == NULL` partial modification in
  `send_cmio_response`: already reported (STEP-PROOF-4).
