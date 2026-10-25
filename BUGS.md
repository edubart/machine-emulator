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

9 confirmed issues: 2 high, 5 medium, 2 low.

| # | Severity | Origin | Area | Issue | Proof of concept |
|---|---|---|---|---|---|
| [B01](#b01-stale-page-hash-tree-cache-after-a-mixed-sharing-session-yields-wrong-proofs) | high | pre-existing | Hash tree (page cache, store/load) | Stale page hash-tree cache after a mixed-sharing session yields wrong proofs | `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/` |
| [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong) | high | introduced by branch | Hash tree (page cache, dense trees, crash consistency) | Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong | `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/` |
| [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree) | medium | pre-existing | Hash tree (sparse tree, crash consistency) | Crash in sparse-tree update freezes the root hash of a shared hash tree | `bugs/ht-03-persisted-sparse-marked-flag-stale-root/` |
| [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages) | medium | introduced by branch | Hash tree (clear_hash_tree) | Crash during clear_hash_tree leaves zeroed hashes on clean pages | `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/` |
| [B06](#b06-frontier_forest_store-commits-truncated-tree-files-on-write-errors) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | frontier_forest_store commits truncated tree files on write errors | `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/` |
| [B07](#b07-interrupted-remove_stored-leaves-a-directory-that-blocks-the-name-forever) | medium | pre-existing | Stored machine API | Interrupted remove_stored leaves a directory that blocks the name forever | `bugs/ht-09-remove-stored-not-idempotent/` |
| [B09](#b09-json-rpc-server-exits-when-an-error-message-contains-invalid-utf-8) | medium | pre-existing | JSON-RPC remote machine server | JSON-RPC server exits when an error message contains invalid UTF-8 | `bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/` |
| [B05](#b05-cartesifilesystemwrite_file-ignores-close-errors-cli-writes-empty-hash-files) | low | pre-existing | Lua cartesi.filesystem, CLI | cartesi.filesystem.write_file ignores close errors, CLI writes empty hash files | `bugs/ht-08-filesystem-write-file-swallows-close-errors/` |
| [B08](#b08-clone_stored-fails-with-emlink-instead-of-falling-back-to-a-copy) | low | pre-existing | Stored machine API, cartesi.filesystem | clone_stored fails with EMLINK instead of falling back to a copy | `bugs/ht-10-clone-stored-emlink-no-fallback/` |

## Issues

### B01. Stale page hash-tree cache after a mixed-sharing session yields wrong proofs

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

**Related**: [B06](#b06-frontier_forest_store-commits-truncated-tree-files-on-write-errors).

### B06. frontier_forest_store commits truncated tree files on write errors

**Title**: hash-tree.lua `write_file` ignores `file:write` errors, so `frontier_forest_store` commits a truncated tree file that later stores never repair

**Problem:** The durable `write_file` helper in `cartesi.hash-tree` calls `temporary.file:write(contents)` and never checks the result. Lua's `file:write` does not raise on failure; it returns `nil, err`. When a large `fwrite` fails partway (ENOSPC, EFBIG, EDQUOT), glibc returns a short count and leaves nothing pending in the stdio buffer. The later `fs.sync_file` therefore succeeds (`fflush` returns 0 and `fsync` works). `temporary:rename` in `cartesi.filesystem` also ignores the result of `self.file:close()`, so the truncated temporary file is renamed into place. This breaks the helper's own guarantee that "the name never appears with incomplete contents". `store_tree` writes a tree file only `if not fs.exists(path)`, and files are named by the tree's hash, so no later store rewrites or checks the corrupt file, even in a fresh process with free space. The next `frontier_forest_store` then commits a new frontier file (the store's commit point) that references the unloadable tree.

**Origin:** Introduced by this branch. `src/cartesi/filesystem.lua` and the durable forest store in `src/cartesi/hash-tree.lua` do not exist on `main`.

**Area:** Lua library `cartesi.hash-tree` (frontier forest and frontier persistence) and `cartesi.filesystem`. The `cartesi-machine` CLI's `store_frontier` also goes through `write_file`.

**Category:** Durability / silent data corruption (an unchecked I/O error).

**Location:**
- `src/cartesi/hash-tree.lua:509-514`: `write_file`, where `temporary.file:write(contents)` is unchecked.
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
- In `filesystem.lua`'s `rename`, use `assert(self.file:close())` before renaming, so a deferred write error cannot be lost either.
- Optionally make `store_tree` stronger: check an existing file (parse it and compare its hash) before trusting it, or rewrite trees that the forest has not recorded as durable, so a corrupt file left by earlier code or by external damage is repaired instead of committed.

**Severity:** Medium. Both reviewers agree, and both note it is close to high. It needs a disk-full, quota or file-size-limit event during a store. When that happens, a validator's persisted state is silently corrupted, later stores never self-repair it, and recovery is manual, so a node can fail on restart or mid-dispute. It cannot produce a wrong hash or proof: a truncated file always fails JSON parsing, and `load_tree` checks the hash. The node fails loudly rather than asserting something false on-chain, which keeps it below critical or high.

**Risks:**
- *Of the bug:* Nodes that once hit a full disk carry corrupt snapshots that look committed. They then hit query failures at the worst time: after a restart or deep in a bisection. Dispute deadlines can be missed while operators diagnose a JSON parse error in a hash-named file.
- *Of the fix:* Checking the write and close results is low risk. Stores that used to "succeed" on a full disk will now raise, so callers must handle that error, for example by retrying after freeing space. The temporary file is still removed by its `<close>` handler. Validating or rewriting existing files in `store_tree` costs extra reads and hashing per store, and must keep the rule that the frontier file is written only after every tree it reaches is durable.

**Proof of concept:** `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 with `OK:` once it is fixed. It needs `bash` and `ulimit -f` (RLIMIT_FSIZE) and uses a `mktemp -d` work directory that it removes afterwards.

**ID**: `ht-07-hashtree-lua-write-file-ignores-write-error`

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
