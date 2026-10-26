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

17 confirmed issues: 2 high, 4 medium, 11 low.

| # | Severity | Origin | Area | Issue | Proof of concept |
|---|---|---|---|---|---|
| [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong) | high | introduced by branch | Hash tree (page cache, dense trees, crash consistency) | Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong | `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/` |
| [B91](#b91-read-only-queries-after-sync_stored-rewrite-the-shared-page-cache-so-a-host-crash-leaves-a-synced-machine-unloadable-or-with-wrong-proofs) | high | pre-existing | Hash tree (page cache), stored machines | Read-only queries after sync_stored rewrite the shared page cache, so a host crash leaves a synced machine unloadable or with wrong proofs | `bugs/u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr/` |
| [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree) | medium | pre-existing | Hash tree (sparse tree, crash consistency) | Crash in sparse-tree update freezes the root hash of a shared hash tree | `bugs/ht-03-persisted-sparse-marked-flag-stale-root/` |
| [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages) | medium | introduced by branch | Hash tree (clear_hash_tree) | Crash during clear_hash_tree leaves zeroed hashes on clean pages | `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/` |
| [B59](#b59-replace_memory_range-leaves-the-config-stale-so-store-persists-the-old-flash-image) | medium | pre-existing | Machine API (replace_memory_range, store) | replace_memory_range leaves the config stale, so store persists the old flash image | `bugs/w2b-11-replace-memory-range-stale-config-store/` |
| [B92](#b92-queries-after-sync_stored-rewrite-the-shared-dense-trees-with-no-write-ordering-so-a-host-crash-can-leave-a-wrong-root-hash) | medium | pre-existing | Hash tree (dense trees, dirty-page trees), stored machines | Queries after sync_stored rewrite the shared dense trees with no write ordering, so a host crash can leave a wrong root hash | `bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/` |
| [B16](#b16-verify_slice-and-verify_splice-accept-malformed-proofs) | low | pre-existing | Lua cartesi.hash-tree (proof verification) | verify_slice and verify_splice accept malformed proofs | `bugs/lua-06-verify-slice-noncanonical-address/` |
| [B25](#b25---clear-hash-tree-is-reapplied-on-every-stored-mode-revert) | low | introduced by branch | CLI | --clear-hash-tree is reapplied on every stored-mode revert | `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/` |
| [B26](#b26---clear-hash-tree-is-silently-ignored-for-existing-remote-machines) | low | introduced by branch | CLI | --clear-hash-tree is silently ignored for existing remote machines | `bugs/rpc-09-clear-hash-tree-ignored-existing-remote/` |
| [B27](#b27---dump-memory-ranges-runs-mkdir-through-the-shell-with-an-unquoted-path) | low | pre-existing | CLI | --dump-memory-ranges runs mkdir through the shell with an unquoted path | `bugs/rpc-10-dump-memory-ranges-shell-mkdir/` |
| [B28](#b28-get_data_root_hash-returns-nil-for-empty-data-and-rejects-root-sizes-63-and-64) | low | pre-existing | Lua cartesi.hash-tree | get_data_root_hash returns nil for empty data and rejects root sizes 63 and 64 | `bugs/lua-16-get-data-root-hash-empty-nil/` |
| [B49](#b49-lua-hash-functions-ignore-an-empty-second-argument-and-frontier-functions-accept-non-32-byte-hashes) | low | pre-existing | Lua cartesi (hash functions), cartesi.hash-tree | Lua hash functions ignore an empty second argument and frontier functions accept non-32-byte hashes | `bugs/lua-15-concat-hash-empty-second-arg/` |
| [B52](#b52-a-full-disk-kills-a-sharing_all-machine-with-sigbus-on-writes-to-sparse-pages) | low | pre-existing | Memory mapping (os-mapped-memory), stored machines | A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages | `bugs/w2b-04-sharing-all-enospc-sigbus/` |
| [B55](#b55-spawn_server-hangs-on-its-error-path-when-the-caller-has-sigterm-blocked) | low | pre-existing | JSON-RPC client (spawn_server) | spawn_server hangs on its error path when the caller has SIGTERM blocked | `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/` |
| [B64](#b64-clear_hash_tree-punches-holes-in-shared-hash-files-so-a-full-disk-later-kills-the-process-with-sigbus) | low | introduced by branch | Memory mapping (mapped_memory::clear) | clear_hash_tree punches holes in shared hash files, so a full disk later kills the process with SIGBUS | `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/` |
| [B83](#b83-rollback-frees-the-working-servers-port-before-rebinding-so-a-bind-in-the-gap-makes-revert-fail) | low | pre-existing | JSON-RPC remote machine (rollback, rebind_server) | Rollback frees the working server's port before rebinding, so a bind in the gap makes revert fail | `bugs/p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race/` |
| [B84](#b84-the-json-rpc-client-cannot-use-ipv6-server-addresses) | low | pre-existing | JSON-RPC client and server (addresses) | The JSON-RPC client cannot use IPv6 server addresses | `bugs/p1-07-rml-05-ipv6-endpoint-format-unparseable/` |

## Issues

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

**Related**: B20 (fixed).

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

**Related**: B23 (fixed).

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

### B49. Lua hash functions ignore an empty second argument and frontier functions accept non-32-byte hashes

**Title**: `cartesi.keccak256`/`sha256(h, "")` and `(h, nil)` return `hash(h)` instead of raising an error; in-memory hash-tree frontier and proof functions accept entries that are not 32 bytes

**Problem**: `cartesi_mod_hasher` reads its second argument with `luaL_optlstring(L, 2, "", &len2)` and takes the two-hash concat path only `if (len2 > 0)`. So `keccak256(h, "")` and `keccak256(h, nil)` (and the same calls to `sha256`) look exactly like the one-argument call. They return `hash(h)` with no error, although the two-argument form is documented as the hash of two 32-byte hashes. The check is also asymmetric: `("", h)` and `(h, 31-byte)` raise an error, but `(h, "")` does not. The in-memory functions in `cartesi.hash-tree` pass caller entries straight to `hash_function(left, right)` without checking that they are 32-byte hashes. These are `frontier_push_back`, `frontier_append`, the pad of `frontier_get_root_hash`, `frontier_pad_back`, `frontier_next_proofs`, and `roll_hash_up_tree`/`verify_slice`. When an empty right-hand entry reaches them, they build a wrong node or root and report nothing. Only `frontier_load` and `load_tree` check sizes with `is_raw_hash`. A 31-byte entry is accepted on insertion and fails only later, inside a root or proof computation, with a confusing error.

**Origin**: Pre-existing. `cartesi_mod_hasher` is the same as on `origin/main`. The frontier functions already exist on `main`; this branch extends them, and the PRT node uses them.

**Area**: The Lua bindings (`src/clua-cartesi.cpp`) and the shipped Lua module `cartesi.hash-tree` (`src/cartesi/hash-tree.lua`), which validators use to build output and computation commitments and their proofs.

**Category**: Correctness / input validation (fail-open).

**Location**:
- `src/clua-cartesi.cpp:64-101` (`cartesi_mod_hasher`: `luaL_optlstring(L, 2, "", ...)` at line 77, `if (len2 > 0)` at line 81)
- `src/cartesi/hash-tree.lua:9-23` (`roll_hash_up_tree`, used by `verify_slice`)
- `src/cartesi/hash-tree.lua:165-178` (`frontier_push_back`)
- `src/cartesi/hash-tree.lua:186-214` (`frontier_append`)
- `src/cartesi/hash-tree.lua:219-238` (`frontier_get_root_hash`, `pad` argument)
- `src/cartesi/hash-tree.lua:248` (`frontier_pad_back`)
- `src/cartesi/hash-tree.lua:310-359` (`frontier_next_proofs`)
- For contrast: `src/cartesi/hash-tree.lua:516` (`is_raw_hash`, used only by the load paths at lines 543, 548, 949 and 1008)

**Evidence**: The test runs each case under `pcall`. The only cases that raise an error are the ones where the empty value is the left operand. Excerpt:
```
BUG: keccak256(a, "") returned keccak256(a) instead of raising an error
BUG: keccak256(a, nil) returned keccak256(a) instead of raising an error
ok: keccak256("", a) raises: true (bad argument #1 to 'cartesi.keccak256' (concatenate hash is only supported for inputs with size of hash))
BUG: sha256(a, "") returned sha256(a) instead of raising an error
BUG: frontier_push_back(f, "") accepted; f[2] == keccak256(a) (single-input hash of left sibling)
BUG: frontier_push_back(f, 31-byte entry) accepted; later root computation fails late with: .../hash-tree.lua:229: bad argument #1 to 'hash_function' (...)
BUG: frontier_get_root_hash(f, "") accepted empty pad, returned 0x9de88bce...334270e
BUG: frontier_next_proofs(f, {a, ""}) accepted; root 0xb839c4dc...4634a8f1, target_hash[2] length 0
   proof[1] verifies against that root: true
BUG: verify_slice accepted a proof with an empty sibling hash (root = keccak256(target))
9 defect(s) observed
```
Run: `eval $(make -s env); timeout 30 lua5.4 bugs/lua-15-concat-hash-empty-second-arg/test.lua` (exit status 1 while the bug is present).

**Scenario**: A Lua validator (the PRT node, or another node built on the same `cartesi` / `cartesi.hash-tree` APIs) builds its outputs or computation commitment with `frontier_push_back`, `frontier_append` or `frontier_next_proofs`. A bug in the caller can feed it `""` or `nil` instead of a hash, for example an off-by-one index into a table of hashes, a missing field, or a truncated read. Lua code hits these mistakes easily. The library does not fail loudly. It computes a commitment that looks valid but is wrong, and the node posts it, so an honest player can end up defending a wrong claim. Code that calls `keccak256(left, right)` directly, with `right` coming from a sparse table, makes the same silent mistake. An adversary cannot exploit this. A forged proof cannot be made to verify against an honest root, because the bogus parent `keccak256(child)` would have to match a node built from 64 bytes, which needs a preimage. Every hash the C API returns is exactly 32 bytes.

**Possible solution**: In `cartesi_mod_hasher`, choose the concat path with `nargs == 2` (or `!lua_isnoneornil(L, 2)`) instead of `len2 > 0`, and require both inputs to be `CM_HASH_SIZE`. Decide whether an explicit `nil` second argument is an error or the one-argument form, and document the choice. Optionally, assert `is_raw_hash` on the entries, pads and siblings that `frontier_push_back`, `frontier_append`, `frontier_pad_back`, `frontier_get_root_hash`, `frontier_next_proofs` and `roll_hash_up_tree` receive, so that bad input is rejected when it enters, not deep inside a later computation.

**Severity**: Low. All three reviewers rated it low, and one of them argued it is not a defect. With well-formed 32-byte inputs every hash and proof is correct and deterministic, verification cannot be fooled, and there is no crash or hang. The impact is fail-open behaviour that turns a separate caller bug into a silently wrong commitment instead of an error.

**Risks**: Of the bug: a caller-side mistake goes unnoticed and leads to a wrong on-chain commitment or proof, which in the worst case makes an honest validator lose a dispute. It also makes such bugs harder to diagnose, because the error, if any, appears far from its cause. Of the fix: code that today calls `keccak256(x, nil)` or `keccak256(x, "")` on purpose to mean "hash x" would start raising an error. A search of in-tree callers is needed. Size asserts in the frontier functions cost a little time on hot paths, which matters little next to the hashing itself.

**Proof of concept**: `bugs/lua-15-concat-hash-empty-second-arg/test.lua`. Run it from the repo root with `eval $(make -s env); timeout 30 lua5.4 bugs/lua-15-concat-hash-empty-second-arg/test.lua`. It prints one `BUG:` line per accepted malformed input and exits with 1 while the bug is present, and with 0 once it is fixed.

**ID**: `lua-15-concat-hash-empty-second-arg`

### B52. A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages

**Title**: A full disk kills the process with SIGBUS when a SHARING_ALL machine writes to a sparse page

**Problem**: When a machine is loaded or created with `SHARING_ALL` (or with shared backing stores), its RAM, flash drive and phtc payload files are mapped `MAP_SHARED` straight from the stored directory, and those files stay sparse. The first write to a page that is still a hole makes the kernel allocate a disk block during the page fault. If the filesystem is full at that point, the kernel raises SIGBUS. The writer can be the guest during `run` or the host through `write_memory` and similar calls. Nothing reserves space when the machine loads: `mapped_memory` only checks that `st_size` equals the expected length, which a sparse file passes, and it never calls `fallocate`/`posix_fallocate`. libcartesi also installs no SIGBUS handler. So the process dies in the middle of an instruction or an API call, and no error ever reaches the caller (no C error code, no Lua error). The `cartesi-jsonrpc-machine` server dies the same way, because it deliberately leaves SIGBUS out of its Asio signal set. The SHARING_ALL directory is left part-written.

**Origin**: Pre-existing. `origin/main` (v0.22.0) has the same `MAP_SHARED` mapping and also reserves no space. The branch makes the failure a little more likely: its new `mapped_memory::clear()` punches holes (`FALLOC_FL_PUNCH_HOLE`) across the shared backing file, so pages written after a clear need disk space again when they fault. Commit ff9ac85 on the branch ("fix: let SIGBUS terminate the JSON-RPC server") deliberately keeps the current kill-on-SIGBUS behaviour and leaves graceful recovery for later.

**Area**: os-mapped-memory / machine load with `SHARING_ALL`, both in-process (C API, Lua, CLI) and in the JSON-RPC server.

**Category**: Crash / robustness: an uncontrolled process kill on ENOSPC instead of a returned error.

**Location**:
- `src/os-mapped-memory.cpp:161-182`: the backing file is checked only by `st_size` against the expected length. Sparse files pass, and no space is reserved.
- `src/os-mapped-memory.cpp:187`, `:227`, `:253`: `MAP_SHARED` mmap of the backing file.
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear()` (added on the branch) punches holes in the shared backing file.
- `src/machine.cpp:1730-1775`: `machine::write_memory` does a plain `memcpy` into the shared mapping, which faults with SIGBUS on ENOSPC.
- `src/jsonrpc-remote-machine.cpp:328`: SIGBUS is deliberately not handled, so the server process dies.

**Evidence**: `test.lua` runs `child.lua` inside `unshare -m`, on a private 60 MiB tmpfs. The child stores a machine with 64 MiB of RAM there; the directory takes about 33 MiB because the RAM file is sparse. It then reloads the machine with `cartesi.SHARING_ALL` and calls `write_memory` one 4 KiB page at a time, wrapping each call in `pcall`. After about 6-7k pages the tmpfs is full and the child is killed by SIGBUS. `pcall` never sees an error. Run with `eval $(make -s env); lua5.4 bugs/w2b-04-sharing-all-enospc-sigbus/test.lua` as root; it takes about 0.2 s and exits 1:
```
stored; df:
tmpfs              61440 33676     27764  55% .../mnt
pages written: 2048
pages written: 4096
pages written: 6144
Bus error
EXIT=135
BUG: process killed by SIGBUS (exit 135) on write_memory to SHARING_ALL machine when disk fills; no error returned
```

**Scenario**: A PRT validator, a Dave node, or anything following `doc/recipes/prt.lua` (lines 1021, 1113, 1172) loads its epoch machine in-process with `SHARING_ALL`. If the host disk fills up while the guest touches fresh RAM or flash pages during `run`, or while the node calls `write_memory` / `send_cmio_response`, the node process is killed with a bare "Bus error". There is no log line and no error to handle. The working directory is left torn in the middle of a step. A Rollups Node or app using a `cartesi-jsonrpc-machine` with shared stores sees the connection drop and gets no reason for it. CLI users running `cartesi-machine` with shared stores see the same crash.

**Possible solution**: Choose one or combine:
- Optionally reserve the backing file's blocks for shared-writable mappings on load and after `clear()`: `posix_fallocate`/`fallocate(mode=0)`, enabled by a runtime flag such as `preallocate`. This turns ENOSPC into a load-time `std::system_error`, at the cost of giving up sparseness.
- Before load or `run`, check free space with `statvfs` against the number of hole blocks (`SEEK_HOLE`/`SEEK_DATA`), and warn or fail early.
- At minimum, document that `SHARING_ALL` needs headroom of up to the full RAM and flash sizes, and have the JSON-RPC server log a clear "SIGBUS on mapped memory (disk full?)" message before it dies, using a `sigaction` handler that only writes and calls `_exit`.

Recovering from SIGBUS inside the library (`siglongjmp`) is fragile and is not recommended.

**Severity**: Low. Both reviewers rated it low and the prover rated it medium. It needs a full host disk, which stops the node in any case. Hashes, proofs and step logs are never wrong. The torn directory is the same outcome as any other crash during a `SHARING_ALL` run, which nodes already have to recover from via snapshots. The practical cost is a sudden kill that is hard to diagnose, instead of a clean error.

**Risks**: Of the bug: an operator whose disk fills sees validators die with no explanation, and the shared working directory is left inconsistent, so recovery depends on a good snapshot or clone existing. Of the fix: preallocating removes the disk savings of sparse RAM and flash images, which can be several GiB per machine and per snapshot. Calling `fallocate` after `clear()` undoes the point of punching holes. A SIGBUS handler that tries to resume execution can corrupt state or loop on the faulting instruction.

**Proof of concept**: `bugs/w2b-04-sharing-all-enospc-sigbus/test.lua` (driver: makes a private mount namespace and a 60 MiB tmpfs; needs root) and `bugs/w2b-04-sharing-all-enospc-sigbus/child.lua` (stores, reloads with `SHARING_ALL`, and writes pages). Run from the repo root: `eval $(make -s env); lua5.4 bugs/w2b-04-sharing-all-enospc-sigbus/test.lua`. Exit 1 means the bug reproduced (SIGBUS); exit 0 means it is fixed (`write_memory` raised an error, or every page was written); exit 2 means `unshare`/`mount` were unavailable.

**ID**: `w2b-04-sharing-all-enospc-sigbus`

**Related**: [B64](#b64-clear_hash_tree-punches-holes-in-shared-hash-files-so-a-full-disk-later-kills-the-process-with-sigbus).

### B55. spawn_server hangs on its error path when the caller has SIGTERM blocked

**Title**: cm_jsonrpc_spawn_server hangs forever on its error path when the caller has SIGTERM blocked

**Problem:** `jsonrpc_machine` starts the server with `posix_spawnp(&child_pid, bin, nullptr, nullptr, args, environ)`. It passes no `posix_spawnattr_t`, so `POSIX_SPAWN_SETSIGMASK` is not set and the child inherits the calling thread's signal mask. The server's `install_signal_handlers()` resets the SIGINT/SIGTERM dispositions to `SIG_DFL` and later adds them to an asio `signal_set`. Nothing in the server calls `sigprocmask` or `pthread_sigmask`, so a SIGTERM that was blocked in the caller stays blocked in the server. If anything fails after the spawn, the `child_waiter` scope-exit sends `kill(child_pid, SIGTERM)` once and then loops on `waitpid(child_pid, nullptr, 0)` with no time limit. It escalates to SIGILL only on `EINTR`, which never happens here. The SIGTERM stays pending, the server never exits, and `cm_jsonrpc_spawn_server` never returns its error. The server process also leaks. Failures that lead here: version check failure or timeout, and failure of the `fork`, `shutdown` or `rebind` requests. On the success path the direct child exits through the `shutdown` RPC, so the call returns. Servers spawned that way still ignore SIGTERM/SIGINT for their whole life, but this was not tested. A secondary claim was also not tested: the waiter always SIGTERMs `child_pid`, even after the child may have been auto-reaped under `SIGCHLD=SIG_IGN`, so a narrow race could signal a reused pid.

**Origin:** pre-existing. The spawn and waiter logic is the same before this branch.

**Area:** libcartesi_jsonrpc spawn (`jsonrpc-machine.cpp`) / server signal setup (`jsonrpc-remote-machine.cpp`).

**Category:** hang

**Location:**
- `src/jsonrpc-machine.cpp:491`: `posix_spawnp` with null file actions and null attrs, so the signal mask is inherited.
- `src/jsonrpc-machine.cpp:505-545`: `child_waiter` sends `kill(child_pid, SIGTERM)`, then `waitpid` with no bound; SIGILL is sent only on `EINTR`.
- `src/jsonrpc-machine.cpp:559-586`: post-spawn steps that can throw (`check_server_version`, `fork`, `shutdown`, `rebind`).
- `src/jsonrpc-remote-machine.cpp:170-182`: `install_signal_handlers()` resets dispositions only and never unblocks the signals.
- `src/jsonrpc-remote-machine.cpp:325-327`: `signals.add(SIGINT/SIGTERM)` cannot fire while the signals are blocked.

**Evidence:** The test forks a helper into its own process group. The helper calls the public C API `cm_jsonrpc_spawn_server("127.0.0.1:0", 0, ...)`. A timeout of 0 forces the version check to time out, which takes the error path.
- Baseline, SIGTERM unblocked: the call returns -6 at once.
- After `pthread_sigmask(SIG_BLOCK, {SIGTERM})`: the call does not return within 5s. `/proc` shows the caller sleeping in `waitpid`. The spawned `cartesi-jsonrpc-machine` has `SigBlk=0x4000` (SIGTERM inherited as blocked) and `ShdPnd=0x4000` (the waiter's SIGTERM is stuck pending). The test then SIGKILLs the group.

Run command:
```
eval $(make -s env); sh bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh
```
Output excerpt:
```
pid 24806 test_spawn_sigt: State:	S (sleeping) ShdPnd:	0000000000000000 SigBlk:	0000000000004000
pid 24807 cartesi-jsonrpc: State:	S (sleeping) ShdPnd:	0000000000004000 SigBlk:	0000000000004000
baseline (SIGTERM unblocked): spawn returned -6 (error, as expected for timeout 0)
BUG: cm_jsonrpc_spawn_server did not return within 5s when caller has SIGTERM blocked (spawned server inherited mask, ignores SIGTERM, waitpid blocks forever)
```
(exit status 1)

**Scenario:** A C/C++ host such as a PRT validator, a custom node or an app harness follows the common daemon pattern: it blocks SIGTERM/SIGINT in `main` and handles them in a dedicated `sigwait`/`signalfd` thread. Every thread created afterwards inherits that mask, including the one that calls `cm_jsonrpc_spawn_server`. When a spawn fails, the worker thread freezes forever instead of getting an error code, and an orphaned `cartesi-jsonrpc-machine` stays alive holding its listening socket. Typical failures are a version mismatch between libcartesi_jsonrpc and the installed server binary, a server that starts too slowly under load and exceeds `spawn_timeout_ms`, or a failed fork, shutdown or rebind. The validator cannot retry or report the failure. Rust/Go hosts such as the Rollups Node and Dave usually do not block these signals, so they are less likely to be affected.

**Possible solution:**
- In `jsonrpc-machine.cpp`, pass a `posix_spawnattr_t` with `POSIX_SPAWN_SETSIGMASK` (empty mask) and `POSIX_SPAWN_SETSIGDEF` (at least SIGINT, SIGTERM and SIGCHLD reset to default). Rust's `std::process::Command` resets the child's mask the same way.
- As defense in depth, make the server unblock SIGINT/SIGTERM at startup (`pthread_sigmask(SIG_UNBLOCK, ...)` in `install_signal_handlers`).
- Optionally bound the waiter: after SIGTERM, poll `waitpid(..., WNOHANG)` for a short grace period, then escalate to SIGKILL.
- Skip the unconditional SIGTERM once the child has acknowledged `shutdown`, to avoid signalling a possibly reused pid.

**Severity:** low. Both reviewers rated it low, at most borderline medium. Two uncommon conditions must hold at once: the caller has SIGTERM blocked, and a spawn fails after `posix_spawnp`. When they do, the result is a permanent hang plus a leaked server process instead of an error code. Hashes, proofs and stored state are never affected, and successful spawns work.

**Risks:**
- Of the bug: a host thread deadlocks forever on a spawn failure. Servers accumulate as leaked processes holding ports, and supervisors cannot terminate spawned servers with SIGTERM/SIGINT.
- Of the fix: resetting the mask and dispositions in the child is standard and low-risk. A hard SIGKILL escalation must keep the coverage-build rule of not signalling a child that is already flushing gcov counters after `shutdown`. Callers that relied on spawned servers ignoring SIGTERM (unlikely, and undocumented) would see different behaviour.

**Proof of concept:** `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/test_spawn_sigterm_blocked.cpp`, built and run by `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh`. From the repo root:
```
eval $(make -s env); sh bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh
```
The test exits 1 and prints a `BUG:` line while the defect is present, and exits 0 once it is fixed.

**ID**: `w2b-07-spawn-server-hangs-when-sigterm-blocked`

**Related**: B10 (fixed).

### B59. replace_memory_range leaves the config stale, so store persists the old flash image

**Title**: `replace_memory_range` leaves `m_c.flash_drive`/`m_c.nvram` stale, so `store` with `SHARING_CONFIG`/`SHARING_NONE` persists the pre-replacement image

**Problem**: `machine::replace_memory_range` replaces the address range object (`m_ars.replace`), rebuilds the hot TLB and evicts clean pages. It never writes the new `backing_store` (data/dht/dpt filenames and the `shared` flag) into the matching `m_c.flash_drive[i]` or `m_c.nvram[i]` entry. `machine::store` decides what to do with each flash/nvram range from that stale `m_c` entry. As a result:
- **Shared replacement under `SHARING_CONFIG`.** If the original range was not shared (for example, any machine loaded with `SHARING_NONE`), `store` takes the "copy unshared backing store" branch. It runs `os::copy_file` on the ORIGINAL image and its `.dht`/`.dpt` files instead of writing current memory. This breaks the `cm.h` contract: "Store current machine state for shared backing stores".
- **Unshared replacement under `SHARING_CONFIG` or `SHARING_NONE`.** The range is rolled back to the image it had before the replacement, not to the replacement file.

The stored snapshot mixes the current processor/RAM state with the old flash contents, and its root hash is neither the live machine's hash nor the replacement image's hash. `get_initial_config()` also keeps reporting the old backing store (old `data_filename`, `shared=false`). That could be read as intended for an "initial" config, but `store` depends on it, so either way the snapshot is wrong.

**Origin**: Pre-existing. `origin/main` has the same `replace_memory_range` and `store` code.

**Area**: C API / Lua API `replace_memory_range` + `store` (stored machines, flash drives and NVRAM). Reached by the `cartesi-machine` CLI (`--replace-memory-range` plus `--store=...,sharing:config|none`).

**Category**: corrupted-state (a silently wrong persisted snapshot).

**Location**:
- `src/machine.cpp:633-681`: `machine::replace_memory_range` resolves start/length from `m_c` and calls `m_ars.replace(resolved)`, but never updates `m_c.flash_drive[i]`/`m_c.nvram[i]`.
- `src/machine-address-ranges.cpp:639-663`: `machine_address_ranges::replace` builds the new `memory_address_range` from `config.backing_store`. This is the only place the new backing store is recorded.
- `src/machine.cpp:418-459`: the `store_address_range` lambda picks "write current memory" vs "copy unshared backing store" (line 436) from the `backing_store_config` it is handed.
- `src/machine.cpp:467-472`: `store` passes the stale `f.backing_store`/`n.backing_store` from `m_c` for each flash drive and NVRAM range.
- `src/cm.h:569`: documented `CM_SHARING_CONFIG` store semantics, which the shared case violates.
- `src/cartesi-machine.lua:3141` (replacements applied) and `:4727` (store): the CLI path.

**Evidence**: `test.lua` stores a base machine whose flash drive (`0x0080000000000000`, length `0x2000`) holds `'A'`. It then runs three scenarios. In each, it loads the base with `SHARING_NONE`, replaces the drive with a `'B'` file (shared or unshared), writes `'Z'` at `+0x1000`, stores with `SHARING_CONFIG` or `SHARING_NONE`, and reloads. In every scenario the reloaded flash holds the pre-replacement `'A'` image. Run with `eval $(make -s env); lua5.4 bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It exits 1:
```
[shared-B_SHARING_CONFIG] get_initial_config flash backing_store: data_filename=/tmp/lua_G3S6gc-w2b-11/base/0080000000000000-2000.bin shared=false
[shared-B_SHARING_CONFIG] memory before store="BBBBBBBB" after reload="AAAAAAAA"
[shared-B_SHARING_CONFIG] root hash equal after store/reload: false
[shared-B_SHARING_CONFIG] byte at +0x1000 after reload="A" expected="Z"
BUG: [shared-B_SHARING_CONFIG] store after replace_memory_range persisted the PRE-replacement flash image ("AAAAAAAA", byte@+0x1000="A") instead of the replacement ("BBBBBBBB", byte@+0x1000="Z")
[unshared-B_SHARING_CONFIG] memory before store="BBBBBBBB" after reload="AAAAAAAA"
[unshared-B_SHARING_NONE]   memory before store="BBBBBBBB" after reload="AAAAAAAA"
```
In the shared scenario the processor did not run, so the flash range is the only source of the root hash mismatch. For the unshared scenarios a hash mismatch alone is expected, because those ranges roll back by design. The defect there is that they roll back to `A` instead of `B`.

**Scenario**: An app or CLI user, or a node, keeps a template machine and swaps in an app or input drive per run. For example: `cartesi-machine --load=template,sharing:none --replace-memory-range=label:app,filename:app-v2.ext2,shared --store=snap,sharing:config`, or the same sequence through `cm_replace_memory_range` + `cm_store`. The stored `snap` silently contains the template's old drive (and its old `.dht`/`.dpt`), so reloading it gives a different root hash and a machine that boots the wrong drive contents. Anyone who later loads that snapshot (an operator restoring a checkpoint, an app developer reproducing a run) works from state that matches neither the live machine nor the replacement image. The default `SHARING_ALL` always writes current memory and is not affected. No evidence was found that PRT validators, the Rollups Node or Dave combine `replace_memory_range` with `SHARING_CONFIG`/`SHARING_NONE` stores, and live-machine hashes, proofs and logs are unaffected.

**Possible solution**: In `machine::replace_memory_range`, after `m_ars.replace(resolved)` succeeds, find the `m_c.flash_drive`/`m_c.nvram` entry with the same start/length and update its `backing_store` (data/dht/dpt filenames, `shared`, `create`, `truncate`) from `config.backing_store`. Keep its `label`, `read_only`, start and length. Alternatively, have `store` take the per-range backing-store decision from the live `address_range` object instead of `m_c`. Add a regression test that stores after `replace_memory_range` under all three sharing modes and reloads.

**Severity**: medium. Both reviewers rated it medium and the prover low-to-medium. It silently corrupts a persisted snapshot (wrong flash image and root hash) in a legitimate, documented, CLI-reachable flow, which is more than low. It is not high because the default `SHARING_ALL` is unaffected, live-machine hashes/proofs are correct, and no validator path is known to use the combination.

**Risks**:
- Of the bug: snapshots that silently contain the wrong drive, which leads to unexpected root hashes, wrong program behaviour after reload, and hard-to-diagnose divergence when such a snapshot is used as a checkpoint or template.
- Of the fix: `get_initial_config()` would start reporting the replacement backing store. Callers that compare it with the originally loaded config, or that rely on it to find the original image, would see a change. The stored `config.json` would then reference the replaced drive's files, which is correct, but the semantics of "initial config" should be documented. `create`/`truncate` flags copied from the replacement must not cause files to be recreated or truncated on a later load. The update must stay exception-safe, so `m_c` is changed only after `m_ars.replace` succeeds.

**Proof of concept**: `bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It is self-contained and uses a temporary directory (override with `WORKDIR=...`). Run from the repo root with `eval $(make -s env); lua5.4 bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It prints `BUG:` lines and exits 1 while the bug is present, and prints `OK` and exits 0 once it is fixed.

**ID**: `w2b-11-replace-memory-range-stale-config-store`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `w2a-01-store-after-replace-memory-range-uses-stale-config`: run with `eval $(make -s env); lua5.4 bugs/w2a-01-store-after-replace-memory-range-uses-stale-config/test.lua`.

**Related**: B01 (fixed).

### B64. clear_hash_tree punches holes in shared hash files, so a full disk later kills the process with SIGBUS

**Title**: mapped_memory::clear punches holes in shared .dht backing files, so after cm_clear_hash_tree on a full filesystem the next get_root_hash dies with SIGBUS instead of returning an error

**Problem**: `mapped_memory::clear()` handles a shared writable mapping (`m_backing_sync_length > 0`) by calling `fallocate(FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE)` (`F_PUNCHHOLE` on macOS) over the whole backing file. Every allocated block of the file is freed. `dense_hash_tree::do_clear()` reaches this code, and `hash_tree::clear()` calls that and then marks every page dirty. The next `get_root_hash`, `get_proof` or `collect_*` call therefore rewrites every dense node through the `MAP_SHARED` mapping. Pristine-page hashes are nonzero, so every node really is written. Each first touch of a punched page has to allocate a block from inside a page fault. If the filesystem is full or the quota is used up, the fault cannot be served and the kernel sends SIGBUS. The process is killed and the C API returns no error. A plain zero-fill (`std::ranges::fill`) would write over blocks that are already allocated and would need no new space. The punch saves almost nothing, because the blocks are filled again right away. `clear_hash_tree` is a recovery path, so it is likely to run on a node that is already short on disk.

**Origin**: introduced by this branch. `mapped_memory::clear()`, `i_dense_hash_tree::clear` / `dense_hash_tree::do_clear` and the dense-tree part of `hash_tree::clear` are all new (`git diff origin/main...HEAD -- src/os-mapped-memory.cpp src/dense-hash-tree.hpp src/hash-tree.cpp`). On `origin/main`, `clear_hash_tree` never touched the dense trees. There is a related limitation that existed before the branch: stored RAM, flash and `.dht` files are sparse, so a `SHARING_ALL` machine loaded on a disk that is already full can SIGBUS on its first write to a hole. The branch makes this worse: a machine that was running fine on a full disk is turned into one that crashes as soon as someone else takes the freed space.

**Area**: OS memory mapping / hash tree (`src/os-mapped-memory.cpp` `clear()`, `hash_tree::clear`, `cm_clear_hash_tree`, runtime option `clear_hash_tree`).

**Category**: crash (SIGBUS, process kill with no error reported).

**Location**:
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear()`, the `fallocate(PUNCH_HOLE|KEEP_SIZE)` / `F_PUNCHHOLE` branch
- `src/dense-hash-tree.hpp:80-82`: `dense_hash_tree::do_clear()` calls `m_mapped_memory.clear()`
- `src/hash-tree.cpp:717-728`: `hash_tree::clear()` clears every dense tree and marks every page dirty
- `src/hash-tree.cpp:310-320`: `hash_tree::return_updated_dirty_pages`, where the fault fires (the `std::ranges::equal` / `copy` on the dense node in the punched `.dht` mapping)

**Evidence**: The test mounts a 96 MiB tmpfs. It stores a machine with 16 MiB of RAM there using `SHARING_ALL`, then runs a child process that does the following:
1. Loads the machine with `SHARING_ALL` and calls `get_root_hash`, which allocates every `.dht` block.
2. Fills the filesystem to ENOSPC.
3. Calls `get_root_hash` again. This still works.
4. Calls `clear_hash_tree()`. Free space goes from 0 to 376832 bytes, about the total size of the `.dht` files, which shows the punch really freed the blocks.
5. Fills the filesystem again, the way another process would.
6. Calls `get_root_hash`.

The child dies with SIGBUS. In the control run, which skips step 5, the child succeeds with the same root hash. A gdb backtrace places the fault in `std::__memcmp` under `cartesi::hash_tree::return_updated_dirty_pages(...)._omp_fn.0` at `hash-tree.cpp:317`.
```
$ eval $(make -s env); lua5.4 bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua
child: avail after clear:  376832 (blocks freed by PUNCH_HOLE)
child: get_root_hash after clear ok
control (no refill): true exit 0
...
child: avail after clear:  376832 (blocks freed by PUNCH_HOLE)
child: avail after refill: 0
Bus error
refill case: nil exit 135
BUG: get_root_hash after clear_hash_tree on a full filesystem killed the process with SIGBUS (...)
```
On tmpfs, a read fault on a hole also needs a page, so the fault comes at the `memcmp` read. On ext4 or xfs, a read of a hole maps the zero page and the SIGBUS comes at the first write, when `page_mkwrite` fails. The result is the same crash.

**Scenario**: A PRT/Dave validator or a Rollups Node keeps its machine stored with `SHARING_ALL` on a volume that is nearly full. It suspects a damaged hash tree and calls `cm_clear_hash_tree`, or reloads with runtime `clear_hash_tree=true`. While that runs, logs, snapshots or another machine use up the blocks the punch just freed. On the next `cm_get_root_hash` or `cm_get_proof`, the node is killed by SIGBUS in the middle of a dispute or epoch, and it gets no error it could handle. A CLI user running `cartesi-machine` on a shared stored machine on a full disk sees "Bus error" with no explanation.

**Possible solution**: Drop the punch for dense hash trees and zero the shared mapping in place (`std::ranges::fill(data, 0)`), so blocks that are already allocated are reused. If space reclamation is wanted, make the punch opt-in and call `fallocate(0, ...)` (plain allocate, without `PUNCH_HOLE`) right after it to reserve the blocks again. That turns ENOSPC into an `errno` that can be reported as an error from `clear()`. The function is currently `noexcept`/`void`, so it would need to be made able to fail. This touches the same code as B04/`api-07` (the dense tree is cleared before its pages are marked dirty). A fill through the shared mapping has the same ordering problem as the punch, so this change should go together with the mark-dirty-first fix described there. In general, a shared mapping on a full disk can SIGBUS on any hole. A broader fix would preallocate (`posix_fallocate`) shared backing files at load time, or handle SIGBUS, but that is outside the scope of this branch's regression.

**Severity**: low. Triggering it needs four things at once: `SHARING_ALL` storage, a full disk or used-up quota, a call to the rare `clear_hash_tree` recovery path, and another consumer taking the freed blocks before the next hash update. The result is a hard process kill with no wrong hash, wrong proof or corruption, and a restart after space is freed recovers. Both reviewers rated it low. The prover said low/medium, because it is a silent kill on a recovery path. The final rating is low: shared-mmap SIGBUS on a full disk already exists before the branch, and the branch only widens it slightly.

**Risks**: Bug: a validator or node can be killed without warning while computing a root hash or proof after a hash-tree reset, which can cost it time in a dispute. Disk pressure is common exactly when operators reach for recovery tools. Fix: replacing the punch with a fill means the cleared `.dht` files keep their full allocation. They are rewritten right away anyway, so space use does not change. A zero-fill of a large dense tree costs more CPU and dirty page writeback than a punch, but the next update rewrites all of it regardless. Adding `fallocate` preallocation changes the API contract of `clear()` (it can now fail), and that error has to be passed through `hash_tree::clear` and `cm_clear_hash_tree`.

**Proof of concept**: `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua`. It needs root, because it mounts a 96 MiB tmpfs at `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/mnt` and unmounts it afterwards. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua
```
Exit 1 with `BUG: ... SIGBUS` means the bug reproduced. Exit 0 means fixed (no crash, or an error reported instead). Exit 77 means skipped (not root), and exit 2 means an unexpected result.

**ID**: `w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc`

**Related**: [B52](#b52-a-full-disk-kills-a-sharing_all-machine-with-sigbus-on-writes-to-sparse-pages), [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages).

### B83. Rollback frees the working server's port before rebinding, so a bind in the gap makes revert fail

**Title**: Rollback frees the working server's ephemeral port before rebinding the backup to it, so anything that binds that port in the gap makes `revert` fail with EADDRINUSE

**Problem**: The only rollback method runs `get_server_address()`, `shutdown_server()`, `swap(backup)`, then `rebind_server(address)`. Both the CLI's `revert_fork` and the PRT recipe's `machine_pair:revert` use it. `shutdown_server` closes the working server's acceptor on port A right away, as its own comment says, "so the port can be immediately reused". A came from `bind(127.0.0.1:0)`: either `spawn_server("127.0.0.1:0")` or a fork child, which always binds `(addr, 0)`. So A is an ephemeral port, and nothing reserves it once it is freed. `rebind_server(A)` then builds a fresh `tcp::acceptor` on A. If any other socket is actively bound to A or listening on it by then, the bind fails with `bind: Address already in use` and `revert()` raises. Possible sources of that socket:
- an explicit bind;
- another JSON-RPC server binding `:0`, for example another validator node on the same host;
- an outgoing connection that auto-binds A.

The API has no way to pass a listening socket from one server to another, and no way to have the fork reserve A in advance. Asio's `SO_REUSEADDR` covers only a port in TIME_WAIT. State is not corrupted: the acceptor constructor throws before `handler->rebind`, so the backup keeps serving at its fork address with the correct restored root hash. What is lost is the stable address that callers use and the snapshot (`backup_machine` is already nil).

**Origin**: pre-existing. `revert_fork` on origin/main does the same `rebind_server(address)`.

**Area**: remote-machine lifecycle (`shutdown_server` → `swap` → `rebind_server`), JSON-RPC server acceptor handling.

**Category**: api-contract (time-of-check/time-of-use race on a released port).

**Location**:
- `src/jsonrpc-remote-machine.cpp:755-769`: `jsonrpc_shutdown_handler` calls `close_acceptor()`, which frees A.
- `src/jsonrpc-remote-machine.cpp:837`: `jsonrpc_fork_handler` binds the child acceptor to `(addr, 0)`, so the port is ephemeral.
- `src/jsonrpc-remote-machine.cpp:894-907`: `jsonrpc_rebind_handler` constructs a new `tcp::acceptor{ioc, A}`, which throws on EADDRINUSE.
- `src/jsonrpc-machine.cpp:749-754`: `jsonrpc_machine::rebind_server` passes the error back to the client.
- Callers: `src/cartesi-machine.lua:3703-3711` (`revert_fork.__index:revert`) and `doc/recipes/prt.lua:1067-1075` (`machine_pair_methods:revert`).

**Evidence**: The test runs the exact revert sequence. After `shutdown_server()` it starts a second JSON-RPC server on the freed address, standing in for another validator node or any process on the host. `rebind_server(A)` then fails, the machine stays on its fork address, and the root hash is restored correctly:
```
$ eval $(make -s env); timeout 60 lua5.4 bugs/p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race/test.lua
working server address:	127.0.0.1:38079
squatter bound to:	127.0.0.1:38079
rebind_server:	false	bind: Address already in use [system:98 at .../reactive_socket_service.hpp:161:5 ...]
machine address after revert:	127.0.0.1:39581	root hash restored:	true
BUG: rollback could not rebind the backup to the released ephemeral port 127.0.0.1:38079: bind: Address already in use [system:98 ...]
exit=1
```
The test forces the bad interleaving. It does not catch a natural race.

**Scenario**: A PRT validator, Rollups Node or Dave node rolls back a rejected input with `shutdown_server`/`swap`/`rebind_server`, or a CLI user's `revert_fork` does. In the few milliseconds between the shutdown reply and the rebind, another process on the host takes port A. That process could be another node spawning or forking a JSON-RPC server on `:0`, an outgoing connection auto-binding that port, or a co-located process deliberately squatting on ports it sees in use. `revert()` raises, the node aborts input processing, the snapshot is gone, and the machine is no longer at the address the node tracks.

**Possible solution**: Make the handover atomic instead of release-then-rebind. Options:
- Have the backup take over the working server's listening socket. For example, a `swap`/`takeover` RPC passes the fd over a Unix socket (`SCM_RIGHTS`), or the fork child inherits the parent's acceptor fd and keeps it dormant, so the port is never released.
- Do the rebind before the shutdown. That needs `SO_REUSEPORT`, or a server-side "replace me with the fork" operation that closes the old acceptor only after the new one is bound.
- In the recipes, at least make `revert` tolerate a failed rebind: keep using the fork address, which `swap` already points the client at, and report the new address instead of raising. Callers who need a stable address can use a fixed, non-ephemeral port.

**Severity**: low. Both reviewers agree. No wrong hashes, proofs or corrupted state result, and the failure is a clean exception with the backup still usable at its fork address. A natural collision needs a random bind to land on one specific ephemeral port inside a window of a few milliseconds, about 1 in 28k per bind in that window. Triggering it on purpose needs a co-located process, which could already disrupt the node in worse ways. The worst realistic outcome is one aborted rollback/input step, recoverable by restart or retry.

**Risks**:
- Of the bug: occasional, hard-to-reproduce rollback failures on busy hosts that run several nodes or servers. The node's view of the machine address diverges from the server's actual address, and the snapshot is lost.
- Of the fix: passing fds or inheriting the acceptor adds platform-specific code (Unix-only `SCM_RIGHTS`), and it adds fd lifetime and leak concerns across fork/shutdown. `SO_REUSEPORT` lets unrelated processes share the port and can steer connections to the wrong server. Making `revert` tolerate a failed rebind changes the recipe contract: callers must re-read `get_server_address()` after a revert.

**Proof of concept**: `bugs/p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race/test.lua`. Run from the repo root:
```
eval $(make -s env); timeout 60 lua5.4 bugs/p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race/test.lua
```
It exits with status 1 and prints `BUG: ...` while the bug is present, and prints `OK` once rollback can no longer lose the port. The test shuts down every server it spawns.

**ID**: `p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race`

**Related**: B58 (fixed).

### B84. The JSON-RPC client cannot use IPv6 server addresses

**Title**: The JSON-RPC client cannot use any IPv6 server address, and the "[::1]:N" form the server reports is rejected by both client and server

**Problem**: The remote-machine endpoint helpers disagree on the IPv6 address format, so the IPv6 support that `cartesi-jsonrpc-machine --help` advertises (`<ipv6-address>:<port>`) does not work end to end:
1. `endpoint_to_string` (`ss << tcp::endpoint`) writes IPv6 endpoints in brackets, for example `[::1]:41234`. The server returns this string from `fork_server`, `rebind_server` and `get_server_address`, and `spawn_server` hands it back.
2. The client's `parse_endpoint` splits the address at the **first** `:` (`find_first_of`). `[::1]:N` gives host `[` and calls `stoi(":1]:N")`. `::1:N` gives an empty host and calls `stoi(":1:N")`. Both throw. `parse_endpoint` runs on every request (`json_post`), so the client cannot talk to an IPv6 server in any address form.
3. Both copies of `address_to_endpoint` split at the last `:`, but they pass the host to `make_address` with its brackets still on, so it is rejected. As a result `spawn_server("[::1]:0")`, `rebind_server("[::1]:0")` and `cartesi-jsonrpc-machine --server-address=[::1]:0` all fail with `invalid endpoint address`. The last of these fails fatally at startup.

The unbracketed form `::1:0` gets through `address_to_endpoint`, so an IPv6 server can bind. It then fails at the first client request (`check_server_version` during spawn), because `parse_endpoint` cannot parse the address.

**Origin**: Pre-existing. `origin/main` has the same `parse_endpoint` (`find_first_of(':')`), the same `address_to_endpoint` and `endpoint_to_string`, and the same IPv6 help text.

**Area**: Remote-machine lifecycle (`spawn_server`, `connect_server`, `fork_server`, `rebind_server`, `get_server_address`, `--server-address`). This is the JSON-RPC client (`src/jsonrpc-machine.cpp`) and server (`src/jsonrpc-remote-machine.cpp`), reached through the C API (`cm_jsonrpc_*`), the Lua `cartesi.jsonrpc` module and the `cartesi-jsonrpc-machine` CLI.

**Category**: Correctness (a documented feature does not work, and the address formats are inconsistent).

**Location**:
- `src/jsonrpc-machine.cpp:131-147`: `parse_endpoint` splits at `find_first_of(':')`.
- `src/jsonrpc-machine.cpp:175`: every `json_post` calls `parse_endpoint`.
- `src/jsonrpc-machine.cpp:442-455`: `address_to_endpoint` (used by spawn) keeps the brackets.
- `src/jsonrpc-machine.cpp:457-461`: `endpoint_to_string` returns the bracketed form.
- `src/jsonrpc-remote-machine.cpp:801-813`: `address_to_endpoint` (used by rebind and `--server-address`) keeps the brackets.
- `src/jsonrpc-remote-machine.cpp:815-819`: `endpoint_to_string` returns the bracketed form for fork, rebind and the server address.
- `src/jsonrpc-remote-machine.cpp:2032`: `--help` documents `<ipv6-address>:<port>`.

**Evidence**: The test has five parts:
- `fmt.cpp`, compiled on the fly, prints what `ss << tcp::endpoint` produces for `::1`.
- `connect_server` is tried with both IPv6 forms.
- `spawn_server("[::1]:0")` is tried.
- An IPv4 server is spawned, then `rebind_server("[::1]:0")` is called on it.
- `cartesi-jsonrpc-machine --server-address=[::1]:0` is run.

Only address-parsing errors (`failed to parse endpoint`, `invalid endpoint address`) count as defects. Socket errors (EAFNOSUPPORT, connection refused) do not count, so a fixed build passes even on a host without IPv6. Run it with `eval $(make -s env); lua5.4 bugs/p1-07-rml-05-ipv6-endpoint-format-unparseable/test.lua`. It exits 1:
```
server/client endpoint_to_string(::1, 41234) = [::1]:41234
connect_server("[::1]:41234") -> false jsonrpc error: post error contacting [::1]:41234 (failed to parse endpoint from address "[::1]:41234": stoi)
connect_server("::1:41234") -> false jsonrpc error: post error contacting ::1:41234 (failed to parse endpoint from address "::1:41234": stoi)
spawn_server("[::1]:0") -> false invalid endpoint address "[::1]:0"
rebind_server("[::1]:0") -> false invalid endpoint address "[::1]:0"
cartesi-jsonrpc-machine --server-address=[::1]:0 -> ... fatal cartesi-jsonrpc-machine ... caught exception: invalid endpoint address "[::1]:0"
5 IPv6 endpoint parsing defects found
```
The sandbox has no IPv6 networking, so the full `spawn_server("::1:0")` path (bind succeeds, then the client fails to parse) could not be run end to end. Every step it depends on is covered above.

**Scenario**: An operator configures a PRT validator, a Rollups Node, Dave or an app's tooling to run remote machines on IPv6 loopback (`::1`) or another IPv6 address, for example on an IPv6-only host or in a container network. `spawn_server("[::1]:0")` fails immediately. `spawn_server("::1:0")` binds the server, then fails when the client contacts it. A server started by hand with `--server-address=::1:N` cannot be reached by `connect_server`, and `--server-address=[::1]:N` exits at startup. Because of this, the node cannot create, fork (snapshot) or roll back (rebind) machines. Every failure is loud and happens at setup. Nothing goes wrong silently during a dispute.

**Possible solution**: Use one shared parser in both files. It should accept `[v6]:port`, strip the brackets before `make_address`, split at the last `:` for the unbracketed form, and reject a bare IPv6 address with no port. A simpler alternative is to call `address_to_endpoint` (fixed) from the client instead of `parse_endpoint`. Keep `endpoint_to_string` producing the bracketed form, which is the standard one, and make sure every parser round-trips it. Add a unit test that parses `endpoint_to_string` output for IPv4 and IPv6 endpoints. Optionally, either stop documenting the unbracketed `<ipv6-address>:<port>` form or keep accepting it for compatibility.

**Severity**: Low. Both reviewers rated it low. It only affects deployments that choose IPv6, while the default (127.0.0.1) works. It fails deterministically and loudly at setup, with a clear parse error. Hashes, proofs and stored state are not affected, and a running dispute cannot be disrupted by it.

**Risks**:
- Of the bug: IPv6-only environments cannot use remote machines at all, and the documented IPv6 option misleads operators. Because the failure is immediate, the risk is limited to deployment friction.
- Of the fix: low. Parsing changes could alter how malformed IPv4 strings are accepted or rejected. For example, `find_first_of` currently rejects `1.2.3.4:5:6`, while splitting at the last `:` would read `1.2.3.4:5` as the host and still reject it in `make_address`. The fix should be covered by tests for IPv4, bracketed IPv6, unbracketed IPv6, missing port and out-of-range port. Both copies of the helper (client and server) must change together.

**Proof of concept**: `bugs/p1-07-rml-05-ipv6-endpoint-format-unparseable/test.lua` and `bugs/p1-07-rml-05-ipv6-endpoint-format-unparseable/fmt.cpp`. `test.lua` compiles `fmt.cpp` into a temporary file with `g++`, using the Boost headers from the system or `third-party/`. `CXX` and `BOOST_INC` can override the compiler and the include dir. If the compile fails, the test falls back to the known `[::1]:41234` format. Run from the repo root:
`eval $(make -s env); lua5.4 bugs/p1-07-rml-05-ipv6-endpoint-format-unparseable/test.lua` (exits 1 while the bug is present, 0 once fixed).

**ID**: `p1-07-rml-05-ipv6-endpoint-format-unparseable`

### B91. Read-only queries after sync_stored rewrite the shared page cache, so a host crash leaves a synced machine unloadable or with wrong proofs

**Title**: Read-only hash-tree queries after sync_stored rewrite the shared .phtc in place; after a host crash the machine is unloadable, or gives wrong word proofs while the root hash and verify_hash_tree() look correct

**Problem.** On a machine loaded with `SHARING_ALL`, `hash_tree.phtc` is mapped shared, so every change to the page hash-tree cache goes straight into the stored file. This includes the header, the entry metadata (the intrusive `offset_ptr` LRU links, `paddr_page`, the `borrowed` flag and `payload_index`) and the cached page payloads and trees. Queries a caller would treat as read-only still mutate this file:
- Each `get_root_hash`/`get_proof` runs `update_hash_tree`, which re-marks up to 256 write-TLB pages and the always-dirty pages as dirty. Their cache entries are then borrowed and returned again.
- Each `get_proof` borrows an entry. A hit splices it to the LRU front. A miss evicts the LRU tail, sets a new `paddr_page` and recomputes the payload in place.

None of these writes is ordered or journaled, and the file carries no clean/valid marker. A single `get_root_hash` after `sync_stored` already changes 25 .phtc pages, and a batch of proofs changes every page of the file.

If the host crashes while the kernel is writing those dirty pages back (in any order, any subset), the .phtc on disk is a mix of synced and later pages. On load there are two outcomes:
- (a) The structural checks throw ("duplicate page address" or "inconsistent LRU links"). Nothing discards or rebuilds what is only a cache, so the machine cannot be loaded.
- (b) The structure is valid, but some entries claim pages whose payload holds another page's tree. `get_page_proof` trusts a cache hit, so word proofs are wrong. `get_root_hash` and `verify_hash_tree()` use the dense tree and the page data, so they still report a correct state.

**Origin.** Pre-existing. On origin/main the .phtc was already persisted through a mapped LRU. This branch reworked the layout in `page-hash-tree-cache.hpp`/`hash-tree.cpp` but kept the behavior.

**Area.** Page hash-tree cache persistence (`hash_tree.phtc`) and proof generation.

**Category.** Durability / crash consistency (silent proof corruption).

**Location.**
- `src/page-hash-tree-cache.hpp:515-555`: `borrow_entry` does the LRU `splice`, `push_front`, `pop_back`, `set_paddr_page` and `set_borrowed` in the mapped file.
- `src/page-hash-tree-cache.hpp:566-572`: `return_entry` clears the borrowed flag in place.
- `src/page-hash-tree-cache.hpp:443-455` and `689-723`: the load-time checks (`check_metadata`, the duplicate-address map build) throw on inconsistency and otherwise trust every entry.
- `src/hash-tree.cpp:100-134`: `get_page_proof` uses a cache-hit payload without checking it against the dense tree or the page data.
- `src/machine.cpp:1549-1560`: `update_hash_tree` re-marks the TLB and always-dirty pages on every `get_root_hash`/`get_proof`.

**Evidence.** The test builds a 4 MiB RAM image with distinct content in every page and a cache of `phtc_size=256` (771 .phtc pages, 3 of them metadata), and stores it. A child process then:
1. clones the stored machine and loads it `SHARING_ALL`, calls `get_root_hash`, then `sync_stored`, and snapshots the directory as S (the durable state);
2. calls `get_root_hash` again and snapshots R, then calls `get_proof` on N pages, snapshots U and kills itself with SIGKILL.

The parent rebuilds .phtc files page by page from S and U, as a torn writeback would leave them, loads each one and compares 1024 word proofs with a fresh reference machine.

Run: `eval $(make -s env); timeout 600 lua5.4 bugs/u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr/phtc_torn.lua` (about 8 s, exits 1). Output excerpt:
```
pages changed by one get_root_hash after sync_stored: 25
pages changed by get_root_hash+get_proof after sync_stored: 771 (metadata 3)
all pages from S (synced image)        loads; root ok=true verify_hash_tree=true ... bad proofs=0/1024
first 1 metadata page(s) from U        LOAD FAILED: corrupted page hash-tree cache: duplicate page address
all metadata from U, payloads from S   loads; root ok=true verify_hash_tree=true proofs-call=true bad proofs=248/1024 first=776 proof.root_hash ok=true, target_hash==keccak(actual word): false, proof recomputes to root: false
=== scenario: ... get_proof on 300 pages ...
first 1 metadata page(s) from U        loads; root ok=true verify_hash_tree=true ... bad proofs=62/1024 ...
BUG: 4 torn .phtc mixtures (...) make the stored machine unloadable
BUG: torn .phtc loads with correct root hash and verify_hash_tree()==true but yields wrong word proofs
```
- With N=1024 queried pages, every mix that takes some metadata pages from U fails to load.
- With N=300, every metadata mix loads and gives 52 to 144 bad proofs.
- "Metadata from U, payloads from S" (an ascending writeback cut short) loads in both cases and gives 248 bad proofs.
- The bad proofs carry the correct `root_hash` field, but their `target_hash` is not the keccak of the word and they do not recompute to the root.

**Scenario.**
- A validator node (for example `doc/recipes/prt.lua`) keeps an epoch machine loaded `SHARING_ALL`, commits with `sync_stored`, and then keeps serving `get_root_hash` and outputs or dispute proofs from it.
- `recover_epoch_machine` assumes the directory "was synced at that boundary and is unchanged since" (`doc/recipes/prt.lua:2673`). Reopening it with `new_stored_machine` and calling `get_root_hash` rewrites the .phtc again.
- If the power fails or the kernel panics during the writeback, there are two outcomes:
  - (a) `cartesi.machine(dir)` throws, `get_stored_root_hash` returns nil, the assert fires and the node crash-loops with no recovery path.
  - (b) The directory loads with the recorded root hash, so recovery accepts it. The bad cache then spreads through `clone_stored`, and later word proofs, uarch step logs and `send_cmio` logs for the affected pages are wrong. These all go through `get_proof`/`get_page_proof` (`uarch-record-state-access.hpp:103`, `record-send-cmio-state-access.hpp`). The on-chain verifier rejects the honest player's moves and the player loses the dispute. `verify_hash_tree()` cannot detect it.
- Any Rollups Node, Dave or app integration that loads `SHARING_ALL`, syncs, then queries is exposed in the same way.

**Possible solution.** Use one or more of these:
- Keep a clean/valid flag in the .phtc header. Clear it (and flush it) before the first change after a sync or load, and set it again in `sync_stored`/`store`. On load, a cache that is not clean is discarded and rebuilt from the page data.
- When `check_metadata` or the duplicate check fails, reset the cache instead of throwing.
- Check a cache hit's payload root against the page hash in the dense tree before trusting it, and recompute on a mismatch.
- Map the .phtc privately (or in anonymous memory) and write it out only at `store`/`sync_stored`, so read-only queries never change the stored directory.

**Severity.** High. Both reviewers rate it high:
- After a power loss, a node that only queried its synced machine either cannot reopen it (a permanent crash loop) or reopens a directory that passes the root-hash and `verify_hash_tree` checks and then produces wrong proofs and step logs.
- Outcome (b) can make an honest player lose a dispute, which taken alone would be critical. It is not rated critical because it needs a host-level crash during the writeback window plus a particular partial writeback. A process crash (SIGKILL) alone does not trigger it, because the page cache survives.

**Risks.**
- Of the bug: permanent unavailability of a stored machine, or undetectable wrong proofs that cause disputes to be lost. The writeback window recurs every time the machine is queried after a sync, and the cm.h contract that changes before a sync are durable is broken in practice.
- Of the fix:
  - A clean flag adds a flush on the first change after each load or sync, which costs some latency.
  - Discarding the cache on load costs a cold-cache rebuild after a crash.
  - Checking cache hits against the dense tree adds hashing to `get_proof`.
  - Moving the cache to a private mapping changes the cost of `sync_stored`/`store` and the meaning of `SHARING_ALL` for the .phtc.
  - Any change to the header layout or load path must stay compatible with existing stored machines, or reject them cleanly.

**Proof of concept.** `bugs/u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr/phtc_torn.lua`. It is self-contained, re-invokes itself as the child process, and writes its scratch files to a `run/` directory next to itself, which it removes on exit. The host crash is simulated by splicing pages of the S and U snapshots, which is a fair model since writeback of a `MAP_SHARED` mapping has no ordering guarantee. Run it from the repo root:
`eval $(make -s env); timeout 600 lua5.4 bugs/u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr/phtc_torn.lua`. Exit code 1 and the `BUG:` lines mean the bug reproduces.

**ID**: `u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr`

**Related**: B01 (fixed), [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong), B32 (fixed), [B92](#b92-queries-after-sync_stored-rewrite-the-shared-dense-trees-with-no-write-ordering-so-a-host-crash-can-leave-a-wrong-root-hash).

### B92. Queries after sync_stored rewrite the shared dense trees with no write ordering, so a host crash can leave a wrong root hash

**Title**: A hash-tree query after sync_stored rewrites the shared .dht/.dpt with no write ordering, so a host crash can leave a synced SHARING_ALL directory with a wrong root hash

**Problem**: With `SHARING_ALL`, the dense hash trees (`.dht`), dirty-page trees (`.dpt`), sparse tree (`hash_tree.sht`) and page cache (`hash_tree.phtc`) are `MAP_SHARED` mappings of the stored files. `machine::sync_stored` only fsyncs those files. It does not bring the hash tree up to date first, and since it is static it ignores the machine instance. The next `get_root_hash`/`get_proof` (any caller of `update_hash_tree`) then does three things to the just-synced directory:
- it re-marks write-TLB pages dirty;
- it writes new page and inner-node hashes into the `.dht` mapping;
- it clears the dirty marks in the `.dpt` mapping, which is a separate file.

Nothing orders or msyncs these writes; the only `msync` in the tree is an `MS_ASYNC`. A clean bit in the `.dpt` vouches that the `.dht` hash is current, and load trusts it. If the kernel writes back the new `.dpt` before the new `.dht` and the host then crashes, the directory reloads with stale hashes. The root hash is wrong (neither the committed root nor any real state) and `verify_hash_tree()` is false. A query that looks read-only quietly undoes the durability that `sync_stored` just provided, even though the guest state has not changed since the sync.

**Origin**: pre-existing (not introduced by this branch).

**Area**: hash tree persistence / `sync_stored` durability (SHARING_ALL stored machines).

**Category**: durability.

**Location**:
- `src/machine.cpp:622-631`: `machine::sync_stored` only fsyncs files and directories; no `update_hash_tree()` first, and the instance is ignored.
- `src/machine.cpp:1549-1560`: `update_hash_tree` (`mark_write_tlb_dirty_pages`, then `m_ht.update`) and `get_root_hash`.
- `src/hash-tree.cpp:730-742`: `hash_tree::update` calls `get_dirty_page_tree().clean()` on changed ranges after the dense-tree writes.
- `src/hash-tree.cpp:340-353`: `mark_clean_page_and_up` on pages whose hash did not change.
- `src/hash-tree.cpp:841-843`: page hashes copied into the shared `.dht` (`node_hash_view`).
- `src/os-mapped-memory.cpp:573`: the only `msync`, `MS_ASYNC`, with no ordering between files.

**Evidence**: The test cannot cut power, so it simulates the crash at file granularity. It runs a tiny RV64 program that writes 1500 pages, more than the TLB holds, so evicted pages get marked dirty in the RAM `.dpt` during the run. It runs to halt and calls `sync_stored`, then copies the directory as S (what is durable). It calls `get_root_hash` (R) and copies the directory as U (the dirty page cache). Then it reloads every per-file mix of S and U. Kernel writeback has no ordering across inodes, so each mix is a possible on-disk state after a host crash.

Result: `get_root_hash` rewrote 5 files. Every mix that takes the RAM `.dpt` from U and the RAM `.dht` from S (8 of 32) reloads with the wrong root and fails `verify_hash_tree`. The other 24 mixes reload with R. A real crash can also tear pages within a file, which allows more bad states, not fewer.
```
R (root hash of the committed state) = e38fc881fa67ff19f4f7cad06e79c6eb2bb3f39f7f5942189d9e1f2b4887d876
files rewritten by get_root_hash after sync_stored: 0000000000000000-8000.dht 0000000080000000-800000.dht 0000000080000000-800000.dpt hash_tree.phtc hash_tree.sht
BAD from U={0000000080000000-800000.dpt}: aabe5ce6e0687871af0b397bde082914154bcfb56ea0fc519e05a60672859113 verify_hash_tree=false
...
BUG: 8 of 32 possible post-crash file mixes of a synced SHARING_ALL directory reload with a wrong root hash; ...
(stderr) page 0x80100000 (in RAM) is not marked dirty but is dirty / cached page root hash mismatch
exit=1
```
In the control `hashfirst.lua`, `get_root_hash` runs before `sync_stored`. The post-sync `get_root_hash` then changes only `hash_tree.phtc`, every mix reloads with R, and the script exits 0. Run: `eval $(make -s env); lua5.4 bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/test.lua 2>/dev/null`. The bug does not show when every written page is still in the TLB at sync time, because TLB pages are re-marked dirty on load.

**Scenario**: A PRT validator, Rollups Node or Dave node keeps its epoch machine loaded with `SHARING_ALL` and commits each input by calling `sync_stored` and then querying the hash. In `doc/recipes/prt.lua`, `stored_machine_pair:commit()` only calls `sync_stored`, and later `commit_epoch_state` calls `pair.machine:get_root_hash()` and records that root in `state.json`. `recover_epoch_machine` assumes the machine "was synced at that boundary and is unchanged since". Suppose the host loses power or panics within the dirty-writeback window (about 30 s), after the `.dpt` pages reached disk but before the `.dht` pages did. On restart, the epoch directory loads with a root that matches neither R nor `machine.revert`. Recovery then asserts "the epoch machine does not match its state", and the node crash-loops until an operator rebuilds the epoch from an earlier snapshot or the template, which can cost an honest player its dispute deadlines. The CLI's `--revert-mode=stored` commit and any app that runs sync-then-hash on the C API (`cm_sync_stored` followed by `cm_get_root_hash`) follow the same pattern. Killing only the process is safe, because the page cache stays coherent.

**Possible solution**:
1. Make sync instance-aware: `machine::sync_stored` / `cm_sync_stored(m, dir)` with a non-null machine calls `update_hash_tree()` before fsyncing. A query right after a sync then has nothing left to persist, as the control shows.
2. More generally, order the writes in `hash_tree::update`: `msync(MS_SYNC)`/`fdatasync` the `.dht` (and `.sht`) before clearing `.dpt` bits in shared mappings. Alternatively, do not trust `.dpt` clean bits on load unless a durable "consistent" marker written after the hashes says so.
3. Until then, document the hazard and have callers (prt.lua `commit`, the CLI) call `get_root_hash` before `sync_stored`.

**Severity**: medium. The three reviewers said high, medium and low. The bug is real: stored state becomes corrupt on the standard validator commit path, and recovery fails without an operator. But it needs a host-level crash inside a short writeback window, and only after runs that evict written pages from the TLB. The damage is also detected (`verify_hash_tree` fails and the reload root mismatches the recorded root), not silent. The `.bin` data stays intact, so a rehash or replay can recover it, and no wrong hash or proof can be accepted on-chain.

**Risks**:
- Bug: a node cannot reopen its committed epoch after a power loss or kernel panic and needs manual recovery, which risks missed dispute deadlines. A tool that skips the `verify_hash_tree`/root checks would read a wrong root hash from the directory.
- Fix: updating the hash tree inside `sync_stored` makes sync slower (one hash update per commit, which callers usually do anyway). It also changes the static API's semantics, so the C API needs to pass the machine through. Adding `MS_SYNC`/fsync ordering inside `hash_tree::update` would add I/O latency to every `get_root_hash`/`get_proof` on SHARING_ALL machines, so it should be limited to the shared, file-backed case. Distrusting `.dpt` on load would force a full rehash on every load, which is costly for large machines.

**Proof of concept**:
- `bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/test.lua`: the reproducer. It exits 1 and prints `BUG: 8 of 32 ...` while the bug is present.
- `bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/hashfirst.lua`: the control (hash before sync). It exits 0.

Run from the repo root:
```
eval $(make -s env)
lua5.4 bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/test.lua 2>/dev/null
lua5.4 bugs/u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c/hashfirst.lua 2>/dev/null
```
The scripts work in `$TMPDIR/cm-bug-u1-02-{test,hashfirst}` (default `/tmp`), or in the directory given as the first argument. They need about 300 MB free.

**ID**: `u1-02-post-sync-hash-tree-writes-dpt-clean-before-dht-host-c`

**Related**: [B91](#b91-read-only-queries-after-sync_stored-rewrite-the-shared-page-cache-so-a-host-crash-leaves-a-synced-machine-unloadable-or-with-wrong-proofs), [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

## Candidates that were not confirmed

These candidates were proposed and investigated but did not pass review. They are listed so that readers can see what
was ruled out, and why. Several were reproduced and rejected only because reviewers judged the behavior intended; a split
vote means at least one reviewer would have confirmed it.

| Candidate | Outcome | Reason |
|---|---|---|
| `const` C API hash calls (`cm_get_proof`, `cm_get_root_hash`, `cm_get_node_hash`) update the page cache without locking | rejected 2 to 1 | Reproduced: concurrent calls on one machine object crash or return wrong proofs. Rejected as misuse, since one machine object is not meant to be shared across threads. |
| `clone_file` hard-links read-only files, so clones alias the source inode | rejected 2 to 0 | Reproduced, but hard-linking read-only sources is the documented contract of `clone_file`. |
| `frontier_forest_expand_leaf` raises on a leaf that is already expanded | rejected 2 to 1 | Reproduced, but the documented precondition covers only opaque leaves. |
| `frontier_forest_load` reads every stored mixed tree at load time | rejected 2 to 1 | Reproduced (all tree files are read before any query), but hashes are correct and reviewers judged it the documented design, a performance matter only. |
| Page cache copies new words into a shared entry before hashing them | not reproduced | A real kill leaves the entry marked borrowed, so the reload fails loudly (B03) rather than trusting a torn entry. |
| CLI `--print-uarch-cycle-root-hashes` passes a fake revert tail in cmio mode | not reproduced | The CLI refuses that option combination before running. |
| `set_runtime_config` accepts `clear_hash_tree=true` and does nothing | rejected 2 to 1 | Reproduced, but the field is documented as applying at create or load only. |
| `cartesi.util.read_file` and `write_file` were removed | rejected 2 to 0 | A deliberate, changelogged change with a one-line migration to `cartesi.filesystem`. |
| `clear_hash_tree` commits about 50 MiB per machine | rejected 2 to 0 | One-time and bounded by the page-cache size; not a leak. |
| Shut-down JSON-RPC servers become zombies when the node runs as PID 1 or a subreaper | rejected 2 to 0 | Reproduced. Rejected because the double fork is deliberate daemonization that relies on PID 1 reaping orphans; a container without an init breaks that for any program, and `--init` or `tini` fixes it. |
| A JSON-RPC machine object identifies its server only by address, so after a crash its requests and cleanup reach whatever later binds that port | rejected 2 to 0 | Reproduced. Rejected because addressing by host and port is the contract `rebind_server` relies on, and the PRT rollback cannot reach the scenario (its `shutdown_server` fails first if the server crashed). |
| Spawned and forked servers outlive a crashed client | rejected 2 to 0 | Reproduced. Rejected as the documented design: servers are independent processes, the client gets their pids, and supervisors that kill the process group clean them up. |
| `clone_stored` hard-links every file of a read-only template, so the clone cannot be loaded with `SHARING_ALL` | rejected 2 to 0 | Reproduced. Rejected as the documented and tested contract (read-only files are hard-linked); the load fails with a clear message. |
| `remove_stored` and `rename_stored` take no locks and act on a directory a live `SHARING_ALL` machine is using | rejected 2 to 0 | Reproduced. Rejected because `cm.h` requires that the stored machine is not in use. |
| `receive_cmio_request` throws on a guest-chosen data length above 2 MiB | rejected 2 to 0 | Reproduced. Rejected as the documented contract of the API; input delivery and proofs are unaffected. |
| `log_send_cmio_response` accepts a revert root hash that `send_cmio_response` would reject | rejected 2 to 0 | Reproduced. Rejected because `cm.h` documents that the logged call does not check it, so that an honest party can always prove the transition; verifiers reject a log made with a different revert hash. |
| A user schema dictionary overrides machine type names nested inside machine types | rejected 2 to 0 | Reproduced. Rejected as the documented lookup order (user dictionary first). |
| Base64 and Hex schema fields accept non-string values | rejected 2 to 0 | Reproduced. Rejected because the schema only describes conversions and was never meant to validate. |
| `fs.exists` reports dangling symlinks as absent and raises on `ENOTDIR` | rejected 2 to 1 | Following symlinks is the usual meaning of "exists"; raising on other errors was judged acceptable. |
| The default console sends unbounded guest output to the validator's stdout, which can block `run` or fill the disk | rejected 2 to 0 | Reproduced. Rejected as an operational default rather than a defect: no hash or proof is affected, and validators can set `output_destination=to_null`. |
| The built-in uarch reset image depends on the toolchain used to build the emulator, and nothing checks it | rejected 2 to 0 | Reproduced with a modified image. Rejected as a build-reproducibility concern: official builds pin the toolchain, a different image is in effect a different machine specification, and the node already checks loaded root hashes against the on-chain template. |
| JSON-RPC `spawn_server` and connections check only the protocol version, so a server from a different build (another uarch image) is accepted | rejected 2 to 0 (two panels) | Reproduced with a relinked server. Rejected as a deployment-hardening request: the handshake promises protocol compatibility only, and callers can compare `get_uarch_pristine_hash`. Mixing builds needs a misconfigured install. |
| `cm_receive_cmio_request` zeroes the returned length when the buffer is too small | rejected 2 to 0 | Reproduced. Rejected because `cm.h` documents the two-step pattern (query with NULL first) and the in-tree callers follow it. |

`verify_hash_tree` not checking inner nodes was first rejected 2 to 1 (`ht-05`), then confirmed by another panel, and it
is listed as B30 with a reviewer note.

## Method and environment

Twenty-one review workflows ran in four rounds. Each hunter agent worked one area or angle and proposed candidates. A triage
agent merged duplicates. A prover agent wrote and ran a test for each candidate. Two independent reviewers, plus a
tie-breaker when they split, tried to refute each claim. A recorder agent wrote the entry. Issues found by more than one
group are listed once, with the other reproductions linked.

The second wave added differential testing of the hash tree and of dispute artifacts in normal operation. It compared
root hashes, node hashes, proofs, step logs, uarch and mcycle collections across store and load in every sharing mode,
`clear_hash_tree`, tiny page caches that force evictions, remote machines, and concurrency settings. It found no
divergence outside the crash, stale-cache and `replace_memory_range` scenarios listed above.

The third round focused on the emulator APIs that the Lua PRT node uses, cataloged in `PRT-APIS.md`, with one hunter
per API category (IDs starting with `p1`, `p2` and `p3`). One hunter replayed the node's whole emulator call sequence
for an epoch with several inputs: remote machines, snapshots with `fork_server`, chunked mcycle and uarch collection,
rollback of rejected inputs, storing and restarting. It compared every state hash, commitment and proof against a local
machine, a restarted machine and a straight reference run, and found no divergence. Mutation fuzzing of opponent-supplied
step, reset and cmio logs found no log that the static verifiers used by the node accept wrongly.

The third round looked only for bugs that could be high or critical (IDs starting with `c1` and `c2`). Three fuzzers
compared the native interpreter with the uarch, which runs the same `interpret.cpp`: integer, memory and CSR
instructions, floating point and the uint128 helpers, and MMU, TLB, interrupts, traps and devices. Dozens of generated
programs ran for tens of thousands of mcycles each, comparing native root hashes, uarch-to-halt-and-reset root hashes,
collected uarch leaves and verified step logs. They found no divergence with the built-in uarch image; the findings of
this round (B85, B90 and a second trigger for B39) all need a custom uarch RAM image in the template. An independent
rebuild of the commitment layout from the specification matched every `collect_*` result, and proofs checked against a
brute-force Merkle tree at range boundaries found nothing new.

The fourth round started from the node's assumptions about the emulator, cataloged in `PRT-ASSUMPTIONS.md` (57
assumptions in 8 groups), with one hunter per group (IDs starting with `u1`, `u2` and `u3`). Its main findings concern
crash recovery after a host crash (B91, B92), hash-tree performance under CPU contention (B87) and `clone_file` (B08,
B89).

The tests ran on Ubuntu 24.04 (x86-64, ext4) against a local build of this branch. The uarch was built with GCC 13
rather than the official GCC 14 toolchain, so uarch-dependent hashes differ from upstream golden values. No test
compares against golden values.
