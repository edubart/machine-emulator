# Emulator bugs found reviewing `feature/prt`

Review of the emulator C/C++/Lua sources that ship in the emulator package (libcartesi C API, JSON-RPC remote machine,
Lua libraries, and the `cartesi-machine` CLI) on branch `feature/prt` against `main`. It covers bugs the branch
introduces and bugs that already existed in the APIs it touches or that the PRT validator node uses. The PRT node itself
(`doc/recipes/prt*.lua`) was not reviewed.

Each issue was proposed by a bug-hunting agent, reproduced by a separate agent with a test case, and confirmed by
independent reviewers who tried to disprove it. Issues are numbered in the order they were confirmed. The summary table is sorted by severity.

Severity scale:

- **critical**: can make an honest PRT player lose a dispute, or produce wrong or nondeterministic hashes or proofs.
- **high**: crashes, hangs, or corrupts stored state for a validator in realistic use.
- **medium**: wrong results or crashes in less common but legitimate use.
- **low**: minor.

Proofs of concept live under `bugs/<id>/`. Run them from the repo root after building (`make`) with the environment
from `eval $(make -s env)` and `CARTESI_IMAGES_PATH` pointing at a directory with `linux.bin` and `rootfs.ext2`.
A test exits non-zero and prints a `BUG:` line while the bug is present.

## Summary

40 confirmed issues: 4 high, 10 medium, 26 low.

