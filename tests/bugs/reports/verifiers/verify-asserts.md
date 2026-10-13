# verify-asserts: independent verification of ASSERTS-1 and ASSERTS-2

Verifier: `verify-asserts`. Work dir: `<SCRATCH>/verify/verify-asserts/`
(`<SCRATCH>` = `<SCRATCH>`).
I tested against the repo's default build (`/home/user/machine-emulator/src`, relwithdebinfo). I also tested the
official upstream v0.22.0-test2 `.deb` binaries (`<SCRATCH>/sol/upstream`), a `release=yes` build
(`<SCRATCH>/work/step-proof/rel`, read-only use), and my own patched build (`fixbuild/`). For the on-chain side I
used a copy of machine-solidity-step PR #104 (`mss/`, forge 0.8.30).

| ID | Verdict | Hunter sev | My severity |
|---|---|---|---|
| ASSERTS-1 | CONFIRMED (independent repro on default, upstream and release builds; on-chain disagreement shown with forge) | High | **Medium**. It becomes High only for a verifier that takes the pre-state hash from an untrusted party. |
| ASSERTS-2 | CONFIRMED, with corrections. New trigger: a custom uarch image. The `release=yes` build hangs instead of only emitting an extra period. The claim that the `:2755` assert is reachable is REFUTED. | Medium | **Low** as a standalone item. It is a symptom of crafted-state-1 / verify-uarch-NEW-1 and should be merged there. |

---

### ASSERTS-1: uarch `require()` is a live `assert()`; a misaligned uarch fetch or access aborts the process (default and official builds) and diverges from Solidity in `release=yes` builds

- **Verdict: CONFIRMED.** I re-derived it from the code, re-ran the hunter's PoC and wrote an independent reproducer
  that uses a different trigger and a different log source. I also confirmed the on-chain disagreement with a forge
  test.

- **Root cause (my words):**
  - `src/uarch-solidity-compat.hpp:251-254`: `require(cond, msg)` is `assert((condition) && (message))`.
  - It is called only from `src/uarch-step.cpp:36-101`: `readUint64/32/16`, `writeUint64/32/16` and `copyBits`. The
    first call reached is the instruction fetch `readUint32(a, pc)` at `uarch-step.cpp:1101`.
  - `src/Makefile:212`: the default `relwithdebinfo` build adds `-DNDEBUG` only for `interpret.cpp`. `:215`: only
    `release=yes` disables all asserts.
  - The `Dockerfile` (`make` with default flags) and the official v0.22.0-test2 `libcartesi.so` /
    `cartesi-jsonrpc-machine` keep the assert. `strings` shows `misaligned readUint32 address`, and they abort under
    my reproducer.
  - Every other uarch failure (`illegal instruction`, `unsupported ecall function`, `ebreak`) uses
    `throwRuntimeError`, which is a `std::runtime_error` and maps to `CM_ERROR`. So `require` is the only check in
    the uarch step that kills the process.
  - The record and replay accessors were written to tolerate misaligned addresses. See `adjust_access` in
    `uarch-record-state-access.hpp:79` and `uarch-replay-state-access.hpp:135`: "so that even a buggy misaligned
    access can still be logged and verified instead of aborting". The abort contradicts that intent.

