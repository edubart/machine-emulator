# Findings: step-proof (big-machine step log / CMIO response proofs)

Auditor angle: `step-proof`. Work dir: `<SCRATCH>/work/step-proof/` (`<SCRATCH>` = `<SCRATCH>`).

Scope reviewed: `machine.cpp` (log_step, verify_step, send/log/verify_send_cmio_response),
`record-step-state-access.hpp`, `replay-step-state-access.hpp`, `record-send-cmio-state-access.hpp`,
`replay-send-cmio-state-access.hpp`, `send-cmio-response.cpp`, `access-log.hpp`, `hash-tree-proof.hpp`,
`cm.cpp` wrappers, `json-util.cpp` (access-log parsing), plus the consumers `interpret.cpp` (TLB/fetch/PMA paths),
`hash-tree.cpp` (sibling hashes used by log_step), `mock-address-range.hpp`, `shadow-tlb.hpp`, and the ZK consumer
of the step-log format `risc0/cpp/risc0-replay-steps.cpp`.

Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| STEP-PROOF-1 | `cm_log_step` (and `cm_get_node_hash`) abort the process when a step touches the tail of a memory range whose length is not a power of two (assert in `hash_tree::get_dense_node_hash`) | PROVEN | High |
| STEP-PROOF-2 | ZK (risc0) replay computes `mcycle_end` with a wrapping add, C++ `verify_step`/`log_step` saturate: the two verifiers of the same step log disagree; the ZK guest accepts a forged "no-op" transition | PROVEN (host build of the guest entry point) | Medium |
| STEP-PROOF-3 | Untrusted access logs with more than 64 proof levels trigger UB (`1 << 64`) in `hash_tree_proof::bubble_up` (verify_send_cmio_response, verify_step_uarch, verify_reset_uarch) | PROVEN (UBSan) | Low |
| STEP-PROOF-4 | `cm_send_cmio_response(data=NULL, length>0)` fails but leaves `imcyclemax` and the revert root hash modified | PROVEN | Low |
| STEP-PROOF-5 | `cm_get_proof`/`cm_get_node_hash` return stale (wrong) hashes for words in the power-of-two padding of a memory range (evicted page-cache entry reused) | PROVEN | Medium |
| R-1 | Caller-supplied `revert_root_hash` is not checked by log/verify_send_cmio_response (coordinator question) | REJECTED (by design, documented; referee must pass root_hash_before) | - |
| R-2 | Crafted step log claiming an rx-rejected yield / forged revert hash | REJECTED (bound to root_hash_before) | - |
| R-3 | Memory-safety / soundness of binary step-log parsing and replay | REJECTED (analysis + 32k ASan/UBSan mutations) | - |
| R-4 | Divergence log_step/verify_step vs cm_run (Linux boot keccak+sha256, chunked runs with console breaks, 1-cycle steps, rejection and imcyclemax inside a step, cmio lengths/reasons) | REJECTED (no divergence found) | - |
| R-5 | Other hypotheses (hash function not bound by cm_verify_step, uarch state not checked by verify_step, marchid/mvendorid/mimpid read differently by record and replay) | REJECTED | - |

---

### STEP-PROOF-1: `cm_log_step` aborts when a step touches the tail of a non-power-of-two memory range (assert in `hash_tree::get_dense_node_hash`)
- Status: PROVEN
- Area: step-log / hash-tree / C API / JSON-RPC
- Category: liveness (honest prover cannot produce a proof), DoS (process abort reachable from API input)
- Where: `src/hash-tree.cpp:567` (`hash_tree::get_dense_node_hash`, the assertion
  `ar.contains_absolute(address, HASH_TREE_WORD_SIZE)`), reached from
  `src/record-step-state-access.hpp:204` (`record_step_state_access::get_sibling_hashes_impl` → `machine::get_node_hash`
  → `hash_tree::get_node_hash`, `src/hash-tree.cpp:616`), called by `machine::log_step` (`src/machine.cpp:2185`).
  Also directly reachable from `cm_get_node_hash` and the JSON-RPC `machine.get_node_hash` method.
