# Emulator bugs found reviewing `feature/prt`

Review of the emulator C/C++/Lua sources that ship in the emulator package (libcartesi C API, JSON-RPC remote machine,
Lua libraries, and the `cartesi-machine` CLI) on branch `feature/prt` against `main`. It covers bugs the branch
introduces and bugs that already existed in the APIs it touches or that the PRT validator node uses. The PRT node itself
(`doc/recipes/prt*.lua`) was not reviewed.

Each issue was proposed by a bug-hunting agent, reproduced by a separate agent with a test case, and confirmed by
independent reviewers who tried to disprove it. Entries are added as soon as they are confirmed, so the list is
ordered by confirmation time, not by severity.

Severity scale:

- **critical**: can make an honest PRT player lose a dispute, or produce wrong or nondeterministic hashes or proofs.
- **high**: crashes, hangs, or corrupts stored state for a validator in realistic use.
- **medium**: wrong results or crashes in less common but legitimate use.
- **low**: minor.

Proofs of concept live under `bugs/<id>/`. Run them from the repo root after building (`make`) with the environment
from `eval $(make -s env)` and `CARTESI_IMAGES_PATH` pointing at a directory with `linux.bin` and `rootfs.ext2`.
A test exits non-zero and prints a `BUG:` line while the bug is present.

## Issues


<a id="ht-02-phtc-stale-entries-after-mixed-sharing-session"></a>

### Persisted page hash-tree cache keeps stale entries after a mixed-sharing session, so get_proof and uarch-cycle root hashes come out wrong while get_root_hash and verify_hash_tree pass

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

ID: `ht-02-phtc-stale-entries-after-mixed-sharing-session`

<a id="ht-03-persisted-sparse-marked-flag-stale-root"></a>

### A crash inside `update_sparse_tree` leaves transient `marked` flags and stale inner hashes in a shared `hash_tree.sht`; the loader accepts them and the root hash stays silently wrong (`verify_hash_tree` still returns true)

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

ID: `ht-03-persisted-sparse-marked-flag-stale-root`

<a id="ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover"></a>

### A process kill during a hash-tree update of a SHARING_ALL machine corrupts the stored directory: it becomes unloadable even with clear_hash_tree=true, or it loads with a silently wrong root hash

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

ID: `ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover`

Related: the sparse-tree counterpart of this crash-consistency problem is [`ht-03`](#ht-03-persisted-sparse-marked-flag-stale-root).

<a id="ht-04-clear-hash-tree-zeroes-before-marking-dirty"></a>

### hash_tree::clear punches a range's .dht before marking its .dpt dirty, so a process kill mid-clear leaves a stored machine whose reload silently reports wrong root hashes and zero proofs

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

ID: `ht-04-clear-hash-tree-zeroes-before-marking-dirty`