- **Reachability (my analysis):**
  - **Not reachable with a pristine uarch.**
    - The canonical uarch code is compiled C (rv64i), so JALR and branch targets are 4-aligned and its loads and
      stores are naturally aligned.
    - The big machine's 2-byte-aligned instruction fetch is done with halfword loads (`read_memory_word<uint32_t,
      uint16_t>`).
    - Misaligned big-machine data accesses trap in `interpret.cpp:977/1095`.
    - This matches the campaign's negative results: Linux boot, about 120 random programs and the collect sweeps all
      ran under the uarch without an abort.
  - **Path (a), non-pristine uarch state.** The trigger is a custom uarch RAM image (config
    `uarch.ram.backing_store.data_filename` / `--uarch-ram-image`), uarch registers in the config or a stored
    machine, or `cm_write_reg` / `cm_write_memory`. That reaches `cm_run_uarch`, `cm_log_step_uarch`,
    `cm_collect_uarch_cycle_root_hashes` and `cm_collect_uarch_cycle_bundle`. This is the same input class as
    crafted-state-1 / NEW-1 and uarch-1.
  - **Path (b), static `cm_verify_step_uarch(NULL, root_before, log)` and JSON-RPC `machine.verify_step_uarch`.**
    - The abort needs a `root_before` that commits to a misaligned uarch pc (or to registers or code that produce a
      misaligned access). Every access is Merkle-checked against `root_before`.
    - If the verifier uses a pre-state hash it trusts, such as its own state or the agreed state of a PRT leaf
      dispute, no crafted log can reach the `require`: execution is fully determined by the trusted state.
    - So (b) needs either a verifier that accepts both the hash and the log from the counterparty, or an agreed state
      that already derives from a non-pristine template (path (a)).
    - The JSON-RPC server also exposes `shutdown` (`jsonrpc-remote-machine.cpp:748`) to every client. A client that
      can send requests could already stop the server, so the extra risk is only a trusted client forwarding
      untrusted (hash, log) data.

- **Independent reproducer:** `<SCRATCH>/verify/verify-asserts/asserts1/run.sh` (exit 1 means the bug is present; it
  takes `LIBDIR=` to test another build).
  - **Different technique from the hunter.** No register poking: a 16-byte custom uarch RAM image, passed through
    the documented config key, executes `lui t0,0x600; jalr x0,10(t0)`. JALR clears only bit 0, so the uarch pc
    becomes 0x60000a, where the bytes `93 00 a0 02` (`addi x1,x0,42`) straddle two 32-bit slots.
  - **Verify log.** The log for the static verify is not spliced from proofs. It is the full step-3 log that the
    `release=yes` emulator itself recorded and accepted (`out/step3.*`, regenerated when the release lib is present).
  - Output against the default build (abridged):
    ```
    == release=yes build: log + verify the 3 uarch steps
    gen: step 1 uarch_pc=0x600000 log_step_uarch OK; verify_step_uarch: ACCEPTED (obtained == after); uarch_x1=0
    gen: step 2 uarch_pc=0x600004 log_step_uarch OK; verify_step_uarch: ACCEPTED (obtained == after); uarch_x1=0
    gen: step 3 uarch_pc=0x60000a log_step_uarch OK; verify_step_uarch: ACCEPTED (obtained == after); uarch_x1=42
    == tested build: /home/user/machine-emulator/src
    [run] cm_run_uarch ...                      repro_t: uarch-solidity-compat.hpp:253: ... Assertion `(condition) && (message)' failed.  -> exit 134
    [log] cm_log_step_uarch ...                 (same assertion)                                                     -> exit 134
    [collect] cm_collect_uarch_cycle_root_hashes (same assertion)                                                    -> exit 134
    [bundle] cm_collect_uarch_cycle_bundle      (same assertion)                                                     -> exit 134
    [verify] static cm_verify_step_uarch(NULL, root_before_step3, release-build log of step 3)  (same assertion)   -> exit 134
    [jsonrpc-verify] spawned cartesi-jsonrpc-machine ... (no machine loaded)
    cartesi-jsonrpc-machine: uarch-solidity-compat.hpp:253: ... Assertion ... failed.   server pid ... is gone      -> exit 134
    BUG REPRODUCED: ...
    ```
  - Official upstream v0.22.0-test2 binaries (`repro_upstream`): `verify`, `jsonrpc-verify` and `log` all abort the
    same way, exit 134.
  - Hunter's PoC (copied to `hunter/uarch-require/`) also reproduces: run, log, collect, verify and jsonrpc-verify
    all exit 134. Their `rel_release` / `rel_default` results also reproduce.

- **Verifier-path question: can a log accepted by a `release=yes` `cm_verify_step_uarch` be rejected by the Solidity
  step? YES. Shown on-chain.** `asserts1/sol/run_sol.sh` converts the three release-build logs to the PR #104 JSON
  layout and replays them in `UArchStep.step` (test `asserts1/sol/AssertsMisaligned.t.sol`, run in a light copy
  `verify-asserts/mss`):
  ```
  [PASS] testAlignedStepsAccepted()
    step 1 (aligned uarch pc) accepted on-chain, root hash matches emulator
    step 2 (aligned uarch pc) accepted on-chain, root hash matches emulator
  [PASS] testMisalignedStepRevertsOnChain()
    step 3 (uarch pc 0x60000a) REVERTED on-chain: misaligned readUint32 address
  BUG REPRODUCED: release-build cm_verify_step_uarch accepts a step that the on-chain UArchStep reverts
  ```
  - The same (root_before, log) pair therefore gets three verdicts:
    - release emulator: accepted (`obtained == after`, uarch_x1=42);
    - default and official emulator: SIGABRT;
    - Solidity: revert.
  - **The reverse (Solidity accepts, emulator rejects)** cannot happen through these checks. Solidity's `require`
    always reverts on exactly the conditions that the host either aborts on (default build) or ignores
    (`release=yes`), so the chain is never more permissive here. No invalid transition becomes provable on-chain.
    The risk is the opposite: a `release=yes` node can produce, for a non-canonical uarch state, a proof that the
    chain refuses.
  - **A second `release=yes`-only divergence inside the emulator** (`asserts1/ld/ld.c`; the default build aborts):
    for a misaligned uarch `ld` (`ld t1,3(t0)`), `cm_run_uarch` throws `attempted misaligned read from word`
    (`machine::read_word`, `machine.cpp:1912-1916`). `cm_log_step_uarch` + `cm_verify_step_uarch` instead accept
    the step, because record and replay align the address down (t1 = word at 0x600000). Solidity would revert. So
    in `release=yes`, run, log/verify and the chain give three different outcomes.
  - **Release-mode semantics.** `readUint32` computes the shift within the aligned 8-byte word. A pc ≡ 2 (mod 8)
    reads the 4 real bytes at pc. A pc ≡ 6 (mod 8) reads only 16 bits and zero-extends them. Both are
    deterministic across host paths.

