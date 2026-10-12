# Bug report: `feature/v0.22.0-test2` (v0.22.0) against `main`

This report reviews every change on `feature/v0.22.0-test2` relative to `origin/main` (25 commits, 91 files). It covers the emulator core, libcartesi (C/C++ API, JSON-RPC client and server, Lua bindings), the Lua libraries (`cartesi.hash-tree`, `cartesi.util`, `cartesi.gdbstub`) and the `cartesi-machine` CLI. Documentation, typos and missing tests are out of scope.

Every issue below has a runnable reproduction under [`bugs/`](bugs/). Each test prints `BUG REPRODUCED` and exits 1 while the bug is present. It prints `OK` and exits 0 once the bug is fixed.

## How the issues were found

1. **Hunting.** Nine hunters worked independently, one per area:
   - `collect_mcycle_bundle`
   - `collect_uarch_cycle_bundle` and the rejected-yield and overflow change
   - CMIO send semantics and break-reason precedence
   - JSON-RPC parity
   - Lua C++ bindings
   - CLI computation-hash builders
   - CLI runtime and gdbstub
   - `cartesi.hash-tree`
   - persistence (page hash cache, archive version, `O_CLOEXEC`)

   Each hunter reasoned about the diff, proposed candidate bugs and kept only those it could reproduce with code.
2. **Review.** A second batch of independent reviewers re-ran every reported reproduction. They re-derived the root cause from the source, often correcting the hunter's analysis. They compared against `origin/main` to decide whether the branch introduced the bug, recalibrated severity, and wrote the minimal regression tests committed here.
3. **Final check.** All committed tests were re-run on the branch build; results are in the summary table.

## Running the tests

From the repository root:

```sh
make                                   # emulator, libcartesi, Lua bindings, cartesi-jsonrpc-machine
make -C tests machine uarch images     # bare-metal test guests + Linux/rootfs images
source bugs/env/env.sh                 # LD_LIBRARY_PATH, LUA_PATH/CPATH, CARTESI_TESTS_PATH, CM_CLI, ...
bash bugs/run-all.sh                   # runs every reproduction and prints a summary
```

The tests only need the in-tree build, `tests/build/machine/*.bin` and `curl` (for the raw JSON-RPC cases). None of them depends on absolute uarch hashes, so they are valid with any uarch toolchain.

## Summary

