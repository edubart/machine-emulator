# Verification report: verify-step

Verifier: `verify-step`. Work dir: `<SCRATCH>/verify/verify-step/` (`<SCRATCH>` =
`<SCRATCH>`).
Tree: `/home/user/machine-emulator` @ 8236e69 (v0.22.0 branch), default build in `src/` (relwithdebinfo).

Fix validation: I built a private copy of `src/` with the default flags (relwithdebinfo, so asserts stay on outside
`interpret.cpp`) plus the patch `<SCRATCH>/verify/verify-step/fix.patch`, which covers STEP-PROOF-1/5 and ROLLUP-FLOW-1.
The resulting libraries are kept in `<SCRATCH>/verify/verify-step/fixlib/` (`cartesi.so` for Lua, `libcartesi.so` for C).
Every `run.sh` below takes that directory as its first argument, so you can rerun it against the fixed build.

| ID | Verdict | Severity (mine) |
|----|---------|-----------------|
| STEP-PROOF-1 (= HT-11) | CONFIRMED | High (Critical where disputes are settled with `cm_log_step`/ZK) |
| STEP-PROOF-5 (= HT-10) | CONFIRMED (a separate defect from STEP-PROOF-1, same theme) | Medium |
| ROLLUP-FLOW-1 | CONFIRMED | Critical for the step-log/ZK verification path (High if that path is considered not deployed) |
| STEP-PROOF-3 | CONFIRMED | Low |
| STEP-PROOF-4 | CONFIRMED | Low |
| R-1 (revert hash not checked by log/verify_send_cmio_response) | Not a defect (documented). At most an optional Low hardening for `log_send_cmio_response` only | Low / do not report as a vulnerability |

---

### STEP-PROOF-1 (and HT-11): `cm_log_step` / `cm_get_node_hash` abort on hash-tree nodes in the power-of-two padding of a non-power-of-two memory range
- Verdict: **CONFIRMED.** HT-11 is a duplicate: same assertion, same line. HT-11 hits it with a word-sized node, STEP-PROOF-1 with page-sized and larger nodes.
- Hunter PoCs, re-run from copies in `verify-step/hunter/` against the default build:
  - `run.sh` prints `RAM length 0x5000 ... log_step FAILED / child killed by signal 6` and `BUG REPRODUCED`.
  - `run-linux1.sh` (Linux boot, `cm_log_step(1)` at mcycle 31464660) prints `Assertion ... failed` and `BUG REPRODUCED ... (signal 6)`.
  - `jsonrpc-crash.lua`: the `cartesi-jsonrpc-machine` server dies on `get_node_hash(0x80005000,12)` (`Connection refused` afterwards).
  - Against the hunter's NDEBUG build (`work/step-proof/rel/src`), `poc1` prints `log_step OK` for both cases and
    `cm_get_node_hash on padding node: OK`.