- **Severity: Medium (downgraded from High).**
  - No memory corruption, and the default build never accepts an invalid transition. The defect is a fail-stop abort
    instead of an error, plus a disagreement with the chain that exists only in non-default `release=yes` builds.
  - Path (a) needs a non-pristine uarch in the machine. That input class is already rated High as NEW-1, and its
    worst case is uarch-1's memory corruption. Here it only adds the abort, and only until the first uarch reset:
    on-chain `UArchReset` restores the pristine uarch every mcycle.
  - Path (b) needs a verifier that trusts a counterparty's pre-state hash. Normal PRT practice is the opposite: the
    chain is the arbiter, and nodes check proofs against their own hashes.
  - It would be **High** for a deployment that offers log verification for (hash, log) pairs both supplied by
    untrusted parties (a shared verification service, or a JSON-RPC verifier fed with untrusted data). There one
    request kills the process for all its users.

- **Risks if unfixed:**
  - DoS of any process or JSON-RPC server that verifies untrusted (hash, log) pairs.
  - Honest default-build nodes crash, rather than get an error, on a template with a non-canonical uarch. They
    cannot compute uarch commitments or proofs, so they lose by timeout in that scenario.
  - Release-built tooling disagrees with the chain, and run disagrees with log.

- **Relationship to other findings:**
  - **uarch-4 (REJECTED): its premise was wrong.** It assumed "require()/assert is compiled out under -DNDEBUG", which
    holds only for `release=yes`. The default, Docker and official builds keep the assert, and they abort. The
    "misaligned pc is handled / deterministic" conclusion should be revised.
  - **verify-uarch** folded uarch-4's pc angle into NEW-1. It saw only the aligned out-of-range case (`pc=0x600008`
    throws a sentinel error) and not the misaligned abort.
  - **crafted-state-1 / NEW-1:** same input class for path (a). NEW-1's proposed entry check ("uarch subtree ==
    pristine hash" in run/log/collect) would block path (a), but **not** path (b): the static verify has no machine
    to check. ASSERTS-1 therefore needs its own fix.

- **Fix assessment: VALIDATED.**
  - Patch (`verify-asserts/fix.patch`): `require` becomes `if (!(condition)) throw std::runtime_error(message);`. The
    header is host-only: `throwRuntimeError` there already throws, and the uarch RAM image does not compile
    `uarch-step.cpp`.
  - I built it in a private copy (`verify-asserts/fixbuild/src/libcartesi.so`). The affected translation units
    (`uarch-step.cpp`, `machine.cpp`, `uarch-reset-state.cpp`, `send-cmio-response.cpp`) were rebuilt with the
    default flags, so asserts are live.
  - Results: `LIBDIR=.../fixbuild/src bash asserts1/run.sh` gives `[run|log|collect|bundle|verify] returned -6:
    misaligned readUint32 address`, then `OK`, exit 0.
  - Regression: 2000 pristine uarch steps logged, verified and reset (`fixcheck/eq.c`) give the same root hash
    (`5bccdd24…`) with the default and the fixed lib.
  - The fix changes no root hash and no on-chain artefact. The transpiler maps `require` to Solidity's `require`
    whatever its C++ body is. It makes the host reject exactly when the chain reverts, in every build type.
  - No partial-state concern within a step: every `require` fires before the step's first write.
  - Complementary: NEW-1's pristine-uarch entry check.

---

### ASSERTS-2: `assert(mcycle_reached == mcycle_target)` in `collect_uarch_cycle_root_hashes` aborts on a uarch that halts without advancing mcycle