| ID | Severity | Introduced by branch | Title |
|----|----------|----------------------|-------|
| [BUG-01](#bug-01) | **High** | No (pre-existing; this release touches the same code) | Interrupted hash-tree update leaves a shared stored machine that silently reports a stale root hash |
| [BUG-02](#bug-02) | **Medium** | Yes (88df5f7) | GIO response with response code 0 is silently dropped; GIO hosts loop forever |
| [BUG-03](#bug-03) | Low | Yes (f23ed60) | `collect_mcycle_bundle` has no size cap; a halted machine yields 2^b hashes and the process aborts (SIGABRT) instead of returning an error |
| [BUG-04](#bug-04) | Low | Partly (new bundle API inherits it) | Oversized `revert_uarch_tail` aborts the process or JSON-RPC server; the bundle API silently accepts it |
| [BUG-05](#bug-05) | Low | Yes in the new entry points (pattern pre-existing) | Out-of-range log2 bundle counts are silently truncated to int32 in Lua and JSON-RPC: the machine advances and a wrong-size bundle is returned |
| [BUG-06](#bug-06) | Low | Yes (88df5f7) | C API `cm_send_cmio_response` narrowed to `uint32_t` length: lengths ≥ 4 GiB are silently truncated and delivered |
| [BUG-07](#bug-07) | Low | Yes (88df5f7) | CLI `--cmio-inspect-state` silently drops queries larger than the rx buffer and exits 0 |
| [BUG-08](#bug-08) | Low | Yes (4215293) | `rpc.discover` advertises JSON-RPC protocol 0.7.0 while the server is 0.8.0 |
| [BUG-09](#bug-09) | Low | Partly | `cartesi.hash-tree` frontier API accepts invalid heights, hash types and counts, giving silently wrong frontiers or roots |
| [BUG-10](#bug-10) | Low | No | Corrupted page hash-tree cache with a cyclic LRU list hangs machine load forever |
| [BUG-11](#bug-11) | Low | No (option renamed on branch, same check on main) | CLI `--mcycle-computation-hash` bundle-size check overflows; the CLI spins forever instead of rejecting the option |

Results of `bash bugs/run-all.sh` on the branch build: every test printed `BUG REPRODUCED`.

---

<a id="bug-01"></a>
## BUG-01: Interrupted hash-tree update leaves a shared stored machine that silently reports a stale root hash

- **Severity:** High
- **Area:** Hash tree / persistence of shared stored machines (`.dht`, `.dpt`, `.sht`, `.phtc` files)
- **Category:** Correctness / consensus (silent wrong root hash and proofs, undetected by `verify_hash_tree`)
- **Introduced by branch:** No. `src/hash-tree.cpp` is unchanged on the branch and is the same on `origin/main`. It matters for this release for two reasons:
  - The branch ships a fix in the same subsystem: commit 4bbedaf, "Fixed stored machines whose page hash-tree cache could be corrupted by sync or clone".
  - The CLI promotes shared stored machines (`--load=dir,sharing:all`, `--revert-mode=stored`).
- **Where:**
  - `src/hash-tree.cpp:306-309` (`return_updated_dirty_pages`): writes each page's new leaf hash directly into the shared, mmapped dense tree (`node_hash_view`).
  - `src/hash-tree.cpp:336-342`: a page whose stored leaf already equals its recomputed hash is treated as "not in fact dirty" and gets `mark_clean_page_and_up(offset)`, which clears its clean-only ancestors.
  - `src/hash-tree.cpp:694-702` (`hash_tree::update`): inner dense nodes (`update_dense_trees`), the sparse tree (`update_sparse_tree`) and `dirty_page_tree().clean()` are updated only after all leaves are written.
  - `src/hash-tree.cpp:418`: on failure only the page cache is cleared.
  - `src/page-hash-tree-cache.hpp:442-493`: loading a cache file does not reset persisted `borrowed` flags (aggravating factor).
  - `src/hash-tree.cpp:628-692` (`verify`): checks page leaves against memory and dirty bits, but never checks inner dense nodes against their children.
- **Problem:** An update of the hash tree is not atomic with respect to the shared files. A process can die after `return_updated_dirty_pages` has written new leaf hashes and before the inner nodes, sparse tree and dirty-page tree are updated. The directory is then left with:
  - memory already new;
  - the page still marked dirty in the `.dpt`;
  - the leaf in the `.dht` already new;
  - the ancestors stale.

  On the next load and update, the recomputed leaf equals the stored leaf, so `changed == false`. The page is then marked clean "and up", and `update_dense_trees` never recomputes its ancestors. From then on, every load of the directory, and every store or clone made from it, reports a stale root hash and stale proofs, until each affected page happens to be written again. `verify_hash_tree()` returns `true`.

  If the kill happened while cache entries were borrowed, the stale `borrowed` flags make the first `get_root_hash` fail with "update hash tree failed". By then some pages were already marked clean, and the retry silently returns the stale root.
- **Scenario:** A rollups or dispute (PRT/Dave) node, or a CLI user, runs a machine directly from a stored directory with `sharing = all`. Examples:
  - `cartesi.machine(dir, {}, cartesi.SHARING_ALL)`
  - `cartesi-machine --load=dir,sharing:all`
  - `--revert-mode=stored`

  The process is SIGKILLed (OOM killer, `docker stop` timeout, systemd, an unhandled Ctrl-C/SIGTERM) while computing `get_root_hash`, `get_proof` or a `collect_*` hash collection. After a restart, the node computes and commits to root hashes and proofs that do not correspond to the machine memory. On chain, this means wrong claims and lost disputes. Nothing detects it.
- **Evidence:**
  - Deterministic reproduction. It crafts on disk exactly the state such a kill leaves: store a dirty machine with `SHARING_ALL`, then write the correct page leaf into the `.dht`. A control load runs before the patch.

    ```
    $ lua5.4 bugs/01-stale-root-after-interrupted-update/interrupted-update-stale-root.lua
    expected root: 0x0305ec2a548809fa349344091af71579b29540d93f07a3794138d0354ba76f95
    got root:      0x525f84c204434dd6b7a5ca1d37bea80e3ae4fb936a7ddcf23f6705011357105f (verify_hash_tree() = true)
    BUG REPRODUCED
    ```

    The "got" root equals the root of the machine before the memory change, so the change is invisible. The expected root was confirmed independently by the in-memory machine and by `tests_util.calculate_emulator_hash` (a Lua tree built from `read_memory`).
  - End-to-end reproduction with a real SIGKILL during `get_root_hash` on a 64 MiB shared machine: `bash bugs/01-stale-root-after-interrupted-update/kill-during-update.sh [trials]`.
    - The reviewer got 4/4 stale roots; the hunter got 11/12 with a rebuild-from-scratch cross-check.
    - Controls behave correctly: no kill, or a kill before hashing.
    - The bug also reproduces with the cache file zeroed, so the dense-tree ordering is the root cause, not the cache.
- **Possible solution:**
  - Do not treat "leaf unchanged" as proof that the ancestors are up to date. For a page marked dirty whose leaf already matches, keep its ancestors dirty and add its address range to `changed_ars`. The cost is about log2(pages) concatenation hashes per such page.
  - Or persist an "update in progress" marker, e.g. in the `.sht`. Set it durably before writing leaves and clear it after `dpt.clean()`. On load, if it is set, mark every page dirty (or rebuild the dense trees) and reinitialize the cache.
  - Reset `borrowed` flags (or reinitialize the cache) when loading a `.phtc`, and clear the cache on any exception during update.
  - Make `verify()` also check inner dense nodes and the dense root against the sparse tree.
- **Risks:**
  - Of fixing: the update path is hot, so dropping the "unchanged page" optimization costs some hashing for always-dirty pages. A marker-based fix must be crash-durable (msync ordering) and must not change hashes for uninterrupted runs.
  - Of not fixing: silent consensus divergence after any crash of a node that uses shared stored machines. This directly contradicts the durability that sharing mode advertises.

---

<a id="bug-02"></a>
## BUG-02: GIO response with response code 0 is silently dropped; GIO hosts loop forever

- **Severity:** Medium. It is a functional regression for any GIO host that uses response code 0, with no error to diagnose it. It drops to low only if GIO with code 0 is declared unsupported for this release.
- **Area:** CMIO / `send_cmio_response` (host-facing C, C++, Lua and JSON-RPC API)
- **Category:** Correctness / hang (silent no-op, previously an error)
- **Introduced by branch:** Yes. Commit 88df5f7 ("fix: align CMIO input and stop behavior with logged transitions") replaced the throwing `check_pending_cmio_request` with `check_cmio_response_revert_root_hash`. The core rule in `src/send-cmio-response.cpp:41-48` is unchanged since v0.21.0.
- **Where:**
  - `src/send-cmio-response.cpp:41-48`: every response with `reason == HTIF_YIELD_REASON_ADVANCE_STATE` (0) is treated as an advance-state input, and is a no-op unless the machine is at an rx-accepted manual yield.
  - `src/machine.cpp:1970-1994` (`check_cmio_response_revert_root_hash` and `send_cmio_response`): the host-facing call no longer rejects this case.
  - `src/cm.h:1019-1033`.
- **Problem:** For GIO (generic I/O) requests, the guest (libcmt `cmt_gio_request`) yields manually with `reason = domain`, and reads the host's response code from the fromhost reason field. That field is the `reason` argument of `send_cmio_response`. A response code of 0 is numerically equal to `HTIF_YIELD_REASON_ADVANCE_STATE`, so the core classifies it as an advance-state input. Since the machine is at a GIO yield, not an rx-accepted one, the response is dropped. Nothing in `cm.h`, the README or libcmt says code 0 is reserved.
  - v0.20.0 delivered the response.
  - v0.21.0 and `main` refused it with "machine is not waiting on an rx-accepted manual yield".
  - This branch returns success and changes nothing. `run()` returns `YIELDED_MANUALLY` immediately at the same mcycle, and `receive_cmio_request` returns the same GIO request, so a host that answers it again never makes progress.
- **Scenario:** A GIO host uses 0 as its "OK" response code. This is a natural convention: for example, cartesi-lambada's worker answers its IPFS GIO domains with `send_cmio_response(0, ...)`. After upgrading to 0.22.0, the host spins forever on the first GIO request with no error. A rollups or app node that services GIO this way stops processing inputs.
- **Evidence:**

  ```
  $ lua5.4 bugs/02-gio-response-code-zero/gio-response-code-zero.lua local     # same output with: jsonrpc
  iteration 1: send succeeded, state unchanged, run -> 2 at mcycle 0 (started at 0)
  iteration 2: send succeeded, state unchanged, run -> 2 at mcycle 0 (started at 0)
  iteration 3: send succeeded, state unchanged, run -> 2 at mcycle 0 (started at 0)
  BUG REPRODUCED: GIO response code 0 reported success but was never delivered; the host loops forever
  ```

  Control: the same test with response code 1 shows `response delivered: fromhost reason=1 length=17`.
- **Possible solution:**
  - (a) In the host-facing `send_cmio_response`, refuse with an error when the core would no-op because of a reason/yield mismatch, at least for `reason == 0` at a non-rx-accepted yield. Keep `log_send_cmio_response` and `verify_send_cmio_response` as provable no-ops.
  - Or (b) return a "delivered" indication to the caller.
  - Or (c) treat reason 0 as advance-state only at rx-accepted, rx-rejected or exception yields and as a plain response at GIO yields. This changes the step function and its Solidity port, so it is a consensus change that needs coordination.
  - At a minimum, document in `cm.h`, the README and libcmt that GIO response code 0 is reserved.
- **Risks:**
  - Of fixing: options (a) and (b) are host-side only and do not affect provable transitions. Option (c) changes the state transition function and the on-chain verifier.
  - Of not fixing: GIO hosts silently hang after upgrading. The related host-misuse cases from the same commit are documented design and are not counted as bugs here (see "Other observations"); they now succeed silently as well.

---

<a id="bug-03"></a>
## BUG-03: `collect_mcycle_bundle` has no size cap; a halted machine yields 2^b hashes and the process aborts instead of returning an error

- **Severity:** Low. The bundle size is chosen by the trusted caller (the PRT recipe uses 2^4), and a JSON-RPC client can already shut the server down. Still, a single bad parameter kills the node process or the remote server, and its machine state is lost, instead of producing an error.
- **Area:** New `collect_mcycle_bundle` API (C++, C API, Lua, JSON-RPC server)
- **Category:** DoS / robustness (std::terminate)
- **Introduced by branch:** Yes (f23ed60, "feat: add machine entrypoints for direct bundle collection").
- **Where:**
  - `src/machine.cpp:2467`: the only bound is `log2_mcycle_period + log2_bundle_mcycle_count <= 63`.
  - `src/machine.cpp:2499-2501`: the comment "so an oversized bundle fails without advancing the machine" covers only the 32-byte-per-hash vector.
  - `src/machine.cpp:2537`: `resize(2^b)` at a fixed point.
  - `src/cm.cpp:776` and `src/jsonrpc-remote-machine.cpp:1000`: JSON serialization of the result.
  - `third-party/nlohmann-json/json.hpp:20591`: `json_value::destroy` allocates a stack sized to the array.
- **Problem:** On a machine already at a fixed point (halted, yielded or overflowed), `collect_mcycle_bundle(0, p, b)` returns 2^b copies of the root hash without executing anything. `collect_mcycle_root_hashes` returns a single entry in the same situation. Serializing the result as base64 strings in an `nlohmann::json` array, and then the dumped string, takes about 10× the raw 32·2^b bytes.

  When allocation fails during `to_json`, stack unwinding destroys the partially built JSON array. `basic_json`'s destructor allocates (`stack.reserve(array->size())`) and throws a second `bad_alloc` out of an implicitly `noexcept` destructor. That calls `std::terminate`, so the process gets SIGABRT and exits with 134. The function-try-block in `cm_collect_mcycle_bundle` never gets the chance to catch it. With unlimited memory the outcome is the OOM killer instead: b≈26 needs about 20 GB.

  On a running machine, the error can also arrive after the machine has already advanced to `mcycle_end`.
- **Scenario:** A node or tool passes a wrong or misconfigured `log2_bundle_mcycle_count`, for example 20–26, on a halted machine, locally or through `cartesi-jsonrpc-machine`. The process (or the remote server, together with its machine) dies instead of reporting an error.
- **Evidence:**

  ```
  $ lua5.4 bugs/03-mcycle-bundle-oom-abort/test-mcycle-bundle-oom-abort.lua          # local (Lua + C API)
  baseline VmPeak 104616 kB, running bundle 2^20 under ulimit -v 227496
  terminate called after throwing an instance of 'std::bad_alloc'
    what():  std::bad_alloc
  BUG REPRODUCED: process died (signal 6) instead of returning an error
  $ lua5.4 bugs/03-mcycle-bundle-oom-abort/test-mcycle-bundle-oom-abort.lua jsonrpc  # remote server
  baseline server VmPeak 104292 kB, bundle 2^20 under ulimit -v 227172
  returned error: jsonrpc error: post error contacting 127.0.0.1:28685 (end of stream ...)
  BUG REPRODUCED: cartesi-jsonrpc-machine server process died instead of returning an error
  ```

  The test runs `collect_mcycle_bundle(0, 0, 20)` on a halted machine under `ulimit -v` (baseline + 120 MiB), so it is safe on shared machines. With 700 MiB of headroom the same call succeeds, which confirms it is an allocation failure path. gdb shows `_Unwind_Resume` → `~basic_json` → `__cxa_call_terminate`.
- **Possible solution:**
  - Cap `log2_bundle_mcycle_count` before running. For example, use `ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE` (20), as `collect_uarch_cycle_bundle` already effectively does, or a dedicated constant.
  - Separately, avoid building a temporary `nlohmann::json` array for large hash lists: serialize directly to a string, or catch `bad_alloc` before the JSON value is destroyed.
  - Fix the misleading comment.
- **Risks:**
  - Of fixing: a cap could reject legitimately huge bundles. No in-tree user needs them.
  - Of not fixing: a parameter mistake crashes a node or the remote server.

---

<a id="bug-04"></a>
## BUG-04: Oversized `revert_uarch_tail` aborts the process or JSON-RPC server; the bundle API silently accepts it

- **Severity:** Low. Honest nodes always build the tail themselves with `collect_uarch_cycle_root_hashes(log2=0)` on their reverted machine.
- **Area:** `collect_uarch_cycle_root_hashes` and the new `collect_uarch_cycle_bundle` (C++, C API, Lua, JSON-RPC)
- **Category:** Validation / DoS (assert abort) and a silently wrong result
- **Introduced by branch:** Partly. The assert abort exists on `origin/main` (`machine.cpp:2511` there). The new `collect_uarch_cycle_bundle` inherits the missing check, and it silently returns a bundle built from the invalid tail.
- **Where:**
  - `src/machine.cpp:2668-2679`: the precondition block only checks that the tail is non-empty, has at least 2 entries and that its last entry is the revert root hash.
  - `src/machine.cpp:2576`: `assert(execution_bundle_count < bundle_capacity)` in `append_uarch_reset_root_hash`.
  - `src/machine.cpp:2845` (`collect_uarch_cycle_bundle`).
- **Problem:** A valid tail has at most 2^20 entries, one per position of the mcycle: at most 2^20−2 transient entries, plus halt and reset. Nothing rejects longer tails:
  - With `log2_bundle_uarch_cycle_count > 0`, on a machine at an rx-rejected yield, the assert fires. Asserts are compiled into the default `relwithdebinfo` build, so the process aborts; under JSON-RPC, `cartesi-jsonrpc-machine` dies.
  - With log2 = 0, a period of more than 2^20 entries is returned with no error.
  - `collect_uarch_cycle_bundle` drops tail entries past position 2^20−2, including the halted hash. It returns a bundle (for example `[transient #2^20−1, reset]`) that no valid tail can produce.
- **Scenario:** A client or buggy node concatenates several periods' hashes into one tail and calls `collect_uarch_cycle_root_hashes` or `collect_uarch_cycle_bundle` on a machine at a rejected input. The process or server crashes, or the client gets a plausible-looking but invalid bundle to commit to.
- **Evidence:**

  ```
  $ lua5.4 bugs/04-overlong-revert-uarch-tail/test-overlong-revert-uarch-tail.lua
  BUG REPRODUCED: 1048578-entry revert_uarch_tail was not rejected
    (a) collect_uarch_cycle_root_hashes(log2=1) child died (exit 134)
    (b) collect_uarch_cycle_root_hashes(log2=0) accepted it, returned 1048578 entries (> 1048576)
    (c) collect_uarch_cycle_bundle accepted it, returned 2 entries
  ```
- **Possible solution:** In the precondition block, add `if (revert_uarch_tail.size() > (UINT64_C(1) << ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)) throw std::runtime_error{"revert uarch tail is too long"};`. This covers both APIs. Optionally, turn the assert into an exception.
- **Risks:**
  - Of fixing: minimal, since only a check before execution is added.
  - Of not fixing: a crash (DoS) for any client able to pass a tail, and silently invalid bundles.

---

<a id="bug-05"></a>
## BUG-05: Out-of-range log2 bundle counts silently truncated to int32 in Lua and JSON-RPC

- **Severity:** Low. Only absurd caller inputs trigger it, and local and remote behave identically.
- **Area:** Lua bindings and JSON-RPC server handlers for the new bundle methods
- **Category:** Validation / silent wrong result with an unwanted state change
- **Introduced by branch:** Yes in the two new entry points. The same cast already exists on `main` in the older `collect_*_root_hashes` handlers (`clua-i-machine.cpp:1242,1275`, `jsonrpc-remote-machine.cpp:981,1018` on the branch), and the branch copied it.
- **Where:**
  - `src/clua-i-machine.cpp:1260`: `static_cast<int32_t>(luaL_checkinteger(L, 4))` in `collect_mcycle_bundle`.
  - `src/clua-i-machine.cpp:1292`: the same cast in `collect_uarch_cycle_bundle`.
  - `src/jsonrpc-remote-machine.cpp:994-999` and `:1030-1036`: values parsed as `uint64_t`, then `static_cast<int>(...)`.
- **Problem:** A log2 count of 2^32+k becomes k. When k is valid, the C++ range checks never see the bad value: the call succeeds, runs the machine and returns a bundle of the wrong size, instead of an error with the machine unchanged. Values from 2^31 upwards become negative and are rejected with a misleading message. C, C++ and Rust callers going through `cm.h` (`int32_t`) are not affected.
- **Scenario:** A Lua script, or a raw JSON-RPC client (for example one generated from `rpc.discover`, which declares these parameters `UnsignedInteger`), passes an unvalidated or overflowed u64. The machine silently advances and the client gets a wrong-size bundle.
- **Evidence:**

  ```
  $ lua5.4 bugs/05-bundle-log2-truncation/test-bundle-log2-truncation.lua
  lua-local  collect_mcycle_bundle(0, 0, 4294967297): accepted, 2 hashes returned, mcycle 0 -> 2
  lua-remote collect_mcycle_bundle(0, 0, 4294967297): accepted, 2 hashes returned, mcycle 0 -> 2
  lua-local  collect_uarch_cycle_bundle(0, 4294967298): accepted, 4 hashes returned, mcycle 0 -> 1
  lua-remote collect_uarch_cycle_bundle(0, 4294967298): accepted, 4 hashes returned, mcycle 0 -> 1
  raw-rpc    collect_mcycle_bundle[0,0,4294967297]: accepted, mcycle 0 -> 2 ...
  raw-rpc    collect_uarch_cycle_bundle[0,4294967298,[Z,Z]]: accepted, mcycle 0 -> 1 ...
  BUG REPRODUCED: out-of-range log2 bundle counts silently truncated (6 cases)
  ```
- **Possible solution:** Range-check before narrowing in all four collect handlers, in both layers. In Lua, use `luaL_argcheck(L, v >= 0 && v <= INT32_MAX, ...)`. In JSON-RPC, reject values above `INT32_MAX` with an invalid-params error, or parse them as `int32_t` with a range check.
- **Risks:**
  - Of fixing: none, since it only rejects already-invalid inputs.
  - Of not fixing: caller bugs are masked by silent state advancement.

---

<a id="bug-06"></a>
## BUG-06: C API `cm_send_cmio_response` narrowed to `uint32_t` length; lengths ≥ 4 GiB are silently truncated and delivered

- **Severity:** Low. It needs a response of at least 4 GiB from a C or FFI host that does not validate the length, and it has no consensus impact because log and verify agree with send.
- **Area:** C API (`cm.h`) and the C++ machine interfaces
- **Category:** API/ABI compatibility / validation (silent truncation, previously an error)
- **Introduced by branch:** Yes for `cm_send_cmio_response`. Commit 88df5f7 changed `uint64_t length` to `uint32_t` with no range check, and removed the host-side "CMIO response data is too large" error. `cm_log_send_cmio_response` and `cm_verify_send_cmio_response` already truncated on `main`.
- **Where:**
  - `src/cm.h:1033`, `:1088`, `:1132`.
  - `src/cm.cpp:1325`, `:1338`, `:1357`.
  - `src/machine.cpp:1988`.
- **Problem:** A C caller that passes a `size_t` or `uint64_t` length compiles cleanly under `-Wall -Wextra -Werror`; only `-Wconversion` warns. The length is reduced mod 2^32. The same happens through FFI bindings still declaring `uint64_t` (ctypes, bindgen or cgo built from the 0.21 header): on x86-64 and aarch64 the callee reads only the low 32 bits. Before, a 4 GiB + 16 byte response was rejected; now 16 bytes are delivered and the call reports success. The documented outcome for oversized data would be the rx-buffer no-op. The Lua and JSON-RPC bindings do check `<= UINT32_MAX`.
- **Scenario:** A C or FFI host forwards a response whose size comes from a file or a network read without checking it, and part of the data is silently delivered to the guest.
- **Evidence:**

  ```
  $ sh bugs/06-c-api-cmio-length-truncation/run.sh
  cm_send_cmio_response(length=4294967312) -> success; state changed=1; fromhost length=16
  BUG REPRODUCED: a 4294967312-byte response was delivered as a 16-byte response
  ```
- **Possible solution:**
  - Keep `uint64_t` in the C API and `i_machine`, and reject (or saturate to the oversized no-op) any length above `UINT32_MAX` before narrowing to the core's `uint32`.
  - Or keep `uint32_t`, document loudly that callers must range-check, and call out the FFI signature change in the release notes.
- **Risks:**
  - Of fixing: a trivial change.
  - Of not fixing: non-Lua, non-JSON-RPC bindings carry a silent truncation where there used to be an error.

---

<a id="bug-07"></a>
## BUG-07: CLI `--cmio-inspect-state` silently drops queries larger than the rx buffer and exits 0

- **Severity:** Low. It affects the CLI only, inspect state is reverted, and there is no consensus impact. It is still a silently wrong result for tools that drive inspects through the CLI.
- **Area:** `cartesi-machine` CLI
- **Category:** Validation / silent wrong result
- **Introduced by branch:** Yes (88df5f7). Before, `send_cmio_response` threw "CMIO response data is too large" and the CLI failed. The same commit added a warning to the advance-input path (`load_cmio_input`) but not to the query path.
- **Where:** `src/cartesi-machine.lua:3547-3550` (`load_cmio_query`).
- **Problem:** A query larger than 2 MiB is sent with `send_cmio_response`, which is now a silent no-op. The CLI then "runs" the query, stops immediately at the previous rx-accepted yield, prints that old yield as the result, writes no reports and exits 0. The guest never sees the query.
- **Scenario:** A user, script or test harness runs `cartesi-machine --cmio-inspect-state=query:big.bin,...` with a query that is too large, and gets a successful-looking inspect with zero reports. That is indistinguishable from an application that legitimately produced no reports.
- **Evidence:**

  ```
  $ lua5.4 bugs/07-cli-oversized-inspect-query/oversized-inspect-query.lua
  --- valid query, exit 0
  Automatic yield tx-output (2) (0x000008 data)
  Cycles: 25
  Automatic yield tx-output (2) (0x000008 data)
  Cycles: 36
  Manual yield rx-accepted (1) (0x000020 data)
  Cycles: 606
  --- oversized query, exit 0
  Manual yield rx-accepted (1) (0x000000 data)
  Cycles: 6
  BUG REPRODUCED: oversized inspect query silently ignored (exit 0, no diagnostic, guest never ran)
  ```
- **Possible solution:** In `load_cmio_query`, fail with an error when `#data > 1 << cartesi.AR_CMIO_RX_BUFFER_LOG2_SIZE`. An inspect is off-chain and need not replay the no-op transition. At a minimum, warn and exit non-zero, as `load_cmio_input` does.
- **Risks:**
  - Of fixing: none.
  - Of not fixing: misleading results for CLI-driven inspects.

---

<a id="bug-08"></a>
## BUG-08: `rpc.discover` advertises JSON-RPC protocol 0.7.0 while the server is 0.8.0

- **Severity:** Low. The server's behaviour is correct and no in-tree consumer reads the value, but clients generated from the published discovery document will label themselves incorrectly.
- **Area:** JSON-RPC API metadata (served by the server through `rpc.discover`)
- **Category:** API compatibility / consistency
- **Introduced by branch:** Yes. Commit 4215293 bumped `JSONRPC_VERSION_MINOR` to 8 but left `jsonrpc-discover.json` untouched. The previous bump (20e5008) changed both files together.
- **Where:** `src/jsonrpc-discover.json:5` (`"version": "0.7.0"`) and `src/jsonrpc-version.hpp:25` (`JSONRPC_VERSION_MINOR = 8`).
- **Problem:** `machine.get_version` reports 0.8.0 while `rpc.discover` reports `info.version` 0.7.0. Protocol 0.8 adds `machine.collect_mcycle_bundle` and `machine.collect_uarch_cycle_bundle`. The real client requires an exact major.minor match (`jsonrpc-machine.cpp:403`).
- **Scenario:** An OpenRPC-generated client (Go, Rust, TypeScript), or tooling that pins or labels clients by `info.version`, records the 0.8 API as 0.7.0. It can then mismatch the servers it is used against, or assume the bundle methods are absent.
- **Evidence:**

  ```
  $ lua5.4 bugs/08-rpc-discover-version/test-discover-version.lua
  get_version:                0.8.0
  rpc.discover info.version:  0.7.0
  BUG REPRODUCED: rpc.discover advertises a different protocol version than get_version
  ```
- **Possible solution:** Set `"version": "0.8.0"`. Add a build-time or test check that `info.version` equals `JSONRPC_VERSION_MAJOR.MINOR.PATCH`, or generate it from the header.
- **Risks:**
  - Of fixing: none.
  - Of not fixing: generated clients carry the wrong protocol version.

---

<a id="bug-09"></a>
## BUG-09: `cartesi.hash-tree` frontier API accepts invalid heights, hash types and counts, giving silently wrong frontiers or roots

- **Severity:** Low. API hardening: no in-tree caller can reach these cases. `cartesi-machine.lua` and the PRT recipes pass only constant-derived heights, valid hash types and counts below 2^48. Direct users of the public Lua library get a wrong frontier or root instead of an error. The new forest API correctly rejects the same inputs.
- **Area:** `src/cartesi/hash-tree.lua` (public Lua library)
- **Category:** Validation / silent wrong result
- **Introduced by branch:** Partly. `frontier_append`, the omitted-count path of `frontier_pad_back` and `frontier_forest` are new on the branch. `frontier_push_back`, `frontier_get_root_hash`, `frontier_genesis` and the counted `frontier_pad_back` path behave the same on `main`.
- **Where:**
  - `frontier_push_back` (`hash-tree.lua:164`), `frontier_append` (`:185`), `frontier_get_root_hash` (`:218`) and `frontier_pad_back` (`:247`).
  - `frontier_genesis` (`:362`) and `frontier_forest` (`assert(cartesi[hash_type])`).
- **Problem:**
  - (1) Subtree or pad heights above the frontier height are accepted:
    - `push_back` and `append` with height H+1 silently grow the frontier to H+2 levels, changing its height and capacity.
    - `get_root_hash(pad, H+k)` returns the pad itself as the root.
    - `pad_back(X, nil, H+1)` sets the top entry to X.
  - (2) `frontier_append` is not atomic: a bad entry later in the range fails only after earlier subtrees were folded in.
  - (3) Any field of the `cartesi` module (for example `"tohex"`) is accepted as the hash function, in both `frontier()` and `frontier_forest()`, and computes a garbage root.
  - (4) On frontiers taller than 64 levels, `frontier_pad_back` treats negative counts as unsigned values ≥ 2^63:
    - On an empty frontier, count −1 is silently accepted as 2^64−1 leaves.
    - On a non-empty one, the call fails with "too many leaves" after mutating the frontier.
- **Scenario:** A downstream Lua tool (for example a dispute-node reference implementation built on `cartesi.hash-tree`) passes a wrong height, count or hash-type string, and commits to a wrong root without any error.
- **Evidence:**

  ```
  $ lua5.4 bugs/09-hash-tree-frontier-validation/test-hash-tree-frontier-validation.lua
  BUG REPRODUCED
    frontier_push_back(X, height=H+1): accepted (frontier now has 6 levels, expected 5)
    frontier_append({X}, height=H+1): accepted (frontier now has 6 levels, expected 5)
    frontier_pad_back(X, nil, pad_height=H+1): accepted (frontier now has 5 levels, expected 5)
    frontier_get_root_hash(pad=X, pad_height=H+1): accepted, returned the pad itself
    frontier_append({A,B,A,B,<table>,<table>}): failed but mutated the frontier
    frontier(2, "tohex"): accepted
    frontier_forest(2, "tohex"): accepted
    height-70 empty frontier_pad_back(count=-1): accepted (frontier now has 71 levels, expected 71)
    height-70 frontier_pad_back(count=-1) after one 2^63 subtree: failed but mutated the frontier
  ```

  Randomized differential tests of the forest and frontier code against a naive reference (keccak256 and sha256, heights 0–62, thousands of iterations) found no wrong roots, node hashes or proofs for valid inputs.
- **Possible solution:**
  - Assert that `height` and `pad_height` are integers in [0, #frontier−1] in all four functions.
  - Validate the whole range in `frontier_append` before mutating, as `normalize_hash_range` does for the forest.
  - Allow-list the hash type to {`keccak256`, `sha256`} in `frontier_genesis` and `frontier_forest`.
  - Assert that `count` is a non-negative integer in `frontier_pad_back`.
- **Risks:**
  - Of fixing: none, since only checks are added before mutation.
  - Of not fixing: a silently wrong Merkle root for library users who pass bad arguments.

---

<a id="bug-10"></a>
## BUG-10: Corrupted page hash-tree cache with a cyclic LRU list hangs machine load forever

- **Severity:** Low. It needs a corrupted or crafted stored machine; a crash cannot plausibly produce it, because the list unlinks before it links.
- **Area:** Persistence / page hash-tree cache (`.phtc`) loading
- **Category:** DoS / hang on corrupted input
- **Introduced by branch:** No (the constructor is identical on `origin/main`).
- **Where:** `src/page-hash-tree-cache.hpp:471-483`: the validation loop `for (auto &e : m_lru)` has no iteration bound. The header-size check at line 458 does not help.
- **Problem:** The constructor intends to reject corrupted cache files ("corrupted page hash-tree cache"). An LRU `next` chain that loops without returning to the list root passes every pointer and alignment check, and makes the load spin at 100% CPU forever.
- **Scenario:** A node loads a stored machine received from elsewhere, or one damaged by disk corruption, and hangs instead of failing.
- **Evidence:**

  ```
  $ lua5.4 bugs/10-phtc-lru-cycle-hang/phtc-lru-cycle-hang.lua
  rc=124
  BUG REPRODUCED: loading a page hash-tree cache with a cyclic LRU list hangs
  ```
- **Possible solution:**
  - Inside the loop, throw once `++list_size > num_entries` ("LRU list too long or cyclic").
  - Optionally validate the `prev` links, and check that `(addr - begin) % sizeof(entry) == 0`, not just 8-byte alignment.
- **Risks:**
  - Of fixing: none.
  - Of not fixing: a hang on corrupted or crafted stored machines.

---

<a id="bug-11"></a>
## BUG-11: CLI `--mcycle-computation-hash` bundle-size check overflows; the CLI spins forever instead of rejecting the option

- **Severity:** Low. It needs an absurd option value, the result is a local hang, and it never produces a wrong hash.
- **Area:** `cartesi-machine` CLI option validation
- **Category:** Validation / DoS (hang)
- **Introduced by branch:** No. The option is new on the branch (it replaces `--cmio-advance-state` sub-options), but `origin/main` has the identical unchecked addition (`cartesi-machine.lua:1949` there).
- **Where:**
  - `src/cartesi-machine.lua:2841-2850` (`check_mcycle_computation_hash_options`).
  - The spin happens in `src/cartesi/hash-tree.lua:118-131` (`frontier_get_leaf_count`), called from `initialize_mcycle_computation_hash`.
- **Problem:** `log2_mcycle_period + log2_bundle_mcycle_count <= 48` uses signed Lua integers, so `1 + 0x7fffffffffffffff` wraps to a negative value and the check passes. `input_height` then becomes hugely negative, and `frontier_get_leaf_count` loops about 2^63 times.
- **Scenario:** A typo, or a script forwarding an unchecked value, such as `--mcycle-computation-hash=log2_mcycle_period:1,log2_bundle_mcycle_count:0x7fffffffffffffff`, hangs the CLI instead of failing with "computation hash bundle cannot exceed the mcycles of an input".
- **Evidence:**

  ```
  $ bash bugs/11-cli-computation-hash-overflow/cli-computation-hash-overflow.sh
  control (log2_bundle_mcycle_count:48) exit=1: computation hash bundle cannot exceed the mcycles of an input ...
  overflow (log2_bundle_mcycle_count:0x7fffffffffffffff) exit=137
    | Warning: computation hash tree height 71 exceeds 63
    | Loading machine: please wait
  BUG REPRODUCED: CLI accepted the overflowing option and spun until killed
  ```
- **Possible solution:** Check each operand separately, without adding first: `log2_bundle_mcycle_count >= 0 and log2_bundle_mcycle_count <= ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE - log2_mcycle_period`.
- **Risks:**
  - Of fixing: none.
  - Of not fixing: the CLI hangs on bad input.

---

## Other observations (not counted as bugs)

These came out of the review but are documented design or are already on `main` with no new exposure. They are listed so that release notes or follow-up issues can address them.

- **`send_cmio_response` no longer reports host misuse (88df5f7, documented in `cm.h` and the CHANGELOG).** Three misuses that used to error now succeed and do nothing:
  - an advance input sent to a machine at an rx-rejected yield (the host forgot to revert);
  - an oversized advance input;
  - a garbage revert hash at a no-op boundary.

  A host that forgot to revert used to fail loudly. Now it silently records every later input as rejected, while the dispute-canonical path reverts. It is consistent with the provable transition, and the host can still detect it with `receive_cmio_request` or `iflags.Y`, but a release note is advisable. BUG-02 and BUG-07 are the concrete traps that come from this change.
- **The `get_data_root_hash("")` rename keeps old behaviour:** it returns `nil` instead of the pristine root.
- **Pre-existing on `main`, untouched by the branch:**
  - `frontier(proof)` with `target_address = -1` loops forever.
  - gdbstub `_handle_write_mem` inverts its OK/error replies.
  - A gdbstub breakpoint at the pc after a manual yield cannot be stepped past.
  - The GDB `k` packet exits without cleaning up the fork snapshot server.
  - `--print-uarch-cycle-root-hashes=<n>` without `start:` on a loaded machine whose mcycle is already ≥ n prints nothing and exits 0.

## Areas verified correct

These are the main things the review checked, all by running code, that matter most for downstream users:

- **`collect_mcycle_bundle`:**
  - Every bundle equals the corresponding slice of a sequential `collect_mcycle_root_hashes` run, locally and over JSON-RPC.
  - Cases covered: halt, manual and automatic yields, console output, mcycle overflow mid-period and on a bundle boundary, mcycle near `UINT64_MAX`, and period/bundle sizes up to (4,4).
- **`collect_uarch_cycle_bundle` and the rejected-yield-at-overflow change:**
  - Every bundle equals ground truth obtained by stepping with `log_step_uarch`/`verify_step_uarch` and `log_reset_uarch`/`verify_reset_uarch`, across 15 scenarios.
  - The removal of the `!at_mcycle_overflow` guard aligns collection with `uarch_reset_state`. `main` was inconsistent in that case.
- **`send_cmio_response` vs `log_send_cmio_response` + `verify_send_cmio_response`:**
  - Identical post-state over 10,080 local and 5,040 JSON-RPC precondition combinations.
  - The new break-reason precedence is consistent across `run`, `log_step` and the `collect_*` functions, locally and remotely.
- **CLI `--mcycle-computation-hash` and `--uarch-cycle-computation-hash`:**
  - Output equals an independent reference that does not use `collect_*` or `cartesi.hash-tree`.
  - Covered: keccak256 and sha256, rejects, outputs, halts, exceptions, resumable epoch splits, and fork/stored/remote revert modes.
  - Exit codes and rolling-template output-root validation behave as documented.
- **Persistence changes on the branch:**
  - The page hash cache storage-length fix and the archive version bump are consistent; 144 store, load and clone combinations match a never-stored reference.
  - The `O_CLOEXEC` change only affects short-lived descriptors.
- **Lua bindings:**
  - `machine:move()` (local and remote, including server lifetime), tuple schemas and `util.protect` are correct and clean under valgrind.