- Problem: An address range's dense hash tree covers the next power of two of its length
  (`address_range::get_level_count()` uses `bit_ceil(page_count)`), and the hash tree keeps pristine hashes for the padding
  nodes beyond the range end. `hash_tree::get_node_hash` hands any node inside the AR's power-of-two span to
  `get_dense_node_hash`, which asserts that the node start address is inside `[start, start+length)`. When a step log
  is built, `get_sibling_hashes_impl` asks for the hash of every maximal untouched subtree. If a touched page lies in
  the last partially-filled power-of-two block of a range, one of these siblings starts at or past the range end
  (inside the padding), and the assertion fires. The default build is `relwithdebinfo` (top-level and `src/Makefile`:
  "By default we compile in release with debug information, so the emulator is packaged correctly by default"), which
  keeps asserts enabled for everything except `interpret.cpp`. So the packaged library/server calls `abort()`.
  In a `release=yes` (NDEBUG) build the same code returns the correct pristine hash and the log verifies (checked with
  a release copy built in `work/step-proof/rel`), so the assertion itself is wrong.
  Flash drives (rootfs / app ext2 images) commonly have non-power-of-two lengths. Example: the test rootfs is
  0x15dd1000 bytes at 0xA0000000, so its span is 2^29 bytes and any step touching a page in [0xB0000000, 0xB5DD1000)
  (the last ~94 MiB, about 25% of the drive) makes log_step request node (0xB8000000, 2^27) and abort.
- Scenario: (1) Honest party in a dispute that is resolved with big-machine step proofs (`cm_log_step` → ZK/risc0
  prover, see `risc0/`). The adversary picks its false claim so that the disputed cycle is one that reads from the tail
  of the application's flash drive (for example, the kernel copying file blocks located at the end of the rootfs).
  When the honest node calls `cm_log_step` with the packaged library, the process aborts (SIGABRT), so it cannot
  produce the proof and loses on timeout. (2) Any client of a `cartesi-jsonrpc-machine` server can kill it with
  `get_node_hash` on a padding node, or with `log_step` on such a step.
