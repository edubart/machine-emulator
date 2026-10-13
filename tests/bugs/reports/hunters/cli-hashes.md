# Angle: cli-hashes (hash values computed by the cartesi-machine CLI and its Lua helpers)

Scope: every hash/proof value that `src/cartesi-machine.lua` and `src/cartesi/hash-tree.lua` compute or print
for dapp developers and node tooling: mcycle and uarch-cycle computation hashes (`--mcycle-computation-hash`,
`--uarch-cycle-computation-hash`, resumable/explicit epochs, frontier files), outputs Merkle roots, output proofs
and outputs-Merkle-root proofs (`--cmio-advance-state`, `last_output_proof`, history files), printed root hashes
(`--print-mcycle-root-hashes`, `--print-uarch-cycle-root-hashes`, `--initial/final-hash`, `--initial/final-proof`),
the frontier / frontier-forest library, and the `cartesi-hash-tree-hash` tool.

`<SCRATCH>` = `<SCRATCH>`.
Work dir: `<SCRATCH>/work/cli-hashes/`. Environment for every command:
`eval $(make -C /home/user/machine-emulator -s --no-print-directory env)`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| cli-hashes-3 | Under `--gdb`, a cycle step (`monitor stepc N` + `continue`, the documented `stepc` macro) that ends on an automatic-yield mcycle never completes: a plain run silently stops at the yield and exits 0 printing a "final" hash of the unfinished machine; an advance-state epoch with a computation hash spins forever | PROVEN | Medium (borderline Low: debugging path only) |
| cli-hashes-1 | `--print-uarch-cycle-root-hashes` prints a fabricated uarch group (2 entries built from a fake revert tail) after an rx-rejected yield, instead of the canonical group that `collect_uarch_cycle_root_hashes`/`--uarch-cycle-computation-hash` use | PROVEN | Low |
| cli-hashes-2 | `hash_tree.get_data_root_hash("", n)` returns `nil` instead of the pristine root | PROVEN | Low |
| (negative) | CLI mcycle / uarch computation hashes, output proofs, outputs-Merkle-root proofs, resumable epochs, frontier & forest library, printed root hashes, `cartesi-hash-tree-hash`: all equal independent references over large randomized sweeps | REJECTED (no defect) | - |

Every value the CLI computes for computation hashes and output proofs matched an independent from-scratch
reference in all configurations tried (details and evidence below). The defects found are in the CLI's
diagnostic/debugging paths: the GDB-stub stepping bug (cli-hashes-3, found while checking that hashes collected
with a debugger attached equal those collected without it) and two Low issues.

---

## Independent references and harness

All in `<SCRATCH>/work/cli-hashes/common/` (none of them uses `cartesi.hash-tree`; only the raw primitives
`cartesi.keccak256`/`cartesi.sha256`, which the hash-tree angle verified against independent Keccak/SHA-256):

- `ref.lua`
  - `rl_root(runs, height)`: run-length Merkle root (pairs consecutive elements level by level), used for every
    tree whose leaves are long repetitions (computation hashes up to 2^72 leaves are evaluated as per-input
    subtrees of height 48-p and an epoch tree of height 24, which is mathematically the same root).
  - `sparse_root` / `sparse_node` / `output_proof`: outputs Merkle tree (height 63, pristine leaf = 32 zero bytes)
    and its proofs, from scratch.
  - `epoch_reference(template, inputs, p)`: mcycle computation hash from first principles: delivers each input
    with `send_cmio_response`, runs with `cm_run` to every sample point `start + k*2^p` (servicing automatic
    yields), takes `get_root_hash()` there; at a fixed point the remaining samples of the input repeat the
    fixed-point hash (the revert root hash for rx-rejected); a rejected input is undone by replaying only the
    accepted inputs from the template; unprocessed inputs repeat the epoch's final state. Also records accepted
    outputs and, per accepted input, the state hash and tx-buffer word (for the outputs-Merkle-root proofs).
