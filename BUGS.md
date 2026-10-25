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