- **Verdict: CONFIRMED, with three corrections:**
  1. **There is a second trigger that the hunter's main fix misses.** A custom uarch image `addi a7,x0,1; ecall` starts
     with `uarch_halt = 0`, halts itself after two uarch cycles without executing any big-machine instruction, and
     aborts at `:2807`. The suggested precondition "require `uarch_halt == 0`" does not catch it. Replacing the
     assert with a throw, or checking that the uarch is pristine, does.
  2. **The `release=yes` behaviour is worse than described.**
     - With `uarch.processor.registers.halt=1` it does emit an extra no-op period (`mcycle_hash_offsets [0,2,702]` for
       `mcycle_end = mcycle+1`).
     - With the custom-image trigger the collect **never returns**. The partial uarch reset in collect only restores
       dirty uarch words, so the custom code survives (the HT-7 interplay) and halts again on every iteration. RSS
       grew by about 0.5 MB/s (67 MB to 71 MB in 8 s) until I killed it.
  3. **The `machine.cpp:2755` side claim is REFUTED.** The hunter said `assert(uarch_cycle_reached ==
     uarch_cycle_target)` is reachable when uarch code stores to its own `uarch_cycle` word. In fact `uarch_step`
     reads `cycle` first and writes `cycle + 1` after the instruction (`uarch-step.cpp:1091-1104`), overwriting the
     store. My `cycle-store` variant (`sd t1,8(t0)` to 0x400008, then halt) aborts at `:2807`, not at `:2755`.

- **Root cause (my words):**
  - `machine.cpp:2648-2700` checks only Keccak, `uarch_cycle == 0` and the revert-tail preconditions.
  - The loop at `:2716-2810` assumes that one uarch run to halt advances mcycle by exactly one. That holds only for
    the pristine uarch.
  - If the uarch is already halted, or halts without executing a big-machine instruction, the loop resets it and
    `mcycle_reached` is still `mcycle_start`. The sanity assert then fires: abort in the default build. In
    `release=yes` the loop continues into a bogus period or loops forever.
  - `cm_collect_uarch_cycle_bundle` calls the same function.

- **Independent reproducer:** `<SCRATCH>/verify/verify-asserts/asserts2/run.sh` (C API; triggers set through the JSON
  config and a uarch RAM image file, not `write_reg`; pristine control included):
  ```
  [pristine/root]  OK; mcycle now 1; "mcycle_hash_offsets":[0,700]                          -> exit 0
  [halt-config/root|bundle]  machine.cpp:2807: ... Assertion `mcycle_reached == mcycle_target' failed.  -> exit 134
  [halt-image/root|bundle]   machine.cpp:2807: ... Assertion `mcycle_reached == mcycle_target' failed.  -> exit 134
  BUG REPRODUCED
  ```
  - Release lib (`repro_release`): `halt-config` gives `[0,2,702]`. `halt-image` and `cycle-store` time out after
    60 s (exit 124).
  - Hunter's PoC (`hunter/collect-uarch/run.sh`) reproduces: root and bundle exit 134.

- **Severity: Low as a separate item. Merge it into crafted-state-1 / verify-uarch-NEW-1.**
  - It is reachable only with a non-pristine uarch in the template or snapshot, which is exactly NEW-1's input class
    (High, with a Critical ceiling).
  - The default-build outcome is fail-stop. The end-to-end harm (an honest defender cannot compute uarch-level
    commitments, and the uarch level disagrees with `cm_run` and the mcycle level) is NEW-1's.
  - Its separate contributions are two failure modes that should be listed under NEW-1: a process abort (default and
    official builds) and an unbounded hang (`release=yes`).

- **Fix assessment: VALIDATED for the abort and the hang.**
  - Patch (same `fix.patch`): `:2807` becomes `if (mcycle_reached != mcycle_target) throw
    std::runtime_error{"uarch did not advance exactly one mcycle"};`.
  - With the fixed lib, all four non-pristine cases return `uarch did not advance exactly one mcycle` (exit 0) and
    the pristine control is unchanged.
  - Limitation: the throw happens after the uarch ran and was partly reset, so the machine is left modified. The
    proper fix is NEW-1's entry check (uarch subtree hash == pristine, before anything runs). The throw is still
    worth keeping as the last line of defence, since it is what stops the `release=yes` infinite loop.
  - No root-hash or on-chain change.

---

## Files
- Reproducers (one command, exit 1 when the bug is present):
  - `<SCRATCH>/verify/verify-asserts/asserts1/run.sh` (ASSERTS-1, default build + JSON-RPC).
  - `asserts1/sol/run_sol.sh` (release emulator vs on-chain `UArchStep`).
  - `asserts2/run.sh` (ASSERTS-2).
- Extra: `asserts1/ld/ld.c` (release: run vs log divergence on a misaligned `ld`).
- Fix: `verify-asserts/fix.patch`. Patched lib: `verify-asserts/fixbuild/src/libcartesi.so`, used via
  `LIBDIR=<that dir> bash asserts{1,2}/run.sh`, which gives exit 0.
- Regression check: `fixcheck/eq.c`.
- Copies of the hunter's PoCs: `verify-asserts/hunter/`.