- `uc.lua` (`uarch_reference`): uarch cycle computation hash from `run_uarch(u+1)` + `get_root_hash()` after every
  uarch cycle, halt repetition to 2^20-1 leaves, `reset_uarch()` (revert root hash when the mcycle reached an
  rx-rejected yield), fixed-point groups computed by running the uarch over the fixed point, the reverted
  machine's group after a rejection, and the epoch's final fixed point when the target input is never reached.
- `guest.S`/`guest.bin`: bare-metal rollup guest; each input selects accept/reject/exception/halt/unknown manual
  yield, busy-loop lengths, number of tx-output automatic yields, tx-report yields, and carries the expected
  outputs Merkle root (computed by the harness with `ref.sparse_root`), which the guest writes to the tx buffer
  on accept, so the CLI's default `check_outputs_merkle_root:true` is exercised on every accepted input.
  `guest2.S`: plain program with periodic progress automatic yields, then halt.
- `cli.lua`, `scen.lua`: CLI driver and random scenario builder; `gdbc.lua`: minimal GDB remote-protocol client.

## Negative results (all with the default release build)

| Test (command, in `common/`) | What is compared | Result |
|---|---|---|
| `WORK=$PWD/../tmp lua5.4 mc.lua <seed> <n>` | CLI `--mcycle-computation-hash` (p in {0..5,7,9,12,20,47,48}, bundle 0..6, keccak & sha256, 0-6 inputs with accept/reject/exception/halt/unknown-yield, outputs, reports) vs `epoch_reference`; every output proof file (JSON) vs `ref.output_proof`; every `outputs_merkle_root_proof` (root = state at accept, address = tx buffer, log2 sizes, target = machine-hash(word), roll-up with the machine hash function) | seeds 1,2,7: 47/47 OK |
| `NEAR_MAX=3000 lua5.4 mc.lua 22 12` (template mcycle = 2^64-1-d) | same, inputs hitting the mcycle-overflow fixed point and saturated sample points | 12/12 OK (also NEAR_MAX=400 seed 21) |
| `PMAX=3 MAXLOOPS=2500 lua5.4 mc.lua 41 15` | long inputs (thousands of mcycles, p<=3) so collections span many chunk boundaries, partial bundles carried across chunks and across automatic yields | see final counts below |
| `REMOTE=1 lua5.4 mc.lua 31 6` | same through `--remote-spawn` (JSON-RPC machine, `--revert-mode=fork`) | 6/6 OK |
| `lua5.4 uc.lua 2 30`; `TARGETED=1 SPLIT=1 MAXLOOPS=60 lua5.4 uc.lua 6 25` | CLI `--uarch-cycle-computation-hash` (p 0..6, uarch bundle 0..19, targets inside executing periods, at the fixed-point period, past the inputs, rejections inside/before the period, terminal inputs) vs `uarch_reference`; `SPLIT` also runs the target from a later input (`begin_epoch:false,next_input_offset:k`) on a machine produced by a previous resumable invocation | see final counts below |
| `lua5.4 rs.lua 1 3`, `lua5.4 rs.lua 11 12`, `SPLIT2=1 lua5.4 rs.lua 51 10` | resumable epochs split at random input boundaries (`begin_epoch/end_epoch/resumable`, `state_hash`, `outputs_frontier`, `output_hashes`, `output_input_indices`, computation `frontier`), 10 of them first interrupted by `--max-mcycle` and re-run; then a second epoch resumed from the first epoch's `last_output_proof` (optionally split too); computation hashes and all output proofs (global indices) vs reference | all OK |
| `lua5.4 ht.lua <seed> 3000` (seeds 1-5) | `frontier`, `frontier_push_back`, `frontier_append` (with subtree heights and begin/end ranges), `frontier_pad_back` (counts, pad heights, `count=nil`), `frontier_get_root_hash` (zero/custom pad, pad heights), `frontier_copy`, `frontier_get_leaf_count`, `frontier_next_proofs` (every sibling), `frontier(last_proof)` == pushed frontier, heights 0-62, keccak & sha256 | 12,300 iterations OK |
| `lua5.4 forest.lua <seed> 3000` (seeds 1-6) | frontier forests: `append`/`push_back` (raw hashes and completed sub-forests)/`pad_back` (incl. fill), `get_root_hash`, `get_node_hash` and `get_siblings` at random positions/heights (incl. into sub-forests), `expand_leaf` (opaque replacements rejected as designed) vs an item-list reference | 378,000 checks OK |
| `lua5.4 pm.lua 1 6` | every `<mcycle>: hash` and `<first>-<last>: bundle` line printed by `--print-mcycle-root-hashes` (start:, bundles, --max-mcycle, fixed point) vs `cm_run`+`get_root_hash` | OK |
| `lua5.4 gdbt.lua <seed> <n>` | computation hashes printed with a GDB session attached (breakpoints in guest loops, `monitor stepc`) equal those printed without GDB (gdbstub's per-mcycle collect aggregation, offsets rebasing, fixed-point de-duplication) | see final counts below |
| `../hthash/t.lua 1 80` | `cartesi-hash-tree-hash` (random word/leaf/root sizes, file sizes incl. 0 and non-multiples, keccak & sha256) vs `rl_root` | 80/80 OK |
| manual | `--initial-proof=label:` on non-power-of-two drives/NVRAM: proofs cover the reserved power-of-two window, no overlap with the next range (placement reserves the window) | OK |

Code-level checks with no defect: `frontier_padding_fits` for heights > 63 (computation trees reach height 72);
`frontier(proof)` lowest-complete-level reconstruction; `frontier_next_proofs` frontier/active/pristine
boundaries; mcycle builder per-input bundle capacity and fixed-point padding; uarch builder period offsets,
fixed-point extra group, rejected-input tail and pre-period stops; `imcyclemax = start + 2^48 - 1` agrees with the
builder's `input_mcycle_end = start + 2^48`; Lua offsets returned by `collect_uarch_cycle_root_hashes` are 1-based
and every consumer (`print_collected_uarch_hashes`, builders, gdbstub) uses them consistently; `util.parse_number`
negative/2^63+ inputs are rejected by every computation-hash option check.

---

### cli-hashes-1: `--print-uarch-cycle-root-hashes` prints a fabricated uarch group after an rx-rejected yield
- Status: PROVEN
- Area: CLI
- Category: divergence (printed values differ from the canonical collection)
- Where: `src/cartesi-machine.lua:3836-3846` (`uarch_cycle_root_hashes_runner_run`):
  ```lua
  -- The revert uarch tail only matters when the run stops at a rejected manual yield, which
  -- never happens outside cmio mode. The minimal valid tail suffices: ...
  local fake_revert_uarch_tail = { revert_root_hash, revert_root_hash }
  ```
- Problem: the comment's premise is false. `--print-uarch-cycle-root-hashes` is the tool for inspecting a stored
  machine, and a machine stored or loaded in the middle of an advance-state input (a snapshot taken during a
  dispute, for example) reaches an rx-rejected manual yield outside cmio mode. `collect_uarch_cycle_root_hashes` then
  appends "one extra period, that of the reverted machine, as given by revert_uarch_tail". The CLI passes a fake
  2-entry tail, so the printed group after the rejection is `<m>,1: R` / `<m+1>: R`. The canonical group (what
  `collect_uarch_cycle_root_hashes` with the real tail returns, and what `--uarch-cycle-computation-hash` commits to)
  has one entry per uarch cycle of the reverted machine (43 in the PoC). The `<m+1>:` label also names an mcycle
  the machine never reaches.
- Scenario: an operator debugging the uarch level of a dispute around a rejected input loads the snapshot and
  prints uarch hashes to compare with a claim. All entries match except the post-rejection group, which is
  fabricated, so the comparison points at a divergence that does not exist (or hides one).
- Evidence: `<SCRATCH>/work/cli-hashes/uarch-print-reject/run.sh` (machine stored right after delivering a
  rejecting input; CLI output vs `collect_uarch_cycle_root_hashes` with the real tail):
  ```
  canonical group after the rejection: 43 entries; last = 0x0eba234548392cc4
  CLI printed lines total: 26683; last printed lines:
    50,2196: 0x32d19e717bb8b5725d0d574d1a822
    51: 0x0eba234548392cc42113f925d74bffe886
    51,1: 0x0eba234548392cc42113f925d74bffe8
    52: 0x0eba234548392cc42113f925d74bffe886
  CLI entries for the post-rejection group: 2 (canonical 43)
  entries before the post-rejection group matching canonical: 26680 of 26680 (canonical total 26723)
  BUG REPRODUCED: --print-uarch-cycle-root-hashes prints a fabricated group after an rx-rejected yield
  ```
- Possible solution: the real tail cannot be derived from the current machine. When a collect call stops at an
  rx-rejected yield and no tail is available, print the entries up to and including the rejecting mcycle's
  reset line (which already carries the canonical revert root hash), drop the extra group, and print a warning.
  Alternatively, add a `revert_uarch_tail:<file>` sub-option and require it when the window can reach a
  rejection.
- Severity: Low. Diagnostic output only. The computation-hash builders use the real tail.
- Risks: none. Hashes and on-chain formats do not change.

---

### cli-hashes-3: stepping onto an automatic yield under `--gdb` ends the run early (exit 0, bogus final hash) or loops forever
- Status: PROVEN
- Area: CLI / `cartesi.gdbstub`
- Category: divergence (wrong result printed with success status) / DoS of the debug session
- Where: `src/cartesi/gdbstub.lua:475-521` (`GDBStub:_handle_continue`): line 482 `mcycle_end = self.mcycle_limit`,
  the yield checks at lines 495 and 515 (`iflags_Y ~= 0 or iflags_X ~= 0` → `self.suspended = true`), and
  `GDBStub:run` (`:648`) / `GDBStub:collect_*` (`:668-745`), which return the break reason of the last inner
  advance to the CLI.
- Problem: `monitor stepc N` (or `stepu`) sets `mcycle_limit`, and `continue` runs to it. If the machine reaches that
  mcycle with an automatic yield (tx-output, tx-report, progress), the stub suspends the outer call so the CLI can
  service the yield. That much is correct. When the CLI resumes, `_pump_session` re-enters `_handle_continue`, which
  again uses `mcycle_end = mcycle_limit` = the current mcycle. The inner `run`/`collect` performs no transition, so
  `iflags_X` is still set. The stub treats this as a new yield, suspends again, and never sends GDB the
  "step done" stop reply.
  - Plain run: the zero-length `run` returns `REACHED_TARGET_MCYCLE`, and `GDBStub:run` passes that on to the CLI's
    `run_to_stop` as if the CLI's own target (`--max-mcycle`) had been reached. The CLI stops, prints
    `--final-hash` for the machine at the yield mcycle, and exits 0. The program has not finished (it would halt
    at mcycle 2845), and the GDB connection is closed without a reply.
  - `--cmio-advance-state` with `--mcycle-computation-hash`/`--uarch-cycle-computation-hash`: the builders see
    "no progress" and call again, forever, so the run never ends. With no breakpoint, the stub returns the zero-length
    `REACHED_TARGET_MCYCLE` and the builder silently walks through empty chunks. With a breakpoint set, the
    breakpoint loop is skipped and the stale `self.break_reason` (`YIELDED_AUTOMATICALLY`) is returned. The CLI then
    re-services the same yield on every iteration, re-printing it and appending the same output to the input's
    pending outputs again. One sweep run (mcycle hash p=1, breakpoint plus `stepc 5`) produced a 783 MB log of the
    same "Automatic yield tx-output … Cycles: 235" pair (13.3 million times) before its 600 s timeout.
- Scenario: a developer debugging a guest uses the documented `stepc` macro (`tools/gdb/gdbinit`:
  `monitor stepc N; c; monitor stepc_clear`). Single-stepping across any instruction that emits an
  output/report/progress yield, which is exactly where rollup debugging happens, hits this. A plain run exits
  "successfully" with a final hash (and `--store`d machine) that is not the end of the program. A cmio run hangs.
  The CLI documents that GDB may be combined with hash collection as long as the debugger only observes. Stepping
  only observes, yet it breaks the run.
- Evidence: `<SCRATCH>/work/cli-hashes/gdb-stepc-yield/run.sh` (`client.lua` sends exactly `qRcmd stepc N` then
  `c`):
  ```
  == (A) plain run of a program with periodic progress yields, then halt
  first automatic yield at mcycle 23, program halts at mcycle 2845
  stop reply after stepc 22: S02
    stepc 22: client rc=0, CLI exit 0, halted: 1, last printed hash line: 2845: 0x7a7cb0a8d4dbafdec1d5a5
  no stop reply within 5 s after stepc 23 (closed)
    stepc 23: client rc=1, CLI exit 0, halted: 0, last printed hash line: 23: 0x4742e10bdd884c8f4d7a4bbe
    -> (A) reproduced: no stop reply, run ended at the yield (mcycle 23 < 2845) with exit 0
  == (B) --cmio-advance-state with --mcycle-computation-hash, stepping onto a tx-output yield
  no stop reply within 5 s after stepc 32 (timeout)
    stepc 32 (onto the first tx-output yield): client rc=1; CLI still running 8 s later: 1; CPU ticks in 3 s: 137
    -> (B) reproduced: no stop reply; the CLI never finishes the epoch (spins at the yield)
  BUG REPRODUCED: stepping onto an automatic yield under --gdb ends the run early or loops forever
  ```
  With breakpoints only, or with steps that do not end on a yield, computation hashes collected under GDB equal
  those collected without it (`common/gdbt.lua`; the only mismatches in that sweep were runs that combined
  `stepc` with a step ending on a yield, which never produced a hash).
- Possible solution: in `_handle_continue`, detect a completed step before the yield checks. If
  `self.mcycle_limit` is set and `machine:read_reg("mcycle") == self.mcycle_limit`, reply `SIGINT` (step done) and
  do not suspend again. Equivalently, remember the mcycle of a yield already handed to the caller and do not
  re-report it when resuming at the same mcycle. Separately, `GDBStub:run`/`collect_*` should not return
  `REACHED_TARGET_MCYCLE` to the caller for a target other than the caller's own `mcycle_end` (they should keep
  pumping the session).