- Independent reproducer: `<SCRATCH>/verify/verify-step/sp1/run.sh [libdir] [--linux]`. It uses Lua and a different
  access pattern from the hunter's PoC. The machine has 64 KiB of RAM and a **3-page flash drive** at 0x90000000.
  The guest runs `lui/slli/lui/add`, then the logged mcycle is a single **`ld` from the drive's last page**.
  Controls: a power-of-two drive, a load from page 0 of the 3-page drive, the **uarch path on the same mcycle**
  (1482 `log_step_uarch`+`verify_step_uarch` plus `log/verify_reset_uarch`), and `get_proof` of the padding page.
  ```
  control: flash 0x4000 (pow2), ld from page 2, log_step(1)      exit   0
  control: flash 0x3000, ld from page 0, log_step(1)             exit   0
  uarch path, flash 0x3000, ld from page 2 (same mcycle)         exit   0
    uarch: 1482 logged+verified uarch steps + reset: b2bc7f966179ec6a, cm_run b2bc7f966179ec6a
  get_proof(padding page 0x90003000, 12)                         exit   0
  BUG? flash 0x3000, ld from page 2 (last page), log_step(1)     exit 134
  lua5.4: hash-tree.cpp:567: ... get_dense_node_hash(...): Assertion `ar.contains_absolute(address, HASH_TREE_WORD_SIZE) && "addr...
  BUG? get_node_hash(padding page 0x90003000, 12)                exit 134
  BUG? Linux boot (rootfs 0x15dd1000 bytes), log_step(1) @31464660 exit 134      (with --linux)
  BUG REPRODUCED: cm_log_step/cm_get_node_hash abort on hash-tree nodes in the power-of-two padding ...
  ```
  With the fixed build (`./run.sh <SCRATCH>/verify/verify-step/fixlib --linux`):
  `log_step(1) ok: after=b2bc7f966179ec6a verify=b2bc7f966179ec6a cm_run=b2bc7f966179ec6a` (equal to the uarch result
  of the unfixed build), `get_node_hash = 292c23a9aa1d8bea` (equal to the `get_proof` target, i.e. the dense-tree value),
  `log_step(1) at mcycle 31464660: OK, verify_step 0xa2c4019c96a0d6aa == root 0xa2c4019c96a0d6aa`, `OK: not reproduced`.
  - CLI user path, same abort: `cartesi-machine.lua --ram-image=linux.bin --flash-drive=label:root,data_filename:rootfs.ext2
    --max-mcycle=31464660 --log-step=<file>,count:1 -- "echo hello; ls /"` prints
    `lua5.4: hash-tree.cpp:567: ... Assertion ... failed`, exit 134 (`sp1/cli.out`).
  - uarch path on the **same Linux mcycle** with the default (assert-enabled) build: 1721 `log_step_uarch`+`verify_step_uarch`
    and `log/verify_reset_uarch` give `0xa2c4019c96a0d6aa`, which equals `cm_run` and the fixed `log_step(1)`.
    So `cm_log_step_uarch` does **not** abort (`sp1/linux.lua <cfg> <dir> uarch`; it takes about 12 min on the loaded host).
- Root cause:
  - Each address range has a dense tree over `bit_ceil(page_count)` pages (`address-range.hpp:334-340`,
    `dense-hash-tree.hpp` allocates `1<<level_count` nodes).
  - The padding leaves are deliberately marked dirty at creation (`dirty-page-tree.hpp:113`).
  - `update_dirty_pages` then writes the pristine page hash for every `offset >= length` (`hash-tree.cpp:390-393`), and
    the dense update propagates it, so padding nodes at page level and above hold correct pristine hashes.
  - `record_step_state_access::get_sibling_hashes_impl` (`record-step-state-access.hpp:198-212`, called from `finish` in
    `machine::log_step`) asks `get_node_hash` for every maximal untouched subtree. It only asks for nodes at page size
    or larger. When a touched page is in the last, partially filled power-of-two block of a range, one of these
    siblings starts at or past the range end.
  - `hash_tree::get_node_hash` (`hash-tree.cpp:588-625`) passes any node inside the AR's span to `get_dense_node_hash`,
    whose first statement `assert(ar.contains_absolute(address, HASH_TREE_WORD_SIZE))` (`hash-tree.cpp:567`) rejects
    the node and fires.
  - `get_proof` → `get_dense_proof` reads the dense tree without this assert, which is why `get_proof` and
    `log_step_uarch` work.
  - The default build (`src/Makefile:200-212`, top `Makefile:130-134`) is relwithdebinfo. It defines `NDEBUG` only for
    `interpret.cpp`, and `libcartesi.so` contains the assert string. The Docker/Debian packaging (`Dockerfile:56-64`,
    `DEBUG=no`, so relwithdebinfo by default) and the CI non-tag builds (`DEBUG=yes`) both keep the assert.
  - For the rootfs at 0xA0000000 (length 0x15DD1000, span 2^29), any step touching a page in [0xB0000000, 0xB5DD1000)
    asks for the sibling (0xB8000000, 2^27) and aborts. That is about 94 MiB, or 27% of the drive.
- Is the assert wrong, or does it guard a real inconsistency? Both:
  - For page-level and larger nodes, which are all `log_step` ever asks for, the assert is wrong. NDEBUG returns the
    dense-tree value, which is the pristine hash. The log verifies, and the fixed build's log matches the uarch and `cm_run` (above).
  - For sub-page nodes (only reachable via `cm_get_node_hash`), the assert happens to mask a real defect. The sub-page
    branch would return stale page-cache data (STEP-PROOF-5; the hunter's `pad2-rel` on NDEBUG prints
    `WRONG (stale hash from an evicted page)`).
  - So the fix must not just delete the assert. It must return pristine hashes for nodes that start past the range end.
- Severity: **High.**
  - With the packaged/default build, an honest party cannot produce a big-step log (the `cm_log_step` → risc0 prover
    path, also the CLI `--log-step` and JSON-RPC `log_step`). The trigger is a common configuration (flash drives are
    rarely a power of two) and a large fraction of steps that touch the drive tail. A client can also kill a JSON-RPC
    server with `get_node_hash`, but that server's clients are normally trusted.
  - It is not Critical for the PRT flow documented in this repo, because `doc/recipes/prt.lua` settles the bottom
    level with uarch steps, which are unaffected, and an operator can avoid the abort with a `release=yes` build.
  - It becomes Critical in a deployment whose disputes are settled with `cm_log_step`/ZK. There the adversary picks the
    divergent leaf and the honest prover aborts.
- Fix assessment: the hunter's proposal (return `m_pristine_hashes[log2_size]` when the node starts at or past `ar.get_end()`) is correct and complete for this item. I validated an equivalent version (`fix.patch`, `get_dense_node_hash`):
  - It fixes `log_step` and `get_node_hash` for both page-level and word-level padding nodes.
  - It does not change any root hash or proof, because NDEBUG builds already returned the same values.
  - It needs no on-chain or risc0 change: the replay never asks for these hashes.
  - Suggested regression test: `log_step` on a machine with a non-power-of-two drive touching its last page. `sp1.lua` is a ready-made one.

### STEP-PROOF-5 (and HT-10): word-level `get_proof` / `get_node_hash` in the padding of a range return stale hashes
- Verdict: **CONFIRMED.** HT-10 is a duplicate.
- Hunter PoC: `hunter/run-pad3.sh` (default build) prints `target_hash 0BTT7etA...` against the expected pristine
  `KQ3s2VSL...`, then `BUG REPRODUCED`. `hunter/pad2.c` linked against the NDEBUG build prints `node hash of padding word 0x82002000: WRONG (stale hash from an evicted page)`.
- Independent reproducer: `<SCRATCH>/verify/verify-step/sp5/run.sh [libdir]`. It uses Lua with a 3-page flash drive and
  `phtc_size=4`. All RAM and drive pages are dirtied, then word proofs are taken to fill the cache. The script asks for
  `get_proof(0x90003040, 5)`, recomputes the root with `cartesi.keccak256`, and checks the procedure on a real RAM word.
  Default build:
  ```
  get_proof(0x90003040, 5): target 0x4530df819e806363 (pristine word 0x290decd9548b62a8), recomputed root 0x57fde0fa2b208c72, machine root 0x9e87b2205d96f18b
  lua5.4: hash-tree.cpp:567: ... Assertion ... failed     (get_node_hash on the same word)
  BUG REPRODUCED: cm_get_proof returns a stale (wrong) word proof for an address in the padding of a memory range
  ```
  The fixed build gives the pristine target, the recomputed root equals the machine root, `get_node_hash = 0x290decd9...`
  (pristine), and `OK: not reproduced`.
- Root cause:
  - `get_page_proof` (`hash-tree.cpp:101-124`) and the sub-page branch of `get_dense_node_hash` (`hash-tree.cpp:568-580`)
    borrow a page-cache entry for a page outside the range.
  - On a miss, `borrow_entry` hands out an evicted LRU entry.
  - `update_dirty_page` returns `false` without filling it because the page is not contained (`hash-tree.cpp:229-233`),
    and the return value is ignored. The proof or node is then built from another page's hashes.
- One bug or two? **Two distinct defects with a common theme**: padding nodes are handled inconsistently by the query paths.
  - STEP-PROOF-1 is an over-strict assert. It blocks a correct path (page level and above) that `log_step` needs.
  - STEP-PROOF-5 is a wrong-data path (below page level). It is reachable via `get_proof` in every build, and via
    `get_node_hash` once the assert is gone or under NDEBUG.
  - They have different call sites and impacts, so report them as two cross-referenced items, or as one issue with two
    parts. Removing only the assert would turn the HT-11 abort into a silent STEP-PROOF-5 wrong answer, so both fixes should land together.
- Severity: **Medium.** By the guide's wording this is "wrong proofs returned by the API" (High), but the realistic impact is limited:
  - The address lies outside every range the guest can access.
  - No protocol flow (step logs, uarch logs, outputs proofs) asks for padding words.
  - The returned proof fails verification, so it cannot be accepted. It is a detectable wrong answer, not a soundness issue.
- Fix assessment:
  - The hunter's suggestion (fill padding word proofs and nodes from `m_pristine_hashes`, never use the cache for
    pages outside the range) is correct. I validated it in `get_page_proof` (`fix.patch`), together with the
    STEP-PROOF-1 early return, which covers `get_node_hash`.
  - Also checking the ignored `false` return of `update_dirty_page` (throw instead of using the entry) would be good defensive hygiene.
  - No hash or compatibility change.

### ROLLUP-FLOW-1: `log_step(N)`/`verify_step(N)` (and the risc0 replay) stop at the first automatic yield, while the logged count and the verified transition claim N mcycles
- Verdict: **CONFIRMED.**
- Hunter PoCs, re-run from copies in `verify-step/hunter-rf/`:
  - `poc-c guest.bin`: `cm_run 803dac05...`, `uarch 803dac05...`, `log_step/verify_step(64) fdb84a39...`,
    `break reason 3, machine at boundary+57`, `BUG REPRODUCED`.
  - `poc-logstep-autoyield.lua`: the same, plus `collect_mcycle_root_hashes`, `collect_mcycle_bundle`, and the chained
    57+7 logs, all equal to `803dac05...`.
  - `-sha256.lua`: `BUG REPRODUCED (sha256 machine)`.
- Independent reproducer: `<SCRATCH>/verify/verify-step/rf1/run.sh [libdir]`.
  - C API. The guest is a minimal bare-metal loop, with no CMIO protocol and no input delivery. One event happens
    strictly inside a 64-mcycle window, then a store loop runs.
  - Five paths are compared: `cm_run` resumed after non-fixed-point breaks, 64 × `run_uarch`+`reset_uarch`,
    `cm_collect_mcycle_bundle(period 2^6)`, **64 chained `cm_log_step(1)`+`cm_verify_step`**, and one
    `cm_log_step(64)`+`cm_verify_step(64)`.
  - The script also answers "which other non-fixed-point breaks matter" by testing console output (`to_buffer`,
    `every_char`) and soft yield (runtime `soft_yield=true`).
  ```
  event: automatic yield
      cm_run resumed to mcycle 64        30e0313e4792078c  (first cm_run break: YIELDED_AUTOMATICALLY at mcycle 37)
      uarch (64 x run_uarch+reset_uarch) 30e0313e4792078c
      collect_mcycle_bundle(period 64)   == cm_run
      64 x log_step(1)+verify_step(1)    30e0313e4792078c
      log_step(64)+verify_step(64)       36978142990863ff  (log_step break: YIELDED_AUTOMATICALLY, machine at mcycle 37)
      => single 64-cycle step log DIVERGES from the other paths
  event: console putchar (to_buffer, every_char)
      cm_run ... (first cm_run break: CONSOLE_OUTPUT at mcycle 39) ... log_step(64) ... REACHED_TARGET_MCYCLE, mcycle 64
      => single 64-cycle step log AGREES with the other paths
  event: soft yield (soft_yield=true)
      cm_run ... (first cm_run break: YIELDED_SOFTLY at mcycle 38) ... log_step(64) ... REACHED_TARGET_MCYCLE, mcycle 64
      => single 64-cycle step log AGREES with the other paths
  BUG REPRODUCED: cm_verify_step accepts a 64-mcycle step log whose final root hash is the state at the automatic yield ...
  ```
  (The "no event" case agrees too.) With the fixed build, `log_step(64)+verify_step(64) 30e0313e4792078c (... REACHED_TARGET_MCYCLE, machine at mcycle 64)` is printed, followed by `OK: all paths agree`, exit 0.
- Root cause:
  - `machine::log_step` (`machine.cpp:2171-2190`), `machine::verify_step` (`machine.cpp:2192-2210`) and
    `risc0_replay_steps` (`risc0/cpp/risc0-replay-steps.cpp:38-40`) each call `interpret()` once.
  - `interpret()` returns `yielded_automatically` as soon as `iflags.X` is set (`interpret.cpp:6398-6399`), which
    happens on the loop's `success_and_yield` exit.
  - The log header still carries `mcycle_count = N`, and `verify_step` / the risc0 journal return or commit the hash
    of the state at the yield. That state contains `mcycle = start+k` with k < N, and X=1.
  - Every other path treats the automatic yield as a non-fixed point and continues: `collect_mcycle_root_hashes` loops
    until the target (`machine.cpp:2373`), `collect_mcycle_bundle` documents "Execution continues through automatic
    yields" (`machine.hpp:281`, `cm.h:905`), and the uarch performs one mcycle per big step, with `interpret` clearing X
    at the next mcycle. That is why 64 chained 1-cycle logs agree.
- Other non-fixed-point break reasons:
  - **Only the automatic yield is affected.** The record and replay step accessors are not interactive. Their `putchar`
    returns `false` (`record-step-state-access.hpp:357`, `replay-step-state-access.hpp:598`), so console output never
    breaks the loop.
  - The soft-yield hint is only honoured for `is_an_i_interactive_state_access_v` accessors (`interpret.cpp:3286`).
  - Console input (`getchar`) only refills under interactive access, and needs an unreproducible machine anyway.
  - Halt, manual yield and mcycle overflow are fixed points, and every path stops at them.
  - All of this is confirmed empirically above.
- Intent and documentation: I found nothing saying `log_step`/`verify_step` stop at automatic yields.
  - `cm.h:1040-1050` says `cm_log_step` "Runs the machine for the given mcycle count". `cm.h:1095-1101` says that
    `mcycle_count` of `cm_verify_step` is the "Number of mcycles in the step".
  - The early return on automatic yields is documented only for `machine:run` (`doc/README.md:4162-4167`).
  - No test asserts the behaviour. `tests/lua/machine-bind.lua:2124-2160` only checks a yield-free 10-cycle step.
  - CHANGELOG 0.20 introduced log/verify_step "to log multiple machine cycles and verify with ZK VMs" and the risc0
    "fraud proof verification".
  - The cm_log_step break reason (`CM_BREAK_REASON_YIELDED_AUTOMATICALLY`, with the machine left at start+k) lets an
    honest caller detect the early stop. It gives no way to produce a valid N-cycle log, though. On the verifier side
    nothing reveals it: "Removed the break reason output of `cm_verify_step`" (`CHANGELOG.md:140`), the log header and
    the risc0 journal hold only `(root_hash_before, N, root_hash_after)`, and `CartesiStepVerifier.verifyStep` documents
    `mcycleCount` as the "Expected number of machine cycles executed".
- Who uses N-cycle step logs:
  - The risc0 guest and `cartesi-risc0-cli prove` consume `cm_log_step` / `--log-step` logs. The fixtures
    (`tests/lua/create-step-logs.lua`) use up to 1000-cycle steps.
  - `CartesiStepVerifier.sol` is the on-chain verifier.
  - `doc/README.md:349` and `3370-3372` describe ZK proofs of batches, and sha256 machines can only use this path,
    because they cannot use the uarch.
  - In-repo PRT recipes (`doc/recipes/prt.lua`, `prtu.lua`) use uarch steps at the bottom level and do not call `log_step`.
- Severity: **Critical**, with a deployment caveat.
  - This is a divergence between implementations that must agree: the step-log/ZK/on-chain verifier against the uarch
    and the mcycle computation hash (`collect_*`).
  - It lets an invalid transition be proved, `S_j --N--> S_yield`, where S_yield has `mcycle = j+k`, from an unmodified
    emulator. The honest transition `S_j --N--> S_{j+N}` cannot be proved at all.
  - It triggers on every output, report or progress yield inside a batch, i.e. essentially every rollup input, with no
    special template.
  - If the coordinator treats the ZK/step-log dispute path as not yet deployed, it is High. It is clearly more severe
    than COORD-1/STEP-PROOF-2, which needs counts that overflow.
- Fix assessment:
  - The hunter's fix (loop `interpret` while it returns `yielded_automatically`, identically in `log_step`,
    `verify_step` and `risc0_replay_steps`) is correct. I validated it for `log_step`/`verify_step` (`fix.patch`).
  - `log_step`'s internal re-verification passes, and the result equals `cm_run`, the uarch, `collect_mcycle_bundle`
    and the 1-cycle chain. There are no root-hash changes.
  - The risc0 guest must get the same loop. That changes the image ID, so `CartesiStepVerifier`'s ImageID must be
    updated. I did not build it (it needs Docker/risc0).
  - Existing logs that stop at an automatic yield with N > k would stop verifying. That is the intended outcome.
  - Alternative: loop "until fixed point or `mcycle >= mcycle_end`", which also protects against any future
    non-interactive break reason. Consider sharing one helper between `log_step`, `verify_step` and the risc0 entry
    point (the same advice as for COORD-1).
  - Add a regression test with a yield inside a multi-cycle step (`rf1.c` can serve).

### STEP-PROOF-3: access-log proofs with more than 64 levels cause a shift-by-64 UB
- Verdict: **CONFIRMED** (UB without soundness impact).
- Hunter PoC: `hunter-cmio/run-ubsib.sh` (ASan build) prints `hash-tree-proof.hpp:190:79: runtime error: shift exponent 64 is too large` and `BUG REPRODUCED`.
- Independent reproducer: `<SCRATCH>/verify/verify-step/sp3/run.sh`. It uses the Lua ASan/UBSan module and a different
  entry point: a **uarch step log** (`log_step_uarch`) with one extra sibling appended to the first access, then
  `verify_step_uarch`. It prints `hash-tree-proof.hpp:190:79: runtime error: shift exponent 64 is too large for 64-bit type` and `BUG REPRODUCED`.
  With the default (non-sanitized) build, the same log is
  `rejected: siblings and read hash do not match root hash before 1st access to uarch.cycle`, so it is sound.
- Root cause: `access::make_proof` (`access-log.hpp:175-200`) derives `log2_root_size = proof_log2_size + siblings.size()`
  from untrusted JSON with no bound, and `hash_tree_proof::bubble_up` (`hash-tree-proof.hpp:188-190`) computes `1 << log2_size` for `log2_size >= 64`.
- Severity: **Low.** UB reachable from untrusted logs. A sanitizer build aborts. Release x86 masks the shift and
  rejects the proof, since accepting it would need a 32/64-byte preimage collision.
- Fix assessment: every caller (`replay-send-cmio-state-access.hpp:168/261/341`, `uarch-replay-state-access.hpp:183`)
  proves against the 64-bit machine root. So requiring `sibling_hashes.size() == HASH_TREE_LOG2_ROOT_SIZE - proof_log2_size`
  in `make_proof`, and `log2_root_size <= 64` in the `hash_tree_proof` constructor, is correct and has no side effects.

### STEP-PROOF-4: `cm_send_cmio_response` / `cm_log_send_cmio_response` with `data == NULL, length > 0` fail but leave the machine modified
- Verdict: **CONFIRMED.**
- Hunter PoC: `hunter-cmio/run-nulldata.sh` prints `error -6 (data is null)`, `root hash changed: YES`, `BUG REPRODUCED`.
- Independent reproducer: `<SCRATCH>/verify/verify-step/sp4/run.sh`. There is no guest code: the rx-accepted yield is
  set directly in the config (`iflags.Y=1`, `htif.tohost`). Both the plain and the logged variant are tested:
  ```
  cm_send_cmio_response(data=NULL, length=8): error -6 (data is null)
    root hash changed: YES, imcyclemax = 0xffffffffffff, iflags.Y = 1
  cm_log_send_cmio_response(data=NULL, length=8): error -1 (data is null)
    root hash changed: YES, imcyclemax = 0xffffffffffff, iflags.Y = 1
  BUG REPRODUCED: a failed cmio response call left the machine partially modified
  ```
- Root cause: `send-cmio-response.cpp:71-76` writes `imcyclemax` and the revert root hash before
  `writeMemoryWithPadding`. That function throws on `data == nullptr` (`state-access.hpp:450-452`, and likewise in the
  record accessor). `cm.cpp:1325-1336`/`1338+` never validate the pointer, which contradicts the `cm.h` statement
  "validation errors leave the machine unchanged".
- Severity: **Low.** It needs C API misuse. The Lua and JSON-RPC bindings always pass a non-null buffer, and a later
  correct response overwrites both fields.
- Fix assessment: validating `data != nullptr || length == 0` in the three `cm_*_cmio_response` wrappers (or in
  `machine::send_cmio_response`/`log_send_cmio_response` before the transition) is correct and has no side effects.

### R-1 (opinion requested): `log_send_cmio_response` / `verify_send_cmio_response` do not check `revert_root_hash == root_hash_before`
- Facts re-checked (`r1/r1.lua`):
  - `send_cmio_response` refuses (`revert root hash does not match the machine root hash`, `machine.cpp:1970-1986`).
  - `log_send_cmio_response` with a wrong revert hash is accepted **and applied**: the machine's shadow revert hash at
    0xfe0 becomes the wrong value.
  - `verify_send_cmio_response` accepts that log when given the same wrong hash, and rejects it when given
    `root_hash_before`, as the reference referee in `doc/recipes/prt.lua` does.
  - `cm.h:1077` documents "Unlike cm_send_cmio_response, it is not checked against the machine root hash".
- Opinion: **do not report it as a defect or vulnerability.** It is documented API design.
  `verify_send_cmio_response` mirrors the on-chain step verifier, where the dispute contract supplies the revert hash.
  Adding a check only to the C++ verifier would make it stricter than its on-chain twin, and it would not protect
  on-chain deployments anyway. The safe usage, passing `root_hash_before`, is what the reference referee does.
- If anything, file one **optional Low hardening item for the prover side**: `log_send_cmio_response` should apply the
  same `check_cmio_response_revert_root_hash` as `send_cmio_response`.
  - It mutates the node's own machine, so a caller bug silently plants a wrong revert hash.
  - Every later rejection would then make that node's `collect_*`, `log_step` and uarch hashes "revert" to the wrong
    root, and the node would lose its own dispute. That is self-inflicted and needs a caller bug.
  - The check is cheap, aligns the two APIs, and changes no hash for correct callers.

---

Files: `<SCRATCH>/verify/verify-step/{sp1,sp3,sp4,sp5,rf1,r1}/`, `fix.patch`, `fixlib/` (fixed default-flag build
libs), and `hunter*/` (copies of the hunter PoCs as re-run, with temporary-file paths moved into my dir).
