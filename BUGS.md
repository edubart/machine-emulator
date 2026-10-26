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

3 confirmed issues: 1 high, 2 low.

These are the issues still open. The other 89 issues were fixed on the branch `claude/emulator-0.23-bug-fixes`, one
commit per fix (B85 and B90 share one), and their entries were removed from this file as they were fixed. Each
commit message names the bug it fixes, and a few later commits complete earlier fixes ("Follow-up to ..."). The three
issues below were left open because no small, safe fix exists; each entry has a **Fix status** note with the reason and
what a proper fix needs.

| # | Severity | Origin | Area | Issue | Proof of concept |
|---|---|---|---|---|---|
| [B91](#b91-read-only-queries-after-sync_stored-rewrite-the-shared-page-cache-so-a-host-crash-leaves-a-synced-machine-unloadable-or-with-wrong-proofs) | high | pre-existing | Hash tree (page cache), stored machines | Read-only queries after sync_stored rewrite the shared page cache, so a host crash leaves a synced machine unloadable or with wrong proofs | `bugs/u1-03-post-sync-phtc-writes-torn-lru-or-wrong-proofs-host-cr/` |
| [B52](#b52-a-full-disk-kills-a-sharing_all-machine-with-sigbus-on-writes-to-sparse-pages) | low | pre-existing | Memory mapping (os-mapped-memory), stored machines | A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages | `bugs/w2b-04-sharing-all-enospc-sigbus/` |
| [B83](#b83-rollback-frees-the-working-servers-port-before-rebinding-so-a-bind-in-the-gap-makes-revert-fail) | low | pre-existing | JSON-RPC remote machine (rollback, rebind_server) | Rollback frees the working server's port before rebinding, so a bind in the gap makes revert fail | `bugs/p1-05-rml-03-rollback-rebind-to-released-ephemeral-port-race/` |

## Issues

### B52. A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages

**Fix status**: not fixed. Turning the SIGBUS into an error needs disk space reserved in advance (`posix_fallocate`). Doing that always would give up sparse RAM and flash images, which can cost GiBs per machine and per snapshot. Doing it only on request needs a new runtime option in the C API, JSON-RPC and Lua. Recovering from SIGBUS inside the library is fragile, and a logging handler in the JSON-RPC server would only add a diagnostic. This needs a maintainer decision. B64's fix keeps `clear_hash_tree` from punching new holes, so the branch no longer makes this more likely.

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

**Related**: B64 (fixed).

### B83. Rollback frees the working server's port before rebinding, so a bind in the gap makes revert fail

**Fix status**: not fixed. Every safe fix needs a design change. Keeping the parent's listening socket open in the forked child holds the port for the child's whole life and breaks fixed-port setups. Rebinding before shutdown with `SO_REUSEPORT` load-balances between two live servers. Passing the socket over a Unix socket needs a new RPC. Tolerating a failed rebind in callers changes their contract and does not remove the race.

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

### B91. Read-only queries after sync_stored rewrite the shared page cache, so a host crash leaves a synced machine unloadable or with wrong proofs

**Fix status**: not fixed. The fixes for B01 (cache entries are checked against the dense tree on load), B03 (borrowed entries make the cache rebuild) and B92 (`sync_stored` brings the hash tree up to date first) narrow this issue, but a torn write-back of the shared cache after a sync can still make the snapshot unloadable or, if one entry is torn internally, give wrong proofs while `get_root_hash` and `verify_hash_tree` look right. A complete fix needs a durable "clean" marker: mark the cache uninitialized and flush that page synchronously before the first change after a load or sync, and set it back after a full flush on sync or close. `os::mapped_memory` has no synchronous flush today. The other option is to verify every cached entry against memory on load, one page hash per entry.

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

**Related**: B01 (fixed), B03 (fixed), B32 (fixed), B92 (fixed).

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