- Severity: Medium (borderline Low). Only debugging sessions are affected, but a common action in them gives a
  silently wrong "successful" result (final hash/stored machine of an unfinished run) or a hang. Consensus values
  are unaffected.
- Risks: none for hashes. The fix only changes stub control flow.

---

### cli-hashes-2: `hash_tree.get_data_root_hash("", n)` returns nil
- Status: PROVEN (`lua5.4 -e 'print(require"cartesi.hash-tree".get_data_root_hash("", 12))'` → `nil`; with
  `"\0"` it returns the pristine root `0x292c23a9…`)
- Area: Lua helper (`src/cartesi/hash-tree.lua:45-68`)
- Problem: with empty data the leaf level is empty and the pairing loop never creates parents, so the function
  returns `nil` instead of the root of an all-zero tree.
- Scenario: a tool that checks an empty NVRAM/output region with
  `get_data_root_hash(data, log2) == proof.target_hash` fails on valid empty data. It rejects a valid value and
  never accepts an invalid one.
- Possible solution: `if #level == 0 then level[1] = pristine end` before the loop (or seed with one zero word).
- Severity: Low.
- Risks: none.

### Other observations (Low, not separately reported)
- With default `check_outputs_merkle_root:true`, any advance-state run that starts from a template whose outputs
  tree is not empty aborts at the first accept unless `outputs_frontier` or `last_output_proof` is supplied. The
  help for `--uarch-cycle-computation-hash` says "no epoch files are required" when starting from a later input
  (`begin_epoch:false,next_input_offset:k`), which leads users into this abort. The CLI aborts loudly, so no wrong
  value is produced. A note in the help, or skipping the check when no outputs history is supplied, would avoid it.
- A computation `frontier` file records only its height (24 + 48 − p − b), so resuming with a different
  (`log2_mcycle_period`, `log2_bundle_mcycle_count`) pair with the same sum is accepted silently. The help says to
  use the same values, but storing them in the file would let the CLI reject the mix.
- `hash_tree.roll_hash_up_tree`/`verify_slice` ignore `target_address` bits outside
  `[log2_target_size, log2_root_size)` and extra siblings. Every in-tree caller checks address, sizes and sibling
  count itself (`prt.lua` claim/seal validation, `game-output.lua`).