| # | Severity | Origin | Area | Issue | Proof of concept |
|---|---|---|---|---|---|
| [B01](#b01-persisted-page-cache-is-not-checked-against-memory-so-a-reload-yields-wrong-proofs) | high | pre-existing | Hash tree (page cache, store/load) | Persisted page cache is not checked against memory, so a reload yields wrong proofs | `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/` |
| [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong) | high | introduced by branch | Hash tree (page cache, dense trees, crash consistency) | Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong | `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/` |
| [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files) | high | introduced by branch | Lua cartesi.hash-tree and cartesi.filesystem (durable writes) | frontier_forest_store and fs.sync_file ignore write errors and commit truncated files | `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/` |
| [B32](#b32-interrupted-store-or-clone_stored-leaves-a-torn-page-cache-that-loads-silently-and-gives-wrong-hashes) | high | pre-existing | Hash tree (page cache), stored machine API | Interrupted store or clone_stored leaves a torn page cache that loads silently and gives wrong hashes | `bugs/api-05-torn-phtc-silent-wrong-hash/` |
| [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree) | medium | pre-existing | Hash tree (sparse tree, crash consistency) | Crash in sparse-tree update freezes the root hash of a shared hash tree | `bugs/ht-03-persisted-sparse-marked-flag-stale-root/` |
| [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages) | medium | introduced by branch | Hash tree (clear_hash_tree) | Crash during clear_hash_tree leaves zeroed hashes on clean pages | `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/` |
| [B07](#b07-interrupted-remove_stored-leaves-a-directory-that-blocks-the-name-forever) | medium | pre-existing | Stored machine API | Interrupted remove_stored leaves a directory that blocks the name forever | `bugs/ht-09-remove-stored-not-idempotent/` |
| [B09](#b09-json-rpc-server-exits-when-an-error-message-contains-invalid-utf-8) | medium | pre-existing | JSON-RPC remote machine server | JSON-RPC server exits when an error message contains invalid UTF-8 | `bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/` |
| [B10](#b10-spawned-json-rpc-servers-inherit-client-sockets-so-concurrent-spawns-fail) | medium | pre-existing | JSON-RPC client (spawn_server) | Spawned JSON-RPC servers inherit client sockets, so concurrent spawns fail | `bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/` |
| [B12](#b12-frontier_forest_store-drops-expansions-under-single-value-fixed-point-trees) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | frontier_forest_store drops expansions under single-value fixed-point trees | `bugs/lua-02-store-skips-expanded-single-value-tree/` |
| [B13](#b13-lazily-loaded-forest-used-as-a-value-loses-its-unloaded-subtrees) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | Lazily loaded forest used as a value loses its unloaded subtrees | `bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/` |
| [B14](#b14-forest-tree-files-keyed-only-by-hash-collide-across-heights-and-representations) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | Forest tree files keyed only by hash collide across heights and representations | `bugs/lua-04-content-addressing-ignores-height-and-representation/` |
| [B17](#b17-abi-decoder-rejects-canonical-empty-arrays-of-dynamic-types) | medium | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder rejects canonical empty arrays of dynamic types | `bugs/lua-09-evmu-decode-empty-dynamic-element-array/` |
| [B35](#b35-collect_uarch_cycle_-reset-shortcut-diverges-from-reset_uarch-when-uarch-ram-is-not-the-built-in-image) | medium | pre-existing | Machine API (uarch cycle collection) | collect_uarch_cycle_* reset shortcut diverges from reset_uarch when uarch RAM is not the built-in image | `bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/` |
| [B05](#b05-cartesifilesystemwrite_file-ignores-close-errors-cli-writes-empty-hash-files) | low | pre-existing | Lua cartesi.filesystem, CLI | cartesi.filesystem.write_file ignores close errors, CLI writes empty hash files | `bugs/ht-08-filesystem-write-file-swallows-close-errors/` |
| [B08](#b08-clone_stored-fails-with-emlink-instead-of-falling-back-to-a-copy) | low | pre-existing | Stored machine API, cartesi.filesystem | clone_stored fails with EMLINK instead of falling back to a copy | `bugs/ht-10-clone-stored-emlink-no-fallback/` |
| [B11](#b11-json-rpc-request-with-an-invalid-id-is-rejected-but-still-executed) | low | pre-existing | JSON-RPC remote machine server | JSON-RPC request with an invalid id is rejected but still executed | `bugs/rpc-03-jsonrpc-invalid-id-still-executes/` |
| [B15](#b15-frontierlast_proof-hangs-on-the-last-leaf-of-a-64-bit-tree-and-does-not-validate-the-proof) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier(last_proof) hangs on the last leaf of a 64-bit tree and does not validate the proof | `bugs/lua-05-frontier-from-proof-hang-and-no-validation/` |
| [B16](#b16-verify_slice-and-verify_splice-accept-malformed-proofs) | low | pre-existing | Lua cartesi.hash-tree (proof verification) | verify_slice and verify_splice accept malformed proofs | `bugs/lua-06-verify-slice-noncanonical-address/` |
| [B18](#b18-abi-decoder-bounds-checks-overflow-and-accept-out-of-bounds-offsets) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder bounds checks overflow and accept out-of-bounds offsets | `bugs/lua-10-evmu-offset-length-overflow-accepts-oob/` |
| [B19](#b19-abi-type-parser-mangles-parameter-names-starting-with-memory-storage-or-calldata) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI type parser mangles parameter names starting with memory, storage or calldata | `bugs/lua-11-evmu-param-name-data-location-prefix-mangled/` |
| [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_next_proofs does not check tree capacity | `bugs/lua-12-next-proofs-no-capacity-check/` |
| [B21](#b21-frontier_next_proofs-is-wrong-on-trees-of-height-64-or-more) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_next_proofs is wrong on trees of height 64 or more | `bugs/lua-13-next-proofs-signed-compare-ge64/` |
| [B22](#b22-frontier_pad_back-rejects-valid-counts-and-corrupts-very-tall-frontiers) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_pad_back rejects valid counts and corrupts very tall frontiers | `bugs/lua-14-pad-back-tall-tree-size-wrap/` |
| [B23](#b23-json-rpc-protocol-version-not-bumped-for-the-new-clear_hash_tree-api) | low | introduced by branch | JSON-RPC client and server | JSON-RPC protocol version not bumped for the new clear_hash_tree API | `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/` |
| [B24](#b24-temporary-and-frontier-files-are-created-with-mode-0600-and-without-atomic-o_cloexec) | low | introduced by branch | Lua cartesi.filesystem and cartesi.hash-tree, CLI | Temporary and frontier files are created with mode 0600 and without atomic O_CLOEXEC | `bugs/rpc-07-frontier-files-mode-0600/` |
| [B25](#b25---clear-hash-tree-is-reapplied-on-every-stored-mode-revert) | low | introduced by branch | CLI | --clear-hash-tree is reapplied on every stored-mode revert | `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/` |
| [B26](#b26---clear-hash-tree-is-silently-ignored-for-existing-remote-machines) | low | introduced by branch | CLI | --clear-hash-tree is silently ignored for existing remote machines | `bugs/rpc-09-clear-hash-tree-ignored-existing-remote/` |
| [B27](#b27---dump-memory-ranges-runs-mkdir-through-the-shell-with-an-unquoted-path) | low | pre-existing | CLI | --dump-memory-ranges runs mkdir through the shell with an unquoted path | `bugs/rpc-10-dump-memory-ranges-shell-mkdir/` |
| [B28](#b28-get_data_root_hash-returns-nil-for-empty-data-and-rejects-root-sizes-63-and-64) | low | pre-existing | Lua cartesi.hash-tree | get_data_root_hash returns nil for empty data and rejects root sizes 63 and 64 | `bugs/lua-16-get-data-root-hash-empty-nil/` |
| [B29](#b29-frontier-api-accepts-heights-above-the-tree-height-and-silently-grows-the-frontier) | low | pre-existing | Lua cartesi.hash-tree (frontier) | Frontier API accepts heights above the tree height and silently grows the frontier | `bugs/lua-17-frontier-height-args-unvalidated/` |
| [B30](#b30-verify_hash_tree-returns-true-when-inner-nodes-or-the-root-are-corrupted) | low | pre-existing | Hash tree (verify_hash_tree) | verify_hash_tree returns true when inner nodes or the root are corrupted | `bugs/api-03-verify-hash-tree-misses-inner-nodes/` |
| [B31](#b31-a-failed-expansion-store-is-never-retried-by-later-frontier_forest_store-calls) | low | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | A failed expansion store is never retried by later frontier_forest_store calls | `bugs/lua-20-failed-expansion-store-never-retried/` |
| [B33](#b33-lua-bindings-call-lual_error-inside-c-catch-handlers-and-leak-the-exception) | low | both | Lua bindings (clua-*.cpp) | Lua bindings call luaL_error inside C++ catch handlers and leak the exception | `bugs/lua-22-lual-error-in-catch-leaks-exceptions/` |
| [B34](#b34-frontier-stores-fail-for-files-directly-under-the-filesystem-root) | low | introduced by branch | Lua cartesi.hash-tree (frontier store) | Frontier stores fail for files directly under the filesystem root | `bugs/lua-24-hash-tree-root-parent-directory/` |
| [B36](#b36-temporary-files-from-killed-stores-are-never-cleaned-up) | low | introduced by branch | Lua cartesi.hash-tree (frontier store) | Temporary files from killed stores are never cleaned up | `bugs/lua-25-leftover-temp-files/` |
| [B37](#b37-filesystemtemp_pathname-returns-a-deleted-tmp-name-that-another-user-can-claim) | low | introduced by branch | Lua cartesi.filesystem | filesystem.temp_pathname returns a deleted /tmp name that another user can claim | `bugs/lua-27-temp-pathname-toctou/` |
| [B38](#b38-abi-decoder-accepts-dirty-address-bits-and-non-zero-padding) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder accepts dirty address bits and non-zero padding | `bugs/lua-28-evmu-lenient-dirty-bits-padding/` |
| [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset) | low | pre-existing | Machine API (uarch cycle collection) | collect_uarch_cycle_* aborts the process when the uarch is halted but not reset | `bugs/api-09-collect-uarch-halted-uarch-assert-abort/` |
| [B40](#b40-over-long-revert_uarch_tail-aborts-on-an-assert-or-yields-an-invalid-mcycle-subtree) | low | pre-existing | Machine API (uarch cycle collection) | Over-long revert_uarch_tail aborts on an assert or yields an invalid mcycle subtree | `bugs/api-10-collect-uarch-revert-tail-length-unvalidated/` |

## Issues

### B01. Persisted page cache is not checked against memory, so a reload yields wrong proofs

**Title**: Persisted page hash-tree cache keeps stale entries after a mixed-sharing session, so get_proof and uarch-cycle root hashes come out wrong while get_root_hash and verify_hash_tree pass

**Problem**: The page hash-tree cache (phtc) is reused across store/load with no check that its entries still match the memory of the range they describe. The only guard is in the `hash_tree` constructor. It evicts an entry only when the range's `shared` flag *in the session now loading* differs from the cache's `shared` flag. Entries go stale in an earlier session, one where the phtc and a range were persisted differently. Two cases:
- RAM shared, hash tree private: writes reach the RAM `.bin/.dht/.dpt` files, but the phtc on disk keeps the old page hashes.
- Hash tree shared, RAM private: the phtc gets hashes for content that is never written to the RAM file.

On disk, the range's dirty-page tree still says the page is clean. A later load whose flags match (`SHARING_NONE`, or `SHARING_ALL`) evicts nothing. The cache-hit paths then trust the stale entry:
- `get_page_proof`, used by `get_proof`, reads the target and sibling hashes from the entry.
- `update_words`, used by `collect_uarch_cycle_root_hashes` and by other uarch/step paths, rehashes only the written words on top of the stale cached page.
- `get_dense_node_hash` has the same exposure. It was read in the code but not exercised by a test.

`get_root_hash` stays correct because it comes from the dense hash tree. `verify_hash_tree` returns true because it inspects the cache only for pages that are not marked dirty but differ from the `.dht`, and never compares the cache entries of clean pages against memory.

**Origin**: Pre-existing. The same eviction logic and the same hit paths are on `origin/main`.

**Area**: Page hash-tree cache / hash-tree load and store (C++ core, reached through the C and Lua APIs and the `cartesi-machine` CLI `--load`/`--store`).

**Category**: Correctness. The proofs and state commitments are wrong, and nothing reports a problem.

**Location**:
- `src/hash-tree.cpp:1003-1008`: `evict_entries_if` in the `hash_tree` constructor compares only the current session's `ar.has_shared_backing_store()` with the cache's `shared` flag.
- `src/machine.cpp:476-487`: `machine::store` writes the phtc separately from each range's persistence.
- `src/page-hash-tree-cache.hpp:440-455`: loading a persisted cache marks every stored entry as valid.
- `src/hash-tree.cpp:99-133`: the `get_page_proof` cache-hit path.
- `src/hash-tree.cpp:810-830`: the `update_words` cache-hit path, which hashes only the changed words.
- `src/hash-tree.cpp:649-713`: `hash_tree::verify` does not check cached entries of clean pages.

**Evidence**: Both tests compare the machine against a reference loaded from the same directory with `clear_hash_tree = true`, which recomputes everything from memory.

In `test-proof.lua`, all three cases (two routes, three final loads) give the correct root hash and `verify_hash_tree=true`. In every case, the `get_proof(RAM, 5)` target and sibling hashes differ from the reference proof, and the proof does not even roll up to its own `root_hash`. The reference proof does roll up.
```
[A(ram shared, cache private) SHARING_NONE] mem=BBBB root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
[B(cache shared, ram private) SHARING_NONE] mem=AAAA root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
[B(cache shared, ram private) SHARING_ALL] mem=AAAA root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
```
In `test-uarch-cycle.lua`, the machine is created in a directory with `ram.backing_store.shared=true`, which is the default hash-tree config. A host write follows, in a `SHARING_CONFIG` session. The final load runs a three-instruction program whose `sd` writes into the stale page. In the run, 688 of the 2109 uarch-cycle root hashes differ, starting at index 1422, where the store happens. The initial and final roots match, and `verify_hash_tree` is true before and after. Two reference runs give identical hashes, so the results are deterministic.
```
[SHARING_NONE] initial_root_ok=true verify_before=true uarch_hashes=2109/2109 differing=688 first_differing=1422 final_root_ok=true verify_after=true
[SHARING_ALL] initial_root_ok=true verify_before=true uarch_hashes=2109/2109 differing=688 first_differing=1422 final_root_ok=true verify_after=true
```
Run command: `eval $(make -s env); lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua; lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua`. Each test exits 1 while the bug is present.

**Scenario**: A validator or an operator keeps snapshot directories made with per-range sharing that differs from `hash_tree.shared`. Examples:
- A machine created in a directory with a shared RAM or flash drive while the hash tree keeps its default `shared=false`.
- A shared hash tree with private ranges.

The directory is opened once with `SHARING_CONFIG`, which is the CLI `--load` default, and modified. Examples: `send_cmio_response`, `write_memory`, or running the machine. Later the same directory, or a copy of it, is loaded with `SHARING_ALL` (as `prt.lua` does) or `SHARING_NONE`. From then on:
- `get_proof` returns Merkle proofs that fail on-chain verification.
- `collect_uarch_cycle_root_hashes` produces wrong leaf-level commitments.

The honest player then commits to, or tries to prove, a state that does not match the real execution, and loses the PRT dispute. Every integrity check passes: the root hash matches and `verify_hash_tree` returns true. The bundled PRT node always uses `SHARING_ALL` with `clone_stored`, so it does not trigger this by itself. Other nodes, and mixed workflows through the CLI, can.

**Possible solution**: Make cache validity independent of the sharing mode of the session that is loading now. Options:
- Record per-range persistence or a generation id, for example a hash of the `.dht` root, in the phtc header. On load, evict the entries of any range whose recorded value does not match.
- In `machine::store`, and when loading, evict the entries of every range whose persistence differs from the cache's, so a mixed session can never leave a phtc that disagrees with the range files.
- As a cheap safety net, on load check each cached clean page's root against the `.dht` page hash and evict on mismatch. Also make `verify_hash_tree` check the cache entries of clean pages against memory.

**Severity**: High. When it triggers, the impact is critical in kind: Merkle proofs and uarch-cycle commitments are silently wrong, and an honest player can lose a dispute. Both reviewers rated it high rather than critical because it needs a mixed-sharing session followed by a load with matching flags, which the default flows (uniform `SHARING_ALL`, or everything private) do not do.

**Risks**:
- Of the bug: it fails silently. No API detects it, it persists in the directory and every copy of it, and it corrupts proofs and step or uarch commitments, not the root hash.
- Of the fix: evicting more often only costs rehashing time. A header or format change to the phtc needs a version bump and invalidates existing cache files, which is acceptable. A check on load that compares cached roots with the `.dht` adds O(cached pages) work when loading.

**Proof of concept**: `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua` (get_proof, both routes) and `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua` (collect_uarch_cycle_root_hashes). Run them from the repo root with `eval $(make -s env); lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua && lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua`. Both use temporary directories under the system temp dir, create a phtc file of about 50 MB, and print `BUG:` lines and exit 1 while the bug is present.

**ID**: `ht-02-phtc-stale-entries-after-mixed-sharing-session`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `api-06-persisted-phtc-not-validated-against-backing`: run with `eval $(make -s env); lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-replace-memory-range.lua; lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-mixed-sharing.lua`. It adds a second, more common trigger: `replace_memory_range` on a machine loaded with `SHARING_ALL` writes the new image's page entries into the shared `hash_tree.phtc` while the stored range files still describe the old image. Reloading the directory with `SHARING_ALL` then gives wrong `get_proof`, `get_node_hash` and uarch-cycle root hashes, with a correct `get_root_hash`. No mixed-sharing session is needed.

### B02. Crash in sparse-tree update freezes the root hash of a shared hash tree

**Title**: A crash inside `update_sparse_tree` leaves transient `marked` flags and stale inner hashes in a shared `hash_tree.sht`; the loader accepts them and the root hash stays silently wrong (`verify_hash_tree` still returns true)

- **Problem**: `update_sparse_tree` uses `node.marked` in the sparse nodes as a transient "already queued" flag. It sets the flag when it pushes a node and clears it only when it pops that node, and it enqueues a parent only when `marked == 0`. The sparse nodes live directly in the `hash_tree.sht` mapping, which is `MAP_SHARED` when a machine is stored or loaded with `SHARING_ALL` or backed by a directory. If the process dies between push and pop, the file keeps `marked = 1`. The loading constructor rejects only `marked > 1`. It never resets the flag and never rehashes inner nodes. From then on that node (for example the root) is never enqueued again, so its hash is frozen across every later update. A kill can also land after the address-range leaf hashes were copied but before the inner nodes were rehashed (the SIMD queue defers hashing until `flush()`). On reload the leaves already match the dense roots, so nothing is enqueued and the stale inner nodes and root survive even when the flag is 0. `verify_hash_tree` never checks sparse inner nodes or the root against their children. Its leaf-vs-dense-root mismatch branch only prints a message and does not set `ret = false`, so it returns true on the corrupted tree. Only `cm_clear_hash_tree` (`hash_tree::clear`) repairs it.
- **Origin**: pre-existing. The branch did not introduce the flag logic.
- **Area**: hash tree, sparse tree (`hash_tree` loading constructor, `update_sparse_tree`, `verify`); C API `cm_load_new`/`cm_get_root_hash`/`cm_get_proof`/`cm_log_step`/`cm_verify_hash_tree` and the Lua bindings, on machines that use `SHARING_ALL` or on-disk storage.
- **Category**: correctness (crash consistency / silent hash corruption)
- **Location**:
  - `src/hash-tree.cpp:962-972`: the constructor maps an existing sht, accepts `marked <= 1`, and does not reset the flag or rehash inner nodes.
  - `src/hash-tree.cpp:497-569`: `update_sparse_tree` sets `marked = 1` on push (lines 515-518, 530-533, 559-562), clears it only on pop (line 550), and enqueues only when `marked == 0`.
  - `src/hash-tree.cpp:650-713`: `verify` ignores sparse inner nodes and the root, and the leaf-mismatch branch (lines 704-706) does not fail.
  - `src/hash-tree.cpp:717-727`: `clear` is the only code that zeroes `marked`.
  - `src/hash-tree.cpp:729-740`: `update` cleans the dirty page trees only after a full successful update. The dense part is redone after a crash; the sparse part is not.
- **Evidence**: Part A of `test.lua` makes a real kill. A child process loads a 1 MiB machine stored with `SHARING_ALL`, writes `"hello"` and calls `get_root_hash`. gdb sets a hardware watchpoint on the root node's `marked` field (sht offset 64+28) in the mapping. It fires inside `update_sparse_tree` (`hash-tree.cpp:562`, called from `machine::update_hash_tree`), and gdb sends SIGKILL. The file on disk is left with root `marked = 1`. After reload with `SHARING_ALL`, the root hash differs from a fresh machine with identical RAM. It stays wrong after more writes, and `verify_hash_tree` keeps returning true. Part B patches only the flag into an otherwise correct sht. The next write is then silently missing from the root hash.
  ```
  $ eval $(make -s env); lua5.4 bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua
  [A] root marked flag on disk after SIGKILL inside update_sparse_tree: 1
  [A] after reload           root_ok=false verify_hash_tree=true
  [A] after write 1          root_ok=false verify_hash_tree=true
  [A] after write 2          root_ok=false verify_hash_tree=true
  BUG: after a real SIGKILL inside update_sparse_tree, the reloaded SHARING_ALL machine reports a wrong root hash that stays wrong after further writes, while verify_hash_tree still says true
  [B] after reload        root_ok=true
  [B] after write         root_ok=false verify_hash_tree=true
  BUG: a persisted marked=1 on the root sparse node is accepted on load and freezes the root hash (write ignored)
  ```
  Extra experiment: zeroing the root flag in the killed directory before reload is not enough. The root is still wrong right after reload (`false`) and becomes correct only after the next write that changes a leaf.
- **Scenario**: A validator node (the in-branch PRT node, or Rollups Node / Dave if they persist machines with `sharing: all`) keeps its machine in a directory with `SHARING_ALL`. The CLI's `--revert-mode=stored` and the documented `sharing:all` workflow do the same. The node is SIGKILLed, OOM-killed or crashes while a hash-tree update is running (`get_root_hash`, `get_proof`, `log_step`, `store`, ...). After restart it reloads the directory. Every later root hash, proof and step log built from that machine carries a wrong state hash, and `verify_hash_tree` reports the tree as fine. Snapshots made by cloning the directory copy the corruption. A node that checks the reloaded root against a known hash, as `prt.lua` does, fails loudly at startup. Recovery then needs a non-obvious `cm_clear_hash_tree`. A node that trusts the reloaded root, or whose stale root happens to match the expected pre-update value while the root's flag is stuck, would commit to or prove wrong state, and an honest player could lose a dispute. Apps inside the machine are not affected; only the host-side hashes are wrong.
- **Possible solution**: When the constructor maps an existing sht, reset every `marked` to 0 and recompute all sparse inner nodes bottom-up from the leaves and pristine hashes. There are few sparse nodes, so this is cheap. Alternatively, treat any nonzero `marked` (or a persisted "update in progress" flag set before and cleared after `update_sparse_tree`) as a reason to rehash the whole sparse tree. Separately, make `verify` check every sparse inner node and the root against their children, and set `ret = false` on a leaf vs dense-root mismatch.
- **Severity**: medium. The corruption is silent, permanent and undetected by `verify_hash_tree`, and it yields wrong root hashes and proofs, which argues for high. But it needs a process death inside a short window (60 random kills never hit it), only on shared or on-disk hash trees, and nodes that check the reloaded root, like the reference PRT node, fail loudly instead of committing wrong state. Both reviewers rated it medium, and one noted that validators restarted by SIGKILL or the OOM killer could justify high.
- **Risks**: Bug: a validator silently commits to or proves a wrong state hash, or fails to restart with no clear cause, and cloned snapshots spread the corruption. Fix: rehashing the sparse tree on every load adds a small, bounded cost to load. It must use the configured hash function and handle pristine subtrees exactly as `update_sparse_tree` does, or it could itself produce wrong roots. Making `verify` stricter may start rejecting directories already corrupted in the field, which is the correct outcome but may surprise operators.
- **Proof of concept**: `bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua` (driver), `bugs/ht-03-persisted-sparse-marked-flag-stale-root/kill.py` (gdb script: watchpoint on the root `marked` field, then SIGKILL), `bugs/ht-03-persisted-sparse-marked-flag-stale-root/child2.lua` (child that loads, writes and hashes). Part A needs `gdb` and is skipped without it; Part B always runs. The test exits 1 when the bug reproduces. Run from the repo root:
  `eval $(make -s env); timeout 200 lua5.4 bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua`

**ID**: `ht-03-persisted-sparse-marked-flag-stale-root`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-14-sht-marked-freezes-root`: run with `eval $(make -s env); timeout 120 lua5.4 bugs/rpc-14-sht-marked-freezes-root/test.lua`.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B03. Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong

**Title**: A process kill during a hash-tree update of a SHARING_ALL machine corrupts the stored directory: it becomes unloadable even with clear_hash_tree=true, or it loads with a silently wrong root hash

**Problem**: When a machine is loaded with `SHARING_ALL`, or created in a directory, its hash-tree state lives in `MAP_SHARED` files: the page hash-tree cache (`hash_tree.phtc`), the dense hash trees (`.dht`) and the dirty page trees (`.dpt`). The updates to these files are not crash-safe. Two failure modes follow from a kill during an update.
- **Unloadable directory.** `update_dirty_pages` borrows a whole batch of cache entries (up to `phtc_size`, 2048 by default) and keeps them borrowed while every page in the batch is hashed. The per-entry `m_borrowed` flag and the intrusive LRU links are part of the persisted metadata. If the process is SIGKILLed, OOM-killed or stopped in that window, the file keeps `borrowed=1` entries. The new `check_metadata()` then throws `corrupted page hash-tree cache: borrowed entry` (or an LRU/payload-index error for half-spliced links) inside the `page_hash_tree_cache` constructor. That constructor runs first in the `hash_tree` constructor, which runs in the `machine` member-initializer list. The new `clear_hash_tree` runtime option runs only at the end of the `machine` constructor body, so it can never recover. The directory cannot be loaded with any sharing mode, and copies made by `clone_stored` inherit the problem. Deleting `hash_tree.phtc` fails too (`unable to open backing file`). The only repair is to replace it by hand with an all-zero file of the same size. Even `get_root_hash` on a freshly loaded machine is enough to open the window, because `mark_always_dirty_pages` always marks pages dirty.
- **Silently wrong root hash.** `return_updated_dirty_pages` writes each new page hash into the persisted `.dht` leaf. The DPT is cleaned only after `update_dense_trees` and `update_sparse_tree` both succeed. After a kill inside `update_dense_trees`, no entry is borrowed, so the phtc passes validation and the directory loads normally. On the next update, each recomputed page hash already equals the stored leaf, so `changed=false` and `mark_clean_page_and_up` clears the dirty bits without ever recomputing the stale inner dense nodes or the sparse nodes above them. `get_root_hash()` returns a wrong root, and `verify_hash_tree()` still returns true, because it checks page leaves and sparse roots but not dense inner nodes. Only a load with `clear_hash_tree=true` gives the right root. The same wrong root appears after the manual "zero the phtc" repair unless `clear_hash_tree=true` is also used.

The phtc is only a cache, so rejecting the whole stored machine because of it is disproportionate.

**Origin**: Introduced by this branch for the unloadable directory: `check_metadata()` and the `clear_hash_tree` runtime option are new. On `main`, load accepted the stale flags, but `borrow_entry` later threw `already borrowed`, so hashing failed there too. The silent wrong-root mechanism (`.dht` leaves persisted before the DPT is cleaned, plus the `mark_clean_page_and_up` shortcut) appears to be pre-existing for `SHARING_ALL` directories. It was not run against a `main` build.

**Area**: Hash tree persistence: page hash-tree cache, dense hash trees and dirty page trees of stored machines; machine constructor (`clear_hash_tree` runtime option). Reached through the C API (`cm_load_new`, `cm_get_root_hash`, `cm_get_proof`, ...), the Lua API and the `cartesi-machine` CLI.

**Category**: Durability / crash safety. Leads to denial of service (unloadable snapshot) or to a silently wrong state commitment.

**Location**:
- `src/page-hash-tree-cache.hpp:440-456`: the constructor calls `check_metadata()` on an initialized file.
- `src/page-hash-tree-cache.hpp:689-724`: `check_metadata()` rejects borrowed entries (698-700), invalid payload indices and broken LRU links.
- `src/hash-tree.cpp:380-431`: `update_dirty_pages` keeps a whole batch borrowed while hashing.
- `src/hash-tree.cpp:946-948`: `m_page_cache` is the first member constructed by `hash_tree`.
- `src/machine.cpp:303` and `316-318`: `m_ht` is built in the initializer list; `clear_hash_tree()` runs only at the end of the body.
- `src/hash-tree.cpp:316-320`: persisted `.dht` page leaves are overwritten before the update is complete.
- `src/hash-tree.cpp:340-352`: the "unchanged, mark clean and up" shortcut.
- `src/hash-tree.cpp:731-739`: the DPT is cleaned only after the dense and sparse updates succeed.
- `src/hash-tree.cpp:650-713`: `hash_tree::verify` does not check dense inner nodes.

**Evidence**: The test stores a 64 MiB machine with `SHARING_ALL`. A child process loads it with `SHARING_ALL`, writes all of RAM and calls `get_root_hash`. A gdb breakpoint SIGKILLs the child at an exact point. The reference root comes from a fresh machine with the same RAM contents. Run with `eval $(make -s env); lua5.4 bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua` (about 10 s, exits 1 while the bug is present):
```
case 1: SIGKILL inside hash_tree::return_updated_dirty_pages (3rd batch borrowed, 2 batches returned)
  borrowed entries persisted in hash_tree.phtc: 2048
  load SHARING_ALL                          -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_NONE                         -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_NONE + clear_hash_tree=true  -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_ALL + clear_hash_tree=true   -> FAILED: corrupted page hash-tree cache: borrowed entry
  after zeroing hash_tree.phtc by hand:
  load SHARING_ALL                          -> ok, root ~= expected
  load SHARING_NONE + clear_hash_tree=true  -> ok, root == expected
case 2: SIGKILL inside hash_tree::update_dense_trees (all page entries returned)
  borrowed entries persisted in hash_tree.phtc: 0
  load SHARING_NONE -> ok; root ~= expected; verify_hash_tree() = true
  with clear_hash_tree=true root == expected
case 3: load with clear_hash_tree=true after persisting one borrowed flag -> FAILED: corrupted page hash-tree cache: borrowed entry
```
Earlier timed kills (no gdb) of a 64 MiB loop made the later load fail in 5 of 6 runs, and a 256 MiB variant killed after 0.3 s also failed.

**Scenario**: A validator (Rollups Node, Dave, a PRT player) runs a stored machine in place with `SHARING_ALL`, as `prt.lua` and the README's disk-based driver do, and reopens its directories after a crash. A SIGKILL, OOM kill, container stop or restart arrives during `get_root_hash`, `get_proof`, `log_step`, `collect_*_root_hashes` or a run that updates the hash tree. Hashing a large RAM takes seconds, so the window is wide. On restart:
- either `cm_load_new(dir, {"clear_hash_tree":true}, ...)` fails with `borrowed entry` under every sharing mode, the snapshot is unusable, and the node must replay from an older snapshot or wait for a manual repair, possibly missing dispute deadlines;
- or the directory loads and the node computes a wrong root hash and wrong proofs that `verify_hash_tree` does not flag. A node that does not compare the root against a known value commits to a wrong state and loses the dispute. `prt.lua` asserts the root against the expected state hash, so for that node it becomes a failure rather than a wrong commitment.

**Possible solution**:
- Treat the phtc as disposable: on any validation failure (borrowed entry, bad LRU link, bad payload index, tag mismatch), reinitialize the cache instead of throwing. Do not persist the borrowed flag (or clear all borrowed flags on load).
- Pass `clear_hash_tree` into the `hash_tree` / `page_hash_tree_cache` constructors so that validation is skipped and the cache is rebuilt before it is used.
- For the wrong-root mode, evicting borrowed entries is not enough. Persist an "update in progress" marker (set before the first `.dht` leaf write, cleared after the DPT is cleaned) and on load, if it is set, force a full rebuild or a bubble-up of all dirty pages instead of the "unchanged, mark clean" shortcut. Alternatively, do not take that shortcut for pages whose leaf may have been written by an interrupted update.
- Make `verify_hash_tree` also check dense inner nodes so the inconsistency is at least detectable.

**Severity**: High. Both reviewers rated it high: a routine process kill during an in-place `SHARING_ALL` update leaves the stored machine either unloadable, with the documented `clear_hash_tree` recovery ineffective, or loadable with a silently wrong root hash that `verify_hash_tree` accepts. The wrong-root mode approaches critical, but it requires a crash during an in-place update, and nodes that load immutable snapshots with `SHARING_NONE` or clone them first are not affected.

**Risks**:
- Of the bug: a validator cannot restart from its own snapshot without manual file surgery, or it silently computes wrong hashes and proofs. The corrupted state persists in the directory and in any `clone_stored` copy.
- Of the fix: reinitializing the cache costs only rehashing time. An "update in progress" marker or format change needs a phtc/dht version bump. A full rebuild on load after a crash can take a long time on large machines. Not persisting borrowed flags must not break concurrent hashing within one process.

**Proof of concept**: `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua`, with helpers `child.lua` (the process that gets killed) and `killat.py` (gdb Python script that sends SIGKILL at the N-th hit of a function). Run from the repo root with `eval $(make -s env); lua5.4 bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua`. It needs `gdb` with Python for the deterministic kill points; without gdb, case 1 falls back to a timed SIGKILL and case 2 is skipped. It uses a temporary directory under the system temp dir and prints `BUG:` lines and exits 1 while the bug is present.

**ID**: `ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-13-phtc-borrowed-unloadable`: run with `eval $(make -s env); lua5.4 bugs/rpc-13-phtc-borrowed-unloadable/test.lua; lua5.4 bugs/rpc-13-phtc-borrowed-unloadable/kill_test.lua 512`. Unloadable-directory mode.
- `rpc-12-crash-during-update-stale-dense`: run with `eval $(make -s env); lua5.4 bugs/rpc-12-crash-during-update-stale-dense/test_stale_dense.lua; bugs/rpc-12-crash-during-update-stale-dense/test_sigkill_gdb.sh`. Silent wrong-root mode (stale dense inner nodes).
- `api-02-phtc-borrowed-unrecoverable-even-with-clear`: run with `eval $(make -s env); lua5.4 bugs/api-02-phtc-borrowed-unrecoverable-even-with-clear/test.lua`. Unloadable-directory mode.
- `api-01-kill-during-hash-update-stale-root`: run with `eval $(make -s env); lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test.lua; lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test-boundary.lua`. Silent wrong-root mode. It also shows that the reloaded root is often exactly the root from before the interrupted write, so a node that compares against the previous known state hash would accept it, and that this mode is pre-existing on main.

**Related**: [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree), [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages).

### B04. Crash during clear_hash_tree leaves zeroed hashes on clean pages

**Title**: hash_tree::clear punches a range's .dht before marking its .dpt dirty, so a process kill mid-clear leaves a stored machine whose reload silently reports wrong root hashes and zero proofs

**Problem**: `hash_tree::clear` processes each address range in this order:
1. It zeroes the range's dense hash tree with `ar.get_dense_hash_tree().clear()`. For a shared `.dht` file this becomes `mapped_memory::clear`, which calls `fallocate(PUNCH_HOLE|KEEP_SIZE)` on the backing file.
2. Only afterwards does it mark the range's pages dirty in the `.dpt` with `mark_dirty_pages_and_up(0, bit_ceil(len))`, a per-page loop.

Everywhere else, the code keeps this rule: "a page marked clean in the `.dpt` has a valid `.dht`". For example, `hash_tree::update` writes the dense trees first and cleans the dpt last. The `memory_address_range` constructor marks everything dirty when it has to rebuild. `clear()` is the only path that breaks the rule, and it stays broken until the marking loop finishes. If the process dies after the punch and before the loop completes, the stored directory has zero dense hashes for pages the dpt still reports as clean. A later normal load skips those pages, and `update_sparse_tree` copies the zero dense root into the sparse tree. The root hash and proofs are then wrong, and no error is raised.

**Origin**: Introduced by this branch (commit ba0b00e, "add hash-tree cache clearing APIs and load option"). `origin/main` has no dense-tree clear.

**Area**: Hash tree cache maintenance (`hash_tree::clear`, `dense_hash_tree::clear`, `os::mapped_memory::clear`). It is reachable from `cm_clear_hash_tree`, from Lua `machine:clear_hash_tree()`, from the runtime option `clear_hash_tree=true` at load, and from CLI `--clear-hash-tree` with `--load=...,sharing:all`.

**Category**: Crash consistency / durability (silently wrong hashes and proofs).

**Location**:
- `src/hash-tree.cpp:717-728`: `ar.get_dense_hash_tree().clear()` runs before `ar.get_dirty_page_tree().mark_dirty_pages_and_up(...)`.
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear` punches a hole in the shared backing file.
- `src/dense-hash-tree.hpp:80-82`: `do_clear` forwards to `m_mapped_memory.clear()`.
- `src/machine.cpp:316-317`: `clear_hash_tree()` is called from the machine constructor when `runtime.clear_hash_tree` is set.

**Evidence**: An `LD_PRELOAD` shim (`killshim.c`) forwards `fallocate` to libc. When the call has just punched the RAM `.dht` (`0000000080000000-400000.dht`), the shim sends a real `SIGKILL`. That is the point between the two steps above. The child process uses only the public Lua API: `cartesi.machine(dir, {}, SHARING_ALL)` followed by `m:clear_hash_tree()`. The test then reloads the directory normally (`SHARING_NONE`, no clear):
```
shim: punched /tmp/tmp.ZmTjAdRIq9/work/m/0000000080000000-400000.dht, sending SIGKILL
child:	nil	exit	137
good root    :	b1f4d32d6c7704054d22d2045d055a0123e530464fbedaebd1bf7a8d67d4830a
reloaded root:	1034679ae63987d15e6b4119dff3bc0c11084ade2a3c6bf206a30e632f170c2d
ref root     :	b1f4d32d6c7704054d22d2045d055a0123e530464fbedaebd1bf7a8d67d4830a
BUG: reloaded machine's proof of RAM page 0 has target_hash 0000...0000 but the true page hash is 7cb685a7...9624
BUG: root hash after interrupted clear_hash_tree is wrong on reload
BUG: after one RAM write, reloaded machine root differs from correct root (stale zero dense hashes reused)
exit=1
```
The data is intact: reloading with `clear_hash_tree=true` rebuilds the correct root (`b1f4...`). Only the hash cache is inconsistent, and a normal load never runs `verify_hash_tree`. To run it: `eval $(make -s env); sh bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`. On a 2 GiB RAM machine, `clear_hash_tree` takes about 42 ms of CPU, and the window grows with RAM size.

**Scenario**: An operator or validator node (Rollups Node, Dave, or another PRT node) suspects its stored cache is bad. To scrub it, the node calls `cm_clear_hash_tree`, or it loads a `SHARING_ALL` directory with `clear_hash_tree=true` or CLI `--clear-hash-tree`. During that call the process is SIGKILLed, OOM-killed, or its container is stopped. On restart the node loads the same directory normally. It then reports a wrong state root, produces wrong proofs (a zero `target_hash` for RAM pages), and keeps computing wrong roots after further steps. An honest player could commit to or defend a wrong state and lose a dispute. Nothing errors, so the problem is not noticed. A node that always loads with `clear_hash_tree=true` repairs this on restart. The `prt.lua` node in this branch never calls `clear_hash_tree`.

**Possible solution**: In `hash_tree::clear`, call `get_dirty_page_tree().mark_dirty_pages_and_up(0, bit_ceil(len))` for a range before zeroing or punching its `.dht`. For power-loss safety, also msync the `.dpt` first. Alternatively, persist a durable "needs rebuild" flag before zeroing anything and clear it only after the operation finishes. With the order swapped, the same test exits 0: the dpt is already fully dirty at the kill point, so the reload rebuilds the tree.

**Severity**: Medium. Both reviewers agree. The impact is high: a stored machine silently reports a wrong state root and wrong proofs. Reaching it is unlikely, though. It needs an explicit, non-routine clear on a shared directory, a process death inside a window of a few to tens of milliseconds, and then a normal reload without a clear. The power-loss variant is not specific to this function: the README already says `sharing:all` directories need `sync` to survive a host crash.

**Risks**: Bug: a validator that keeps using the directory commits to or proves wrong states, with no error raised. `verify_hash_tree` (which normal load does not run) or another clear is the only thing that detects or repairs it. Fix: low risk. Marking the dpt dirty first only means a kill can leave extra dirty pages, which costs a rebuild and is always safe. An extra msync of the `.dpt` adds some latency to `clear_hash_tree`.

**Proof of concept**: `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`, `test.lua` and `killshim.c`. `run.sh` builds the shim into a temporary directory and runs `test.lua`. Run it from the repo root with `eval $(make -s env); sh bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`. It needs `gcc` and `lua5.4`, exits 1 with `BUG:` lines while the defect is present, and exits 0 once it is fixed.

**ID**: `ht-04-clear-hash-tree-zeroes-before-marking-dirty`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-11-clear-hash-tree-crash-order`: run with `eval $(make -s env); sh bugs/rpc-11-clear-hash-tree-crash-order/run.sh`.
- `api-07-clear-hash-tree-zeroes-before-marking-dirty`: run with `eval $(make -s env); sh bugs/api-07-clear-hash-tree-zeroes-before-marking-dirty/run.sh`.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B05. cartesi.filesystem.write_file ignores close errors, CLI writes empty hash files

**Title**: `cartesi.filesystem.write_file` reports success when the final flush fails, so CLI hash and proof files can be left empty

**Problem:** `filesystem.write_file` opens the file as a to-be-closed variable (`local f <close> = ...`), calls `assert(f:write(data))`, and never closes the file explicitly. For small payloads (32-byte hashes, proofs, reports) `f:write` only fills the stdio buffer, so it succeeds. The real `write(2)` happens in `fclose`, which runs from the `<close>` handler. Lua 5.4's file `__close` (the same function as `__gc`) throws away `fclose`'s result. So ENOSPC, EFBIG, EIO or quota errors are lost: `write_file` returns normally and leaves an empty or truncated file. `write_temp_file` wraps `write_file` in `pcall`, so it cannot see the error either. The CLI then exits 0.

**Origin:** Pre-existing. `util.write_file` on `origin/main` has identical code (`src/cartesi/util.lua:344-347`). This branch moved it into the new `cartesi.filesystem` module.

**Area:** Lua library `cartesi.filesystem` (exported to other projects) / `cartesi-machine` CLI.

**Category:** Durability / silent error loss.

**Location:**
- `src/cartesi/filesystem.lua:91-94` (`write_file`)
- `src/cartesi/filesystem.lua:103-109` (`write_temp_file`, and `write_scope_temp_file` through it)
- CLI callers in `src/cartesi-machine.lua`: 3214, 3287 (per-advance state hash files), 3486 and 3500 (proofs), 3587, 3606 (memory-range dumps), 3669 (`--initial-hash`), 4365, 4715 (`--final-hash`)
- Not affected: `hash-tree.lua` has its own `write_file` (temp file, sync, rename) for stored hash trees.

**Evidence:** `test_write_file_close.lua` writes 32 bytes to `/dev/full`. An explicit `f:close()` reports the error, but `fs.write_file` returns success:
```
$ lua5.4 bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua
explicit f:close() on /dev/full ->	nil	No space left on device
fs.write_file(32 bytes, /dev/full) ->	true	nil
BUG: cartesi.filesystem.write_file reported success although the data could not be written (ENOSPC on fclose was swallowed)
```
`test_cli_final_hash.sh` runs `cartesi-machine.lua --final-hash=...` with `ulimit -f 0` and SIGXFSZ ignored, so the write fails with EFBIG:
```
$ sh bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh
Halted
Cycles: 56481123
cli_exit=0
final.bin size=0
BUG: cartesi-machine exited 0 although the --final-hash file was not written (size=0)
```

**Scenario:** A script, CI job or operator tool runs `cartesi-machine --final-hash=final.bin` (or `--initial-hash`, state-hash, proof or dump outputs) on a host whose disk is full, over quota or failing. The CLI exits successfully and leaves a 0-byte or truncated file. Downstream tooling reads an empty or wrong hash or proof and may compare it, submit it or reject it with nothing pointing at the real cause. Lua projects that use `cartesi.filesystem.write_file`, `write_temp_file` or `write_scope_temp_file` (for example to stage input files for a run) can silently feed empty data into a later step after a host I/O failure.

**Possible solution:** Close explicitly and check the result. For example, keep `<close>` and add `assert(f:close())` after the write; closing an already-closed file in `__close` is harmless. Or:
```lua
function filesystem.write_file(data, filename)
    local f = assert(io.open(filename, "wb"))
    local ok, err = f:write(data)
    if ok then ok, err = f:close() else f:close() end
    assert(ok, err)
end
```
Audit other `<close>`-only write paths for the same pattern.

**Severity:** Low. Both reviewers agree. It only triggers on host-side write failures. Machine state and the hashes and proofs computed in memory are correct, and neither the C API nor the PRT hash-tree storage path is involved. The harm is output files left empty or truncated while the CLI reports success.

**Risks:** Bug: downstream consumers of CLI output files, or Lua library users, can act on empty or truncated hashes, proofs or inputs with no error raised. Fix: minimal. Callers that used to "succeed" on a failing disk will now raise an error, which is the intended behavior. `write_temp_file` already removes the file when it fails.

**Proof of concept:** `bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua` (library-level, needs `/dev/full`) and `bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh` (end-to-end CLI, needs the default Cartesi images). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua
eval $(make -s env); sh bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh
```
Both exit 1 while the bug is present and 0 once it is fixed.

**ID**: `ht-08-filesystem-write-file-swallows-close-errors`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-21-write-file-close-error-ignored`: run with `lua5.4 bugs/lua-21-write-file-close-error-ignored/test_write_file_close_error.lua`.

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files).

### B06. frontier_forest_store and fs.sync_file ignore write errors and commit truncated files

**Title**: hash-tree.lua `write_file` ignores `file:write` errors, so `frontier_forest_store` commits a truncated tree file that later stores never repair

**Problem:** The durable `write_file` helper in `cartesi.hash-tree` calls `temporary.file:write(contents)` and never checks the result. Lua's `file:write` does not raise on failure; it returns `nil, err`. When a large `fwrite` fails partway (ENOSPC, EFBIG, EDQUOT), glibc returns a short count and leaves nothing pending in the stdio buffer. The later `fs.sync_file` therefore succeeds (`fflush` returns 0 and `fsync` works): its C implementation, `filesystem_core_mod_sync_file`, checks only `fflush`'s return value and never the stream's sticky error flag (`ferror`). So every user of the public `cartesi.filesystem` durable-write pattern (`new_temporary_file`, `file:write`, `sync_file`, `rename`) that does not check `file:write` itself loses the error too, not just `hash-tree.lua`. The same path can also replace a previously good file with a truncated one. `temporary:rename` in `cartesi.filesystem` also ignores the result of `self.file:close()`, so the truncated temporary file is renamed into place. This breaks the helper's own guarantee that "the name never appears with incomplete contents". `store_tree` writes a tree file only `if not fs.exists(path)`, and files are named by the tree's hash, so no later store rewrites or checks the corrupt file, even in a fresh process with free space. The next `frontier_forest_store` then commits a new frontier file (the store's commit point) that references the unloadable tree.

**Origin:** Introduced by this branch. `src/cartesi/filesystem.lua` and the durable forest store in `src/cartesi/hash-tree.lua` do not exist on `main`.

**Area:** Lua library `cartesi.hash-tree` (frontier forest and frontier persistence) and `cartesi.filesystem`. The `cartesi-machine` CLI's `store_frontier` also goes through `write_file`.

**Category:** Durability / silent data corruption (an unchecked I/O error).

**Location:**
- `src/cartesi/hash-tree.lua:509-514`: `write_file`, where `temporary.file:write(contents)` is unchecked.
- `src/clua-cartesi-filesystem.cpp:111-125`: `filesystem_core_mod_sync_file` checks `fflush` only, never `ferror`.
- `src/cartesi/filesystem.lua:47-51`: `temporary_file_meta.__index:rename`, where `self.file:close()` is unchecked.
- `src/cartesi/hash-tree.lua:577-596`: `store_tree` skips any tree file that already exists.
- `src/cartesi/hash-tree.lua:967-990`: `frontier_forest_store` commits the frontier file over the corrupt tree.
- `src/cartesi/hash-tree.lua:935-938` (`frontier_store`) and `src/cartesi-machine.lua:3274-3277` (CLI `store_frontier`): other users of the same `write_file`.

**Evidence:** The test builds a 512-leaf keccak256 forest, whose single fixed-point tree file is about 35 KB. A child process stores it under `trap '' XFSZ; ulimit -f 8`, so `write(2)` fails with EFBIG at 8 KiB, which is the same short-write path ENOSPC takes on a full disk. The parent then stores again with no limit, reloads the forest, and queries a node hash. Run from the repo root: `eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`
```
child (limited store): STORE-OK
tree file 0x8782ecbf...6e6606a5.json size 8192
second (unlimited) store:	true	nil
tree file after second store 0x8782ecbf...6e6606a5.json size 8192
reload + query:	false	.../src/cartesi/hash-tree.lua:528: failed to parse JSON from a string: [json.exception.parse_error.101] parse error at line 1, column 8193: ... missing closing quote
BUG: frontier_forest_store reported success although writing the tree file failed (EFBIG)
BUG: the committed tree file is truncated and the forest cannot be reloaded/queried: ...
BUG: a later store over the same directory did not repair the truncated file (store_tree skips existing files)
exit=1
```
The prover patched a copy with `assert(temporary.file:write(contents))`. With that change, the limited store raises `hash-tree.lua:511: File too large` and commits nothing, the later store writes the full 35388-byte file, and the reload and query succeed.

**Scenario:** A long-running PRT validator, Rollups Node or Dave component persists its commitment or output forest snapshots with `frontier_forest_store`. Fixed-point tree files hold up to 2^k hashes of about 68 bytes each, so many are larger than the stdio buffer and take this path. If the disk fills or a quota is hit during a store, the store reports success and leaves a truncated tree file. After the operator frees space, later stores succeed but keep the corrupt file and commit frontiers that point at it. `frontier_forest_load` still succeeds because trees load lazily. After a restart, or when a dispute first needs that subtree for bisection or proof siblings, `frontier_forest_get_node_hash` and the related calls raise an error, and the node cannot take part in the dispute from that snapshot until an operator finds and deletes the bad file or rebuilds the forest from the machine. If that takes longer than the tournament's time budget, an honest player can lose on timeout. The CLI's `store_frontier` and `frontier_store` payloads are small and usually fit in the stdio buffer, so for them the failure normally shows up at `fflush` and is caught. Their exposure is lower but not zero.

**Possible solution:**
- In `write_file`, use `assert(temporary.file:write(contents))`.
- In `filesystem_core_mod_sync_file`, raise if `ferror(stream->f)` is set before or after `fflush`, so `sync_file` never reports success for a stream whose writes failed.
- In `filesystem.lua`'s `rename`, use `assert(self.file:close())` before renaming, so a deferred write error cannot be lost either.
- Optionally make `store_tree` stronger: check an existing file (parse it and compare its hash) before trusting it, or rewrite trees that the forest has not recorded as durable, so a corrupt file left by earlier code or by external damage is repaired instead of committed.

**Severity:** High. This entry's own reviewers rated it medium, because a truncated file always fails JSON parsing or the hash check and so never yields a wrong hash or proof. Two independent reproductions (`lua-01` and `rpc-05`, listed below) were each rated high by both of their reviewers. That rating is used here. A realistic operating event, a disk full or quota hit during a store, is reported as success. It leaves committed state permanently unreadable, later stores never repair it, and the validator cannot reload its trees or build bisection proofs until an operator intervenes. It can therefore lose a dispute by timeout. That matches the high level of the scale (stored validator state corrupted in realistic use).

**Risks:**
- *Of the bug:* Nodes that once hit a full disk carry corrupt snapshots that look committed. They then hit query failures at the worst time: after a restart or deep in a bisection. Dispute deadlines can be missed while operators diagnose a JSON parse error in a hash-named file.
- *Of the fix:* Checking the write and close results is low risk. Stores that used to "succeed" on a full disk will now raise, so callers must handle that error, for example by retrying after freeing space. The temporary file is still removed by its `<close>` handler. Validating or rewriting existing files in `store_tree` costs extra reads and hashing per store, and must keep the rule that the frontier file is written only after every tree it reaches is durable.

**Proof of concept:** `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 with `OK:` once it is fixed. It needs `bash` and `ulimit -f` (RLIMIT_FSIZE) and uses a `mktemp -d` work directory that it removes afterwards.

**ID**: `ht-07-hashtree-lua-write-file-ignores-write-error`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-01-tempfile-write-error-silently-committed`: run with `eval $(make -s env); lua5.4 bugs/lua-01-tempfile-write-error-silently-committed/test_tempfile_write_error.lua`. It also identified the missing `ferror` check in `fs.sync_file` and showed that a previously good file can be replaced by a truncated one.
- `rpc-05-hash-tree-write-file-ignores-write-error`: run with `eval $(make -s env); lua5.4 bugs/rpc-05-hash-tree-write-file-ignores-write-error/test_forest_store_short_write.lua`.

**Related**: [B05](#b05-cartesifilesystemwrite_file-ignores-close-errors-cli-writes-empty-hash-files).

### B07. Interrupted remove_stored leaves a directory that blocks the name forever

**Title**: `remove_stored` is not idempotent: after an interrupted removal it cannot remove the leftover directory, and that directory blocks `store`/`clone_stored`/`rename_stored` to the same name

**Problem:** `machine::remove_stored` calls `for_each_stored_filename(dir, os::remove_file)`, then `os::remove_directory(dir)`. `for_each_stored_filename` first runs `machine_config::load(dir)`, which needs `config.json`. It then unlinks a fixed list of files: the data, dht and dpt files of every backing store, then the sht and phtc files, and `config.json` last. `os::remove_file` throws on any `unlink` error, including `ENOENT`. If the process dies partway through (SIGKILL, OOM kill, power loss), the next `remove_stored` call fails one of two ways:
- if `config.json` is still there, it throws on the first file that is already gone;
- if `config.json` was already unlinked (the directory is empty or nearly empty), it throws because it cannot read the config.

Either way the directory never gets removed. `clone_stored` and `store` create the target with `mkdir`, so they fail with `EEXIST`. `rename_stored` uses `RENAME_NOREPLACE`, so it fails with "destination exists". No emulator API can recover the name. A `clone_stored` or `store` killed partway through leaves the same kind of partial directory, because its scope cleanup never runs, and `remove_stored` cannot clean that up either.

**Origin:** Pre-existing. `remove_stored` and `for_each_stored_filename` are the same on `origin/main`. The CLI's stored revert mode and the branch's PRT recipe use them.

**Area:** Stored machine API (`cm_remove_stored`, `cm_clone_stored`, `cm_rename_stored`, `cm_store`), Lua bindings, and `cartesi-machine --revert-mode=stored`.

**Category:** Durability / crash recovery (liveness).

**Location:**
- `src/machine.cpp:576-609` (`for_each_stored_filename`: loads `config.json` first and removes it last)
- `src/machine.cpp:611-619` (`machine::remove_stored`)
- `src/os-filesystem.cpp:193-197` (`os::remove_file` throws on `ENOENT`)
- `src/cm.h:603` (documents only that "some files or the directory may remain"; it gives no way to recover)
- Callers that hit it: `src/cartesi-machine.lua:3739` (`revert_stored:commit`), `src/cartesi-machine.lua:3748-3749` (`revert_stored:revert`: `remove_stored` then `rename_stored`)
- Workaround in this branch: `doc/recipes/prt.lua:1119` (`remove_leftover_stored_machine` falls back to listing the directory and unlinking each entry)

**Evidence:** The test stores a real machine through the public Lua API. It simulates two crash points by deleting files with `os.remove`, then calls the real `remove_stored`, `clone_stored` and `rename_stored`:
```
$ eval $(make -s env); lua5.4 bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua
stored files:	27
A: retry remove_stored:	false	unable to remove file '/tmp/tmp.../victim/0000000000000000-8000.bin': No such file or directory
A: directory still exists:	true	files left:	26
BUG: remove_stored cannot finish a partially removed stored machine (aborts on first missing file: ...)
A: clone_stored to same name:	false	unable to create directory '/tmp/tmp.../victim': File exists
A: rename_stored to same name:	false	... unable to rename directory from '/tmp/tmp.../other' to '/tmp/tmp.../victim': destination exists: File exists
BUG: name stays blocked for clone_stored and rename_stored
B: retry remove_stored on empty leftover dir:	false	unable to read file '/tmp/tmp.../victim/config.json': open() failed: No such file or directory	exists:	true
BUG: remove_stored cannot remove the empty directory left after config.json was unlinked (...)
exit=1
```

**Scenario:** A validator node (Rollups Node, Dave, or a custom PRT node) keeps a revert snapshot or scratch stored machine under a fixed name. It discards the snapshot with `cm_remove_stored`, or replaces the machine with `cm_remove_stored` followed by `cm_rename_stored`. The node is killed during the roughly 27 unlinks. After restart, the leftover can never be removed: `cm_remove_stored` fails with `ENOENT`, and `cm_clone_stored`/`cm_rename_stored`/`cm_store` to that name fail with `EEXIST`. The node stays stuck until custom code or an operator deletes the directory by hand. An honest PRT player stuck this way can miss tournament deadlines. The `cartesi-machine` CLI with `--revert-mode=stored` gets stuck the same way: a stale `<dir>.revert` makes the next snapshot's `clone_stored` fail, and an interrupted revert leaves `<dir>` unremovable. Hashes and proofs are never affected.

**Possible solution:** Make removal idempotent and crash-safe:
- Ignore `ENOENT` in the remover used by `remove_stored`.
- If `config.json` is missing, don't fail. Fall back to removing the known file patterns, or every regular file in the directory, and then the directory itself.
- Better still, first rename the directory atomically to a unique tombstone name, such as `<dir>.removing.<pid>`, and sync the parent directory. Then delete the tombstone's contents. The original name is then free right after one atomic step, and leftovers are easy to find and remove.

**Severity:** Medium. Both reviewers rated it medium, at the low end. Crashes are expected over a long-running validator's life, and this one can leave a node or CLI stuck with no API path to recover. On the other hand, it never produces wrong or nondeterministic hashes or proofs, recovery outside the API is trivial (`rm -rf`), and `cm.h` already warns that files may remain after a failure.

**Risks:**
- Of the bug: lost liveness after a crash. Unattended validators stay down until someone cleans up by hand, which can mean missed dispute deadlines. Integrators may write ad-hoc recursive deletes, which can remove the wrong directory if a path is wrong.
- Of the fix: a fallback that deletes every entry when `config.json` is missing must not run on a directory that is not a stored machine, for example a user path passed by mistake. Limit it to known file-name patterns, or to the tombstone created by the API itself. Ignoring `ENOENT` must not hide real errors such as `EACCES` or `EIO`. The tombstone approach adds a rename and a sync and needs a unique-name scheme.

**Proof of concept:** `bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua`. It works in a fresh `mktemp -d` directory, or in `$WORKDIR` if that is set. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: remove_stored is idempotent` once fixed.

**ID**: `ht-09-remove-stored-not-idempotent`

### B08. clone_stored fails with EMLINK instead of falling back to a copy

**Title**: `clone_stored` fails with EMLINK ("Too many links") instead of copying once about 65000 stored clones share one hard-linked read-only file

**Problem:** `os::clone_file` handles a source with no write bits by hard-linking it with a plain `link()`. It falls back to `copy_file` only when the error is `ENOTSUP`, `EXDEV` or `EPERM`, and rethrows every other errno. `machine::store` always writes the PMAs backing file (`0000000000010000-1000.bin`) read-only, and it does the same for read-only flash drives and NVRAM. As a result, `machine::clone_stored` (`cm_clone_stored`) hard-links that file on every clone, and the template, its clones and their clones all share one inode. ext4 allows at most 65000 links per inode. At that point `link()` returns `EMLINK`, the error is rethrown as `std::system_error("Too many links")`, and `clone_stored` fails. A plain copy would have worked. The failure then hits every clone from the template or from any of its descendants, not just one source, for as long as that many links exist. The Lua `cartesi.filesystem.clone_file` binding calls the same function and fails the same way.

**Origin:** Pre-existing. `origin/main` (v0.22.0) has the same `clone_file` with the same fallback list. This branch makes the defect easier to reach by exposing `clone_file` in the new `cartesi.filesystem` Lua module.

**Area:** Stored machine API (`cm_clone_stored` / `machine:clone_stored`), `os::clone_file`, and the Lua `cartesi.filesystem.clone_file`.

**Category:** Availability / unhandled recoverable error. Hashes are not affected.

**Location:**
- `src/os-filesystem.cpp:598-614`: `os::clone_file` uses `hardlink_file` for read-only sources, and its fallback list does not include `EMLINK`.
- `src/machine.cpp:454-460`: `store` marks the PMAs backing store, plus read-only flash drives and NVRAM, read-only.
- `src/machine.cpp:493-541`: `clone_stored` runs every backing file through `os::clone_file`.
- `src/clua-cartesi-filesystem.cpp:70`: `filesystem.clone_file`.

**Evidence:** The test stores a machine with 4 KiB of RAM and confirms that a clone shares the PMAs file's inode with the template. It then adds hard links to that inode with `os.link` until the ext4 limit is reached, which stands in for about 65000 live stored descendants. Finally it calls `clone_stored` from both the template and a descendant. Run on ext4 (`/dev/vda`), in about 1.5 s:
```
$ eval $(make -s env); lua5.4 bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua
read-only files in stored dir: 0000000000010000-1000.bin
inode template=936448 clone=936448 (shared=true)
hit EMLINK after 64998 extra links; st_nlink= 65000
clone_stored(c1) failed: unable to create hard link from '.../c1/0000000000010000-1000.bin' to '.../c-from-c1/0000000000010000-1000.bin': Too many links
clone_stored(template) failed: unable to create hard link from '.../template/0000000000010000-1000.bin' to '.../c-from-template/0000000000010000-1000.bin': Too many links
BUG: clone_stored fails with EMLINK once the shared read-only inode reaches the filesystem link limit; no fallback to copy
```
The exit status is 1. Once fixed, the test exits 0 and also checks that each clone's root hash matches the template's.

**Scenario:** A validator (a Rollups Node, Dave, or a PRT node such as `doc/recipes/prt.lua`, which calls `clone_stored` from templates and snapshot caches) keeps stored snapshots, for example one per input or checkpoint, all cloned from one stored template or from each other. The shared inode spreads only through `clone_stored` chains: a machine that is loaded, run and then stored gets fresh files. If the node does not prune, the live directories from one lineage reach about 65000. From then on every `clone_stored` from that lineage throws, so the node can no longer snapshot, fork or revert, and it can stall during a dispute until an operator deletes old clones. Filesystems with lower per-inode link limits hit this sooner. XFS and btrfs allow far more links.

**Possible solution:** In `os::clone_file`, also fall back to `copy_file` on `EMLINK`, and arguably on `EACCES` and `EOPNOTSUPP` (the same value as `ENOTSUP` on Linux, but not on every platform). Check that the copied file keeps the source's read-only mode, so that later clones of it are still hard-linked.

**Severity:** Low. Both reviewers agreed. It is an availability failure that needs about 65000 unpruned live clones of one stored lineage on ext4. It produces no wrong hashes or proofs and no corrupted state. The error is clean and catchable, `scope_remove` cleans up the partial target, and deleting old clones lowers the link count again.

**Risks:** Bug: when the limit is reached, a long-running validator that depends on `clone_stored` loses the ability to snapshot or revert, which could delay its dispute moves. Fix: very low risk. Falling back to a copy only costs disk space and time for the affected file (the PMAs file is 4 KiB). If `EACCES` is added, the fallback must not hide real permission errors on the destination directory. `copy_file` would surface those itself.

**Proof of concept:** `bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua`. It needs `python3`, and the `bugs/` directory must be on ext4 or another filesystem with a per-inode link limit. Its temporary files go in a subdirectory next to the test and are removed afterwards. Run from the repo root:
`eval $(make -s env); lua5.4 bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua`

**ID**: `ht-10-clone-stored-emlink-no-fallback`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-08-clone-file-emlink-no-fallback`: run with `eval $(make -s env); lua5.4 bugs/lua-08-clone-file-emlink-no-fallback/test.lua`. It reaches the same failure through `cartesi.filesystem.clone_file`.

### B09. JSON-RPC server exits when an error message contains invalid UTF-8

**Title**: JSON-RPC server process exits when a response error message contains invalid UTF-8 (2-byte POST body, or `load()` of a non-UTF-8 `config.json`)

**Problem:** `jsonrpc_http_reply` serializes every response with `j.dump()`. That uses nlohmann's default `strict` error handler, which throws `type_error.316` when any string in the response holds a byte that is not valid UTF-8. Error messages are copied into responses verbatim, so they can carry such bytes:
- (a) For a malformed request body, `handle_request` passes the nlohmann `parse_error.101` text to `jsonrpc_response_parse_error`. That text echoes the raw bytes it last read ("last read: '...<0xFF>'").
- (b) For an exception raised by machine code, `jsonrpc_response_from_exception` copies the exception message, which can embed file contents. One example is the parse error `machine::load` raises for a `config.json` that contains non-UTF-8 bytes.

Nothing catches the `type_error` thrown by `dump()`. Neither `handle_request` nor `http_session::on_read_request` has a try/catch, and the Asio handler does not either. The exception leaves `ioc.run()`, `main()` logs `fatal ... caught exception` and returns 1, and the whole server process exits along with the machine it holds. Forked snapshot/backup children run the same code and die the same way. A local (in-process) machine given the same input just returns a normal error.

**Origin:** Pre-existing. `j.dump()` in `jsonrpc_http_reply` and `jsonrpc_response_parse_error(x.what())` are unchanged on `main`. This branch did not introduce them, but they sit in the remote-machine server that PRT validator nodes use.

**Area:** JSON-RPC remote machine server (`cartesi-jsonrpc-machine`, `src/jsonrpc-remote-machine.cpp`) and its Lua/C clients (`cartesi.jsonrpc`, `cm_jsonrpc_*`).

**Category:** Crash (an untrapped exception kills the server process).

**Location:**
- `src/jsonrpc-remote-machine.cpp:1791`: `std::string body = j.dump();` in `jsonrpc_http_reply`, which uses the strict UTF-8 handler.
- `src/jsonrpc-remote-machine.cpp:1946-1950`: the parse-error path, `jsonrpc_response_parse_error(x.what())`.
- `src/jsonrpc-remote-machine.cpp:499-505` and `1896-1897`: `jsonrpc_response_from_exception` copies machine exception text into the response.
- `src/jsonrpc-remote-machine.cpp:217-246`: `http_session::on_read_request` calls `handle_request` and `send_response` with no try/catch.
- `src/jsonrpc-remote-machine.cpp:2188` and `2192-2194`: the exception escapes `ioc.run()` into `main`'s catch, which returns 1.

**Evidence:** The test spawns servers with `jsonrpc.spawn_server()`.
- Scenario 1 sends a raw HTTP POST whose body is the 2 bytes `\xff\xfe`.
- Scenario 2 calls `m:load(dir)`, where `dir/config.json` is `{"a":\xff}`. For comparison, it first loads the same directory into a local machine.

After each scenario the test checks whether the server is still alive. Both scenarios kill the server; the local load just raises a Lua error:
```
scenario 1 response: "" err=closed
... fatal cartesi-jsonrpc-machine pid:3893 ... caught exception: [json.exception.type_error.316] invalid UTF-8 byte at index 130: 0xFF
BUG: scenario 1: server at 127.0.0.1:36537 died after POST body \xff\xfe: jsonrpc error: post error contacting 127.0.0.1:36537 (Connection refused ...)
local load: ok=false err="...[json.exception.parse_error.101] parse error at line 1, column 6: syntax error while parsing value - invalid literal; last read: '\"a\":<0xFF>'"
... fatal cartesi-jsonrpc-machine pid:3897 ... caught exception: [json.exception.type_error.316] invalid UTF-8 byte at index 134: 0xFF
remote load: ok=false err="...jsonrpc error: post error contacting 127.0.0.1:37023 (end of stream ...)"
BUG: scenario 2: server at 127.0.0.1:37023 died after load() of corrupted config.json: ... (Connection refused ...)
exit=1
```
Run command: `eval $(make -s env); timeout 60 lua5.4 bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`

**Scenario:**
- A validator (Rollups Node, Dave, or the PRT Lua node) runs its working or backup machine in a remote `cartesi-jsonrpc-machine` and calls `load()` on a stored snapshot whose `config.json` was corrupted on disk (bit flip, partial write) into non-UTF-8 bytes. The same can happen with any error message that embeds non-UTF-8 bytes, such as a file path.
  - Locally this is a recoverable error. Remotely the server process dies: the client sees "end of stream", then "Connection refused".
  - The load fails either way, and `load` only runs on an empty machine, so no machine state is lost. But any retry or fallback over the same connection (for example, loading an older snapshot) now fails. That defeats the node's error handling and can stall it until a supervisor respawns the server.
- Anything that can reach the port can kill the server with `curl -X POST --data-binary $'\xff\xfe' http://HOST:PORT/`. The server is unauthenticated and binds to 127.0.0.1 by default, and such a party can already call `shutdown`. This trigger therefore adds no new attack capability; it only shows that malformed input becomes a crash instead of an error.
- Hashes, proofs and step logs are not affected.

**Possible solution:**
- In `jsonrpc_http_reply`, serialize with `j.dump(-1, ' ', false, json::error_handler_t::replace)`. Alternatively, sanitize error messages to valid UTF-8 (or escape non-ASCII bytes) when building error responses in `jsonrpc_response_parse_error` and `jsonrpc_response_machine_error`.
- As defense in depth, wrap `handle_request` and `send_response` in `on_read_request` in a try/catch that returns a 500 or JSON-RPC internal error and keeps the server running.

**Severity:** Medium. The server crashes and exits, where it should return a recoverable error. Both reviewers rated it medium rather than the suspected high, for three reasons:
- The legitimate trigger, a corrupted snapshot `config.json` or a non-UTF-8 string in an error message, is uncommon.
- The network trigger gives no capability beyond the existing unauthenticated `shutdown` method.
- Hashes, proofs and dispute outcomes are not affected directly.

**Risks:**
- Of the bug: a remote working or backup machine disappears on a recoverable error, which breaks retry or fallback logic in validator nodes. A malformed request from a buggy client or a stray local process takes down the server and the machine it holds.
- Of the fix: with `replace`, error messages a client receives will contain U+FFFD in place of the raw bytes, so clients matching on exact error text may see different strings. A catch-all in `on_read_request` must not hide failures that leave the server in an inconsistent state, such as exceptions thrown around `fork` or snapshot handling; it should log them and reply with an error, not swallow them silently.

**Proof of concept:** `bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`. It needs LuaSocket (`socket`) for the raw POST, and creates its temporary directory with `os.tmpname()`. Run it from the repo root with `eval $(make -s env); timeout 60 lua5.4 bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`. While the bug is present it prints `BUG:` lines and exits 1. Once fixed it prints `OK: server survived both scenarios` and exits 0.

**ID**: `rpc-01-jsonrpc-server-crash-invalid-utf8-error-message`

### B10. Spawned JSON-RPC servers inherit client sockets, so concurrent spawns fail

**Title**: `cm_jsonrpc_spawn_server` leaks client sockets into spawned servers: concurrent spawns on fixed addresses fail with EADDRINUSE, and closed connections stay in CLOSE_WAIT

**Problem.** The spawn constructor binds a listening acceptor on the requested address and calls `posix_spawnp(&child_pid, bin, nullptr, nullptr, args, environ)`. It passes no `posix_spawn_file_actions`. Boost.Asio opens sockets without `SOCK_CLOEXEC` (only its epoll fd and timerfd get CLOEXEC), and nothing in `src/` sets `FD_CLOEXEC` on sockets or calls `close_range`/`closefrom`. So every socket open in the client process at spawn time is inherited by `cartesi-jsonrpc-machine`. That includes keep-alive connections to other remote machines and, in a multi-threaded host, acceptors other threads have just bound for their own spawns. The server never closes fds it does not know about. Its `fork` handler keeps them in the grandchild, and the grandchild is the long-lived server whose pid is returned. This has two effects:
1. **Concurrent spawns fail.** Thread A's acceptor stays LISTENing inside thread B's server tree. A's later `rebind` to that address (or A's next acceptor bind) then fails with `bind: Address already in use`. It keeps failing for as long as B's servers live.
2. **Closed connections leak.** When the client closes a connection (`shutdown_and_close_socket`: receive shutdown plus linger-0 close), the close only drops one reference while another server holds a copy. No RST or FIN is sent, so the remote session never sees EOF. The socket stays in CLOSE_WAIT for the whole lifetime of the inheriting server and its fork descendants.

**Origin.** Pre-existing.

**Area.** JSON-RPC client library (`libcartesi_jsonrpc`, `cm_jsonrpc_spawn_server`) and the `cartesi-jsonrpc-machine` server.

**Category.** Resource leak / file-descriptor inheritance, causing spawn failures (denial of service).

**Location.**
- `src/jsonrpc-machine.cpp:473-494`: the acceptor is bound, then `posix_spawnp` runs with no file actions.
- `src/jsonrpc-machine.cpp:180-198`: `json_post` keep-alive sockets, opened with `async_connect` and no CLOEXEC.
- `src/jsonrpc-machine.cpp:549-551`: the parent closes the acceptor only after the spawn, which leaves a window in which other threads' spawns inherit it.
- `src/jsonrpc-machine.cpp:581-584` and `src/jsonrpc-remote-machine.cpp:894-907`: `rebind` to the requested address, where the EADDRINUSE shows up.
- `src/jsonrpc-remote-machine.cpp:830-886`: the `fork` handler, which carries the inherited fds into the grandchild.
- `src/jsonrpc-remote-machine.cpp:2121-2166`: `--server-fd` handling, which never closes other inherited fds.

**Evidence.** The PoC uses only the public C API.
- **Part A, single thread.** It spawns m1, makes one request (which opens a keep-alive socket), then spawns m2. It then inspects `/proc/<pid2>/fd` and `/proc/net/tcp`.
- **Part B, concurrency.** 4 threads x 8 rounds. Each thread spawns on its own fixed port, outside the ephemeral range. A sequential control run uses one fixed port.

Re-run output (`eval $(make -s env); sh bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/run.sh`):
```
[A] client sockets before spawning m2: 1, of which held by server2 (pid 4645): 1
    leaked socket:[143122]  tcp: 01 local=0100007F:DC26 remote=0100007F:81B1
    after cm_delete(m1): server2 still holds socket:[143122]  tcp: 08 local=0100007F:DC26 remote=0100007F:81B1
BUG: spawned server2 inherited 1 client socket(s) (keep-alive connection to server1); 1 still held after server1 was deleted
    [B] thread 0 round 0 spawn on 127.0.0.1:23461 failed: bind: Address already in use [system:98
        LISTEN holders of port 23461 now: pid=4652(cartesi-jsonrpc) pid=4653(cartesi-jsonrpc) pid=4655(cartesi-jsonrpc)
[B] concurrent spawns: 23/32 failed (23 with 'Address already in use')
[B] sequential control on one fixed port: 0/32 failed
```
State 08 is CLOSE_WAIT. The prover and two independent reviewers saw between 12/32 and 24/32 concurrent failures across runs. The sequential control always failed 0/32. When a spawn fails, the LISTEN socket for the failing port is held by other threads' `cartesi-jsonrpc-machine` processes.

**Scenario.** A validator node (Cartesi Rollups Node, Dave, or another PRT node written in Go or Rust) hosts several applications or tournaments. It calls `cm_jsonrpc_spawn_server` from several threads, each with its own machine object. With cgo this is the normal case, because cgo calls run on separate OS threads. If each machine is configured on a fixed address, a large share of spawns fail with EADDRINUSE. Retries on the same address keep failing while the servers holding the inherited acceptor are alive, so the node can fail to start or restart machines, for example when it needs a fresh machine to compute a commitment or a step proof during a dispute deadline. Even single-threaded, a long-running node that spawns many servers piles up stale fds and CLOSE_WAIT sockets in them. Remote sessions also never see the client's EOF, so the server holds those connections open. CLI users and Lua scripts that spawn several servers are affected the same way, though less severely.

**Possible solution.**
- In the client, pass `posix_spawn_file_actions` that keep only the acceptor fd. Alternatively, have `cartesi-jsonrpc-machine` close every inherited fd except `--server-fd` and stdio on startup (`close_range(3, ~0U, 0)` around the server fd, or iterate `/proc/self/fd`).
- Also open all client sockets and acceptors with CLOEXEC, for example by setting `FD_CLOEXEC` right after open, and clear it only on the acceptor passed to the child (with `posix_spawn_file_actions_adddup2`, or by clearing the flag just before the spawn). This narrows the window but does not remove it unless spawns are serialized, so the server-side close is the robust fix.
- Optionally serialize the acceptor-bind-to-spawn section with a process-wide mutex as defence in depth.

**Severity.** Medium. Both reviewers agree. It causes a denial of service for nodes that spawn concurrently on fixed addresses, plus a bounded fd and socket leak in long-running nodes. It cannot produce wrong or nondeterministic hashes or proofs, and the common `127.0.0.1:0` (ephemeral port) configuration avoids the bind failure.

**Risks.**
- Of the bug: a validator can fail to start or restart machines at a critical moment, such as a dispute deadline. A failure that looks transient tends to persist, because the leaked listeners live as long as unrelated servers. Stale CLOSE_WAIT sockets and missed EOFs slowly use up fds and kernel memory, and they keep remote sessions open.
- Of the fix: closing fds in the server must keep `--server-fd` and stdio, or spawning breaks. Setting CLOEXEC on asio sockets needs care so the acceptor is still inherited. Embedders that deliberately pass extra fds to spawned servers through `CARTESI_JSONRPC_MACHINE` wrappers (unlikely) would lose them.

**Proof of concept.** Files are in `bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/`:
- `test_spawn_fd_leak.cpp`: the C++ test.
- `run.sh`: compiles the test against `src/` into a temp dir and runs it.

Run from the repo root (Linux, needs `/proc`):
```
eval $(make -s env); sh bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/run.sh > rpc-02.log 2>&1; cat rpc-02.log
```
Redirect the output to a file as shown: while the bug is present, leftover spawned servers inherit the shell's stdout, so piping the output (for example into `grep`) never reaches end of file. Exit status 1 and `BUG:` lines mean the bug reproduced. Exit status 0 means it is fixed.

**ID**: `rpc-02-jsonrpc-client-fds-leak-into-spawned-servers`

### B11. JSON-RPC request with an invalid id is rejected but still executed

**Title**: JSON-RPC server rejects a request with an invalid `id` but still executes it, and answers it twice in a batch

**Problem**: `handle_request` in the JSON-RPC remote-machine server checks each request and replies `-32600 invalid request` if the request is malformed. For the `jsonrpc` and `method` fields, the code pushes the error and then `continue`s. For an `id` that is not a string, number or null (for example `true`, `{}` or `[]`), it pushes the error but has no `continue`. Control falls through to `jsonrpc_dispatch_method`, so the method runs and changes machine state. Then, because `ji.contains("id")` is true, the method's result is pushed as a second response. A single request returns only `jr[0]`, which is the error, so the client is told the call was rejected when it actually ran. A batch returns both responses for one request. JSON-RPC 2.0 forbids both behaviours: an invalid request must not be executed, and each request gets exactly one response.

**Origin**: pre-existing. `origin/main` has the same code, and the branch's changes to this file do not touch this check.

**Area**: jsonrpc-remote-machine server (`cartesi-jsonrpc-machine`), request validation.

**Category**: api-contract.

**Location**:
- `src/jsonrpc-remote-machine.cpp:1984-1991`: the invalid-`id` check pushes the error with no `continue`.
- `src/jsonrpc-remote-machine.cpp:1997`: `jsonrpc_dispatch_method(ji, session)` still runs.
- `src/jsonrpc-remote-machine.cpp:2003-2005`: the result is pushed as a second response.
- `src/jsonrpc-remote-machine.cpp:2012`: a single (non-array) request returns only `jr[0]`, the error.

**Evidence**: The test spawns a real `cartesi-jsonrpc-machine` server using the Lua `cartesi.jsonrpc` client and creates a 1 MiB machine. It then sends raw HTTP POSTs with curl. Run with `eval $(make -s env); lua5.4 bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`:
```
single response: {"error":{"code":-32600,"message":"invalid field \"id\" (expected string, number, or null)"},"id":true,"jsonrpc":"2.0"}
x1 after rejected request: 77
BUG: request rejected as invalid (bad id) but write_reg was executed anyway (x1=77)
batch response: [{"error":{"code":-32600,...},"id":{},"jsonrpc":"2.0"},{"id":{},"jsonrpc":"2.0","result":true}]
responses in batch for 1 request: 2, x2=55
BUG: batch with one invalid-id request produced 2 responses
BUG: batch request with invalid id executed (x2=55)
exit=1
```

**Scenario**: A third-party or hand-written client talks to `cartesi-jsonrpc-machine` directly over HTTP, for example a validator written in another language or a debugging script. It sends a request whose `id` is not a scalar, such as `{"method":"machine.write_reg","id":true,"params":["x1",77]}`. It receives "invalid field id", treats the call as having no effect, and may retry or carry on. Meanwhile `write_reg`, `run`, `write_memory`, `send_cmio_response` or `store` has already run, so the client's view of the machine no longer matches the real state. A batch-aware client that pairs responses with requests is also confused by the extra response. The official `libcartesi_jsonrpc` C/C++ client, which the Lua bindings, the `cartesi-machine` CLI, Rollups Node, Dave and the PRT node all use, always sends numeric ids. Honest validators using the shipped clients cannot trigger this, and hashes and proofs are not affected.

**Possible solution**: Add `continue;` after `jr.push_back(jsonrpc_response_invalid_request(ji, "invalid field \"id\" ..."))` at line 1990. The invalid-`id` check then behaves like the `jsonrpc` and `method` checks: one error response, and no dispatch.

**Severity**: low. Both reviewers agreed with the prover. Only clients that send a malformed, non-scalar `id` can reach this, and the official C/Lua clients never do. There is no crash, hang, memory corruption, or wrong hash or proof. The harm is that the server tells non-conforming clients a request was rejected when it actually ran.

**Risks**: The bug itself can make a non-conforming client misjudge machine state after a state-changing call it believes was rejected, and can break response pairing in batches. The fix is a one-line change with minimal risk. Any client that currently sends non-scalar ids and depends, by accident, on the method running will now see the request genuinely rejected, which is the behaviour JSON-RPC 2.0 requires.

**Proof of concept**: `bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`. It needs `curl` and `cartesi-jsonrpc-machine` in `PATH`. It exits with 1 and prints `BUG:` lines while the bug is present, and exits with 0 once the bug is fixed.

**ID**: `rpc-03-jsonrpc-invalid-id-still-executes`

### B12. frontier_forest_store drops expansions under single-value fixed-point trees

**Title**: `frontier_forest_store` and `store_expansion` silently drop expansions placed under single-value fixed-point trees, so a reloaded forest is opaque where it answered before

**Problem:** In `store_tree`, any `fixed_point` tree with `base_height == height` returns at once, before `store_children` is called. The code assumes such a single-value wrapper only holds a raw hash. That assumption is wrong:
- `forest_flush` creates these wrappers whenever it flushes a raw value alone. This happens on a height change, a pad or value change, or an aligned single-entry chunk, such as the odd value in a 4 + 1 flush.
- `frontier_forest_expand_leaf` walks into fixed-point trees, including these wrappers. When it reaches the opaque value, it sets `values[index] = replacement`.

Suppose the forest had no directory when the expansion ran, so `store_expansion` was skipped. The next `frontier_forest_store` never reaches the replacement. The parent's file records only the raw hash (`get_value_hash`), and no file is written for the replacement. After `frontier_forest_load`, `load_tree(hash)` finds nothing, and the subtree is opaque again.

`store_expansion` has the same blind spot. It calls `store_children` and `store_tree` on the replacement root, so an expanded single-value wrapper nested inside a replacement forest is skipped too.

The in-memory forest keeps answering correctly, so the persisted state silently differs from memory. This breaks the documented contract that a stored forest "keeps its trees" and that "an expansion also stores its new trees there".

**Origin:** Introduced by this branch. `src/cartesi/hash-tree.lua` does not exist on `main`.

**Area:** Lua library `cartesi.hash-tree`, frontier forest persistence (`frontier_forest_store`, `frontier_forest_load`, `frontier_forest_expand_leaf`).

**Category:** Correctness / persistence (silent data loss).

**Location:**
- `src/cartesi/hash-tree.lua:578` (`store_tree` early return for `fixed_point` with `base_height == height`)
- `src/cartesi/hash-tree.lua:720-755` (`forest_flush` wraps a lone raw value in a single-value fixed-point tree)
- `src/cartesi/hash-tree.lua:886-896` (`frontier_forest_expand_leaf` replaces `values[index]` inside such a wrapper, and calls `store_expansion` only when `forest.directory` is set)
- `src/cartesi/hash-tree.lua:606-613` (`store_expansion`, which inherits the blind spot for nested expansions)
- Real caller: `doc/recipes/prt.lua:1748` (`open_bundle` calls `frontier_forest_expand_leaf` on claim trees), `doc/recipes/prt.lua:2535` and `2804` (`frontier_forest_store`/`frontier_forest_load` of claim trees)

**Evidence:** The test uses only the public `cartesi.hash-tree` API: `push_back`, `pad_back`, `append`, `expand_leaf`, `store`, `load`, `get_node_hash` and `get_siblings`.
- Control: a 2-value tree survives store and load, which shows the test setup is valid.
- Case A: a bundle root flushed alone is expanded in memory, then stored and loaded.
- Case B: the expansion is nested inside a replacement forest and goes through `store_expansion`.
- Case C: a claim-tree-like layout (per-input bundles plus pad bundles, flushed as 4 + 1) has its lone pad bundle opened, then stored and loaded.

Cases A, B and C all lose the expansion:
```
$ eval $(make -s env); lua5.4 bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua
control (2-value tree) after reload ok:	true
  reload error: the node is below an opaque hash
BUG: A: expand_leaf then store (no directory at expand time): node answerable before store is opaque after frontier_forest_load
  get_siblings after reload: the node is below an opaque hash
BUG: A: get_siblings after reload: node answerable before store is opaque after frontier_forest_load
BUG: B: nested expansion inside replacement (store_expansion): node answerable before store is opaque after frontier_forest_load
BUG: C: claim-like layout, pad bundle opened then stored: node answerable before store is opaque after frontier_forest_load
BUG: 4 check(s) failed: store_tree drops expansions under single-value fixed-point trees
exit=1
```
With the fix below applied to a copy of `hash-tree.lua`, all cases pass and the test prints `OK: expansions survive store/load` (exit 0).

**Scenario:** A validator node keeps claim trees as frontier forests. During a dispute it opens a bundle with `frontier_forest_expand_leaf`, as the PRT recipe's `open_bundle` does, and snapshots the tree with `frontier_forest_store`. If that bundle's root was flushed alone (for example, the odd pad bundle after a per-input block), the expansion is not persisted. After a restart, `frontier_forest_load` returns a tree where the bundle is opaque again. `get_node_hash` and `get_siblings` return `nil, "the node is below an opaque hash"` for nodes that answered before the restart. The node must re-run the machine to re-collect the bundle. If the machine snapshot is gone, or there is not enough time before a tournament deadline, it cannot produce the proof. Whether a given claim hits this depends on its layout: aligned per-input blocks often avoid lone wrappers. Hashes, roots and proofs are never wrong.

**Possible solution:** In `store_tree`, recurse into a single-value wrapper but write no file for it, because the parent already records the raw hash and `load_tree(hash)` then finds the expansion's own file:
```lua
if forest.durable[tree] then return end
if tree.kind == "fixed_point" and tree.base_height == tree.height then
    store_children(forest, tree, written)
    return
end
```
This also fixes `store_expansion`, since it goes through `store_tree`/`store_children`. Verified with the PoC.

**Severity:** Medium. Both reviewers rated it medium. The bug silently loses persisted proof data, contrary to the documented store/load contract, and the PRT recipe's claim-tree usage can reach it. It never yields wrong hashes or proofs, and it never crashes or hangs. Callers get a recoverable `nil` result and can recompute by re-running the machine, so an honest player loses a dispute only when that recomputation is impossible or too slow.

**Risks:**
- Of the bug: after a restart, a validator that relies on stored forests to answer proofs without the machine cannot produce siblings or node hashes. This costs availability and time during disputes. Re-expanding after a reload works, because the parent holds a raw hash.
- Of the fix: low. Single-value wrappers still write no file and are not added to `written`, so the stored format does not change. Wrappers are never marked durable, so every store walks into them again. The walk is cheap, because durable children return at once. Existing stores that already lost expansions are not repaired; callers must expand again.

**Proof of concept:** `bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua`. It works under `$WORKDIR` (or `$TMPDIR`, or `/tmp`, or a directory given as the first argument) and removes its files at the end. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: expansions survive store/load` once fixed.

**ID**: `lua-02-store-skips-expanded-single-value-tree`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-06-forest-store-drops-expansion-in-raw-fixed-point`: run with `eval $(make -s env); lua5.4 bugs/rpc-06-forest-store-drops-expansion-in-raw-fixed-point/test_store_drops_expansion.lua`.

### B13. Lazily loaded forest used as a value loses its unloaded subtrees

**Title**: A lazily loaded forest used as a value (push_back/pad_back/expand_leaf) loses its unloaded subtrees in the destination, and storing the destination leaves dangling tree files

**Problem:** `frontier_forest_load` returns trees whose fixed-point values stay raw hashes until a query reaches them. Those hashes resolve only through `load_tree(forest, hash, height)`, and `load_tree` looks only in `forest.directory` of the forest passed to it. Suppose that loaded forest is passed as a value to `frontier_forest_push_back`/`frontier_forest_pad_back`, or as the subtree of `frontier_forest_expand_leaf`. `normalize_forest_value` hands the destination the source's root tree, and the source directory is lost. The destination's later queries call `load_tree` with the destination forest, which has no directory or a different one. So `get_node_hash`/`get_siblings` return `nil, "the node is below an opaque hash"` for positions the source forest answers. Storing the destination into its own directory makes it worse. `store_tree` writes the file of the inner root, but `store_children` only recurses into values that are already trees, so the files behind the raw-hash values are never copied. The new directory ends up holding a tree file whose child files exist only in the source directory, and those leaves stay unreachable after a reload. No error is raised at any point.

**Origin:** introduced by this branch. Durable store and lazy load arrived with commit fcf6819 ("feat: store frontier forests durably in hash-tree"); `main` has no `load_tree` or `frontier_forest_load`.

**Area:** Lua library `cartesi.hash-tree` (frontier forests: durable store/load and composition of forests as values).

**Category:** correctness (data availability / persistence integrity).

**Location:**
- `src/cartesi/hash-tree.lua:525-527`: `load_tree` resolves only against `forest.directory` of the querying forest
- `src/cartesi/hash-tree.lua:690-701`: `normalize_forest_value` returns `value[value.height + 1]` and drops the source forest's directory
- `src/cartesi/hash-tree.lua:642-649`: `descend_tree` calls `load_tree` on the destination forest and returns "opaque"
- `src/cartesi/hash-tree.lua:866-904`: `frontier_forest_expand_leaf` takes the same path (`load_tree` at line 890)
- `src/cartesi/hash-tree.lua:563-572`: `store_children` skips raw-hash values, so files from a foreign directory are never copied
- `src/cartesi/hash-tree.lua:577-596`: `store_tree` writes a parent file that references the missing files

**Evidence:** The test builds `inner` (height 3), which is a height-1 forest `{a, b}` padded 4 times. It stores `inner` in directory A and loads it back, then uses the loaded forest as a value. The controls pass: the loaded forest queried directly, and the same composition done with an in-memory `inner`. All four compositions of the loaded forest fail. Root hashes stay correct.
```
$ eval $(make -s env); lua5.4 bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua
ok:   loaded inner answers leaf 1 itself
ok:   outer with in-memory inner, leaf 1
BUG: pad_back(loaded inner) into in-memory outer: leaf 1: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
ok:   root hash still matches
BUG: outer stored in B and reloaded: leaf 9: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
BUG: push_back(loaded inner) into outer with directory C: leaf 3: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
ok:   leaf 0 opaque before expansion
BUG: expand_leaf(loaded inner): leaf 1: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
4 failure(s)
```
After the store, directory B holds the inner root's file `0x0c96...json`, a fixed-point tree whose value is `0x805b...`. It does not hold `0x805b...json`, which exists only in A.

**Scenario:** A validator built on the shipped Lua library persists bundle or claim forests and, after a restart, reloads them with `frontier_forest_load`. It then composes one into another forest: it pads it into an in-memory or differently stored outer forest, or passes it to `frontier_forest_expand_leaf` to reveal a leaf. Commitments still match, so nothing looks wrong. But when a dispute step needs siblings or a node hash at those positions, `get_siblings`/`get_node_hash` return nil/opaque. The validator then cannot produce the proof and can miss the dispute deadline. Its persisted state also carries dangling references, so restarting does not fix it. The experimental node in `doc/recipes/prt.lua` does not hit this today: it keeps all forests in one shared directory and composes only raw hashes or freshly built in-memory forests.

**Possible solution:** Pick one:
- Bind each lazily loaded tree to the directory it came from, for example by storing the source directory, or a loader closure, on the tree or on its raw-value container. `load_tree` and `descend_tree` would then resolve against that directory rather than the destination's.
- Have `normalize_forest_value` (and `expand_leaf`) reject, or fully materialize, a forest value whose `directory` differs from the destination's.

In either case, `store_tree`/`store_children` should copy (or hard-link) the files behind raw values that are reachable from a foreign directory. Failing that, they should refuse the store instead of writing files that reference missing children.

**Severity:** medium. Hashes and proofs are never wrong (root hashes are preserved). The failure is clean and avoidable, because it occurs only when a reloaded forest is composed into a forest with no directory or a different one. The reference node does not do this. Both reviewers rated it medium. A validator relying on this pattern could still fail to produce dispute proofs and persist incomplete state with no error, so it is more than low.

**Risks:** The bug's risk is lost availability of proof data. A validator cannot answer a step for positions it believes it holds, and a store reports success while leaving dangling references, so the problem shows up only later, during a dispute. On the fix side:
- Tying trees to their source directory keeps a reference to that directory alive and makes lifetime and removal (`remove_stored`) harder to reason about.
- Materializing a forest eagerly can be expensive for large forests.
- Copying files across directories changes store cost and needs the same crash-safe ordering (children first, then sync) that the current store uses.
- Rejecting such values is the simplest option, but it breaks callers that currently work by accident because they share one directory.

**Proof of concept:** `bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `all ok` once it is fixed. It writes into a unique scratch directory under the first argument, `$WORKDIR` or `$TMPDIR` (default `/tmp`). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua
```

**ID**: `lua-03-loaded-forest-as-value-loses-lazy-subtrees`

### B14. Forest tree files keyed only by hash collide across heights and representations

**Title**: Frontier-forest tree files are keyed only by hash: the same hash at another height makes `frontier_forest_load` raise, and a coarser tree stored first permanently hides a finer tree's leaves

**Problem:** `frontier_forest_store` writes each tree to `<directory>/<hash>.json`, and the file name holds nothing but the tree hash. Three things combine:
- `get_tree_path` names the file by `tree.hash` only.
- `store_tree` writes the file only when no file with that name exists, so the first tree stored under a hash owns the file.
- `load_tree` asserts `stored.height == height`, so a file for the same hash at another height raises an error. It does not treat the hash as opaque.

Raw values carry a height the caller declares (`append`, `pad_back` and `push_back` take a `value_height`). So one 32-byte hash can stand for different subtrees. The two hashes need not collide: the subtrees are equal as hash trees but described differently.
- **Different height.** Take the pristine chain `z0 = H(zero word)`, `z[i+1] = H(z[i], z[i])`. Four leaves `z1` form a height-2 node with hash `z3`. Eight leaves `z0` form a height-3 node with the same hash `z3`.
- **Same height, different representation.** Two opaque height-1 values `R = H(a,b)` (fixed_point, base 1) and the four leaves `{a,b,a,b}` (base 0) give the same height-2 hash.

Consequences:
- (a) Whichever tree is stored second under a hash makes later loads raise `stored tree height mismatch`. A mixed tree loads its children eagerly, and frontier levels load at open time, so a single collision aborts the whole `frontier_forest_load`. If the collision is reached lazily through `descend_tree`, `get_node_hash` and `get_siblings` raise instead of returning `nil, "the node is below an opaque hash"`. That defeats a caller's open-the-bundle fallback.
- (b) If the coarse representation is stored first, the finer tree's store skips the file. After reload, the fine forest's leaves are opaque. `get_node_hash` and `get_siblings` return `nil` for nodes they answered before the store.

A shared directory is not needed. A single forest stored alone into an empty directory shows both failures. The documented contract fails: a stored forest is meant to reopen and keep its trees, and the directory is meant to be shared ("successive snapshots of a growing forest share them").

**Origin:** Introduced by this branch. `src/cartesi/hash-tree.lua` was added in commit fcf6819 ("store frontier forests durably") and does not exist on `main`. It ships as the `cartesi.hash-tree` Lua module.

**Area:** Lua library `cartesi.hash-tree`, frontier forest persistence (`frontier_forest_store`, `frontier_forest_load`, lazy loads in `descend_tree`).

**Category:** Correctness / persistence (load failure, silent loss of stored data).

**Location:**
- `src/cartesi/hash-tree.lua:503`: `get_tree_path` names files by hash only.
- `src/cartesi/hash-tree.lua:529`: `load_tree` asserts `stored.height == height`.
- `src/cartesi/hash-tree.lua:548-551`: mixed trees load their children eagerly, so one mismatch aborts the whole load.
- `src/cartesi/hash-tree.lua:581`: `store_tree` skips a file that already exists.
- `src/cartesi/hash-tree.lua:645`: lazy `load_tree` in `descend_tree`, reached from `get_node_hash` and `get_siblings`.
- `src/cartesi/hash-tree.lua:1010`: `frontier_forest_load` loads every frontier level.
- Shared-directory use: `doc/recipes/prt.lua:2511`, `2523`, `2535` (store) and `2786`, `2799`, `2804` (load). The epoch builder, the mcycle forest and every uarch claim forest all use `<epoch>/forests`.

**Evidence:** The PoC uses only the public `cartesi.hash-tree` API. Every case asserts that the in-memory forest answers correctly before the store.
- (a) and (a'): two forests share one directory. They hold the same hash `z3` at heights 2 and 3. The forest stored second fails to reload, whichever order is used.
- (b): coarse `pad_back(R,2,1)` is stored first, then fine `append{a,b,a,b}`. The reloaded fine forest has lost its leaves.
- (c): a single height-5 forest stored alone holds `z3` at (0,2) and at (8,3). It cannot be reloaded.
- (d): a single height-3 forest stored alone holds `pad_back(R,2,1)` and then `{a,b,a,b}`. It loses leaf 4 after reload.
```
$ eval $(make -s env); lua5.4 bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua
BUG (a): reloading forest Y raises because forest X stored the same hash at another height: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (a'): reloading forest X raises because forest Y stored the same hash at another height: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (b): reloaded fine forest lost its leaves: get_node_hash(0,0) -> nil (the node is below an opaque hash); get_siblings(1,0) -> nil (the node is below an opaque hash)
BUG (c): a single forest stored alone cannot be reloaded: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (d): single forest stored alone lost leaf 4 after reload: the node is below an opaque hash
5 check(s) failed: tree files are keyed only by hash
exit=1
```

**Scenario:**
- **Affected users.** A validator or tool built on `cartesi.hash-tree` keeps forests on disk across restarts, in one directory or in a directory shared between forests, as the PRT recipe does. Its leaves mix declared heights or granularities. Examples are leaves that are roots of memory regions of different sizes (pristine or repeated content gives equal hashes at different heights), or forests with different bundle heights over the same values.
- **(a) Crash on startup.** After a restart, `frontier_forest_load` raises, so the node cannot reopen its stored state and must rebuild it by re-running the machine.
- **(b) Lost answers.** The reloaded forest silently becomes opaque below the shared hash. The node can no longer answer node-hash or sibling queries it answered before, and so cannot produce those proofs without recomputation. Under a tournament deadline, this can cost an honest player the dispute.
- **PRT recipe.** Neither the prover nor the reviewers found a trigger in the recipe's own forests. Those forests put state hashes at height 0 and bundle roots at one bundle height per forest. State hashes include `mcycle`, so values repeat only in the halted region, which is represented the same way everywhere. A cross-height match there would need a Keccak collision. An honest node stores only forests it computed itself, so an adversary cannot inject colliding trees.
- **Not affected.** The CLI does not use these functions. Wrong hashes are never accepted: `load_tree` verifies the hash, so failures are loud (an error) or show up as opacity, never as a wrong proof.

**Possible solution:**
- Make the file name identify the representation, not just the hash. For example, `<hex>-h<height>.json`, and ideally also the kind and base height, or a digest of the stored contents. Then `load_tree(hash, height)` looks up only a file of the right height.
- Also make `load_tree` treat a height or representation mismatch as "no file" (return `nil`, so the hash stays opaque) instead of raising. This keeps the opaque-hash fallback working.
- To keep the finest representation, `store_tree` could overwrite an existing file when its representation is coarser (higher `base_height`, or a fixed-point file where the new tree is mixed). Writing under a representation-specific name also does this.
- A simpler mitigation for callers is one directory per forest. That fixes only the cross-forest cases (a, a', b), not the single-forest cases (c, d).

**Severity:** Medium. One reviewer rated it low: there is no PRT trigger, and it never yields wrong proofs. The other rated it medium, after showing it fires inside a single forest stored alone. Medium is the reconciled rating. A shipped persistence API can produce a store that cannot be loaded, or that silently loses leaf-level data, on legitimate input. It is not high, because the PRT recipe's forests do not reach it and an adversary cannot force it.

**Risks:**
- **Of the bug.** A validator restart can fail outright, or come back unable to answer queries and proofs that worked before. Recovery means re-running the machine, which costs time during disputes and fails if the snapshot is gone. Stores already written in the hash-only layout keep the ambiguity.
- **Of the fix.** Changing the file name changes the on-disk format. Existing stores written with hash-only names would become unreadable unless `load_tree` falls back to the old name, checking the height. Overwriting files in place must stay crash-safe (temporary file and rename, as `write_file` already does). It must also not break the store's commit-point guarantee, because another frontier file may reference the old file. Representation-specific names avoid in-place rewrites. Including the height in the name grows the directory only when the same hash is used at several heights.

**Proof of concept:** `bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua`. It works under `$WORKDIR` (or `$TMPDIR`, `/tmp`, or a directory given as the first argument) and removes its files at the end. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua`. It exits 1 and prints `BUG` lines while the bug is present. It prints `PASS` once fixed.

**ID**: `lua-04-content-addressing-ignores-height-and-representation`

### B15. frontier(last_proof) hangs on the last leaf of a 64-bit tree and does not validate the proof

**Title**: `hash_tree.frontier(last_proof)` loops forever on `target_address = 2^64-1` (so `cartesi-machine` hangs on `last_output_proof`) and accepts out-of-range or inconsistent proofs without checking them

**Problem**

`frontier(proof)` rebuilds an outputs frontier from the last leaf's proof. It sets `leaf_count = proof.target_address + 1` and then runs `while (leaf_count & (1 << (lowest_complete_level - 1))) == 0 do ... end`, a loop with no upper bound. Take a proof with `target_address = 0xFFFFFFFFFFFFFFFF`:

- `cartesi.fromjson(..., "Proof")` accepts `18446744073709551615` for a `log2_root_size` 63 proof and returns Lua integer `-1`.
- `leaf_count` wraps to 0.
- In Lua 5.4, `1 << n` is 0 for `n >= 64`, so the mask stays 0 and the loop never ends (100% CPU).

The function also never validates the proof. Nothing checks any of these:

- `0 <= target_address < 2^log2_root_size`
- `log2_target_size == 0`
- `#sibling_hashes == log2_root_size`
- that the target hash rolled up through the siblings equals `root_hash`

As a result, an out-of-range `target_address` silently produces a frontier for a different leaf count. For example, address 16 in a height-4 tree gives `leaf_count` 1. A proof whose `root_hash` does not match its target and siblings is also accepted, and the frontier built from it has a different root.

**Origin**

Pre-existing. `frontier(proof)` and its loop are identical on `origin/main`. This branch changes code around them, and the new PRT recipe node calls the same API.

**Area**

Lua hash-tree library (`cartesi.hash-tree` frontier) and the `cartesi-machine` CLI (`--cmio-advance-state ... last_output_proof:`). The C++ JSON `Proof` parser is also involved: it does not range-check `target_address` against `log2_root_size`.

**Category**

Hang (infinite loop) and missing input validation, which leads to a silently wrong frontier.

**Location**

- `src/cartesi/hash-tree.lua:389-421`: `frontier()`. The unbounded loop is at 397-399; there is no proof validation, and bits at or above `log2_max_leaves` are ignored at 402-405.
- `src/cartesi-machine.lua:3392-3401`: `initialize_cmio_outputs` only asserts `log2_root_size == 63` and `log2_target_size == 0`, then calls `hash_tree.frontier(proof, "keccak256")`.
- `src/cartesi-machine.lua:3305-3309`: `read_proof` uses `cartesi.fromjson(contents, "Proof")`, which accepts out-of-range `target_address`.
- `doc/recipes/vg.lua:715`: the PRT recipe node calls the same API on a stored `last_output_proof`.

**Evidence**

`eval $(make -s env); lua5.4 bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua` (about 26 s, mostly the two timeouts):

```
BUG: hash_tree.frontier(proof) with target_address=2^64-1 (log2_root_size 63) did not return within 5s (infinite loop)
ok: control CLI run with genuine last_output_proof exited 0
BUG: cartesi-machine --cmio-advance-state last_output_proof:<target_address 18446744073709551615> hung (killed by 20s timeout)
BUG: frontier(proof) accepted target_address=16 in a 2^4-leaf tree; frontier leaf_count=1 (expected error; true count would be 17)
BUG: frontier(proof) accepted a proof whose root_hash does not match its target/siblings (frontier root differs from proof.root_hash)
ok: sanity genuine proof rebuilds frontier with leaf_count 6 and matching root
exit=1
```

The test runs `cartesi-machine.lua --revert-mode=none --cmio-advance-state=...,last_output_proof:hang-proof.json,format:json -- true`, which hangs before any input is processed. The same command with a genuine last-output proof exits 0 in about 1.4 s, so the hang comes from the proof. The test also shows that the JSON parser turns `18446744073709551615` into `-1` without complaint.

**Scenario**

- **CLI hang.** An operator or script runs `cartesi-machine --cmio-advance-state=...,last_output_proof:<file>,format:json` with a corrupted, hand-edited or externally received Proof JSON that has `target_address` 18446744073709551615. The process spins forever instead of failing.
- **Validator hang.** A validator node built on the Lua library rebuilds the previous epoch's outputs frontier from a stored or received proof in the same way (the recipe node does this). It hangs, which is a liveness failure.
- **Wrong outputs.** Any `target_address` in `[2^63, 2^64-2]` (for the CLI), or `>= 2^L` in general, or a proof whose root does not match, is silently accepted. Outputs are then numbered from the wrong index and appended to the wrong frontier, so the node produces wrong outputs roots and output proofs instead of rejecting the input.
- **Why this is not a normal-flow bug.** Proofs the emulator itself produces are always in range and consistent, so honest flows that use the node's own previous-epoch proof are not affected. The Rollups Node and Dave, which use the C API, do not go through this Lua function.

**Possible solution**

In `frontier(proof)`, before using the proof:

- Require `math.type(proof.target_address) == "integer"`.
- Require `0 < log2_root_size < 64` and `0 <= target_address < (1 << log2_root_size)`, using an unsigned comparison such as `math.ult`.
- Require `log2_target_size == 0` and `#sibling_hashes == log2_root_size`.
- Check that rolling `target_hash` up through `sibling_hashes` (or `verify_slice`) reproduces `proof.root_hash`.
- Cap the loop at `log2_max_leaves + 1` as defense in depth.

Optionally, make the C++ JSON `Proof` parser reject `target_address` values that are out of range for `log2_root_size`.

**Severity**

Low. Both reviewers rated it low, and the prover rated it low to medium. The bug really hangs a library function and the CLI forever, and it silently builds wrong frontiers. But it is reached only with malformed, corrupted or untrusted proof files that the emulator never produces. It cannot make an honest player who uses genuine proofs lose a dispute, and the C API used by the Rollups Node and Dave is not involved.

**Risks**

- **Of the bug:** a validator or CLI hangs at 100% CPU on bad input instead of failing fast. A wrong frontier, wrong output numbering, and wrong outputs roots or proofs can follow from out-of-range or inconsistent input with no error raised.
- **Of the fix:** the root-hash consistency check costs `log2_root_size` hashes, which is negligible. Strict checks could reject callers that today pass proofs with extra fields or a non-zero `log2_target_size` on purpose, but none are known in this repo. The unsigned range check must handle `log2_root_size` 63 correctly, where `1 << 63` is negative in Lua.

**Proof of concept**

`bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua`. Run it from the repo root:

```
eval $(make -s env); lua5.4 bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua
```

It exits 1 and prints `BUG:` lines while the defect is present, and prints `PASS` once it is fixed. It writes `hang-proof.json`, `ok-proof.json`, `child_hang.lua` and `cli*.log` next to itself, and needs `cartesi-machine.lua` in `PATH`, which the env provides, plus the default kernel and rootfs images.

**ID**: `lua-05-frontier-from-proof-hang-and-no-validation`

### B16. verify_slice and verify_splice accept malformed proofs

**Title**: Lua `verify_slice`/`verify_splice` accept malformed proofs (address beyond root, unaligned address, extra siblings, target size above root size), and `frontier_next_proofs` on a full tree returns one

**Problem:** `roll_hash_up_tree` loops only over `log2_size = log2_target_size .. log2_root_size - 1`. It reads only those bits of `target_address` and only the first `log2_root_size - log2_target_size` entries of `sibling_hashes`. `verify_slice` and `verify_splice` only compare the rolled-up hash with `root_hash`, and check nothing about the shape of the proof. As a result, a valid proof also verifies when:
- (a) `k * 2^log2_root_size` is added to `target_address`, which puts it outside the tree;
- (b) address bits below `log2_target_size` are set, so the address is unaligned;
- (c) extra trailing siblings are appended;
- (d) `log2_target_size > log2_root_size`. The loop then never runs, so any proof with `target_hash == root_hash` "verifies" at any address.

The C++ `hash_tree_proof` (`src/hash-tree-proof.hpp:43-55`) rejects non-positive root sizes and a target size above the root size, and it sizes the sibling vector exactly. The Lua verifier enforces none of this.

Separately, `frontier_next_proofs` has no capacity check, unlike `frontier_push_back` and `frontier_append`, which assert "too many leaves". On a full frontier it returns a proof with `target_address == 2^height`, a leaf that cannot exist. Bit `height` is ignored, so the proof verifies as index 0.

**Origin:** Pre-existing. `roll_hash_up_tree`, `verify_slice`, `verify_splice` and `frontier_next_proofs` are identical on `origin/main` (v0.22.0, the merge base).

**Area:** Lua hash-tree library (`cartesi.hash-tree`): proof verification and output-frontier proofs.

**Category:** API contract / input validation.

**Location:**
- `src/cartesi/hash-tree.lua:9-23` (`roll_hash_up_tree`)
- `src/cartesi/hash-tree.lua:27-29` (`verify_slice`)
- `src/cartesi/hash-tree.lua:33-36` (`verify_splice`)
- `src/cartesi/hash-tree.lua:310-359` (`frontier_next_proofs`, no `leaf_count + #next_output_hashes <= 2^log2_max_leaves` check)

**Evidence:** The test builds proofs that are valid at first: a height-63 outputs-tree proof from `frontier_next_proofs`, and a 32-byte word proof from `machine:get_proof`. It then mutates each proof into a non-canonical form and calls `verify_slice`/`verify_splice`. It also calls `frontier_next_proofs` on a full height-2 frontier. All 6 non-canonical cases are accepted. The one rejected case (address bit 63 with `log2_root_size` 64) is rejected only because that bit falls inside the range the verifier reads.
```
$ eval $(make -s env); lua5.4 bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua
baseline: index	2	verifies
BUG: verify_slice accepted target_address beyond tree (0x8000000000000002 >= 2^63)
BUG: verify_slice accepted proof with 2 extra trailing siblings (65 vs 63)
BUG: verify_slice accepted log2_target_size > log2_root_size with target_hash == root_hash (arbitrary address 12345)
BUG: verify_slice accepted unaligned memory proof target_address 0x80000007 (log2_target_size 5)
ok: rejected memory proof target_address 0x8000000080000000 beyond 2^64 address space root (log2_root_size 64)
BUG: verify_slice accepted verify_splice with unaligned target_address
BUG: verify_slice accepted frontier_next_proofs(full height-2 frontier) proof at target_address 4 (tree has 4 leaves)
BUG: 6 non-canonical proofs accepted
```
The test exits with status 1 while the bug is present.

**Scenario:** A third-party Lua validator, or any tool built on `cartesi.hash-tree`, receives an output proof or state proof from an untrusted party. It calls `verify_slice(proof)`, then records the claim at `proof.target_address`, or derives the depth from `#proof.sibling_hashes`. An adversary can make it accept a claim at an index that does not exist (beyond the outputs tree, which has 2^63 leaves, or unaligned), or accept a degenerate "proof" in which the target is the root.

The bits that are actually read stay bound by the hashes. An attacker therefore cannot prove a false hash at a different valid, in-range, aligned position. The address only aliases the true position.

The reference `doc/recipes/prt.lua` is not affected, because it checks `target_address` exactly before calling `verify_slice` (lines 207-212 and 318-324). The Rollups Node and Dave are not affected either: they use the C API, which does not expose proof verification.

The `frontier_next_proofs` overflow cannot be reached with the real outputs tree (height 63). It occurs only with small custom heights that are deliberately filled.

**Possible solution:**
- In `verify_slice` and `verify_splice` (or in `roll_hash_up_tree`), require all of the following:
  - integer sizes with `0 <= log2_target_size <= log2_root_size <= 64`;
  - `#sibling_hashes == log2_root_size - log2_target_size`;
  - `target_address & ((1 << log2_target_size) - 1) == 0`;
  - `target_address >> log2_root_size == 0` when `log2_root_size < 64`.
- In `frontier_next_proofs`, assert `leaf_count + #next_output_hashes <= 1 << log2_max_leaves`, with the message "too many leaves".

**Severity:** Low. Both reviewers rated it low; the original suspicion was medium. The emulator never produces a wrong or nondeterministic hash, root or proof for valid inputs. The PRT reference node and the C API consumers are not affected. Harm requires a Lua caller that skips its own shape checks and trusts the free address bits or the sibling count. Even then it cannot prove a false hash at a real position.

**Risks:**
- *Of the bug:* Lua validators built on this API may silently accept claims at fabricated indices, out of range or unaligned. This can mislead bookkeeping, for example output indexes or leaf positions, or a decision to dispute. A full-frontier misuse yields a "valid" proof for a leaf that does not exist.
- *Of the fix:* Stricter checks could reject proofs that callers build by hand with non-canonical fields. Examples are `log2_root_size` 64 with `target_address` near 2^64, which needs care because Lua integers are signed, and callers that pad `sibling_hashes`. The new assertions must not break the proofs from `machine:get_proof` or the uarch/mcycle proofs that `prt.lua` builds. Both are canonical today.

**Proof of concept:** `bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua`. It needs no machine images: it builds a RAM-only machine. Run it from the repo root:
`eval $(make -s env); lua5.4 bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua`
Exit status 1 with `BUG:` lines means the bug reproduces. Exit status 0 with "all non-canonical proofs rejected" means it is fixed.

**ID**: `lua-06-verify-slice-noncanonical-address`

**Related**: [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity).

### B17. ABI decoder rejects canonical empty arrays of dynamic types

**Title**: evmu `decode_array` returns a nil end offset for an empty `T[]` with dynamic `T`, so `decode_abi`/`decode_calldata` reject canonical data

**Problem:** In `decode_array`, when the element type is dynamic (`bytes`, `string`, `T[]`, or a tuple with dynamic members), the end offset `last_offset` is declared nil and assigned only inside `for i = 1, size`. For an empty array (`size == 0`), the function returns `result, nil` when it should return the offset just past the length word. `decode_tuple` copies that nil into its `new_offset`. If no later dynamic component overwrites it, the tuple returns nil as its end offset, and the final length checks fail on valid, canonical ABI data. The nil also passes up through enclosing arrays and tuples, so `bytes[][]` holding one empty inner array fails too. Because the encoder is correct, `encode_abi` followed by `decode_abi` is not a round trip.

**Origin:** Pre-existing. The `decode_array`/`decode_tuple` code is the same on `main`, where `decode_calldata` already had the bug. This branch adds the public `decode_abi`, which reuses the same helper for event log data and `eth_call` return values. That gives callers a new way to hit the bug.

**Area:** Lua library `cartesi.evmu`, the ABI decoder (`src/cartesi/evmu.lua`).

**Category:** Correctness (canonical input rejected; robustness/DoS).

**Location:**
- `src/cartesi/evmu.lua:742-750`: `decode_array`, dynamic-element branch (`local last_offset` is set only inside the loop; `return result, last_offset`)
- `src/cartesi/evmu.lua:776`: `decode_tuple` copies the nil into `new_offset`
- `src/cartesi/evmu.lua:831`: `decode_calldata` `assert(offset == #calldata_raw, "calldata too long")`
- `src/cartesi/evmu.lua:846`: `decode_abi` `assert(offset == #data, "ABI data too long")`

**Evidence:** The test encodes values with `evmu.encode_abi`/`encode_calldata` and decodes them back. `encode_abi("(bytes[])", {{}})` produces the canonical 64 bytes (offset `0x20`, length `0`), which is the same as Solidity's `abi.encode(new bytes[](0))`. The non-empty control case passes, and every empty case fails:
```
$ eval $(make -s env); lua5.4 bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua
ok:  abi (bytes[])
BUG: abi (bytes[]) round trip with empty dynamic-element array fails: .../src/cartesi/evmu.lua:846: ABI data too long
BUG: abi (string[]) ... :846: ABI data too long
BUG: abi (uint256,string[]) ... :846: ABI data too long
BUG: abi ((uint256,bytes)[]) ... :846: ABI data too long
BUG: abi (bytes[][]) ... :846: ABI data too long
BUG: calldata f(bytes[]) ... :831: calldata too long
BUG: calldata f(string[],uint256) ... :831: calldata too long
exit=1
```
Reviewers also found that `(bytes[],uint256)` fails, while `(bytes[],bytes)` decodes because the later dynamic component overwrites the nil. This matches the code path described above.

**Scenario:** A Lua validator or tool built on `cartesi.evmu` decodes something that carries an empty `bytes[]`, `string[]` or tuple-with-dynamic `[]` array: a contract event, an `eth_call` return value, or an input or calldata payload. A real-world example is an empty batch. `decode_abi`/`decode_calldata` raise an error on this legitimate data. If the caller does not wrap the call in `pcall`, its event-processing loop stops, and a PRT validator could miss dispute deadlines. The in-tree experimental PRT node does not use such types today, so it is not affected. The Rollups Node and Dave use the C API, not this Lua library. Hashes, proofs and machine state are not involved.

**Possible solution:** In the dynamic-element branch, initialize the end offset to the end of the offsets head: `local last_offset = new_offset + size * 32`. Equivalently, return `size == 0 and new_offset or last_offset`. A more robust fix tracks the maximum end offset over all elements, instead of assuming the last element's data comes last. The same reasoning applies to `decode_tuple`: it should use the maximum end over its dynamic components.

**Severity:** Medium. A shipped public Lua API deterministically errors on valid, canonical ABI data, and encode followed by decode does not round-trip. The error is loud and catchable with `pcall`, never yields wrong decoded values, does not affect hashes or proofs, and does not hit the in-tree PRT node. Both reviewers rated it medium (arguably low).

**Risks:** Bug: a Lua consumer of `decode_abi`/`decode_calldata` (validator, indexer or tool) can stall or crash on legitimate events or inputs containing empty dynamic-element arrays. Fix: low risk, a local change to the end-offset calculation. Switching to "maximum end" semantics would also change the "too long" check for non-canonical but valid layouts (for example, out-of-order element data), so add round-trip tests for nested and mixed types.

**Proof of concept:** `bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 once it is fixed.

**ID**: `lua-09-evmu-decode-empty-dynamic-element-array`

### B18. ABI decoder bounds checks overflow and accept out-of-bounds offsets

**Title**: evmu ABI decoder: integer overflow in offset/length bounds checks lets out-of-bounds dynamic offsets and lengths decode silently as empty or zero values (`decode_abi`, `decode_calldata`)

**Problem:** `check_lua_uint` only rejects values of 2^63 or more. Offsets and lengths up to `0x7fffffffffffffff` therefore become Lua integers, and the decoder adds them with no overflow check:
- `tuple_start + offset` in `decode_tuple`
- `array_data_start + offset` in `decode_array`
- `offset + 32` in `read_word`
- `n + 31` in `ceil32`
- `new_offset + padded_len` in `decode_string` and `decode_bytes`

Lua integer arithmetic wraps, so a sum can become negative. The guard `x > #calldata` is then false and decoding carries on: `calldata:sub(...)` with a start past the end, or a negative end, returns `""`, and `bint.frombe(word_padding .. "")` gives 0. A length of 0 then decodes as an empty value, with a negative "next offset".

The only end-of-data check (`offset == #data` in `decode_abi` and `decode_calldata`) never sees the corrupted component. `decode_tuple` overwrites `new_offset` with each dynamic component's end, so the check only covers the last dynamic component. An earlier `bytes`/`string`/array component with an out-of-bounds offset or length is accepted silently and comes back as `"0x"` or `""`. Solidity's `abi.decode` reverts on all of these inputs. The overflow is the whole defect: offsets that are too large but do not wrap are correctly rejected with "insufficient calldata".

**Origin:** Pre-existing. The decoder logic predates this branch and is reachable through `decode_calldata`. This branch adds a new public entry point, `decode_abi`, that uses the same decoder, and the PRT recipes call it on chain return data.

**Area:** Lua library `cartesi.evmu` (ABI decoder: `decode_abi`, `decode_calldata`, `decode_calldata_hex`).

**Category:** Correctness: input validation, integer overflow in bounds checks.

**Location:**
- `src/cartesi/evmu.lua:45`: `ceil32` (`(n + 31) // 32` wraps)
- `src/cartesi/evmu.lua:48-53`: `check_lua_uint` (limit 2^63, not `#calldata`)
- `src/cartesi/evmu.lua:643`: `read_word` bounds check `offset + 32 > #calldata`
- `src/cartesi/evmu.lua:693-699`: `decode_string`
- `src/cartesi/evmu.lua:716-721`: `decode_bytes` (dynamic)
- `src/cartesi/evmu.lua:747`: `decode_array` element offset
- `src/cartesi/evmu.lua:775-776`: `decode_tuple` dynamic offset and the `new_offset` overwrite
- `src/cartesi/evmu.lua:831, 846`: end checks in `decode_calldata` and `decode_abi`, which only see the last component's end

**Evidence:** The test builds five malformed encodings and passes them to the public `evmu.decode_abi` / `evmu.decode_calldata`. It first checks that a valid encoding round-trips. All five malformed encodings decode without error:
```
BUG: (bytes,bytes) offset 0x7ffffffffffffff0: decode accepted malformed data, returned {0x, 0xcd}
BUG: (bytes,bytes) length 0x7fffffffffffffff: decode accepted malformed data, returned {0x, 0xcd}
BUG: (string,string) offset 0x7ffffffffffffff0: decode accepted malformed data, returned {, x}
BUG: decode_calldata f(bytes[],bytes) element offset overflow: decode accepted malformed data, returned {table: 0x..., 0xcd}
BUG: (address,uint256,bytes,bytes) payload offset overflow: decode accepted malformed data, returned {0x1111111111111111111111111111111111111111, 5, 0x, 0x}
BUG: 5 malformed encodings decoded without error (Solidity abi.decode reverts)
exit=1
```
Run: `eval $(make -s env); lua5.4 bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua`

**Scenario:** An off-chain Lua tool, indexer or alternative validator uses `evmu.decode_calldata` to interpret machine outputs, as `vgu.lua`, `cartesi-rollup-data.lua` and the rolling-calculator recipes do with `Notice`/`Voucher`. It may also use `decode_abi` on chain data, as `prt-bridge.lua` and `prt-deploy.lua` do. An application, buggy or malicious, emits a `Voucher(address,uint256,bytes)`-style output whose payload offset or length is near 2^63. The Lua decoder accepts it and reports an empty payload (or an empty string, or a zero-length array element). On chain, `abi.decode` on the same bytes reverts. So off-chain interpretation differs from on-chain behaviour: a tool may show or act on a "valid, empty" voucher or notice that can never be executed, or skip validation logic that assumes malformed data raises.

None of this touches machine state hashes, Merkle proofs, step logs or PRT commitments. In the PRT flow the decoded chain data is produced by Solidity contracts and is always well-formed.

**Possible solution:** Bounds-check every offset and length against `#calldata` before any arithmetic, for example in a helper `check_offset(value, base, calldata)` that rejects `value > #calldata - base`. Cap `check_lua_uint` results used as offsets or lengths at `#calldata` instead of 2^63. In `ceil32`, check the length against `#calldata` before rounding. In `read_word`, test `offset < 0 or offset > #calldata - 32`. Optionally, make `decode_tuple` track the maximum end over all dynamic components (or check that each one lies inside the data), so the end-of-data check is meaningful for every component and not just the last.

**Severity:** Low. It is a real correctness defect in a shipped Lua library: it silently accepts out-of-bounds ABI data where Solidity reverts. However:
- It needs deliberately crafted offsets or lengths near 2^63.
- It cannot change hashes, proofs or step logs, so it cannot make an honest PRT player lose a dispute.
- It causes no crash or hang.
- The PRT callers decode contract-produced data.

The prover suggested medium/low and both reviewers rated it low. Low-medium is at most justified for third-party indexers that rely on `evmu` to validate untrusted application outputs.

**Risks:**
- Of the bug: off-chain consumers misread malformed outputs or inputs as valid with empty or zero fields, so off-chain views (indexers, explorers, tooling that decides whether to submit a voucher) diverge from on-chain execution.
- Of the fix: stricter checks may start rejecting encodings that were previously, and wrongly, accepted. That is the desired behaviour, but callers that do not wrap decode in `pcall` would now raise. Tracking the maximum dynamic end must not reject valid encodings whose dynamic tails are out of order or overlap (Solidity accepts those), so the fix should check per-component bounds rather than demand a contiguous layout.

**Proof of concept:** `bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua
```
It exits 1 and prints `BUG:` lines while the defect is present, and exits 0 with `PASS` once every malformed encoding is rejected.

**ID**: `lua-10-evmu-offset-length-overflow-accepts-oob`

### B19. ABI type parser mangles parameter names starting with memory, storage or calldata

**Title**: evmu type parser splits parameter names that start with `memory`/`storage`/`calldata`, so named encode/decode uses the wrong field

**Problem:** In the `cartesi.evmu` type-spec grammar, the `data_location` rule is `P("memory") + P("calldata") + P("storage")`. It has no identifier-boundary check (`idnot`), and the int/bytes size rules in the same file do have one. `type_spec` matches `C(V("data_location")^-1) * opsp * C(identifier^-1)`, and `opsp` allows zero spaces. As a result, a parameter name that begins with one of these keywords gets split in two. `uint256 storageRoot` parses as data_location `storage` with name `Root`. `memoryIndex` becomes `Index`, `calldataHash` becomes `Hash`, and `storage_x` becomes `_x`. Every named spec gets these wrong names:
- `parse_type_spec` and `parse_func_sig` return the wrong `name`.
- `decode_abi`, `decode_calldata` and `decode_calldata_hex` return the value under the mangled key, so `v.storageRoot` is `nil`.
- `encode_abi`, `encode_calldata` and `encode_calldata_hex` reject a correctly named argument table with `unexpected tuple component with name "storageRoot"`.

**Origin:** Pre-existing. The grammar line is the same on `main`. This branch adds `encode_abi` and `decode_abi`, which are used for event data and return values. Those specs are usually built from ABI JSON with names, so the new functions make the bug easier to hit.

**Area:** Lua library `cartesi.evmu` (`src/cartesi/evmu.lua`), the EVM ABI helper that ships in the emulator package.

**Category:** Correctness (parser / ABI encoding and decoding).

**Location:**
- `src/cartesi/evmu.lua:127`: the `data_location` rule, missing `* idnot`
- `src/cartesi/evmu.lua:129-141`: `type_spec` uses that rule and assigns `name` and `data_location`
- `src/cartesi/evmu.lua:100`: `idnot`, already defined and not applied here
- Affected entry points:
  - `parse_func_sig` (`:280`) and `parse_type_spec` (`:299`)
  - `encode_calldata` and `encode_calldata_hex` (`:611`, `:623`)
  - `encode_abi` (`:627`)
  - `decode_calldata` and `decode_calldata_hex` (`:820`, `:836`)
  - `decode_abi` (`:842`)

**Evidence:** The test parses, decodes and encodes specs whose parameter names start with each keyword. Run it with `eval $(make -s env); lua5.4 bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua`. Output:
```
BUG: parameter "storageRoot" parsed as name=Root data_location=storage
BUG: parameter "memoryIndex" parsed as name=Index data_location=memory
BUG: parameter "calldataHash" parsed as name=Hash data_location=calldata
BUG: parameter "storage_x" parsed as name=_x data_location=storage
BUG: decode_abi named fields missing: storageRoot=nil memoryIndex=nil; keys present: 1,2,Index,Root
BUG: encode_abi with {storageRoot=7} failed: .../src/cartesi/evmu.lua:39: unexpected tuple component with name "storageRoot"
BUG: encode_calldata with {calldataHash=...} failed: .../src/cartesi/evmu.lua:39: unexpected tuple component with name "calldataHash"
exit=1
```
With the one-line fix below, the same test prints `OK: ...` and exits 0. It also checks that `(bytes memory payload)` still parses as data_location `memory` with name `payload`.

**Scenario:** A validator node or tool builds encode/decode specs from a contract's ABI JSON, keeping the parameter names. Examples are event arguments or function return values decoded with `decode_abi`, or calls built with `encode_calldata`. Names such as `storageRoot`, `memoryHash` and `calldataSize` are legal in Solidity and appear in real contracts.
- Decoding puts the field under `Root`, `Hash` or `Size`, so the caller reads `nil` and fails, or may misread the data.
- Encoding a named argument table throws.

The PRT node in this branch uses only unnamed specs such as `(uint64)` (`prt-bridge.lua`), so it does not hit the bug. Third-party validators and tools that use names would.

**Possible solution:** Add an identifier boundary to the keyword rule:
```lua
data_location = (P("memory") + P("calldata") + P("storage")) * idnot,
```
This fix was verified in a patched copy. Separately, `idfirst`/`idrest` reject `$`, which Solidity allows in identifiers. That is a different grammar limitation and is not covered by this test.

**Severity:** Low. Both reviewers confirmed the bug and rated it low; the prover's medium was not adopted. It is a real bug in a shipped Lua helper, but the impact is narrow:
- Nothing touches state hashes, proofs, step logs or the C API.
- The decoded value is correct and only its key is wrong.
- Failures are usually loud: a nil field or an encode error.
- The trigger is uncommon: a named spec whose name starts with one of the three keywords.

**Risks:**
- Bug: a caller may misread data or fail when decoding events or return values under the expected field name. An encode error may also stop a transaction or query from being built. This can disrupt tools or nodes that rely on names taken from ABI JSON.
- Fix: minimal. Real data locations are always followed by whitespace or the end of the input, and `idnot` accepts both, so `bytes memory payload` and `string calldata` still parse. The only change in behaviour is that names starting with these keywords are now kept whole.

**Proof of concept:** `bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua
```
It exits 1 and prints `BUG: ...` lines while the bug is present. It exits 0 and prints `OK: ...` once fixed.

**ID**: `lua-11-evmu-param-name-data-location-prefix-mangled`

### B20. frontier_next_proofs does not check tree capacity

**Title**: `frontier_next_proofs` does not check tree capacity, so on overflow or a full frontier it returns out-of-tree proofs against a wrong root, while `push_back` and `append` reject the same input

**Problem:** `frontier_next_proofs(frontier, next_output_hashes)` reads `leaf_count` and builds one proof per new hash. It never checks two things:
- that `leaf_count + #next_output_hashes <= 2^log2_max_leaves`;
- that the frontier is not already full (its top entry is unset).

The sibling functions do check both. `frontier_push_back` asserts `not frontier[#frontier]`, and `frontier_append` and `frontier_pad_back` assert `frontier_padding_fits(...)`. When the check is missing, `frontier_next_proofs` returns well-formed proofs instead of raising "too many leaves":
- **Partial overflow.** Proofs get `target_address` values outside the tree, and `root_hash` is whatever ends up in `active[1]`.
- **Full frontier.** `frontier_get_leaf_count` wraps to 0, and `frontier[1..L]` are all `false`, because only the top entry is set. The function therefore treats the tree as empty and returns a proof whose root is the root of `{new, pristine, ...}`. The existing leaves are ignored.

`verify_slice` only rolls the hash up `log2_root_size` levels and ignores the higher address bits. So some of these bogus proofs verify, including the full-frontier proof, which verifies against an unrelated root.

**Origin:** Pre-existing. The function is identical on `main` (`src/cartesi/hash-tree.lua:309`).

**Area:** Lua library `cartesi.hash-tree`, the frontier and output-proof API (`frontier_next_proofs`, with `verify_slice` aliasing the address).

**Category:** Correctness / missing precondition check (API inconsistency).

**Location:**
- `src/cartesi/hash-tree.lua:310-360` (`frontier_next_proofs`: no capacity or full check)
- `src/cartesi/hash-tree.lua:144` (`frontier_padding_fits`), `:169` (`frontier_push_back`), `:191` (`frontier_append`), `:262` (`frontier_pad_back`): the checks that the sibling functions do perform
- `src/cartesi/hash-tree.lua:28-30` (`verify_slice`: does not reject `target_address >= 2^log2_root_size`)
- Callers: `src/cartesi-machine.lua:3474` (`save_cmio_output_proofs`), `doc/recipes/prt.lua:2302`, `doc/recipes/vg-test.lua:779`

**Evidence:** The test builds a height-2 (4-leaf) keccak256 frontier using only the public API.
- Case 1: with 3 leaves present, `frontier_append` rejects 3 more hashes, but `frontier_next_proofs` accepts them.
- Case 2: on a full 4-leaf frontier, `frontier_next_proofs` is asked for 1 more proof.
```
$ eval $(make -s env); lua5.4 bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua
BUG: overflow: next_proofs accepted 3 outputs into a 4-leaf tree holding 3 leaves (frontier_append rejects); target addresses {3,4,5} (tree has 4 leaves), 1 of 3 proofs pass verify_slice
BUG: full: next_proofs on a full frontier returned target_address=4 (out of tree), root differs from the real root, verify_slice=true
     (proof root == root of a tree holding only the new leaf; existing 4 leaves ignored)
exit=1
```
In the partial-overflow case, only the first proof (address 3) passes `verify_slice`. The other two have inconsistent roots.

**Scenario:** A library user, such as a validator node or tooling that serves output proofs, builds a small custom-height frontier, or by mistake feeds more leaves than fit. They get silently wrong proofs instead of an error, and a caller that does not compare `root_hash` against an independently computed root publishes them. In the full-frontier case, the proof even passes `verify_slice`.

The realistic PRT and Rollups paths are not exposed:
- Rollups outputs trees use `ROLLUP_LOG2_MAX_OUTPUT_COUNT = 63`, so an overflow would need about 2^63 outputs.
- The CLI's `save_cmio_output_proofs` grows the live frontier with `frontier_push_back`, which rejects overflow first. It also asserts `proofs[1].root_hash == frontier_get_root_hash(outputs_frontier)`.

**Possible solution:** At the top of `frontier_next_proofs`, after the empty-input early return, add `assert(frontier_padding_fits(frontier, next_output_count, 1), "too many leaves")`, mirroring `frontier_append`. This also covers the full-frontier case, because `frontier_padding_fits` fails when the top entry is set. As separate hardening, make `verify_slice` reject `target_address >= 2^log2_root_size` (and misaligned addresses), so that aliased out-of-tree proofs cannot verify.

**Severity:** Low. Both reviewers confirmed the defect and rated it low. It is a real silent-garbage API inconsistency, but height-63 rollup trees make overflow infeasible, and the shipped CLI rejects overflow earlier and checks the root. Only misuse with a small tree, combined with a missing root check, reaches it, so it does not threaten realistic PRT disputes.

**Risks:**
- Of the bug: callers with small trees, or callers that skip the root check, may emit or accept invalid output proofs. The `verify_slice` address aliasing means verification alone does not catch the full-frontier case.
- Of the fix: low. Callers that relied on the lenient behavior now get a "too many leaves" error. A `verify_slice` range check would also reject any existing proof that uses aliased high address bits. No legitimate in-tree caller produces such proofs.

**Proof of concept:** `bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua`. It exits with 1 and prints `BUG:` lines while the bug is present, and prints `OK: next_proofs rejects overflow` once it is fixed.

**ID**: `lua-12-next-proofs-no-capacity-check`

**Related**: [B16](#b16-verify_slice-and-verify_splice-accept-malformed-proofs).

### B21. frontier_next_proofs is wrong on trees of height 64 or more

**Title**: `frontier_next_proofs` returns wrong roots and proofs on trees of height >= 64 when the new leaves cross leaf index 2^63

**Problem:** `frontier_node` decides whether a node index belongs to the frontier, the active region or the pristine region. It does this with signed comparisons, `index < lo` and `index > hi`. `frontier_next_proofs` passes it global node indices: `(leaf_count + i - 1) >> bit`, `node ~ 1`, `2*p` and `2*p + 1`.

On a tree of height 64 or more, those indices can reach 2^63 and above. Lua then reads them as negative integers. Once the active range crosses the sign boundary (`lo` positive, `hi` or the index negative), the node is put in the wrong region. The function returns the frontier entry or the pristine hash where it should return the active node. Every resulting sibling and root is silently wrong.

The rest of the module treats indices as unsigned:
- right shifts are logical;
- `frontier_pad_back` uses `math.ult`;
- `frontier_get_leaf_count` accepts bit 63;
- `frontier_padding_fits` is documented as supporting "trees taller than a Lua integer".

**Origin:** pre-existing. The same `frontier_node` code is on `origin/main` (line 97).

**Area:** Lua hash-tree frontier library (`cartesi.hash-tree`), which ships as part of the emulator's Lua API.

**Category:** correctness (silent wrong result, integer signedness).

**Location:**
- `src/cartesi/hash-tree.lua:96-106` (`frontier_node`: `if index < lo` / `elseif index > hi`)
- `src/cartesi/hash-tree.lua:332` (sibling lookup in `frontier_next_proofs`)
- `src/cartesi/hash-tree.lua:336-340` (parent loop in `frontier_next_proofs`)

**Evidence:** The test builds a height-64 frontier whose levels 1..63 are filled, so the leaf count is 2^63-1. It then calls `frontier_next_proofs` with 3 leaf hashes. Each proof is compared with the root from `frontier_push_back` + `frontier_get_root_hash`, and each is checked with `verify_slice` and `roll_hash_up_tree`. A control case also runs: height 64 with leaf count 1023, where nothing crosses 2^63. The control passes, while all 3 proofs of the crossing case are wrong:
```
$ eval $(make -s env); lua5.4 bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua
control (leaf count 1023, height 64): OK
proof 1 target_address=0x7fffffffffffffff root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
proof 2 target_address=0x8000000000000000 root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
proof 3 target_address=0x8000000000000001 root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
BUG: frontier_next_proofs produced 3/3 wrong proofs for height-64 tree when range crosses 2^63
```
(exit 1). The prover patched the two comparisons to `math.ult(index, lo)` / `math.ult(hi, index)`. With that change the same test prints all `true` and `OK`, and exits 0.

**Scenario:** A tool or validator uses the exported generic frontier API on a tree of height >= 64, for example:
- a custom accumulator;
- a frontier rebuilt from a stored proof using the `frontier(last_proof)` constructor with `target_address` near 2^63;
- a frontier built with `frontier_push_back` on large subtrees.

It then asks `frontier_next_proofs` for proofs of leaves whose range crosses index 2^63. It gets proofs that fail verification, with roots that differ from `frontier_get_root_hash`, and no error is raised.

The PRT/CMIO outputs tree used by `cartesi-machine.lua`, `prt.lua`, the Rollups Node and Dave has height 63. Its leaf indices stay below 2^63, so the honest PRT path is not affected. `frontier_forest` also rejects heights >= 63.

**Possible solution:** Make the region test unsigned in `frontier_node`:
```lua
if math.ult(index, lo) then return frontier_entry
elseif math.ult(hi, index) then return pristine_entry
else return active[index - lo + 1] end
```
`active[index - lo + 1]` is already correct under two's-complement wrap-around. The `for p = parents_base, (base + #active - 1) >> 1` loop also runs correctly, because both bounds come from logical shifts and so are below 2^63. If supporting heights above 64 is not intended, `frontier_next_proofs` should instead assert `log2_max_leaves < 64`, or `leaf_count + next_output_count - 1` must not wrap.

**Severity:** low. All reviewers agree. The API silently returns a wrong result, but only for trees of height >= 64 holding about 2^63 leaves. No CLI, PRT, Rollups or Dave path can reach that, because the outputs tree has height 63. Getting there in practice also needs a hand-built or reconstructed frontier.

**Risks:**
- Of the bug: a third-party tool using the generic frontier API on a tall tree gets unverifiable proofs or a wrong root without any error. If such a root were committed, it would not match an independently computed root.
- Of the fix: minimal. For indices below 2^63, `math.ult` behaves exactly like the signed comparison, so results for the height-63 outputs tree and for every existing caller stay the same.

**Proof of concept:** `bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua`. It needs no machine images. It exits 1 and prints `BUG:` while the bug is present, and prints `OK` (exit 0) once fixed.

**ID**: `lua-13-next-proofs-signed-compare-ge64`

**Related**: [B22](#b22-frontier_pad_back-rejects-valid-counts-and-corrupts-very-tall-frontiers).

### B22. frontier_pad_back rejects valid counts and corrupts very tall frontiers

**Title**: frontier_pad_back rejects valid counts >= 2^63 and corrupts the frontier when the tree is more than 64 levels above the pad height

**Problem:** `frontier_pad_back` treats `count` as an unsigned 64-bit integer. `frontier_padding_fits` uses logical shifts and scans up to `max(height, 63)`, and phase 1 compares with `math.ult`. Phase 1 also computes `local size = 1 << (level - first_level)`. In Lua a shift of 64 or more gives 0, so once the cursor is 64 or more levels above `first_level`, `math.ult(count, 0)` is false and the loop does not stop. At the next occupied level it folds `pad_hashes[level]` in, subtracts 0 from `count`, and leaves the result on the same level. The next pass sees that level occupied and folds again, so the carry runs to the top, where `assert(level < top, "too many leaves")` fires. `frontier_padding_fits` had already accepted the count, and the call has already rewritten the low levels of the frontier in place. This breaks the documented rule that a failing call changes nothing. Any remaining count >= 2^63 triggers it once the cursor reaches offset 64 and some level at offset 64 or above is occupied. That includes exactly 2^63 when the offset-63 level is empty. The call always fails with an assert. No case was found where it returns a wrong root hash.

**Origin:** pre-existing. `origin/main` has the same phase-1 code.

**Area:** Lua hash-tree frontier (`cartesi.hash-tree` module, exported as `frontier_pad_back`).

**Category:** correctness / error-path state corruption.

**Location:**
- `src/cartesi/hash-tree.lua:274`: `local size = 1 << (level - first_level)`, which is 0 for offsets of 64 or more
- `src/cartesi/hash-tree.lua:275`: `if math.ult(count, size) then break end`, which never breaks when `size == 0`
- `src/cartesi/hash-tree.lua:279`: `assert(level < top, "too many leaves")`, the assert that fires after the frontier has been mutated
- `src/cartesi/hash-tree.lua:144` (`frontier_padding_fits`) and `:262`: the fits check that accepts the count

**Evidence:** The test builds `frontier(66)` holding one height-65 subtree and pads it with `count = -1` (2^64-1 unsigned; 2^65 + 2^64 - 1 < 2^66, so it fits). It then builds `frontier(70)` holding one height-65 subtree and pads it with `1 << 63`. Each case is compared with the same padding done as two smaller calls, which succeed.
```
$ eval $(make -s env); lua5.4 bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua
single-call pad_back(2^64-1):	false	.../src/cartesi/hash-tree.lua:279: too many leaves
BUG: frontier_pad_back rejected a fitting count 2^64-1 in a height-66 tree: ...:279: too many leaves
BUG: the failing frontier_pad_back call mutated the frontier
height-70 pad_back(2^63):	false	.../src/cartesi/hash-tree.lua:279: too many leaves
BUG: height-70 frontier_pad_back rejected fitting count 2^63: ...:279: too many leaves
BUG: the failing call mutated the height-70 frontier
exit=1
```
With the fix below applied to a copy of `hash-tree.lua`, both cases succeed and match the split-call roots (`OK`, exit 0).

**Scenario:** A validator other than the shipped node uses the public `cartesi.hash-tree` API to build a tall frontier, for example over the PRT computation tree, which is 24+48+20 = 92 levels. It pads in one call with a large unsigned-wrapped count (>= 2^63, a negative Lua integer). It gets a spurious "too many leaves" error. If it catches the error with `pcall` and keeps the frontier, it continues from a partly rewritten frontier, and later roots or proofs built from that frontier are wrong. Shipped callers are not affected. The PRT node uses `frontier_forest_pad_back`, which rejects negative counts. The `cartesi-machine` CLI calls `frontier_pad_back` (`src/cartesi-machine.lua` around lines 4036, 4104, 4159, 4198) only with small per-input, per-bundle or per-period counts. Output trees are 63 levels or shorter, where this path cannot run. Padding to the root uses `count = nil`, which takes a separate path that works.

**Possible solution:** In phase 1, break out of the loop when `level - first_level >= 64`. A count below 2^64 can never need a pad subtree of 2^64 or more entries. Phase 2 already handles `size == 0` correctly, because `count & 0 == 0`. A more general option is to validate everything first, or to work on a copy and commit only on success, so that no failing path leaves the frontier changed.

**Severity:** low. Both reviewers and the prover agree. Triggering it takes a frontier more than 64 levels above the pad height and a single pad count of 2^63 or more passed as a wrapped negative integer. No shipped caller does this. The failure is always loud and never yields a wrong or nondeterministic hash. The only lasting harm is a frontier mutated by a rejected call.

**Risks:** Bug: a caller that recovers from the error and keeps using the frontier works from corrupted state, which could produce wrong roots. Fix: very low. The early break only affects offsets of 64 or more, where `size` was already meaningless, and phase 2 places the remaining bits as before. Results for counts below 2^63 or for frontiers of height 64 or less do not change.

**Proof of concept:** `bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua`. It exits 1 while the bug is present and prints `OK` once fixed. Run from the repo root:
`eval $(make -s env); lua5.4 bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua`

**ID**: `lua-14-pad-back-tall-tree-size-wrap`

**Related**: [B21](#b21-frontier_next_proofs-is-wrong-on-trees-of-height-64-or-more).

### B23. JSON-RPC protocol version not bumped for the new clear_hash_tree API

**Title**: JSON-RPC protocol version left at 0.8 although the branch adds `machine.clear_hash_tree` and `runtime_config.clear_hash_tree`

**Problem:** The branch adds a new RPC method, `machine.clear_hash_tree`, and a new runtime-config field, `clear_hash_tree`, to the JSON-RPC protocol. It does not bump the protocol version, which stays at 0.8.0, the value shipped in v0.22.0.

The client's handshake only requires the server to have the same major.minor. So a branch client accepts an older (main / v0.22.0) `cartesi-jsonrpc-machine`. That server parses `machine_runtime_config` by reading only the fields it knows, so it drops `clear_hash_tree=true` without an error. As a result:
- `create`/`load` with `{clear_hash_tree=true}` succeeds, but the cached hash tree is never cleared;
- `get_runtime_config().clear_hash_tree` returns `false`;
- an explicit `clear_hash_tree()` fails only later, with a method-not-found error.

The version handshake exists to catch exactly this kind of mismatch, and here it does not.

**Origin:** Introduced by this branch. The new method and field were added, but `src/jsonrpc-version.hpp` is unchanged from `origin/main`.

**Area:** JSON-RPC client/server version handshake (`cartesi.jsonrpc` Lua module, C API `cm_jsonrpc_*`, `cartesi-jsonrpc-machine`).

**Category:** API contract / version compatibility.

**Location:**
- `src/jsonrpc-version.hpp:24-26`: `JSONRPC_VERSION_MAJOR/MINOR/PATCH = 0/8/0`, not bumped.
- `src/jsonrpc-machine.cpp:407-414`: `check_server_version` compares only major/minor; called at lines 430 and 559.
- `src/json-util.cpp:1130-1140`: `ju_get_opt_field(..., machine_runtime_config&)` reads only known keys and ignores unknown ones. This is how the older server drops the field.
- `src/jsonrpc-remote-machine.cpp:1285-1294,1856`: the new `machine.clear_hash_tree` handler. Client side: `src/jsonrpc-machine.cpp:908-911`.
- `src/json-util.cpp:1139,2583`, `src/machine-runtime-config.hpp:88`, `src/machine.cpp:316`: the new runtime field.

**Evidence:** `run.sh` builds `cartesi-jsonrpc-machine` from `git archive origin/main`, then runs the branch Lua client against it. Run from the repo root with `eval $(make -s env); bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh`:
```
client library version:	0.22.0
handshake accepted, server protocol version 0.8.0
create({...}, {clear_hash_tree=true}) succeeded; get_runtime_config().clear_hash_tree =	false
BUG: runtime option clear_hash_tree=true silently ignored by a server that passed the version handshake
clear_hash_tree() failed only now: .../test.lua:55: machine.clear_hash_tree
BUG: client accepted a server (same protocol 0.8) that does not implement machine.clear_hash_tree
exit=1
```
Control run against the branch server (`CARTESI_JSONRPC_MACHINE=src/cartesi-jsonrpc-machine`): `clear_hash_tree = true`, exit 0.

**Scenario:** An operator of a PRT validator (Rollups Node, Dave or a custom node) upgrades the emulator library or Lua client but keeps an older `cartesi-jsonrpc-machine` binary or container image, for example in a split client/server deployment. The node spawns or connects to the server and passes `clear_hash_tree=true` on `create`/`load` to throw away a possibly stale or untrusted cached hash tree. The handshake succeeds and the option is silently skipped, so the node keeps working from the cached tree. If the node only calls `clear_hash_tree()` later, it gets a "method not found" error in the middle of a run instead of a clear incompatibility error at connect time.

Two things limit the impact:
- an older server cannot load machines stored by the branch (config archive version 8 vs 9), so the silent skip mostly affects `create`, or machines stored by the older server itself;
- skipping the clear only gives a wrong hash if the on-disk cache is actually stale or corrupted.

**Possible solution:** Bump `JSONRPC_VERSION_MINOR` to 9 in `src/jsonrpc-version.hpp`, with a CHANGELOG line ("Bumped JSON-RPC protocol version to 0.9.0"), as v0.21.0 and v0.22.0 did, so the handshake rejects older servers. As defence in depth, the server could also reject unknown keys in `runtime_config` (and other config objects) rather than ignoring them.

**Severity:** Low. Both reviewers agree. It needs a newer client paired with an older server, and its only direct effect is a skipped defensive hash-tree clear plus a late method-not-found error. No hash or proof is computed incorrectly unless the cached tree is already bad. The fix is a one-line version bump, which may already be planned for release, since the library version is also still 0.22.0 and the branch is "Unreleased".

**Risks:**
- Bug: in a mixed-version deployment, a validator that relies on `clear_hash_tree=true` to distrust a cached tree silently keeps using it. A corrupted cache could then produce wrong root hashes or proofs, and the honest player could lose a dispute.
- Bug: it also hides version skew that could break other new behaviour later.
- Fix: bumping the minor version makes 0.22.x servers and newer clients refuse each other at connect time. That is the intended outcome, but deployments that mix versions must upgrade both sides together.
- Fix: strict rejection of unknown config keys would break clients that send extra or forward-compatible fields.

**Proof of concept:** `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/test.lua` (Lua client test, which needs `CARTESI_JSONRPC_MACHINE` to point at an old server) and `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh` (the driver). The driver builds the old server once from `origin/main` into `${OLD_BUILD_DIR:-${TMPDIR:-/tmp}/rpc-04-old-server}`, which takes a few minutes; set `CARTESI_JSONRPC_MACHINE` to reuse an existing old binary and skip the build. Run from the repo root:
```
eval $(make -s env); bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh
```
Exit code 1 means the bug reproduced. Exit code 0 means it is fixed: the handshake rejects the old server, or the option is honoured.

**ID**: `rpc-04-jsonrpc-protocol-version-not-bumped`

**Related**: [B26](#b26---clear-hash-tree-is-silently-ignored-for-existing-remote-machines).

### B24. Temporary and frontier files are created with mode 0600 and without atomic O_CLOEXEC

**Title**: Frontier files from `hash_tree.frontier_store` and `frontier_forest_store`, including the CLI's `outputs_frontier` and computation `frontier` files, are created 0600 and ignore umask

**Problem:** `cartesi.hash-tree` writes its files through a local `write_file` helper. The helper creates a temporary file with `fs.new_temporary_file`, then syncs it and renames it over the target. `fs.new_temporary_file` calls `os::create_temporary_file`, which creates the file with `mkstemp` on POSIX (always 0600) or with `S_IRUSR|S_IWUSR` on Windows. `open_temporary_file` never calls `fchmod`, so every file this path writes is owner-only, whatever the umask is. Because the temporary file is renamed over the target, an existing 0644 file is also replaced by a 0600 one, and its mode is lost. On `main`, the CLI's `store_frontier` used `util.write_file` (`io.open`, mode 0666 & ~umask). It now calls `hash_tree.frontier_store`. As a result the CLI's `outputs_frontier` and `--mcycle-computation-hash=...,frontier:` files are 0600, while `state_hash`, `output_hashes` and the other epoch files written next to them stay 0644. Elsewhere `os-filesystem.cpp` creates files with `S_CREATE_FILE` (0644 before umask), so 0600 here is inconsistent with the rest of the code. It looks like an accidental side effect of switching to atomic writes, not a chosen contract.

**Origin:** Introduced by this branch. `os::create_temporary_file`, `fs.new_temporary_file`, `hash_tree.frontier_store`, `frontier_forest_store` and the hash-tree `write_file` are all new. The CLI change from `util.write_file` to `hash_tree.frontier_store` is in the branch diff.

**Area:** The `cartesi-machine` CLI's resumable epoch files, and the Lua library `cartesi.hash-tree` (`frontier_store`, `frontier_forest_store` and stored-tree files). The underlying `os::create_temporary_file` / `cartesi.filesystem.new_temporary_file` is also affected.

**Category:** API contract / file permissions (operational regression).

**Location:**
- `src/os-filesystem.cpp:647-663` (`open_temporary_file`: no `fchmod`)
- `src/os-filesystem.cpp:665-692` (`create_temporary_file`: `mkstemp` at 687, `S_IRUSR | S_IWUSR` at 676 on Windows)
- `src/cartesi/filesystem.lua:66-67` (`new_temporary_file`)
- `src/cartesi/hash-tree.lua:509-514` (`write_file`), callers at 592 (stored trees), 935-936 (`frontier_store`) and 967-988 (`frontier_forest_store`)
- `src/cartesi-machine.lua:3274-3277` (`store_frontier`), called at 3283 (`outputs_frontier`) and 4109 (computation `frontier`)

**Evidence:** `test_frontier_file_mode.lua` runs itself under `umask 022`. It writes a baseline file with `fs.write_file` and checks the mode of files written by `hash_tree.frontier_store` (to a new file and over an existing 0644 file) and by `frontier_forest_store`. It also runs the real CLI with `resumable:true` epoch files and a computation-hash `frontier`:
```
$ eval $(make -s env); lua5.4 bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua
fs.write_file (baseline)                                     mode 644 (expected 644)
hash_tree.frontier_store, new file                           mode 600 (expected 644)
hash_tree.frontier_store, overwriting existing 0644 file     mode 600 (expected 644)
hash_tree.frontier_forest_store, frontier file               mode 600 (expected 644)
hash_tree.frontier_forest_store, tree file 0x0aa7d3e8df...   mode 600 (expected 644)
CLI state_hash file                                          mode 644 (expected 644)
CLI output_hashes file                                       mode 644 (expected 644)
CLI outputs_frontier file                                    mode 600 (expected 644)
CLI computation frontier file                                mode 600 (expected 644)
...
BUG: frontier files are created mode 0600 (mkstemp) instead of honoring umask like other output files
```
The test exits 1 while the bug is present.

**Scenario:** A deployment runs `cartesi-machine` with resumable epoch files (`--cmio-advance-state=...,resumable:true,outputs_frontier:...` and/or `--mcycle-computation-hash=...,frontier:...`) as one uid. Another process reads them as a different uid, for example a sidecar container, a monitoring or verification tool, or a later run under a different service account on a shared volume. After the upgrade, the reader gets `EACCES` on the frontier files but can still read `state_hash`, so resuming or verifying the epoch fails. Lua tools that persist `hash_tree` frontiers or forests for a separate reader hit the same failure. An existing file that an operator deliberately made group- or world-readable silently becomes 0600 on its next rewrite. Hashes, proofs and determinism are not affected. The Rollups Node and Dave use the C API, which does not go through this path.

**Possible solution:** Give the temporary file the permissions a normal create would have before it is renamed. In `os::create_temporary_file` (or `open_temporary_file`), call `fchmod(fd, S_CREATE_FILE & ~current_umask)` or `0666 & ~umask`. The umask can be read with `m = umask(0); umask(m)` (not thread-safe, so read it once or under a lock) or from `/proc/self/status`. Alternatively, when the destination already exists, copy its mode with `fstat` + `fchmod`, so the rename keeps the original permissions. Fixing it in the C++ helper covers every caller (`frontier_store`, forest store, stored trees and any user of `fs.new_temporary_file`). If some caller does need private temporary files, add an explicit mode parameter instead of relying on mkstemp's default.

**Severity:** Low. Both reviewers agree. It is a real regression new on this branch, but it only affects operations. It needs a multi-uid deployment, fails loudly with `EACCES` rather than corrupting data, can be worked around with `chmod`/umask/uid changes, and cannot change any hash or proof or make an honest player lose a dispute.

**Risks:** Of the bug: resumable-epoch workflows split across users or containers break after the upgrade, and operator-set permissions on existing frontier files are silently narrowed. Of the fix: reading the umask with `umask()` is process-global and racy in multithreaded hosts, so it should be read once or replaced by a mode taken from the destination. Making the files readable again (0644) is the old behaviour and exposes only public hash data. Any caller that relies on `new_temporary_file` for private scratch files would need an opt-in private mode.

**Proof of concept:** `bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua` (self-contained; it re-executes itself under `umask 022`, creates its own temporary directory and small machine, and needs `cartesi-machine.lua` on `PATH`). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua
```
Exit code 1 means the bug is present; it prints `OK: all files honor umask` and exits 0 once fixed.

**ID**: `rpc-07-frontier-files-mode-0600`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-23-temp-file-cloexec-race-and-mode`: run with `eval $(make -s env); sh bugs/lua-23-temp-file-cloexec-race-and-mode/run.sh`. It also shows that `os::create_temporary_file` gets its fd from `mkstemp` without `O_CLOEXEC` and sets `FD_CLOEXEC` with a later `fcntl`, so a fork and exec on another thread in between inherits the fd. Use `mkostemp(..., O_CLOEXEC)` and `fchmod` to `0666 & ~umask`.

### B25. --clear-hash-tree is reapplied on every stored-mode revert

**Title**: `--clear-hash-tree` is reapplied on every `--revert-mode=stored` snapshot/revert reload, forcing a full-machine rehash per input

**Problem:** The help text says `--clear-hash-tree` clears cached hash-tree data once, "after creating or loading the machine". In practice the CLI puts the flag into the single shared `runtime_config` table (`clear_hash_tree = cmdline.clear_hash_tree`), and that same table goes to `new_revert_stored(machine, dir, runtime_config)`, which keeps it as `self.runtime_config`. Both `revert_stored:snapshot()` and `revert_stored:revert()` reload the machine with `m:load(self.machine_directory, self.runtime_config, cartesi.SHARING_ALL)`. The machine constructor calls `clear_hash_tree()` whenever `m_r.clear_hash_tree` is set. The result is that the tree is cleared at create/load, again in the setup snapshot inside `new_revert_stored`, and again at every per-input snapshot (advance and inspect) and every revert. Each of those clears throws away a hash tree the CLI has just synced to disk and marks every page dirty, so the next `get_root_hash` rehashes all of RAM and the flash drives.

**Origin:** Introduced by this branch. `--clear-hash-tree` and the `clear_hash_tree` runtime-config field do not exist on `origin/main`.

**Area:** `cartesi-machine` CLI (stored revert mode).

**Category:** Correctness (option applied far more often than specified), with a performance impact. Hashes stay correct.

**Location:**
- `src/cartesi-machine.lua:2809`: `runtime_config = { ..., clear_hash_tree = cmdline.clear_hash_tree }` (one shared table)
- `src/cartesi-machine.lua:3723-3732`: `revert_stored:snapshot()` reloads with `self.runtime_config`
- `src/cartesi-machine.lua:3744-3751`: `revert_stored:revert()` reloads with `self.runtime_config`
- `src/cartesi-machine.lua:3762-3770`: `new_revert_stored` keeps the table and takes a setup snapshot
- `src/cartesi-machine.lua:3779`: `new_revert_stored(machine, ..., runtime_config)` gets the shared table
- `src/cartesi-machine.lua:4476`, `4514`: per-input `backup:snapshot()`, advance and inspect
- `src/machine.cpp:316-318`: the constructor clears the tree whenever `m_r.clear_hash_tree` is set

**Evidence:** `wrapper.lua` patches the shared machine metatable to count `create`/`load` calls whose runtime config has `clear_hash_tree=true`. It does not change their behavior. After each `get_root_hash` it adds up `get_hash_tree_stats(true).phtc.page_changes`. It then runs the real CLI with `--ram-length=64Mi --create=DIR --revert-mode=stored --cmio-advance-state=...` and 3 inputs (`ioctl-echo-loop`), once with and once without `--clear-hash-tree`. Run with `eval $(make -s env); lua5.4 bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua`:
```
no-clear:        creates=1(clearing 0) loads=4(clearing 0) get_root_hash=4 pages_rehashed=107791 time=10s
--clear-hash-tree: creates=1(clearing 1) loads=4(clearing 4) get_root_hash=4 pages_rehashed=323269 time=16s
hash-tree clears: 5 (expected 1); extra pages rehashed vs no-clear: 215478
BUG: --clear-hash-tree cleared the hash tree 5 times (4 stored-revert reloads with clear_hash_tree=true for 3 inputs), rehashing 215478 extra pages (3.0x the no-clear run)
```
The test exits 1. The extra cost grows linearly with the number of inputs and with machine size.

**Scenario:** An operator suspects a corrupted cached tree and runs a rollup epoch through the CLI with `cartesi-machine --load=m,sharing:all --revert-mode=stored --clear-hash-tree --cmio-advance-state=...` on a GiB-sized machine. Instead of one rebuild, every input (and every rejected-input revert) pays a full-machine rehash. A long epoch can then take far longer than expected and miss tooling or operational deadlines. Validator nodes that use the C/Lua API directly (Rollups Node, Dave, the PRT node) set `clear_hash_tree` in their own runtime config, so they control when it applies. Hashes, proofs and stored state stay correct.

**Possible solution:** Give `new_revert_stored` a copy of `runtime_config` with `clear_hash_tree = false`, or clear the field in the shared table right after the initial create/load. Snapshot and revert reloads should never re-apply a one-shot recovery action. The same pattern is worth keeping in mind for any future one-shot runtime flag.

**Severity:** Low. Both reviewers agree: it only happens in the CLI, only when the user opts into `--clear-hash-tree` together with `--revert-mode=stored`, and the only effect is wasted rehashing. Results stay correct and deterministic, nothing crashes, and C API validator nodes are not affected.

**Risks:** Bug: large slowdowns per input on big machines, and avoidable disk and CPU load during long epochs. Fix: minimal. Removing the flag from reload configs keeps the documented single clear. Any code that relies on the field still being set in `runtime_config` after setup would need to read `cmdline.clear_hash_tree` instead.

**Proof of concept:** `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua` (driver) and `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/wrapper.lua` (instrumented CLI launcher, used by the driver). Run from the repo root: `eval $(make -s env); lua5.4 bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua`. It needs the default kernel/rootfs images (`CARTESI_IMAGES_PATH`) and takes about 30 s. It finds the CLI via `$CARTESI_MACHINE_CLI` or `cartesi-machine.lua` on `LUA_PATH`. Exit 1 with `BUG:` means the bug is present; exit 0 means it is fixed.

**ID**: `rpc-08-clear-hash-tree-reapplied-every-stored-revert`

### B26. --clear-hash-tree is silently ignored for existing remote machines

**Title**: `cartesi-machine` silently ignores `--clear-hash-tree` (and other runtime options) with `--remote-address --no-remote-create` and no `--load`

**Problem**: The CLI applies `runtime_config` only by passing it to `main_machine:load(...)` or `main_machine:create(...)`. That includes `clear_hash_tree`, which this branch adds. When the CLI attaches to an existing remote machine (`--remote-address=X --no-remote-create`, with no `--load`), it calls neither one. As a result `--clear-hash-tree` is accepted with no error or warning and does nothing. The machine already has an API that would do the job (`machine:clear_hash_tree()` in Lua, C and JSON-RPC), but the CLI never calls it. The CLI already rejects a similar meaningless combination, `--create` with `--no-remote-create`, but not this one. The other runtime options (`--concurrency=update_hash_tree:N`, console options, `--skip-version-check`, `--no-reserve`) are dropped the same way on this path. That part predates the branch.

**Origin**: Introduced by this branch (the `--clear-hash-tree` option and the `clear_hash_tree` runtime field). The underlying pattern of dropping runtime options on this path already existed.

**Area**: `cartesi-machine` CLI

**Category**: api-contract (option silently ignored)

**Location**:
- `src/cartesi-machine.lua:2802-2810`: `runtime_config` is built, including `clear_hash_tree = cmdline.clear_hash_tree`
- `src/cartesi-machine.lua:2978-2982`: only `load` receives it, and the `elseif not (cmdline.remote_address and not cmdline.remote_create)` branch skips the existing-remote case
- `src/cartesi-machine.lua:3111`: only `create` receives it
- `src/cartesi-machine.lua:2819-2823`: the assert that rejects `--create` with `--no-remote-create` (there is no equivalent check for runtime-only options)
- `src/cartesi-machine.lua:715, 2127-2129`: option help and parsing
- `src/machine.cpp:316`: `clear_hash_tree` is honoured only while the machine is being constructed

**Evidence**: The test spawns a JSON-RPC server, creates a 1 MiB machine on it, fills the hash tree and resets `get_hash_tree_stats`. It then runs the CLI against that machine with `--remote-address=X --no-remote-create --no-remote-destroy --clear-hash-tree --max-mcycle=0 --final-hash`. The CLI exits 0, yet the remote machine shows 0 page rehashes both during the CLI run and on the next `get_root_hash`. An explicit `clear_hash_tree()` causes 2058 page rehashes. Run command: `eval $(make -s env); lua5.4 bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`
```
running: timeout 60 cartesi-machine.lua --remote-address=127.0.0.1:34253 --no-remote-create --no-remote-destroy --clear-hash-tree --max-mcycle=0 --final-hash 2>&1
Connected to JSONRPC remote cartesi machine at '127.0.0.1:34253'
0: 0xebef64772f7de7c9adf654590cc6e7dbc055380b6f786700465cc753710f27ad
Left alive JSONRPC remote cartesi machine at '127.0.0.1:34253'
CLI exit:	true	exit	0
page_misses during CLI run:	0	sparse_node_hashes:	0
page_misses on next root hash:	0
reference page_misses after explicit clear_hash_tree():	2058
BUG: CLI accepted --clear-hash-tree with --no-remote-create and exited successfully, but the remote machine's hash tree was never cleared (0 page rehashes vs 2058 after a real clear)
```

**Scenario**: An operator suspects that the cached hash tree of a long-running remote machine is corrupted, for example after a crash or after some other hash-tree bug. They run `cartesi-machine --remote-address=X --no-remote-create --clear-hash-tree --final-hash` to get a hash computed from scratch. The CLI succeeds and prints the hash from the same cache they distrust, so they wrongly conclude that the cached state is sound. Validator nodes (Rollups Node, Dave, the PRT node) that use the C/Lua/JSON-RPC APIs directly are not affected, because they call `clear_hash_tree()` or pass the runtime config themselves.

**Possible solution**: On the existing-remote path (`cmdline.remote_address and not cmdline.remote_create and not cmdline.load_dir`), call `main_machine:clear_hash_tree()` when `cmdline.clear_hash_tree` is set. For the runtime options that cannot be applied to an already constructed machine (console, `no_reserve`, `skip_version_check`, concurrency), either assert or print a warning, in the same way `--create` with `--no-remote-create` is already rejected.

**Severity**: Low. Both reviewers agree. The defect is limited to the CLI on a narrow path. No C, Lua or JSON-RPC API is affected, honest-machine hashes and proofs do not change, and nothing crashes or hangs. The only harm is false confidence in exactly the situation where an operator suspects a corrupted cache. The help text ("after creating or loading the machine") arguably limits the scope already, but the CLI still accepts the flag without telling the user.

**Risks**: *Bug*: an operator gets an unverified hash, or skips a recovery step, while believing the cache was rebuilt, and other runtime flags are silently dropped on the same path. *Fix*: calling `clear_hash_tree()` on a large remote machine makes the next root-hash computation expensive, but that is the requested behaviour. Asserting on runtime-only options could break existing scripts that pass them by habit together with `--no-remote-create`, so a warning is the safer choice for the options other than `--clear-hash-tree`.

**Proof of concept**: `bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`. It exits 1 and prints `BUG:` while the bug is present. It exits 0 if the CLI clears the tree or rejects the combination. It needs `cartesi-machine.lua` on `PATH`, which `make -s env` sets up.

**ID**: `rpc-09-clear-hash-tree-ignored-existing-remote`

**Related**: [B23](#b23-json-rpc-protocol-version-not-bumped-for-the-new-clear_hash_tree-api).

### B27. --dump-memory-ranges runs mkdir through the shell with an unquoted path

**Title**: `--dump-memory-ranges` passes the directory name unquoted to a shell `mkdir` (word splitting crashes the CLI, shell metacharacters run commands)

**Problem:** `dump_memory_ranges` in the `cartesi-machine` CLI creates the output directory with `os.execute("mkdir " .. dir)`. Here `dir` is the user-supplied value of `--dump-memory-ranges=<dir>`, and it is passed to `/bin/sh` without quoting. A name that contains spaces is split into several words: `mkdir` creates several unrelated directories and reports success. The next `fs.write_file("<dir>/<start>--<length>.bin")` then fails, and the CLI aborts with a Lua traceback before it dumps anything. Shell metacharacters in the name (`;`, `$(...)`, backticks, `&&`) are executed as commands. Separately, an existing directory makes `mkdir` fail, and the `assertf` aborts the run.

**Origin:** Pre-existing. `origin/main` has the same `os.execute` line, at `src/cartesi-machine.lua:3596`. This branch touched the function only to replace `util.write_file` with `fs.write_file`.

**Area:** `cartesi-machine` CLI (`--dump-memory-ranges`).

**Category:** Correctness / shell command injection (local input).

**Location:**
- `src/cartesi-machine.lua:3599-3601` (`dump_memory_ranges`, `assertf(os.execute("mkdir " .. dir), ...)`)
- `src/cartesi-machine.lua:3606` (`fs.write_file` that then fails)
- `src/cartesi/filesystem.lua:28` (`filesystem.create_directory`, a safe alternative that is already available; `fs` is required at `src/cartesi-machine.lua:2677`)

**Evidence:** The test runs the real CLI twice (`--ram-length=32Mi --max-mcycle=0`), first with `--dump-memory-ranges=<tmp>/dm x` and then with `--dump-memory-ranges=<tmp>/d2;touch <tmp>/INJECTED`:
```
$ eval $(make -s env); lua5.4 bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua
BUG: --dump-memory-ranges='/tmp/tmp.zrloBehyMk/run/dm x' exit_ok=nil dumped=false stray_dirs(dm/x)=true
  lua5.4: /home/user/machine-emulator/src/cartesi/filesystem.lua:92: /tmp/tmp.zrloBehyMk/run/dm x/0000000000000000--0000000000008000.bin: No such file or directory
  stack traceback:
BUG: shell command injected through --dump-memory-ranges: file INJECTED was created by 'touch'
exit=1
```
After the run, the work directory contains the stray directories `dm`, `x` and `d2`, plus the injected file `INJECTED`.

**Scenario:** A developer or a CI script dumps memory ranges for debugging into a path with a space in it, such as a macOS-style `~/My Dumps` or a generated name. The run crashes after the machine has finished, leaves stray directories behind and produces no dump. A wrapper script or tool that builds the directory name from untrusted data, such as an application name, an input ID or a tournament label, and forwards it to `cartesi-machine` gives that data arbitrary shell command execution as the invoking user. Emulator C/Lua APIs, validator nodes, hashes and proofs are not affected.

**Possible solution:** Replace the shell call with the library function, e.g. `fs.create_directory(dir)` (`cartesi.filesystem.create_directory`). Optionally tolerate an already existing directory, or report a clear error for it. Do not build shell strings from user input. If a shell is unavoidable, single-quote `dir` and escape embedded single quotes.

**Severity:** Low. Both reviewers agreed: only a CLI debugging option is affected, and the input comes from the local user (injection matters only if a wrapper forwards untrusted names). Validators, emulator APIs, hashes, proofs and guest applications are not affected.

**Risks:** Bug: failed dumps and stray directories. Also local command execution if a script passes untrusted directory names through. Fix: minimal. `create_directory` fails on an existing directory just as `mkdir` does today, so behavior for valid names is unchanged. If the fix also makes existing directories acceptable, files with the same names would be overwritten.

**Proof of concept:** `bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua
```
It uses a fresh `mktemp -d` work directory, or the directory given as the first argument. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK` once it is fixed.

**ID**: `rpc-10-dump-memory-ranges-shell-mkdir`

### B28. get_data_root_hash returns nil for empty data and rejects root sizes 63 and 64

**Title**: Lua `get_data_root_hash` returns nil for empty data, rejects `log2_root_size` 63/64 (shift overflow), and accepts sizes below a word

**Problem**: `cartesi.hash-tree.get_data_root_hash(data, log2_root_size)` has three defects:
1. **Empty data.** With `data == ""`, level 0 gets no entries, so the pairing loop `for i = 1, #level, 2` never runs. Every level stays `{}` and the function returns `level[1] == nil`. The function's own contract says "the data need not fill the tree" and that untouched nodes take the pristine hash, so it should return the pristine subtree root. That is the same value as `get_data_root_hash(zeros(2^n), n)` and the same value the machine reports for an untouched region.
2. **Shift overflow.** The guard `#data <= (1 << log2_root_size)` uses Lua's 64-bit integers. `1 << 63` is `math.mininteger` and `1 << 64` is `0`, so any non-empty data is rejected with "data does not fit in the tree" at log2 63 or 64. 64 is the machine's root size.
3. **No lower bound.** For `log2_root_size < WORD_LOG2_SIZE` (5, i.e. 32-byte words), the level loop does not run. The function silently returns the zero-padded full-word hash, for example `("a", 0)` and `("abcd", 2)`, instead of rejecting a size smaller than any proof target.

**Origin**: Pre-existing. The function body is the same on `origin/main`; the branch changes other parts of `hash-tree.lua` (the forest storage) but not this function.

**Area**: Lua hash-tree library (`cartesi.hash-tree`), used by off-chain verifiers of input/output regions.

**Category**: correctness (wrong result on an edge input, and integer overflow in a bounds check).

**Location**:
- `src/cartesi/hash-tree.lua:46-69` (`get_data_root_hash`)
- `src/cartesi/hash-tree.lua:48` (overflowing fit guard)
- `src/cartesi/hash-tree.lua:63-69` (level loop, with no lower bound and no empty-level handling; `return level[1]` gives nil)
- Caller example: `doc/recipes/slice-calculator-output.lua:26,36`

**Evidence**: The test computes `get_data_root_hash("", n)` and compares it with the all-zero root and with `machine:get_proof(flash_start, 12).target_hash` for an untouched 4 KiB flash drive. It also calls the function with 1-byte data at log2 63 and 64, and with sub-word sizes. Run: `eval $(make -s env); lua5.4 bugs/lua-16-get-data-root-hash-empty-nil/test.lua`
```
BUG: empty data, log2=12 returned nil, expected pristine 0x292c23a9aa1d8bea7e2435e555a4a60e379a5a35f3f452bae60121073fb6eead
BUG: verifier comparing get_data_root_hash('',12) against machine proof target fails (got nil)
BUG: 1-byte data, log2=63 rejected: .../src/cartesi/hash-tree.lua:48: data does not fit in the tree
BUG: 1-byte data, log2=64 rejected: .../src/cartesi/hash-tree.lua:48: data does not fit in the tree
BUG: log2_root_size=0 (< word) silently returns the full-word hash instead of rejecting
BUG: log2_root_size=2 (< word) silently returns the full-word hash
9 bug(s)
```
(The test exits with status 1 while the bug is present.)

**Scenario**: An application writes an empty result, or a result that starts with a NUL byte, to its output NVRAM. A Lua verifier that follows the documented recipe `doc/recipes/slice-calculator-output.lua` does `result = string.unpack("z", read_memory(output_nvram))` and gets `""`. It then calls `get_data_root_hash(result, log2_size)` and gets nil. The next step, `verify_splice` / `roll_hash_up_tree`, either fails its assertion or raises an error on `keccak256(nil, sibling)`, so an honest, correct proof is rejected or the verifier crashes. The machine's own target hash for that region is the all-zero root. A caller that hashes small data as a whole-machine root (log2 64) is wrongly rejected. The PRT C API paths are not affected: `get_root_hash`, `get_proof`, step and uarch logs, and the frontier/forest code. No on-chain hash or dispute outcome changes.

**Possible solution**: Add `assert(log2_root_size >= WORD_LOG2_SIZE and log2_root_size <= 64)`. Replace the guard with an overflow-safe form, such as `log2_root_size >= 63 or #data <= (1 << log2_root_size)`. Seed level 0 with the pristine word hash when `data` is empty (or return the pristine hash for that height), so the result is always a hash.

**Severity**: low. Both reviewers agree. This is a Lua convenience helper that is not on the PRT/C-API path. Its main failure, on empty data, fails loudly (nil, then an error) and never produces a wrong hash that would be accepted. Callers can work around it with zero-padded data, and the 63/64 and sub-word cases are rarely reached in practice.

**Risks**: Bug: Lua-based output/input verifiers reject valid proofs, or crash, for empty results. Code that hashes at the full machine size breaks. Sub-word sizes quietly give a hash that matches no proof target. Fix: low risk. Callers that relied on `nil` as an "empty" sentinel will now receive the pristine hash, and callers that passed sub-word sizes will get an error instead of a hash.

**Proof of concept**: `bugs/lua-16-get-data-root-hash-empty-nil/test.lua`. Run from the repo root: `eval $(make -s env); lua5.4 bugs/lua-16-get-data-root-hash-empty-nil/test.lua`. It needs no machine images: it builds a RAM-only machine with a flash drive.

**ID**: `lua-16-get-data-root-hash-empty-nil`

### B29. Frontier API accepts heights above the tree height and silently grows the frontier

**Title**: Lua frontier API accepts subtree and pad heights above the tree height, and non-hash `hash_type` values, then silently grows the frontier or returns the pad as the root

**Problem:** No function in the `cartesi.hash-tree` frontier API checks that a subtree or pad height is at most `log2_max_leaves` (`#frontier - 1`):
- `frontier_push_back(f, hash, height)` sets `level = height + 1`. Its only capacity check, `assert(not frontier[#frontier])`, looks at the current top level. When `height + 1 > #frontier`, the final `frontier[level] = right` writes past the end of the array. The tree silently gets taller: on a height-3 frontier, `push_back(f, x, 5)` makes `#f == 6`. After that, `frontier_get_root_hash` returns `x` and `frontier_get_leaf_count` returns 32 for a tree that holds at most 8 leaves.
- `frontier_append(..., height)` relies on `frontier_padding_fits`. When `first_level > #frontier`, the local `height = #frontier - first_level` is negative, so the capacity bits are never checked and the function returns true. `append` then calls `push_back` past the end, giving `#g == 5`.
- `frontier_get_root_hash(f, pad, pad_height)` with `pad_height >= #f - 1` runs its level loop zero times and returns `pad` itself as the root. `frontier_pad_back` has the same gap.
- `frontier_genesis` and `frontier_load` use `assert(cartesi[hash_type])`, so they accept any truthy field of the `cartesi` module, such as `"tohex"`, as a hash function.

These functions' own comments promise the opposite: "Appending past the tree capacity fails" and "Appending past the tree capacity fails before anything changes". `frontier_store` writes a frontier corrupted this way without error, but `frontier_load(path, L)` then rejects it with "frontier height does not match the expected height".

**Origin:** Pre-existing. `origin/main` has the same `frontier_push_back`, `frontier_append`, `frontier_get_root_hash` and `cartesi[hash_type]` lookups, one line earlier.

**Area:** Lua library `cartesi.hash-tree` (frontier functions).

**Category:** API contract / input validation.

**Location:**
- `src/cartesi/hash-tree.lua:144-158`: `frontier_padding_fits`, which mishandles a negative `height`
- `src/cartesi/hash-tree.lua:165-177`: `frontier_push_back`
- `src/cartesi/hash-tree.lua:186-213`: `frontier_append`
- `src/cartesi/hash-tree.lua:219-236`: `frontier_get_root_hash`
- `src/cartesi/hash-tree.lua:248-254`: `frontier_pad_back`
- `src/cartesi/hash-tree.lua:363-364`: `frontier_genesis`, the `hash_type` lookup
- `src/cartesi/hash-tree.lua:942-946`: `frontier_load`, the `hash_type` lookup and height check

**Evidence:** The test uses only the public `cartesi.hash-tree` API. Every out-of-range call succeeds, and each one corrupts the tree or returns a wrong root instead of raising an error:
```
$ eval $(make -s env); lua5.4 bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua
push_back(f,x,5) ok=	true	nil	#f=	6
BUG: frontier_push_back with height 5 > log2_max_leaves 3 grew frontier from 4 to 6 levels
BUG: after that, frontier_get_root_hash returns the pushed hash x as the root of the height-3 tree
leaf count after:	true	32
append({x},1,2,4) ok=	true	nil	#g=	5
BUG: frontier_append with height 4 > log2_max_leaves 3 grew frontier to 5 levels
BUG: frontier_get_root_hash with pad_height 6 > 3 returns the pad itself as the height-3 root
BUG: frontier accepts hash_type 'tohex' (not a hash function)
load corrupted with L=3:	false	.../hash-tree.lua:946: frontier height does not match the expected height
BUG: stored frontier cannot be reloaded with its original height (...)
exit=1
```

**Scenario:** An external validator, such as a Rollups Node or Dave component written in Lua, builds commitment or output trees with `cartesi.hash-tree`. A unit mix-up passes a height in the wrong unit, for example log2 of the bundle size in leaves where the tree counts bundles. Instead of an assertion, the node computes a silently wrong root (or the pad as the root) and a tree whose leaf count is wrong. If it persists that frontier, it cannot reload it after a restart. In-tree callers cannot reach this, because every height is bounded by construction. That covers `src/cartesi-machine.lua` (around lines 3535, 4033, 4158, 4160 and 4198) and the PRT recipes. An honest node that uses the API correctly gets correct roots.

**Possible solution:** Validate the height in `push_back`, `append`, `get_root_hash` and `pad_back`, before anything is mutated:
```lua
local h = height or 0
assert(math.type(h) == "integer" and h >= 0 and h <= #frontier - 1, "subtree height exceeds the tree height")
```
`height == #frontier - 1` must stay legal, because one subtree can fill the whole tree. In `frontier_genesis`, `frontier_load` and `frontier_forest`, accept only the supported hash types (`"keccak256"`, `"sha256"`).

**Severity:** Low. Both reviewers rated it low. It can only be triggered by a caller that breaks the precondition with an out-of-range height or a non-hash `hash_type`. No in-tree CLI or PRT path can do that, and correct use always gives correct hashes. The real cost is that such a programming error in an external validator produces silently wrong roots, or a persisted frontier that cannot be reloaded, where the documented behaviour is a clean failure.

**Risks:**
- Of the bug: a caller's mistake becomes a wrong commitment or root, or a node that cannot restart from its stored frontier, instead of an immediate error. In a fraud-proof setting, that can surface late, during a dispute.
- Of the fix: low. Valid calls are unchanged. Code that passed `height == log2_max_leaves` stays legal. Callers that relied on the silent growth were already producing wrong trees, and they will now fail loudly.

**Proof of concept:** `bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua`. It uses a temporary file from `os.tmpname()` and removes it at the end. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: frontier rejects out-of-range heights and hash types` once the bug is fixed.

**ID**: `lua-17-frontier-height-args-unvalidated`

**Related**: [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity).

### B30. verify_hash_tree returns true when inner nodes or the root are corrupted

**Title**: verify_hash_tree returns true when dense inner nodes, the dense root or sparse nodes are corrupted

- **Problem**: `hash_tree::verify` is the implementation behind `cm_verify_hash_tree`, Lua `m:verify_hash_tree()` and JSON-RPC `machine.verify_hash_tree`. It checks only three things for each address range:
  1. It compares each page's recomputed Merkle hash with the dense-tree node at page level.
  2. It checks that a page or range that is actually dirty is also marked dirty.
  3. It compares the range's sparse node with its dense root.

  It never recomputes dense inner nodes from their children, and it never recomputes sparse inner nodes or the sparse root. The third check only prints `dense hash tree root does not match sparse node hash` to stderr and never sets `ret = false`. A tree whose inner nodes are stale or corrupted therefore passes, even though `get_root_hash`, `get_node_hash` and `get_proof` return wrong values. This breaks the documented contract ("True if tree is self-consistent").
- **Origin**: pre-existing. The branch only changed the cache-payload accessors inside the diagnostic branch. The print-only dense/sparse check is the same on `main`.
- **Area**: hash-tree integrity check API (`cm_verify_hash_tree`, Lua `verify_hash_tree`, JSON-RPC `machine.verify_hash_tree`).
- **Category**: correctness (false positive in an integrity check).
- **Location**:
  - `src/hash-tree.cpp:650-714`: `hash_tree::verify`. Only page-level dense nodes are recomputed (lines 662-666). The dense-root vs sparse-node mismatch at lines 707-710 prints but does not fail.
  - `src/machine.cpp:1620`: `machine::verify_hash_tree` calls `m_ht.verify` directly.
  - `src/cm.cpp:1036-1041`: `cm_verify_hash_tree`. Also `src/clua-i-machine.cpp:993` and `src/jsonrpc-remote-machine.cpp:1311`.
- **Evidence**: The test stores a machine with 1 MiB of RAM, with data written in both halves. It patches the stored hash-tree files and loads them with `sharing = "none"`. For each value it compares the result before and after `clear_hash_tree()`, which forces a full re-hash. The four patches are:
  - (A) the RAM `.dht` root node (heap index 1, byte 32);
  - (B) a dense inner node (heap index 2, byte 64), read with `get_node_hash(RAM, 19)` and also seen as the sibling in `get_proof` for the right half;
  - (C) the sparse root hash inside `hash_tree.sht`.

  In every case `verify_hash_tree()` returns true while the reported value is wrong:
  ```
  $ eval $(make -s env); timeout 120 lua5.4 bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua
  [A dense root] verify_hash_tree=true  value_before=4d05a7c1d6c16b50  recomputed=27323628b3e7e58f
  [B dense inner node hash] verify_hash_tree=true  value_before=0202020202020202  recomputed=27e1bd4ef3afd672
  [B proof sibling] verify_hash_tree=true  value_before=0202020202020202  recomputed=27e1bd4ef3afd672
  [C sparse root] verify_hash_tree=true  value_before=0303030303030303  recomputed=27323628b3e7e58f
  BUG: verify_hash_tree accepted 4 corrupted hash trees
  ```
- **Scenario**: A validator node (Rollups Node, Dave, or another PRT node) keeps a machine on disk and loads it after a crash or restart. It calls `verify_hash_tree` as a health or recovery check before it trusts the hash tree. The stored `.dht`/`.sht` files may be stale or damaged, either from disk corruption or from the crash-during-update states reported separately (ht-01, ht-03, rpc-12, rpc-14: stale dense inner nodes or a stuck sparse root). The check reports a healthy tree, so the node skips `clear_hash_tree` and then publishes wrong root hashes, proofs or step logs. Without that fix, an honest player could commit to or defend a wrong state. Applications inside the machine are not affected.
- **Possible solution**: After the leaf checks in `verify`, recompute every dense inner node from its children and compare. Then recompute the sparse inner nodes up to the root, using pristine hashes for pristine children, and compare each one with the stored value. Set `ret = false` on any mismatch. For the existing dense-root vs sparse-node branch, also set `ret = false`, but only when the range is not marked dirty, because a range that is marked dirty and not yet updated can legitimately differ. Alternatively, compare against a simulated update.
- **Severity**: low. Both reviewers rated it low (one said possibly low-to-medium), and the prover suggested medium. It is a real false positive in a public C, Lua and JSON-RPC API. But it does not produce wrong hashes by itself. The API is documented as "used only for emulator internal tests", and neither the CLI nor the in-branch PRT node calls it. It matters only to a node that relies on it after one of the separately reported corruption bugs.
- **Risks**: Bug: an operator or node that trusts the check gets a false "OK" on a corrupted tree, and wrong roots or proofs get published. That hides the corruption bugs reported separately. Fix: a full inner-node recomputation is O(size of the dense trees). That is acceptable for a diagnostic but slower than today on large machines. Failing on a dense/sparse mismatch without the dirty-range exception would give false negatives on trees that are healthy but not yet updated.
- **Proof of concept**: `bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua` patches stored hash-tree files and checks the result with the public Lua API. It uses a temporary directory, or `$WORKDIR` if that is set. It exits 1 when the bug reproduces. Run from the repo root:
  `eval $(make -s env); timeout 120 lua5.4 bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua`

**ID**: `api-03-verify-hash-tree-misses-inner-nodes`

**Reviewer note**: A separate review panel (`ht-05-verify-hash-tree-misses-inner-nodes`) reproduced the same behavior but rejected it 2 to 1, arguing that `verify_hash_tree` is meant to check dirty-page tracking rather than the whole tree. This panel confirmed it. It is listed as low so that readers can weigh both views.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong), [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree).

### B31. A failed expansion store is never retried by later frontier_forest_store calls

**Title**: After a failed expansion store, `frontier_forest_expand_leaf` leaves the expansion only in memory, and no later `frontier_forest_store` writes it

**Problem:** `frontier_forest_expand_leaf` puts the replacement subtree in the in-memory forest (`values[index] = replacement`) before it calls `store_expansion`. If `store_expansion` raises, for example when `write_file` hits a `sync_file`, write or rename failure such as ENOSPC or EIO, the forest stays expanded in memory but the replacement's `<hash>.json` file is never written. An earlier store already put the fixed-point tree that holds the leaf, and every tree above it, in `forest.durable`. That map is keyed by the tree object, and changing the tree in place does not remove it. So on the next `frontier_forest_store`, `store_tree` returns at once at each durable top tree, and the walk never reaches the replacement. That store reports success and commits the frontier file, but the directory still lacks the expansion. This breaks the documented contract that "later expansions are stored there as well". After a reload, the leaf is opaque again.

**Origin:** introduced by this branch (new `src/cartesi/hash-tree.lua` frontier-forest persistence).

**Area:** Lua library `cartesi.hash-tree`: frontier forest persistence (`frontier_forest_expand_leaf`, `store_expansion`, `store_tree`, `frontier_forest_store`).

**Category:** durability / consistency between the in-memory and stored state after an error.

**Location:**
- `src/cartesi/hash-tree.lua:894-895`: `frontier_forest_expand_leaf` assigns `values[index] = replacement` and then calls `store_expansion(forest, replacement)`, with no rollback if that call fails.
- `src/cartesi/hash-tree.lua:578`: `store_tree` returns early with `if forest.durable[tree] ... then return end`, which hides trees below a durable tree that were never stored.
- `src/cartesi/hash-tree.lua:606-613`: `store_expansion`.
- `src/cartesi/hash-tree.lua:960-966`: the `frontier_forest_store` contract.

**Evidence:** The test builds an outer forest of height 4 from four bundle roots at height 2 and stores it. It then makes `fs.sync_file` fail once while bundle 1 (leaves 4..7) is expanded at position 4, and catches that error with `pcall`. Next it stores again, reloads the forest and queries `(5,0)`. A control run does the same steps with no injected failure.
```
$ eval $(make -s env); lua5.4 bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua
expand_leaf with injected failure:	false	...test_failed_expansion_store.lua:35: injected transient I/O error
in-memory node hash at (5,0):	0xb4f6c549a55037ee98548e37dbf8ee91322007c4a901157138bb753027104cb1
bundle tree file exists after snapshot 2:	false
reloaded node hash at (5,0):	nil	the node is below an opaque hash
control (no failure) reloaded node hash at (5,0):	0xb4f6c549a55037ee98548e37dbf8ee91322007c4a901157138bb753027104cb1
BUG: frontier_forest_store after a failed expansion store did not persist the in-memory expansion; ...
```
Exit status 1 means the bug reproduced; 0 means it is fixed. The I/O error is simulated by stubbing `fs.sync_file`, which `write_file` looks up through the shared module table on each call. Every other step uses only the public API.

**Scenario:** A validator built on `cartesi.hash-tree` (a Rollups Node, a Dave-style node or another PRT player) opens a bundle during a dispute by calling `frontier_forest_expand_leaf` on a stored forest, and hits a transient disk error such as a full disk. If the node catches the error and keeps going, as a retrying event loop would, every later snapshot succeeds. After a restart, though, the reloaded forest is opaque below that bundle, and queries and proofs there fail with "the node is below an opaque hash". The node must recompute the bundle; a node with no recompute path cannot produce the proof in time. The reference node `doc/recipes/prt.lua:1748` does not catch the error, so it crashes and on restart reopens the bundle by recomputing it, which means it is not affected. Only the second variant of the claim, where a second forest changes a durable tree through a shared reference, was not shown.

**Possible solution:** Make the expansion atomic with its store. If `store_expansion` fails, restore `values[index]` to the previous hash before re-raising (`local ok, err = pcall(store_expansion, ...); if not ok then values[index] = old; error(err, 0) end`). Another option is to store the replacement before assigning it to the tree. Or keep a list of pending expansions that the next `frontier_forest_store` retries, or mark the trees on the path as not durable so that `store_tree` descends again.

**Severity:** low. Both reviewers agreed: hashes and proofs are never wrong, `load_tree` checks every file against its hash, and nothing is corrupted. The bug needs both a transient I/O error during an expansion and a caller that swallows it, and the worst effect is that the bundle has to be recomputed after a restart.

**Risks:** Of the bug, the stored snapshot says less than the in-memory forest and nothing reports it, so a node that trusts its snapshots can lose an opened bundle across a restart and then fail to answer a dispute step if it cannot recompute it. If `sync_directory` is the call that fails, the files exist but their directory entries are never synced by a later store, which leaves a power-loss window (not tested). Of the fix, rolling back must restore the exact previous value (the raw hash), and the change must not make `store_tree` rewalk the whole durable forest on every store, which would cost time on large forests.

**Proof of concept:** `bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua`. It uses scratch directories under `$WORKDIR`, then `$TMPDIR`, then `/tmp`, and removes them when done.

**ID**: `lua-20-failed-expansion-store-never-retried`

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files), [B12](#b12-frontier_forest_store-drops-expansions-under-single-value-fixed-point-trees).

### B32. Interrupted store or clone_stored leaves a torn page cache that loads silently and gives wrong hashes

**Title**: Interrupted store or clone_stored leaves a torn hash_tree.phtc that loads silently and gives wrong hashes

**Problem**: If `store()` or `clone_stored()` is killed while it writes `hash_tree.phtc`, the file is left full-size with a valid header and metadata but zeroed page payloads. A later load accepts it without error. The page hash-tree cache then treats the zeroed payloads as valid cached pages, and the machine silently computes wrong root hashes. Proofs and uarch cycle hashes that read the same payloads are also wrong.

Why this happens:
- `hash_tree.phtc` is the last file written (store) or copied (clone_stored). Every other file is already complete at that point.
- `os::create_file` and `os::copy_file` first `ftruncate` the file to its full length, then `pwrite` 4 KiB blocks in order. `clone_file` falls back to `copy_file` when reflink is not available, as on ext4.
- The initialized tag, the LRU and the entry metadata sit at the front of the file, so they are written first. A kill partway through leaves them valid, followed by zeros.
- At load, the `page_hash_tree_cache` constructor checks only the tag and `check_metadata()`. It never checks the payloads.
- `enqueue_hash_entry` rehashes only words that differ from the cached page. Zero words in RAM match the zeroed payload, so their leaves keep a zero hash instead of keccak(0). On an LRU eviction, a torn payload is also reused as the diff base for the page newly assigned to that entry, so the corruption spreads beyond the original hits.

A torn phtc is the only partial state that loads silently. An interruption at any earlier point leaves later files missing, and the load fails.

**Origin**: pre-existing. The write order and payload trust are in code this branch touches (store, clone_stored, page hash-tree cache).

**Area**: Hash tree persistence (page hash-tree cache, `store` / `clone_stored`, `os-filesystem`).

**Category**: Correctness / crash consistency (silent wrong state hash and proofs).

**Location**:
- `src/machine.cpp:475-482`: `store()` writes `hash_tree.sht`, then `hash_tree.phtc`, last.
- `src/machine.cpp:535-538`: `clone_stored()` clones the sht, then the phtc, last.
- `src/os-filesystem.cpp:348-390`: `create_file` (`ftruncate` to full size, then sequential `pwrite`).
- `src/os-filesystem.cpp:397-490`: `copy_file`.
- `src/os-filesystem.cpp:575+`: `clone_file`, which falls back to `copy_file` without reflink.
- `src/page-hash-tree-cache.hpp:414-455`: the constructor validates only the initialized tag and `check_metadata()`.
- `src/page-hash-tree-cache.hpp:340-375`: `enqueue_hash_entry` diffs against the untrusted cached page.

**Evidence**: The test makes no hand edits to any file. A child `lua5.4` process runs `machine:store(dir, SHARING_ALL)` or `cartesi.machine:clone_stored(src, dst)` under an `LD_PRELOAD` shim, which sends a real SIGKILL after N `pwrite()` calls to `hash_tree.phtc`. The machine has 16 MiB of RAM and the default `phtc_size` of 4096, which makes a phtc of about 50 MB. The parent then:
1. loads the directory, which succeeds;
2. writes one word per RAM page;
3. compares the root with an in-memory reference machine and with the same directory loaded with `clear_hash_tree = true`.

Output of `eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh` (default kill point 4000):
```
child store exited: nil exit 137
[store] load accepted; root on load matches reference: false
[store] root after touching pages: b2117719d1c48798bf6237ce4eaf64b6a2680eea9dd26b7fb105862d35b90269
[store] reference root           : c3b78b028e6361ae065e47902f6c753a06d8fabe221bb47a84f7f91c0767c41e
[store] same dir, clear_hash_tree: c3b78b028e6361ae065e47902f6c753a06d8fabe221bb47a84f7f91c0767c41e
BUG: [store] torn hash_tree.phtc accepted at load; machine computes a wrong root hash (clear_hash_tree rebuild matches reference)
[intact-source] root after touching pages: c3b78b028e63...c41e   (control: complete store is correct)
child clone_stored exited: nil exit 137
[clone_stored] root after touching pages: b2117719d1c4...0269
BUG: [clone_stored] torn hash_tree.phtc accepted at load; machine computes a wrong root hash (clear_hash_tree rebuild matches reference)
```
Exit status is 1.

With `KILL_AFTER_PHTC=12000`, the output starts with `[store] load accepted; root on load matches reference: true`. The root after touching pages is still wrong (`60289b49...` vs `c3b78b02...`). So the usual "load, then assert root == expected" check does not catch it.

With `VERIFY=1`, `verify_hash_tree()` returns false, but nothing calls it at load.

**Scenario**: A Rollups Node, Dave or other validator snapshots with `cm_store`, or with `cm_clone_stored` on ext4, straight into its final snapshot directory. The process is killed (OOM killer, container stop timeout, crash) during the roughly 50 MB phtc write. On restart, the node loads that directory with no error, and the root may even match the expected state hash. Then it processes inputs or bisects a dispute, and commits wrong state hashes and proofs. An honest player can lose the dispute this way, with no error anywhere.

The reference PRT node (`doc/recipes/prt.lua`) is not affected. It stores or clones into a temporary directory, then calls `sync_stored` and `rename_stored`, and deletes leftover temporary directories. However, nothing in the `cm_store` / `cm_clone_stored` API says they are not crash-atomic.

**Possible solution**: Make the phtc write all-or-nothing. Either option works:
- Write the payloads and metadata first and the initialized tag last, with an fsync before the tag write when durability is needed. A torn file then fails the tag check, or is reinitialized as empty.
- Or write and copy to a temporary name and rename it into place.

As defense in depth:
- validate the active entries' payloads at load (re-hash each page and compare with its stored page root, dropping mismatched entries), or add per-entry checksums;
- document that `store` / `clone_stored` are not atomic and that the temp-dir, `sync_stored`, `rename_stored` protocol is required.

**Severity**: high. Both reviewers agree. The impact is silent wrong state hashes and proofs, which can lose a PRT dispute, and some kill points pass the post-load root check. It is not critical because it needs both a process kill inside the phtc write window and an integrator that does not use the documented temp-dir, sync and rename protocol.

**Risks**:
- Bug: silent divergence of a validator's state hash and proofs after a realistic process kill. The only signal is `verify_hash_tree()`, which nobody calls at load and which is very noisy on stderr.
- Fix: writing the tag last only changes write order. Note that a reinitialized (empty) cache must still be consistent with the stored sht, or the sht must be rebuilt. Otherwise dropping the cache could expose other stale-hash issues. Payload validation at load costs about one page hash per active entry (4096 by default), which adds to load time. A temp-file-plus-rename approach needs care with `SHARING_ALL` mappings and with cleaning up leftover temporary files.

**Proof of concept**: `bugs/api-05-torn-phtc-silent-wrong-hash/run.sh`, `test_torn_phtc.lua` and `killshim.c`. `run.sh` builds the `LD_PRELOAD` shim into a `mktemp -d` directory and runs `test_torn_phtc.lua` with its work directory there. It needs `gcc` and `lua5.4`, and creates two phtc files of about 50 MB. The `clone_stored` case needs the temp dir on a filesystem without reflink, such as ext4, and is skipped otherwise. Optional settings: `KILL_AFTER_PHTC=<n>` sets the kill point, and `VERIFY=1` also runs `verify_hash_tree()`. Run from the repo root:
```
eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh
```
While the bug is present it prints `BUG:` lines and exits 1. Once fixed it prints `OK: no wrong hash` and exits 0.

**ID**: `api-05-torn-phtc-silent-wrong-hash`

**Related**: [B01](#b01-persisted-page-cache-is-not-checked-against-memory-so-a-reload-yields-wrong-proofs), [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B33. Lua bindings call luaL_error inside C++ catch handlers and leak the exception

**Title**: Lua bindings call `luaL_error` inside C++ `catch` handlers, so every failed call leaks the exception object (about 200-500 B each)

**Problem:** Many Lua bindings are function-try-blocks with this handler:
```cpp
} catch (const std::exception &e) {
    luaL_error(L, "%s", e.what());
    return 1;
}
```
Lua is built as C, so `luaL_error` raises the error with `longjmp`. Calling it inside the handler jumps straight out of the handler, which means `__cxa_end_catch` never runs. The exception object from `__cxa_allocate_exception` is never freed, and neither is anything it owns, such as the message string of a nlohmann `parse_error` or a `std::system_error`. The entry also stays on the thread's `caughtExceptions` chain. Formally this is undefined behaviour: a `longjmp` out of a handler, across frames with non-trivial destructors. Each failed call leaks memory that `collectgarbage` cannot reclaim. Most `machine` methods are not affected, because they call `cm_*`, check the returned error code and call `luaL_error` outside any handler.

**Origin:** Mixed.
- Introduced by this branch: the new `cartesi.filesystem` core module (`src/clua-cartesi-filesystem.cpp`, which is not on `origin/main`) repeats the pattern in all 8 of its functions.
- Pre-existing: the sites in `src/clua-cartesi.cpp` (the same 7 handlers exist on `origin/main`) and in `src/clua-i-machine.cpp`.

**Area:** Lua bindings. These are `cartesi.filesystem`; `cartesi.tobase64`, `frombase64`, `tohex`, `fromhex`, `tojson`, `fromjson` and `new`; and the `clua-i-machine` helpers (register-name conversion, schema dictionary, `clua_tojson`, `clua_fromjson`).

**Category:** Resource leak (unbounded native memory growth on error paths) and undefined behaviour.

**Location:**
- `src/clua-cartesi-filesystem.cpp:41-43, 49-51, 63-65, 73-75, 84-86, 105-107, 125-127, 133-135`
- `src/clua-cartesi.cpp:123-125, 135-137, 147-149, 159-161, 171-173, 181-183, 192-194` (tobase64, frombase64, tohex, fromhex, tojson, fromjson, new)
- `src/clua-i-machine.cpp:228-229` (register conversion), `605-606` (schema dictionary), `634-635` (`clua_tojson`), `650-651` (`clua_fromjson`), `1188`

**Evidence:** The test runs 200,000 failing `pcall`s per case. It measures `VmRSS` after two full GC cycles and compares against a control case that fails through `luaL_argerror`, with no C++ exception involved. The control grows by 0 KiB. The three exception paths grow linearly:
```
$ eval $(make -s env); timeout 300 lua5.4 bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua
control: cartesi.fromhex(non-string)     RSS 14432 KiB -> 14432 KiB (+0 KiB, 0.0 bytes/failed call)
cartesi.fromjson('{bad')                 RSS 15180 KiB -> 99900 KiB (+84720 KiB, 433.8 bytes/failed call)
cartesi.fromhex('zz')                    RSS 100092 KiB -> 138756 KiB (+38664 KiB, 198.0 bytes/failed call)
filesystem.create_directory(bad)         RSS 139552 KiB -> 240096 KiB (+100544 KiB, 514.8 bytes/failed call)
BUG: cartesi.fromjson('{bad') leaks ~434 bytes per failed call (...)
BUG: filesystem.create_directory(bad) leaks ~515 bytes per failed call (...)
exit=1
```
`/usr/bin/lua5.4` imports `_setjmp` and `__longjmp_chk` and does not link libstdc++, which confirms it is a C build that raises errors with `longjmp`.

**Scenario:** The leak hits a long-running Lua process that handles expected failures with `pcall`. Examples:
- a Lua PRT validator, or a JSON-RPC client script, that parses JSON or hex from counterparties that may be malformed or adversarial;
- a process that probes filesystem paths through `cartesi.filesystem`.

Such a process loses a few hundred bytes for every handled failure, and memory grows without bound. An attacker who can make a Lua validator parse many bad inputs can drive memory up slowly, at roughly 2-5 million failures per GB. Hashes, proofs and machine state are not affected. The C API that the Rollups Node and Dave use does not have this pattern, so only Lua-hosted processes are affected. The `cartesi-machine` CLI usually exits on the first error, so in practice it is not affected.

**Possible solution:** Never raise a Lua error while a C++ exception is still being handled. Two ways to do that:
- Inside the `catch`, push the message onto the Lua stack with `lua_pushstring(L, e.what())`, or copy it into a buffer the function owns. Let the handler finish normally, then call `lua_error(L)` after the `try`/`catch`.
- Factor this into a shared helper that wraps the body (for example `clua_protect(L, [&]{ ... })`), which returns a flag and calls `lua_error` after the handler.

The `cm_*` wrappers already raise errors outside any handler. Also check that no C++ object with a non-trivial destructor is still alive in the frame when `lua_error` is called. Temporaries should stay owned by Lua through `clua_push_new_managed_toclose_ptr`.

**Severity:** Low. Both reviewers rated it low. The leak is real and unbounded, but it happens only on error paths in the Lua bindings and it does not corrupt anything. Results stay correct, and memory becomes a problem only after millions of handled failures in one long-running Lua process.

**Risks:**
- Of the bug: slow memory growth, which could end in an OOM kill of a long-running Lua validator or tool fed many malformed inputs. In theory, stale `caughtExceptions` entries could also change what `std::current_exception()` or a bare `throw;` sees later.
- Of the fix: low. The change is mechanical, but it touches many bindings. The fix must keep the same error messages, which callers and tests may match on. It must also keep the message alive until `lua_error` runs (push it before leaving the handler), and it must keep the existing `catch (...)` fallbacks.

**Proof of concept:** `bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua`. Run it from the repo root:
```
eval $(make -s env); timeout 300 lua5.4 bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua
```
It exits with 1 and prints `BUG:` lines while the leak is present. It exits with 0 and prints `OK: no per-call leak detected` once the leak is fixed.

**ID**: `lua-22-lual-error-in-catch-leaks-exceptions`

### B34. Frontier stores fail for files directly under the filesystem root

**Title**: hash-tree `frontier_store` / `frontier_forest_store` raise "unable to sync directory ''" for a file directly under `/`, after the file has already been replaced

**Problem**: `get_parent_directory(path)` is `path:match("^(.*)/[^/]*$") or "."`. For a path directly under the root, such as `/frontier.json`, the capture is `""`, not `"/"`. In Lua `""` is truthy, so the `"."` fallback never applies.
- `write_file` calls `fs.new_temporary_file("", ...)`. That still works, because the template becomes `/<prefix>.XXXXXX`. The temporary file is synced and renamed onto the target, so the new frontier is committed.
- `frontier_store` and `frontier_forest_store` then call `fs.sync_directory("")`. `open("", O_DIRECTORY)` fails with ENOENT, so the store raises.

Result: the public store APIs report failure even though the new file is already in place, and the rename is never made durable by a directory fsync. The C++ counterpart (`parent_directory` in machine.cpp, which uses `std::filesystem::path::parent_path()`) correctly returns `/`. Paths with repeated leading slashes, such as `//x`, behave the same way.

**Origin**: introduced by this branch. `get_parent_directory`, `write_file` and the `sync_directory` calls do not exist in `main`'s hash-tree.lua.

**Area**: Lua library `cartesi.hash-tree` (frontier and frontier-forest persistence); `cartesi-machine` CLI (`frontier:<filename>` / `outputs_frontier:<filename>` options).

**Category**: correctness / durability (wrong error reporting after a commit; missing fsync).

**Location**:
- `src/cartesi/hash-tree.lua:505`: `get_parent_directory`
- `src/cartesi/hash-tree.lua:510`: `write_file` (temporary file directory)
- `src/cartesi/hash-tree.lua:937`: `frontier_store` → `fs.sync_directory(get_parent_directory(path))`
- `src/cartesi/hash-tree.lua:989`: `frontier_forest_store` → `fs.sync_directory(get_parent_directory(frontier_path))`
- `src/cartesi-machine.lua:3276`: the CLI's `store_frontier` passes the user-given filename to `hash_tree.frontier_store`

**Evidence**: the test runs as root. It re-executes itself in a private mount namespace, chrooted into a tmpfs-backed overlay of `/`, so the real root is never written. Inside, it stores a frontier at `/frontier-<t>.json` and a forest frontier at `/forest-frontier-<t>.json`. Both calls raise, yet both files exist with the new contents. `sync_directory("/")` succeeds and `sync_directory("")` fails. Run command: `eval $(make -s env); lua5.4 bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua`
```
frontier_store(/frontier-1792962320.json): ok=false err=.../hash-tree.lua:937: unable to sync directory '': open() failed: No such file or directory file_exists=true
frontier_forest_store(/forest-trees-1792962320, /forest-frontier-1792962320.json): ok=false err=.../hash-tree.lua:989: unable to sync directory '': open() failed: No such file or directory file_exists=true
sync_directory('/') ok=true
sync_directory('')  -> unable to sync directory '': open() failed: No such file or directory
rc=1
```

**Scenario**:
- A validator node or tool running in a container keeps its frontier at a root-level path such as `/state.json` or `/frontier.json`. Every `frontier_store` / `frontier_forest_store` raises, and every `cartesi-machine ... frontier:/frontier.json` run fails the same way.
- A caller that treats the error as "store failed, old state still current" is wrong: the frontier has already been replaced. With `frontier_forest_store`, the trees are already written and `forest.directory` is already updated.
- Because the directory is never fsynced, a crash shortly afterwards can lose the rename.
- Hashes, proofs and dispute outcomes are not affected.

**Possible solution**: map an empty capture to `/`, matching `std::filesystem::path::parent_path()`. For example:
```lua
local function get_parent_directory(path)
    local d = path:match("^(.*)/[^/]*$")
    if d == nil then return "." end
    if d:match("^/*$") then return "/" end
    return d
end
```

**Severity**: low. Both reviewers rated it low, and the prover agrees. It only triggers for frontier files stored directly in the filesystem root, which is rare outside containers. When it triggers it fails reliably and visibly: there is a spurious error after a successful commit, plus one skipped directory fsync. It never corrupts stored data, hashes or proofs, and it does not hang.

**Risks**:
- Of the bug: callers may misjudge whether the persisted state changed, or abort at a store boundary. In root-level layouts the rename is not durable after a crash.
- Of the fix: minimal. The helper is local to hash-tree.lua and only used for the temporary-file directory and the directory sync. Returning `/` for root-level paths gives the same temporary-file location and makes the sync succeed. Relative paths and deeper absolute paths are unchanged.

**Proof of concept**: `bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua`. It must run as root and needs `unshare`, overlayfs and `chroot`. It sandboxes itself in a private mount namespace over a throwaway overlay of `/`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua
```
Exit status 1 together with `BUG:` lines means the bug reproduced; exit status 0 means it is fixed.

**ID**: `lua-24-hash-tree-root-parent-directory`

### B35. collect_uarch_cycle_* reset shortcut diverges from reset_uarch when uarch RAM is not the built-in image

**Title**: collect_uarch_cycle_root_hashes / collect_uarch_cycle_bundle restore only dirty uarch RAM words on reset, so reset leaves (and all later leaves) differ from reset_uarch / verify_reset_uarch when uarch RAM is not the built-in image

**Problem**: After each mcycle, `machine::collect_uarch_cycle_root_hashes` does not call `reset_uarch()`. As an optimization it resets the uarch registers to `uarch_registers_state{}`, then copies the library's built-in `uarch_pristine_ram` (or zeros past its end) back only into the uarch RAM words written during that mcycle (`reset_dirty_words`). It then rehashes only those words with `m_ht.update_words`. The real reset is different. `reset_uarch()`, `log_reset_uarch`/`verify_reset_uarch` and the on-chain reset they model all write the whole built-in image over uarch RAM and zero-fill the rest. The shortcut is equivalent only when every word the uarch did not write already equals the built-in image, and nothing checks this: the only uarch precondition is `uarch_cycle == 0`. If the machine's uarch RAM differs from the built-in image anywhere, the collected reset leaf comes from a mixed state that no reset proof can produce. Every later leaf is then wrong as well, and the machine is left in that mixed state. `collect_uarch_cycle_bundle` calls `collect_uarch_cycle_root_hashes`, so it has the same defect.

**Origin**: pre-existing. The same shortcut is in `origin/main` (v0.22.0) at `src/machine.cpp:2794`.

**Area**: microarchitecture root-hash collection for PRT: `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (C API `cm_collect_uarch_cycle_root_hashes`/bundle, Lua bindings, JSON-RPC).

**Category**: correctness (wrong commitment hashes / state divergence).

**Location**:
- `src/machine.cpp:2797-2824`: shortcut reset in `machine::collect_uarch_cycle_root_hashes` (registers reset, dirty-word restore, `update_words`).
- `src/machine.cpp:2677-2679`: precondition checks only `uarch_cycle == 0`, not that uarch RAM is pristine.
- `src/machine.cpp:2051-2068`: `machine::reset_uarch`, the full reset (whole image plus zero fill) that `log_reset_uarch`/`verify_reset_uarch` replay.
- `src/machine.cpp:2894`: `collect_uarch_cycle_bundle` reuses `collect_uarch_cycle_root_hashes`.

**Evidence**: The test creates a uarch RAM backing file through config `uarch.ram.backing_store.data_filename`, the mechanism behind CLI `--uarch-ram-image`. The file equals the built-in image except its last 4 KiB page, which is filled with `0xaa` and which the uarch never touches. The test compares `collect_uarch_cycle_root_hashes(3, 0, tail)` against a reference loop: `run_uarch(UARCH_CYCLE_MAX)`, then `get_root_hash` (halt leaf), then `log_reset_uarch` + `verify_reset_uarch` (reset leaf). It also checks the machine root after `collect_uarch_cycle_bundle`. The control run with the built-in uarch RAM matches everywhere. With the custom image, the reset leaf of mcycle 1 differs from what `verify_reset_uarch` returns, and every later leaf diverges:
```
[built-in uarch ram] mcycle 1: halt leaf ok (64dcb7ade907f069 vs 64dcb7ade907f069), reset leaf ok (beafc583c3a41063 vs verify_reset_uarch beafc583c3a41063)
[custom uarch ram] mcycle 1: halt leaf ok (ca0120065f62a44c vs ca0120065f62a44c), reset leaf MISMATCH (370c69331539f6a7 vs verify_reset_uarch beafc583c3a41063)
[custom uarch ram] mcycle 2: halt leaf MISMATCH (ef9c969db160a639 vs 38f993e746476dad), reset leaf MISMATCH (4e87a0c3654bd578 vs verify_reset_uarch 5169efe4d5f24b00)
[custom uarch ram] machine root after collect == root after reference: false
[custom uarch ram] machine root after collect_uarch_cycle_bundle == reference reset of mcycle 1: false
BUG: collect_uarch_cycle_root_hashes/collect_uarch_cycle_bundle reset leaves differ from reset_uarch/verify_reset_uarch when uarch RAM is not the built-in pristine image
```
Run: `eval $(make -s env); lua5.4 bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua` (exit 1). On the custom machine, the reference reset hash after mcycle 1 equals the built-in machine's reset hash (`beafc5...`). This confirms that the real reset restores the built-in image.

**Scenario**: A template or snapshot holds uarch RAM that is not byte-identical to the built-in image of the libcartesi the validator links. Ways this happens:
- the machine was built with `--uarch-ram-image` or a `uarch.ram.backing_store`;
- the snapshot was stored by a different build;
- uarch RAM was changed through `write_memory`.

A PRT validator (Dave, the Rollups Node, or another node) that builds its uarch-level commitment with `collect_uarch_cycle_root_hashes` or `collect_uarch_cycle_bundle` then commits reset leaves that `verify_reset_uarch` and the on-chain reset step cannot reproduce. Every later leaf is wrong too. In a dispute that reaches the reset step or any later uarch step, the honest player cannot prove its leaf and loses to an opponent that commits the full-reset leaves. If the differing words were uarch code or data that is read, later mcycles would even run different uarch code than a real reset gives. With the default config (built-in uarch RAM), the shortcut is correct.

**Possible solution**: At the start of collection, or before each shortcut reset, check that the uarch state is pristine: compare the uarch RAM range hash or the uarch state hash with `get_uarch_pristine_hash()`. If it is not pristine, either fall back to a full `reset_uarch()` (full write plus full hash-tree update) for that mcycle, or throw a clear error that rejects the machine. A cheaper and stricter variant: do the full `reset_uarch()` once on the first mcycle, so every later state is pristine and the dirty-word shortcut becomes valid.

**Severity**: medium. When it triggers, the impact is critical: the committed reset leaf and every later leaf cannot be proven, so an honest player loses. Both reviewers rated it medium because it needs a uarch RAM that differs from the library's built-in image, which default templates from the same release never have. A validator whose built-in image differs from the on-chain one would also fail through other paths.

**Risks**: Bug: silent wrong commitments, with no error, for machines with a custom or stale uarch RAM image. The machine is also left in a mixed state, so any later `get_root_hash`, proof or snapshot of it is wrong. Fix: a pristine check adds one hash comparison per collection (cheap). A full-reset fallback costs a full uarch RAM write and rehash per mcycle, but only on the non-pristine path. Rejecting such machines could break existing users of `--uarch-ram-image`; this is acceptable, since their commitments are unprovable today. Whatever the fix, it must keep the leaves byte-identical to `log_reset_uarch`/`verify_reset_uarch` in the pristine case.

**Proof of concept**: `bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua`. The test needs no machine images. It writes a temporary uarch RAM image next to itself (or in the directory given as its first argument) and removes it afterwards. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua
```
Exit 1 means the bug is present, 0 means fixed, and 2 means the built-in-image control unexpectedly failed.

**ID**: `api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram`

**Related**: [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset).

### B36. Temporary files from killed stores are never cleaned up

**Title**: Temporary files from stores killed mid-write are never cleaned up and pile up in forest/frontier directories

**Problem:** `write_file` in `cartesi.hash-tree` writes each tree or frontier file as `<name>.tmp.XXXXXX` in the target directory (`fs.new_temporary_file`). It then syncs the file and renames it into place. The temporary file is removed on failure only by the temporary object's `close`, which runs from `__close`/`__gc` (`cartesi.filesystem`). Neither runs when the process is SIGKILLed or OOM-killed, or when the machine loses power. No store or load path ever removes stale temporary files: `store_tree` and `load_tree` only test or open `<hash>.json` by its exact name, and `hash-tree.lua` never lists the directory. Every crash that lands between creating the temporary file and renaming it therefore leaves an orphaned file behind for good.

**Origin:** Introduced by this branch (`hash-tree.lua` and `filesystem.lua` are new).

**Area:** Lua library `cartesi.hash-tree` (`frontier_forest_store`, `frontier_store`), with `cartesi.filesystem` temporary files.

**Category:** Resource leak (disk).

**Location:**
- `src/cartesi/hash-tree.lua:509-514` (`write_file`: creates `<name>.tmp.` in the target directory)
- `src/cartesi/filesystem.lua:52-68` (cleanup only through `close`, `__close` and `__gc`)
- `src/cartesi/hash-tree.lua:525-527, 577-592` (`load_tree`/`store_tree` only check `<hash>.json` with `fs.exists`)
- `src/cartesi/hash-tree.lua:935-938` (`frontier_store`), `967-1018` (`frontier_forest_store`/`frontier_forest_load`): no cleanup

**Evidence:** `child.lua` builds a 1024-leaf keccak256 forest. It wraps `fs.sync_file` so that the process SIGKILLs itself after the temporary file is written and synced, but before the rename. It then calls `frontier_forest_store`. `test.lua` runs this 5 times with different leaves. It then runs one healthy store and `frontier_forest_load` in the same directory, and counts the `*.tmp.*` entries.
```
$ eval $(make -s env); lua5.4 bugs/lua-25-leftover-temp-files/test.lua
crash 1: ok=nil how=exit code=137 tmp files now=1
...
crash 5: ok=nil how=exit code=137 tmp files now=5
after healthy store+load: 5 leftover .tmp. files (353585 bytes)
  0x45f40119...df47f.json.tmp.9SwUWg
  ...
BUG: 5 orphaned temporary files from 5 interrupted stores remain after a later store/load; nothing cleans them
```

**Scenario:** A validator node (an experimental PRT node, or any Rollups Node or Dave component using these Lua APIs) persists its commitment forests with `frontier_forest_store`. It gets OOM-killed, restarted by its supervisor, or loses power from time to time while storing. Each such crash leaves one tree-sized file, roughly 70 KB per 1024 base hashes, in the forests directory or in the frontier's parent directory. Over a long run on a node that crashes often, these files take up more and more disk space. That moves the node closer to disk-full (ENOSPC) conditions, which feed the separate truncated-write issue in `write_file`.

**Possible solution:** Clean up stale temporary files when a directory is used. For example, in `frontier_forest_load`/`frontier_forest_store` (or in a dedicated `cleanup` helper), remove entries matching `*.json.tmp.*` from the forests directory and from the frontier's parent directory. Only do this when the caller owns the directory, so that a live writer's file is never removed. Another option is to create temporary files in a dedicated subdirectory (on the same filesystem, so rename stays atomic) that is wiped at startup. Document that a forests directory has a single writer.

**Severity:** Low. Both reviewers and the prover agree. Hashes, proofs, stored-state correctness and dispute outcomes are not affected, because loads never read `*.tmp.*` files and the rename commit keeps every committed name consistent. Nothing crashes or hangs. The leak is at most one tree-sized file per crash that lands mid-write, so it matters only for nodes that crash repeatedly over a long time.

**Risks:**
- Of the bug: slow, unbounded disk growth on unstable nodes, which adds to the chance of ENOSPC and the failures that follow it (failed or truncated stores, a node that stops).
- Of the fix: removing temporary files without regard to other processes could delete a file that a concurrent writer is about to rename, making that store fail. So cleanup has to assume or enforce a single owner per directory. A glob that is too broad could also delete user files that share the directory. Match only the exact `<64-hex>.json.tmp.XXXXXX` and `<frontier-name>.tmp.XXXXXX` patterns.

**Proof of concept:** `bugs/lua-25-leftover-temp-files/test.lua` (driver) and `bugs/lua-25-leftover-temp-files/child.lua` (store that is killed mid-write). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-25-leftover-temp-files/test.lua
```
It exits with 1 and prints `BUG: ...` while the leak is present, and prints `OK: no leftover temporary files` once it is fixed.

**ID**: `lua-25-leftover-temp-files`

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files).

### B37. filesystem.temp_pathname returns a deleted /tmp name that another user can claim

**Title**: `cartesi.filesystem.temp_pathname` returns a `/tmp` name it has just deleted, so another local user can claim it (TOCTOU)

**Problem**: `filesystem.temp_pathname()` calls `os.tmpname()`, which uses `mkstemp` to create `/tmp/lua_XXXXXX`. It then deletes that file and returns the name. This is the insecure `tmpnam` / `mktemp -u` pattern. Between the return and the caller's use of the name, any local user can create a symlink or a directory at that path in the world-writable `/tmp`. Callers use the returned name as the place to create a store, a checkpoint or a status directory.

**Origin**: Introduced by this branch. On `main` the same helper existed only in `tests/lua/cartesi/filesystem.lua`. This branch moves it into `src/cartesi/filesystem.lua`, which the Makefile installs through `EMU_TO_LUA_PATH`, so it is now part of the public `cartesi.filesystem` module.

**Area**: Lua library `cartesi.filesystem` (`temp_pathname`)

**Category**: Security (local TOCTOU / insecure temporary file)

**Location**:
- `src/cartesi/filesystem.lua:78-82` (`filesystem.temp_pathname`)
- `Makefile:80` (`EMU_TO_LUA_PATH` installs `src/cartesi/filesystem.lua`)
- Example callers (recipes, not shipped code): `doc/recipes/prt-demo.lua:99`, and `doc/recipes/prt-test.lua:170, 823, 2008, 2217, 2314`

**Evidence**: The test runs the victim as root. Right after `temp_pathname()` returns, it runs the attacker's steps as uid 65534 (`nobody`) through `setpriv`, which stands in for an attacker who has won the race.
(1) The attacker plants a symlink at the returned path that points to a file inside the victim's private 0700 directory. The victim's `fs.write_file` follows the symlink and overwrites that file. This host has `fs.protected_symlinks=0`.
(2) The attacker runs `mkdir` on the returned path first. The victim's `fs.create_directory` then fails with EEXIST.
Run command: `eval $(make -s env); lua5.4 bugs/lua-27-temp-pathname-toctou/test.lua`
```
running as root: true, fs.protected_symlinks=0
temp_pathname() -> /tmp/lua_wXY1oK (exists: false)
victim write_file to temp path: ok=true
BUG: write to fs.temp_pathname() path followed attacker's symlink and overwrote /tmp/tmp.shPbRLvdjK/precious
victim create_directory(temp_pathname()): ok=false err=unable to create directory '/tmp/lua_e39RDd': File exists
BUG: attacker pre-created directory at fs.temp_pathname() path; victim's create_directory fails (DoS)
exit=1
```

**Scenario**: A validator node or tool built on the shipped Lua library runs on a shared host and uses `fs.temp_pathname()` as the location for its store, checkpoint or status directory, the way the PRT recipes do. A local attacker watches `/tmp` (for example with inotify) and creates the name first.
- On every kernel: a pre-created directory or file makes the node's directory creation or store fail at startup. This is a denial of service.
- On hosts with `fs.protected_symlinks=0`: the node's writes follow a planted symlink, so it can overwrite files the attacker chose, with the node's privileges.

No shipped emulator code path (the `cartesi-machine` CLI, the C API or the other Lua modules) calls this helper. Hashes, proofs and step logs are not affected.

**Possible solution**: Remove `temp_pathname` from the shipped module, or make it safe. One option is to create a private directory with `mkdtemp` (mode 0700) and return a path inside it, so no other user can create that path. Another is to provide `create_temporary_directory()` built on `mkdtemp` and move the callers to it. A `mkdtemp` binding in the C filesystem core would make either option straightforward. With either fix the PoC exits 0.

**Severity**: Low. Both reviewers and the prover agree. An attacker needs a local account on a shared host and must win a race against a random name. On default kernels (`protected_symlinks=1`) the impact is limited to making the node fail at startup. No shipped emulator code uses the helper, and consensus data (hashes and proofs) is not affected.

**Risks**:
- Of the bug: other node implementations may copy the recipe pattern and get startup DoS on shared hosts, or symlink-redirected writes where `protected_symlinks` is off.
- Of the fix: removing or renaming the function breaks callers (the recipes and the tests). Returning a path inside a private directory changes cleanup semantics, because the caller must also remove the parent directory, so temporary directories may leak if callers are not updated.

**Proof of concept**: `bugs/lua-27-temp-pathname-toctou/test.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-27-temp-pathname-toctou/test.lua`. It exits 1 when the bug reproduces and 0 when the returned path cannot be claimed. Run it as root (with `setpriv` available) so the attacker steps run as `nobody`. As a non-root user it only gives a weaker same-user demonstration.

**ID**: `lua-27-temp-pathname-toctou`

### B38. ABI decoder accepts dirty address bits and non-zero padding

**Title**: evmu ABI decoder accepts dirty upper bits in `address` and dirty padding in `bytesN`, which Solidity rejects, and non-zero padding in `bytes`/`string`

**Problem**: The ABI decoder in `cartesi.evmu` does not check bits that a canonical encoding requires to be zero:
- `decode_address` keeps the last 20 bytes of the word (`tobe(word):sub(-20)`) and ignores the upper 12 bytes.
- `decode_bytes_sized` (`bytesN`) reads `N` bytes and skips the other `32-N` padding bytes without checking them.
- `decode_string` and the dynamic branch of `decode_bytes` skip the padding up to `ceil32(len)` without checking it.

The same file is strict elsewhere: `decode_uint` and `decode_int` check range, and `decode_bool` rejects anything other than 0 or 1. Solidity's ABI coder v2 reverts on an `address` or `bytesN` with dirty bits, so for those two types evmu accepts data that the on-chain `abi.decode` rejects. Solidity does not check trailing padding of dynamic `bytes`/`string`, so for those two types the issue is only malleability: several distinct byte strings decode to the same value.

**Origin**: Pre-existing. The branch added the selectorless wrappers `encode_abi`/`decode_abi` (commit 44f37ea). `decode_abi` sends data to the same lenient decoders, which makes them reachable from one more public entry point.

**Area**: `src/cartesi/evmu.lua`, the ABI decoder in the shipped Lua library (installed through `EMU_TO_LUA_PATH` in the top-level Makefile).

**Category**: Correctness. The decoder is non-canonical and inconsistent with on-chain decoding.

**Location**:
- `src/cartesi/evmu.lua:670-676` (`decode_address`)
- `src/cartesi/evmu.lua:702-709` (`decode_bytes_sized`)
- `src/cartesi/evmu.lua:691-700` (`decode_string`)
- `src/cartesi/evmu.lua:712-722` (`decode_bytes`, dynamic branch)
- Reached through `_M.decode_calldata` (`:820`), `_M.decode_calldata_hex` (`:836`) and `_M.decode_abi` (`:842`).

**Evidence**: The test first runs two control cases, which are rejected. It then feeds six non-canonical encodings, and all six are accepted:
```
$ eval $(make -s env); lua5.4 bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua
ok: (bool) value 2 [control] rejected: .../evmu.lua:686: invalid bool value in calldata (must be 0 or 1)
ok: (uint8) value 256 [control] rejected: .../evmu.lua:652: integer value does not fit in target type
BUG: (address) with 0xff upper 12 bytes accepted (decoded "0x1111111111111111111111111111111111111111")
BUG: (bytes4) with non-zero padding accepted (decoded "0xdeadbeef")
BUG: (string) with non-zero padding accepted (decoded "a")
BUG: (bytes) with non-zero padding accepted (decoded "0x61")
BUG: decode_calldata Notice(bytes) dirty padding accepted (decoded "a")
BUG: two distinct encodings decode to the same bytes value "a"
BUG: decoder accepted 6 non-canonical encodings
```
The test exits with status 1.

**Scenario**: The decoder is used by a Lua validator, indexer or tool that decodes untrusted ABI data with evmu, such as `decode_calldata` on Notice/Voucher outputs or `decode_abi` on `eth_call` results. Two things can go wrong:
- An `address` or `bytesN` with dirty bits is treated as valid, even though a contract's `abi.decode` of the same bytes would revert. For example, a voucher destination or payload field shows as well formed off-chain but fails on-chain.
- Distinct encodings collapse to the same decoded value. Code that deduplicates or keys on decoded values can then disagree with code that works on the raw bytes.

None of the following uses evmu: the C API, the JSON-RPC machine or the `cartesi-machine` CLI. Machine state hashes, output Merkle roots, proofs and step logs are all computed over raw bytes. So this bug cannot change a PRT commitment or make an honest player lose a dispute.

**Possible solution**:
- In `decode_address`, assert that the upper 12 bytes of the word are zero (`tobe(word):sub(1, 12) == ("\0"):rep(12)`).
- In `decode_bytes_sized`, assert that `calldata:sub(offset + size + 1, offset + padded_len)` is all zero.
- Optionally, for strict canonical decoding, check the same zero padding in `decode_string` and `decode_bytes`. Also optionally reject non-canonical head offsets, since aliasing or overlapping offsets are also accepted today.

**Severity**: Low. Both reviewers agree. The defect is real and reachable through the public Lua API, but it is pre-existing and limited to a Lua helper library. It never affects machine hashes, proofs, step logs, the C API or the CLI, so it cannot crash a validator or decide a dispute.

**Risks**:
- Of the bug: off-chain Lua consumers may accept malformed or malleable ABI data that the on-chain decoder rejects, and so diverge from contract behaviour on what counts as a valid output or input.
- Of the fix: stricter checks may start rejecting inputs that callers currently accept, such as sloppy hand-built calldata in scripts or tests. Making the padding checks on `bytes`/`string` strict goes beyond what Solidity enforces, so it should be a deliberate choice, or be made optional.

**Proof of concept**: `bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua
```
The test exits 1 while the bug is present and prints `PASS` (exit 0) once it is fixed.

**ID**: `lua-28-evmu-lenient-dirty-bits-padding`

**Related**: [B18](#b18-abi-decoder-bounds-checks-overflow-and-accept-out-of-bounds-offsets).

### B39. collect_uarch_cycle_* aborts the process when the uarch is halted but not reset

**Title**: collect_uarch_cycle_root_hashes and collect_uarch_cycle_bundle abort the process (assert) when uarch_halt=1 and uarch_cycle=0, because the precondition checks only uarch_cycle

**Problem**: The only uarch precondition in `machine::collect_uarch_cycle_root_hashes` is `read_reg(reg::uarch_cycle) != 0` -> throw "microarchitecture is not reset". `uarch_halt` is not checked. With `uarch_halt == 1` and `uarch_cycle == 0`, the first `uarch_interpret` in the inner loop returns `uarch_halted` without executing anything, and the loop breaks. The halt and reset hashes are appended and the uarch registers are reset, but mcycle never advanced, so `assert(mcycle_reached == mcycle_target)` fails. In the default build (`relwithdebinfo`, used for packaging), `src/Makefile` adds `-DNDEBUG` only to `interpret.cpp`, so `machine.cpp` keeps its asserts. The call therefore sends SIGABRT to the host process (the validator, or `cartesi-jsonrpc-machine` for a remote machine) instead of raising a catchable error. In an NDEBUG build (`release=yes`) the call does not abort. It returns a halt+reset group for an mcycle that never ran, then continues from the reset uarch, so every later leaf is shifted. `collect_uarch_cycle_bundle` calls `collect_uarch_cycle_root_hashes`, so it has the same defect.

**Origin**: pre-existing. `origin/main` has the same precondition (`src/machine.cpp:2676`) and the same assert (`src/machine.cpp:2834`).

**Area**: microarchitecture root-hash collection for PRT: `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (C API `cm_collect_uarch_cycle_root_hashes` and the bundle call, Lua bindings, JSON-RPC server).

**Category**: crash (process abort through a reachable assert); wrong hashes in NDEBUG builds.

**Location**:
- `src/machine.cpp:2678`: uarch precondition checks only `uarch_cycle`.
- `src/machine.cpp:2780`: an already-halted uarch breaks out of the inner loop at once.
- `src/machine.cpp:2837`: `assert(mcycle_reached == mcycle_target)` aborts the process.
- `src/machine.cpp:2894`: `collect_uarch_cycle_bundle` reaches the same path.

**Evidence**: `test-uarch-halt-abort.lua` runs each local case in a child process and also drives a spawned `cartesi-jsonrpc-machine`. All four cases abort with SIGABRT (exit 134) instead of raising an error:
- (a) `write_reg("uarch_halt", 1)`, then `collect_uarch_cycle_root_hashes`.
- (b) A config with `uarch.processor.registers.halt = 1`, the same state a stored machine can carry.
- (c) `collect_uarch_cycle_bundle`.
- (d) A remote machine: the server process dies.

Run from the repo root with `eval $(make -s env); lua5.4 bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`:
```
lua5.4: machine.cpp:2837: ... collect_uarch_cycle_root_hashes(...): Assertion `mcycle_reached == mcycle_target' failed.
Aborted
BUG: local write_reg case: child terminated abnormally (exit 134) instead of raising an error
... (same for config and bundle cases)
cartesi-jsonrpc-machine: machine.cpp:2837: ... Assertion `mcycle_reached == mcycle_target' failed.
remote collect: ok=false err=jsonrpc error: post error contacting 127.0.0.1:45905 (end of stream ...)
BUG: remote case: cartesi-jsonrpc-machine server died after collect_uarch_cycle_root_hashes: ... (Connection refused ...)
rc=1
```

**Scenario**: A validator (Rollups Node, Dave, or the Lua PRT node) loads a template or snapshot whose uarch registers have `halt = 1` and `cycle = 0`. This can happen through a misconfigured config, a hand-edited or corrupted stored machine, or a tool that called `write_reg("uarch_halt", 1)` before storing. When the node computes uarch-level commitments or a bundle for a dispute, the whole process aborts instead of reporting an error it could handle. If such a template were deployed, every validator using it would crash at that point. With a remote machine, the `cartesi-jsonrpc-machine` server dies and the client sees "end of stream", then "connection refused". Normal API use cannot reach this state: after `run_uarch` to halt, `uarch_cycle` is non-zero and the existing check rejects the call, and `reset_uarch` clears both registers.

**Possible solution**: Also throw `std::runtime_error{"microarchitecture is not reset"}` when `read_reg(reg::uarch_halt) != 0`, or require fully pristine uarch registers. Replace the post-loop sanity `assert`s (`uarch_halt != 0`, `mcycle_reached == mcycle_target`) with runtime checks that throw, so an unexpected state cannot abort the host process or produce silently wrong leaves in NDEBUG builds. Apply the same check to every other uarch entry point that assumes a reset uarch.

**Severity**: low. Both reviewers agree on this. The abort is real and kills the validator or the JSON-RPC server, but it needs a non-canonical uarch state that honest operation never produces, and an adversary cannot inject that state into an honest node's dispute. The wrong-hash variant exists only in non-default NDEBUG builds, from the same state.

**Risks**: Bug: a hard process abort (DoS) of a long-running validator or a shared JSON-RPC server, triggered by a bad template or snapshot. In NDEBUG builds, a silently wrong uarch commitment (a shifted leaf sequence) that would lose a dispute. Fix: low risk. The new check only rejects a state that is already invalid for this API. Turning the asserts into exceptions changes nothing on valid inputs.

**Proof of concept**: `bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`. It exits 1 and prints `BUG:` lines while the defect is present, and prints `PASS` once every case raises a catchable error and the remote server survives.

**ID**: `api-09-collect-uarch-halted-uarch-assert-abort`

**Related**: [B35](#b35-collect_uarch_cycle_-reset-shortcut-diverges-from-reset_uarch-when-uarch-ram-is-not-the-built-in-image), [B40](#b40-over-long-revert_uarch_tail-aborts-on-an-assert-or-yields-an-invalid-mcycle-subtree).

### B40. Over-long revert_uarch_tail aborts on an assert or yields an invalid mcycle subtree

**Title**: Over-long `revert_uarch_tail` (more than 2^20 entries) is accepted: with `log2_bundle > 0` it aborts the process (local or JSON-RPC server) on an assert, otherwise it returns an mcycle group with more than 2^20 leaves

**Problem**: The caller supplies `revert_uarch_tail` to `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (in `cm_*`, as a JSON array; over JSON-RPC it comes from the client). `machine::collect_uarch_cycle_root_hashes` checks three things only: the tail is non-empty, has `size() >= 2`, and has `back() == read_revert_root_hash()`. Nothing bounds its length by `2^ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE` (2^20). `append_revert_uarch_tail_period` pushes `tail[0..n-3]` as leaves, then calls `append_uarch_reset_root_hash`. The outcome depends on bundling and build type:
- `log2_bundle > 0`: `append_uarch_reset_root_hash` executes `assert(execution_bundle_count < bundle_capacity)`. The default `relwithdebinfo` build leaves asserts on outside `interpret.cpp`, so the process aborts with SIGABRT.
- `log2_bundle > 0` in a `release` build (NDEBUG): the assert is compiled out, and the call silently emits more than `2^(20-log2)` bundles for that mcycle.
- `log2_bundle == 0`: the call returns one mcycle group with more than 2^20 leaves, which is not a valid mcycle subtree.

So a bad argument produces either an abort or malformed output, never the `runtime_error` that the other tail checks raise.

**Origin**: pre-existing. The same validation and assert are on `origin/main`. The branch only changes `clear_hash_tree` in `machine.cpp`. The experimental PRT node does use this API, so it is in scope.

**Area**: microarchitecture root-hash collection for PRT, specifically the revert-tail handling of `collect_uarch_cycle_root_hashes` / `collect_uarch_cycle_bundle`. Exposed through the C API (`cm_collect_uarch_cycle_root_hashes`), the Lua bindings and JSON-RPC (`cartesi-jsonrpc-machine`).

**Category**: crash (assert abort, remote DoS of the JSON-RPC server) / input validation (malformed output).

**Location**:
- `src/machine.cpp:2700-2709`: tail validation in `machine::collect_uarch_cycle_root_hashes`, with no upper bound on the length.
- `src/machine.cpp:2645-2655`: `append_revert_uarch_tail_period` pushes every entry except the last two as leaves.
- `src/machine.cpp:2606`: `assert(execution_bundle_count < bundle_capacity)` in `append_uarch_reset_root_hash`.
- `src/machine.cpp:2718` (machine already at an rx-rejected yield, `start_rejected`) and `src/machine.cpp:2849` (machine reaches that state during collection): the two call sites.
- `src/Makefile:211`: the default `relwithdebinfo` build sets `-DNDEBUG` only for `interpret.cpp`, so the assert is live in `machine.cpp`.

**Evidence**: The test sets `iflags_Y=1` and an rx-rejected manual-yield `htif_tohost`, then passes a tail of 2^20+8 entries whose last entry is `read_revert_root_hash()`. It runs three cases:
- Case A: in-process, `log2_bundle=0`.
- Case B: child process, `log2_bundle=4`.
- Case C: `cartesi-jsonrpc-machine` server, `log2_bundle=4`.
```
case A (log2_bundle=0): accepted tail of 1048584 entries, group has 1048584 leaves (max 1048576)
BUG: over-long revert_uarch_tail accepted; mcycle group has more than 2^20 leaves
lua5.4: machine.cpp:2606: void cartesi::append_uarch_reset_root_hash(...): Assertion `execution_bundle_count < bundle_capacity' failed.
case B (local, log2_bundle=4): child exit code 134
cartesi-jsonrpc-machine: machine.cpp:2606: ... Assertion `execution_bundle_count < bundle_capacity' failed.
child-jsonrpc: call returned	false	jsonrpc error: post error contacting 127.0.0.1:44027 (end of stream ...)
child-jsonrpc: server alive after call:	false
BUG: case C (jsonrpc server, log2_bundle=4): process aborted on assert(execution_bundle_count < bundle_capacity)
```
Run: `eval $(make -s env); lua5.4 bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua` (exit 1, about 18 s).

**Scenario**: A validator or tooling built on the C/Lua/JSON-RPC API passes a wrong tail, for example:
- groups from several mcycles concatenated together;
- a tail taken from a machine that is not at the manual-yield fixed point.

The machine is at, or reaches, an rx-rejected manual yield, and the caller uses `log2_bundle > 0`. The node process aborts instead of getting an error. If the machine is remote, the shared `cartesi-jsonrpc-machine` server aborts, so one bad request from any client kills that server and every machine it hosts. Without bundling, or in a release build, the caller instead silently receives an invalid commitment group. A correct caller builds the tail with `collect_uarch_cycle_root_hashes(MCYCLE_MAX, 0)` on the reverted machine, as `prt.lua` does. That returns exactly one mcycle group of at most 2^20 entries, so honest validators that use the API correctly are not affected.

**Possible solution**: In `machine::collect_uarch_cycle_root_hashes`, next to the existing tail checks and before anything executes, add `if (revert_uarch_tail.size() > (UINT64_C(1) << ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)) throw std::runtime_error{"revert uarch tail is too long"};`. Optionally also require the size to be a valid one-mcycle period. Replace the `assert` at line 2606 (and the related `assert(!back_tree.full())`) with runtime checks, so that internal invariants guarding caller-controlled sizes cannot abort the process or be silently skipped under NDEBUG.

**Severity**: low. Both reviewers agree. Only a buggy or malicious caller can trigger it: correctly built tails never exceed 2^20 entries, so an honest player cannot lose a dispute and no correct node crashes. The impact is a process abort (including a remote JSON-RPC server DoS) or malformed output from bad input instead of a clean error.

**Risks**: Bug: abort of the node or of a shared JSON-RPC server on one malformed request; in release builds, silently malformed bundles that a caller might commit. Fix: very low risk. The new bound rejects only tails that can never be valid, and changing asserts into runtime errors does not change behaviour for valid inputs.

**Proof of concept**: `bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua`. The test needs no machine images. It spawns itself as child processes for the abort cases and spawns a local `cartesi-jsonrpc-machine` for case C. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua
```
Exit 1 means the bug is present. Exit 0 means all three cases reject the over-long tail with a normal error.

**ID**: `api-10-collect-uarch-revert-tail-length-unvalidated`

**Related**: [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset).