- Evidence:
  - PoC (minimal, bare metal): `<SCRATCH>/work/step-proof/poc1/run.sh` (builds `poc1.c` against the default build in
    `/home/user/machine-emulator/src`). RAM of 5 pages (0x5000), program `auipc t0,4; sd zero,0(t0); j .` (stores to
    the last RAM page), then `cm_log_step(m, 10, ...)`:
    ```
    poc1: hash-tree.cpp:567: ... get_dense_node_hash(...): Assertion `ar.contains_absolute(address, HASH_TREE_WORD_SIZE) && "address not in expected address range"' failed.
    RAM length 0x8000, store to 0x80004000: log_step OK
      child killed by signal 6
    RAM length 0x5000, store to 0x80004000: log_step FAILED
      child killed by signal 6
    cm_get_node_hash on padding node: CRASHED
    BUG REPRODUCED: cm_log_step cannot produce a step log when the step touches the last pages of a memory range whose length is not a power of two
    ```
    The same PoC linked against an NDEBUG build (`poc1-rel`, lib in `work/step-proof/rel/src`) prints `log_step OK`
    for both cases and `cm_get_node_hash on padding node: OK`. The siblings are correct, and only the assert fails.
  - Realistic, single-cycle step (what a dispute leaf would prove): `<SCRATCH>/work/step-proof/poc1/run-linux1.sh`.
    It uses the standard test Linux machine (`linux.bin` + `rootfs.ext2`, stored at mcycle 0), runs to mcycle 31464660
    (found by bisection as the first boot cycle whose instruction reads the rootfs tail), then calls `cm_log_step(m, 1, ...)`:
    ```
    linux1: hash-tree.cpp:567: ... get_dense_node_hash(...): Assertion `ar.contains_absolute(...)' failed.
    BUG REPRODUCED: cm_log_step(1) at mcycle 31464660 killed the process (signal 6)
    ```
    The same script with an NDEBUG lib (`./run-linux1.sh <SCRATCH>/work/step-proof/rel/src`) prints
    `log_step(1) at mcycle 31464660: OK, verify OK`.
    Also, consecutive `cm_log_step(3000000)` over the boot (`div.c`) abort with gdb backtrace
    `get_dense_node_hash(ar, address=0xB8000000, log2_size=27)` ← `record_step_state_access::get_sibling_hashes_impl`
    ← `finish` ← `machine::log_step`.
  - Remote: `<SCRATCH>/work/step-proof/poc1/jsonrpc-crash.lua`
    (`eval $(make -C /home/user/machine-emulator -s --no-print-directory env) && lua5.4 jsonrpc-crash.lua`):
    ```
    cartesi-jsonrpc-machine: hash-tree.cpp:567: ... Assertion `ar.contains_absolute(...)' failed.
    remote get_node_hash(0x80005000, 12):	false	... end of stream ...
    server still alive after call:	false	... Connection refused ...
    BUG REPRODUCED: remote JSON-RPC server died
    ```
- Possible solution: In `hash_tree::get_dense_node_hash`, accept any node inside the AR's power-of-two span (padding
  nodes have valid pristine hashes in the dense tree) and only use the page-cache path for nodes inside the range:
  ```cpp
  const uint64_t span = UINT64_C(1) << (HASH_TREE_LOG2_PAGE_SIZE + ar.get_level_count() - 1);
  assert(address - ar.get_start() < span);
  if (!ar.contains_absolute(address, HASH_TREE_WORD_SIZE)) {   // node lies entirely in the padding
      return m_pristine_hashes[log2_size];
  }
  ```
  (or equivalently return `m_pristine_hashes[log2_size]` in `get_node_hash` when the node starts at or after
  `ar.get_end()`). Add a regression test: log_step on a machine with a non-power-of-two flash drive touching its last page.
- Severity: High. The packaged (default) build aborts an honest prover, or a JSON-RPC server, on ordinary machine
  configurations. It is Critical for deployments whose disputes rely on `cm_log_step` big-step proofs (ZK path), because
  an adversary can steer the dispute to such a cycle.
- Risks: If left unfixed, honest parties cannot produce step logs for a large class of steps. The fix does not change any
  root hash or proof, since NDEBUG builds already return the same pristine hashes. It only removes an incorrect
  precondition.

### STEP-PROOF-2: ZK (risc0) replay wraps `mcycle_end` while C++ `verify_step` saturates, so the two step-log verifiers disagree
- Status: PROVEN (with a host build of the guest's C++ entry point, unchanged logic, linked against the emulator objects)
- Area: step-log / ZK verifier (`risc0/cpp`, the in-repo consumer of `replay_step_state_access`)
- Category: divergence, proof-soundness
- Where: `risc0/cpp/risc0-replay-steps.cpp:38`
  (`(void) __builtin_add_overflow(a.read_mcycle(), context.logged_mcycle_count, &mcycle_end);`) versus
  `src/machine.cpp:2206` (`verify_step`: `saturating_add(a.read_mcycle(), context.logged_mcycle_count)`) and
  `src/machine.cpp:2179` (`log_step`: same saturating add).
- Problem: On overflow, `__builtin_add_overflow` stores the wrapped sum and the guest ignores the flag. With
  `mcycle + mcycle_count >= 2^64`, the ZK guest runs `interpret(a, mcycle_end)` with a small `mcycle_end <= mcycle`,
  which returns immediately (`reached_target_mcycle`). So the ZK guest proves "state S, after `mcycle_count` cycles,
  is still S", while the reference implementation (log_step/verify_step) runs to `min(UINT64_MAX, imcyclemax)` or to
  halt/yield. The journal commits `(root_hash_before, mcycle_count, root_hash_after)`, and
  `CartesiStepVerifier.verifyStep` accepts any `uint64 mcycleCount` the caller asks for. Two verifiers that must agree
  accept different transitions for the same `(root_hash_before, mcycle_count)`.
- Scenario: If any protocol or integration verifies a big step whose `mcycle_count` is large (for example a "run to the
  fixed point" step with `mcycle_count = 2^64-1`, which wraps for every state with `mcycle >= 1`), a dishonest prover gets a
  valid ZK receipt for a no-op transition (`root_hash_after = root_hash_before`) from a state that actually advances, and the
  honest log cannot be proven at all (the guest throws `final root hash mismatch`). With the per-leaf counts currently
  used (`2^k`, small `k`) and `mcycle < 2^64 - 2^k`, it is not reachable.
- Evidence: `<SCRATCH>/work/step-proof/poc2/run.sh` builds `host-risc0-replay.cpp` (verbatim body of
  `risc0_replay_steps`) and `poc2.c`. The machine (sha256 tree) is at mcycle 10 with `imcyclemax = 30`, and
  `mcycle_count = 2^64 - 6`:
  ```
  honest step: mcycle 10 -> 30 (break 8), state changed: yes
  cm_verify_step: honest log ACCEPTED, forged log rejected
    zk-guest replay rejected log: final root hash mismatch
  zk guest replay: honest log rejected, forged log ACCEPTED
  BUG REPRODUCED: ZK guest proves S -(count)-> S (no-op) while the reference verifier proves S -(count)-> S' != S
  ```
  (The forged log is the honest log with its header `root_hash_after` replaced by `root_hash_before`.)
- Possible solution: In the guest, use the same saturating add as the reference:
  `uint64_t mcycle_end = saturating_add(a.read_mcycle(), context.logged_mcycle_count);`, or abort on overflow
  (`if (__builtin_add_overflow(...)) abort();`). Better, move the "compute mcycle_end, interpret, finish" sequence into
  one shared function used by both `machine::verify_step` and the ZK entry point, so they cannot drift.
- Severity: Medium. It lets an invalid transition be proven by the ZK verifier, but only for `mcycle_count` values that
  overflow, which current dispute parameters do not use. It is Critical if any integration lets the prover choose a
  huge count.
- Risks: Changing the guest changes the risc0 image ID, so the on-chain verifier contract must be redeployed or updated.
  There is no impact on the C++ emulator.

### STEP-PROOF-3: Access-log proofs with more than 64 levels cause UB (shift by 64) during verification of untrusted logs
- Status: PROVEN (UBSan)
- Area: access-log / hash-tree-proof (verify_send_cmio_response, verify_step_uarch, verify_reset_uarch)
- Category: input-validation (UB on untrusted input)
- Where: `src/access-log.hpp:186` (`access::make_proof`: `log2_root_size = proof_log2_size + sibling_hashes.size()`
  with no upper bound), `src/hash-tree-proof.hpp:190` (`bubble_up`: `static_cast<uint64_t>(1) << log2_size` for
  `log2_size == 64`).
- Problem: The number of sibling hashes comes from the untrusted JSON access log. With one extra sibling,
  `log2_root_size = 65` and `bubble_up` evaluates `1 << 64`, which is UB. Soundness is not affected: a proof with a
  different depth would need a Keccak collision between 32-byte and 64-byte preimages, so it is rejected. But it is UB
  reachable by any log submitted to the verifier, and the ASan/UBSan build aborts on it.
- Scenario: An adversary submits a send_cmio (or uarch step/reset) access log with 60 siblings in one access. A
  verifier built with sanitizers aborts. Release builds behave arbitrarily-but-benignly (x86 masks the shift).
- Evidence: `<SCRATCH>/work/step-proof/cmio/run-ubsib.sh`:
  ```
  hash-tree-proof.hpp:190:79: runtime error: shift exponent 64 is too large for 64-bit type 'long unsigned int'
  BUG REPRODUCED: UB (shift by >= 64) while verifying an untrusted access log
  ```
- Possible solution: In `access::make_proof`, require `sibling_hashes.size() == HASH_TREE_LOG2_ROOT_SIZE - proof_log2_size`
  (the replays always prove against the full 64-bit tree), and in the `hash_tree_proof` constructor reject
  `log2_root_size > 64`.
- Severity: Low (UB without exploitable effect in release builds).
- Risks: None. Honest logs always have exactly 64-`log2_size` siblings.

### STEP-PROOF-4: `cm_send_cmio_response(data == NULL, length > 0)` fails after partially modifying the machine
- Status: PROVEN
- Area: C API / cmio
- Category: API contract violation (state modified on error)
- Where: `src/cm.cpp:1325` (no `data == nullptr && length > 0` check), `src/send-cmio-response.cpp:71-76`
  (`writeImcyclemax`/`writeRevertRootHash` run before `writeMemoryWithPadding`), `src/state-access.hpp:453`
  (throws "data is null").
- Problem: The documentation says validation errors leave the machine unchanged. With NULL data, the advance-state path
  writes `imcyclemax` and the revert root hash and then throws, so the error leaves the machine still at the rx-accepted
  yield but with a different root hash. The same applies to `cm_log_send_cmio_response`, where the record path also
  throws after the first writes.
- Evidence: `<SCRATCH>/work/step-proof/cmio/run-nulldata.sh`:
  ```
  send with NULL data: error -6 (data is null)
  root hash changed: YES; imcyclemax 0xffffffffffffffff -> 0x100000000000b
  BUG REPRODUCED: failed cm_send_cmio_response left the machine partially modified
  ```
- Possible solution: In `cm_send_cmio_response` / `cm_log_send_cmio_response` / `cm_verify_send_cmio_response` (and in
  `machine::send_cmio_response`), validate `data != nullptr || length == 0` before calling the transition function.
- Severity: Low (needs caller misuse; a later correct response overwrites both fields).
- Risks: None.

### STEP-PROOF-5: `cm_get_proof` / `cm_get_node_hash` return stale hashes for words in the power-of-two padding of a memory range
- Status: PROVEN
- Area: hash-tree / C API (same root cause family as STEP-PROOF-1: padding nodes are handled inconsistently)
- Category: wrong proofs/hashes returned by the API
- Where: `src/hash-tree.cpp:101-124` (`hash_tree::get_page_proof`) and `src/hash-tree.cpp:567-581`
  (`get_dense_node_hash`, `log2_size < page` branch). Both borrow a page-cache entry for the padding page. On a miss,
  `page_hash_tree_cache::borrow_entry` evicts the LRU entry without clearing it (`page-hash-tree-cache.hpp:557-568`).
  `update_dirty_page` then returns `false` because the page is not inside the range (`hash-tree.cpp:232-233`), and that
  return value is ignored. The proof or node hash is built from the evicted page's hashes.
- Problem: For a word-level (`log2_target_size < 12`) proof or node hash of an address in the padding of a
  non-power-of-two range, the API returns the hash of some other page once the cache is full (default `phtc_size` 4096
  pages). The returned proof does not verify against the root hash. In the default (assert-enabled) build,
  `cm_get_node_hash` aborts instead (STEP-PROOF-1), while `cm_get_proof` silently returns the wrong proof.
- Scenario: A client (node, tooling, JSON-RPC user) that asks for a word proof of a zero/padding location (for
  example to prove that a region is empty) receives an invalid proof. This causes no soundness issue for verifiers,
  because the proof fails, but it is a wrong API result.
- Evidence: `<SCRATCH>/work/step-proof/pad/run-pad3.sh` (default build, RAM of 4097 pages, every page written, then
  `cm_get_proof(0x80000000+len+0x3000, 5, 64)`):
  ```
  expected pristine word hash KQ3s2VSLYqjWA0WpiDhvyEumvJVIQAj2Ni+TFg7z5WM=
  proof: "target_hash":"0BTT7etA50e6XmjwMVqu5iYZJQJ9cOM8HeWK0zCcMUc="}...
  BUG REPRODUCED: cm_get_proof returned a wrong target hash for a padding word
  ```
  In an NDEBUG build (`pad/pad2.c` → `pad2-rel`), `cm_get_node_hash(pad, 5)` likewise returns
  `WRONG (stale hash from an evicted page)`.
- Possible solution: In `get_page_proof` and `get_dense_node_hash`, when the page is not contained in the address range,
  do not use the page cache. Fill the proof/node from `m_pristine_hashes` (all siblings below page level and the target
  are pristine). Also handle the `false` return of `update_dirty_page` (return the entry and throw) instead of ignoring it.
- Severity: Medium (wrong proofs from the API for an uncommon query; no effect on root hashes or on step and uarch logs,
  which never request padding words).
- Risks: None. Root hashes do not change.

---

## Rejected / verified-safe hypotheses (with evidence)

### R-1 (coordinator question): caller-supplied `revert_root_hash` is not checked by log/verify_send_cmio_response
- Status: REJECTED (documented by design). It is a footgun for verifier integrations.
- Facts: `machine::send_cmio_response` requires `revert_root_hash == get_root_hash()` at an rx-accepted yield
  (`machine.cpp:1970-1986`). `log_send_cmio_response` and `verify_send_cmio_response` do not check it. The replay only checks
  that the written leaf equals the Merkle hash of the caller's `revert_root_hash` padded to 32 bytes
  (`replay-send-cmio-state-access.hpp:check_write_memory_with_padding`). `cm.h:1077` documents
  "Unlike cm_send_cmio_response, it is not checked against the machine root hash". The reference referee
  (`doc/recipes/prt.lua:277`) passes `root_hash_before` as the revert hash, so a prover's log built with another revert
  hash is rejected.
- Demonstration (`<SCRATCH>/work/step-proof/cmio/run-revert.sh`):
  ```
  cm_send_cmio_response with revert != root: refused (revert root hash does not match the machine root hash)
  cm_log_send_cmio_response/cm_verify_send_cmio_response with revert != root: log ok, verify accepted
  same log verified with revert := root_hash_before (as prt.lua referee does): rejected
  after guest rejects, verify_step root_hash_after == evil hash: yes
  ```
  So the security of the revert mechanism rests entirely on the verifier passing `revert_root_hash = root_hash_before`.
  A verifier that takes the revert hash from the prover lets the attacker make a later rejection "revert" to any root.
- Hardening suggestion: whenever the replay actually writes the revert hash (advance-state at an rx-accepted yield),
  the only correct value is `root_hash_before`. Make `verify_send_cmio_response` enforce
  `revert_root_hash == root_hash_before` (or drop the parameter and use `root_hash_before`). Do the same in
  `log_send_cmio_response` using the machine's root hash.

### R-2: crafted step log claiming an rx-rejected yield / forged revert root hash
- REJECTED. `replay_step_state_access::finish` substitutes the revert hash only if `iflags.Y` and `htif.tohost`
  (read from shadow page 0) say rx-rejected. It reads the revert hash from shadow page 0 at 0xfe0
  (`do_read_revert_root_hash`). Page 0 is always present in the log (every step reads shadow registers) and its data
  is hashed into the root checked against `root_hash_before` in the constructor. So neither the predicate nor the
  revert value can be forged. `log_step`/`verify_step`/`collect_mcycle_root_hashes` all use the same predicate
  (`rejected-manual-yield.hpp`). Tested: rejection reached inside a multi-cycle step, starting at a rejected state,
  and with imcyclemax overflow before or after the rejection (keccak and sha256). All consistent with
  `cm_run` + canonical hash (`cmio/cmio2.c`, part of `cmio/run-cmio.sh`).

### R-3: memory safety / soundness of binary step-log parsing and replay
- REJECTED. Analysis: header offsets are validated with overflow-checked arithmetic. `page_count > 0` is required.
  Page indices must be strictly increasing (no duplicates). Scratch hashes must be zero. Indices >= 2^52 are never
  consumed by the recursion, which makes it throw "too many pages". Sibling count must match exactly. Every page read or
  written by the interpreter is resolved by `find_page` (throws if absent), and its data is bound to `root_hash_before`.
  Hot TLB entries are created only after `shadow_tlb_verify_slot` with bound PMA data and point into log pages.
  Accesses are aligned and within a page (misaligned accesses trap, and the fetch path never crosses a page). The final
  root re-hashes all pages with the unchanged siblings. The private mmap means verification never modifies the log
  file. Dynamic: `<SCRATCH>/work/step-proof/run-fuzz.sh` applied 32,000 structured mutations (byte flips,
  page/sibling counts, page index/order/duplication/removal, hash function, mcycle_count, page data/scratch,
  truncation) to keccak and sha256 Linux step logs, against the ASan+UBSan build: no sanitizer report, and no accepted
  log with a different before/after root (`done: accepted=319 rejected=19681`, `96/7904`, `52/3948`, where "accepted"
  means the result was identical to the honest one).

### R-4: divergence between log_step/verify_step and cm_run
- REJECTED (no divergence found). `<SCRATCH>/work/step-proof/run-div.sh` (NDEBUG copy because of STEP-PROOF-1):
  - Full Linux boot (58,854,876 cycles) in consecutive 3M-cycle `cm_log_step` + `cm_verify_step` versus `cm_run` on a
    twin, comparing canonical root hash, mcycle and break reason at every step. Keccak: `OK final mcycle 58854876`.
    Sha256: `OK final mcycle 58854876`.
  - `chunk.c`: machine A run in random 1..2000-cycle chunks versus machine B run straight with console
    `to_buffer`/`every_char` (289 console-output breaks), compared every 2M cycles over the whole boot: `OK`.
    This shows that break/resume at arbitrary cycles (which is what a 1-cycle step and the uarch do) matches a full run.
  - 200 consecutive single-cycle `cm_log_step(1)` + `cm_verify_step` from mcycle 1234567, versus `cm_run`:
    `OK final mcycle 1234767`. (The script's original 3000-step run was cut short by the shared machine's load.)
  - `cmio/cmio.c`: advance/inspect/7/0xffff reasons × lengths 0,1,7,31,32,33,63,64,65,4095,4096,4097,2^20+1,
    2^21-1,2^21,2^21+1: log, verify and send agree, and the following 100-cycle log_step matches run (`ALL OK`).
  - `mcycle_count = 0`, steps across halt, yield, rx-rejected and imcyclemax: consistent.

### R-5: other hypotheses
- `cm_verify_step` takes the hash function from the log header and does not bind it. Exploiting this needs a sha256
  Merkle tree whose root equals a given keccak root (preimage). Not exploitable.
- `verify_step` does not check that the uarch is reset (log_step does). The before-state of a disputed step is
  agreed and comes from an mcycle boundary, so this is not exploitable.
- `marchid`/`mvendorid`/`mimpid`: run and record return the compile-time constants, while the step replay (`i_prefer_shadow_state`) reads the
  shadow words. They can differ only for snapshots loaded with `skip_version_check` (documented as non-production).
- `access::make_proof` with fewer than 64 levels: sound because leaf (32-byte) and node (64-byte) hash preimages
  differ, so a shorter proof would need a collision. Only the >64 case is UB (STEP-PROOF-3).
- The interrupt-delivery invariant (no instruction makes a pending interrupt deliverable without returning
  `success_and_serve_interrupts`) was reviewed for mstatus, sstatus, mie, sie, mip, sip, mideleg, CLINT and PLIC
  writes. It holds, and is consistent with the chunked-run results above.
