# Angle `concurrency`: thread-safety, process lifecycle, resources and global state

Scope: OpenMP hashing (hash-tree.cpp, page-hash-tree-cache.hpp, dirty-page-tree.hpp), static/global/thread_local
state, fork/spawn/rebind in the JSON-RPC client/server, signal handling, file locks, mmap lifetime, fds.
PoCs are in `<SCRATCH>/work/concurrency/`. Each `run.sh` prints `BUG REPRODUCED` and exits 1 when the bug is present.

Summary:
| ID | Title | Status | Severity |
|----|-------|--------|----------|
| CONC-1 | JSON-RPC `fork` is allowed when the hash tree is shared, so parent and child share one page-hash-tree cache and LRU. Result: wrong word hashes/proofs, update failures, child abort | PROVEN | High |
| CONC-2 | A shared hash tree with private ranges pollutes the snapshot's `hash_tree.phtc`. Later loads (even `CM_SHARING_NONE`) return wrong word proofs, and the honest `log_send_cmio_response` fails | PROVEN (same root cause as HT-3, new trigger) | High (merge with HT-3) |
| CONC-3 | The JSON-RPC server routes SIGBUS through the Boost.Asio `signal_set`. A real SIGBUS (disk full, truncated backing file) makes it spin forever at 100% CPU: no reply, no crash, and SIGTERM is ignored | PROVEN | Medium |
| CONC-4 | Spawned servers inherit all of the client's sockets (Asio sockets lack CLOEXEC, and `posix_spawnp` has no file actions). Leaked listening sockets make concurrent fixed-port spawns fail with EADDRINUSE | PROVEN | Medium (limited) |
| CONC-5 | `const` C API queries (`cm_get_root_hash`/`cm_get_proof`/`cm_get_node_hash`) mutate shared state. Concurrent calls on one machine corrupt the heap (`unsynchronized_pool_resource`) and fail spuriously | PROVEN | Medium |
| R-1..R-6 | fork after OpenMP pool, OMP_NUM_THREADS determinism, two machines in parallel threads (TSan), fd/mmap/heap leaks, temp-string lifetimes, store/remove in use | REJECTED | — |

---

### CONC-1: JSON-RPC `fork` of a machine whose hash tree is shared makes parent and child share the page-hash-tree cache. Wrong word hashes/proofs, failed updates, crashes
- Status: PROVEN
- Area: JSON-RPC / hash-tree / process lifecycle
- Category: wrong proofs, data corruption across processes, DoS
- Where:
  - `src/jsonrpc-remote-machine.cpp:825` (`jsonrpc_fork_handler`) refuses to fork only when
    `machine->has_shared_address_range()`.
  - `src/machine.hpp:833` (`has_shared_address_range`) looks only at address ranges (`m_ars.all()`).
    The hash tree's own backing stores are not considered: `hash_tree.sht` and `hash_tree.phtc`, mapped
    `MAP_SHARED` when `hash_tree.shared=true` (`src/hash-tree.cpp:912-933`).
  - The page cache keeps its intrusive LRU list, the `borrowed` flags, the page copies and the page hash trees inside
    that mapping (`src/page-hash-tree-cache.hpp:418-493`). The page→entry index `m_map` is per-process heap memory. On a
    cache hit, `get_page_proof` (`hash-tree.cpp:101-124`) and `get_dense_node_hash` (`hash-tree.cpp:566-585`) use
    the entry as-is (`if (!hit) update_dirty_page(...)`).
- Problem: `hash_tree.shared` is independent of address-range sharing. It is a documented option
  (`--hash-tree=...,shared`, config `hash_tree.shared/sht_filename/phtc_filename`, or a store with that config
  loaded with `CM_SHARING_CONFIG`). For such a machine the fork check passes. After `fork()`, both processes:
  - map the same `.sht`/`.phtc` pages `MAP_SHARED`, and
  - inherit the same flock'ed open file description. The `LOCK_EX` that normally prevents a second user of these
    files is therefore held by both.

  Each process keeps its own `m_map` (page→entry) while the entries themselves are shared. When the child hashes its
  own pages, it evicts LRU entries and reuses them for its pages. The parent's `m_map` still maps its old pages to
  those entries, now overwritten with the child's page data and hashes. On the next hit the parent returns the
  child's hashes. Other effects:
  - The parent's `update()` follows the entry's (shared) `paddr` and fails with "update hash tree failed". It then
    `clear()`s the shared cache under the child.
  - `borrowed` flags collide ("page hash-tree cache entry already borrowed").
  - With concurrent activity the shared intrusive list is corrupted (boost::intrusive assertion abort; silent list
    corruption in `NDEBUG` builds).
- Scenario: A node or PRT bot drives machines through `cm_jsonrpc_*` and uses `cm_jsonrpc_fork_server` (or
  `cm_clone_empty`) to snapshot or branch a machine during a dispute. The machine was configured or loaded with a
  persistent (shared) hash tree to avoid rehashing big states. After the fork, either side can return word-level
  hashes/proofs of the other process's memory, while `cm_get_root_hash` stays correct:
  - `cm_get_proof`/`cm_get_node_hash` with `log2 < 12`.
  - The same `get_proof` path used by `log_step_uarch`, `log_send_cmio_response` and `log_reset_uarch`.

  The honest party's leaf proofs then fail on-chain or fail to be produced. Alternatively, hashing fails or the
  server aborts (DoS).
- Evidence: `<SCRATCH>/work/concurrency/fork-shared-ht/run.sh` (config: 4 MiB RAM, private;
  `hash_tree:{shared:true, create:true, phtc_size:64, sht_filename, phtc_filename}`). The parent writes and hashes
  pages 16..23, then forks. The child writes and hashes 54 other pages. The parent changes nothing and queries again.
  Local references with identical operations give the expected values:
  ```
  fork accepted although hash tree is shared (child pid 12886)
  child root hash                    d057e39c19cc...   expected child root hash   d057e39c19cc...
  expected parent root hash          0cba7fc09257...
  parent root hash                   0cba7fc09257...      <-- root hash is right
  page 0x80010000: parent word hash differs from expected
    parent node hash (log2 5)        679c41a698a4434ca7b470211316518fd6f76b51f0e683fb1d3eca718b05781b
    expected node hash (log2 5)      933a789538c02dc3f55190f3d470c2ed4dc75827953ddb967390e8097a7a11db
  page 0x80010000: parent word proof differs from expected proof
  ... (pages 0x80011000..0x80015000 likewise)
  BUG REPRODUCED: forked servers share hash-tree cache; parent returns wrong hashes/proofs
  ```
  With 58 child pages the effects are instead `parent cm_get_root_hash failed: update hash tree failed` and
  `child cm_get_root_hash failed: page hash-tree cache entry already borrowed`.
  `run_stress.sh` has parent and child hash concurrently. The child server aborts:
  ```
  cartesi-jsonrpc-machine: /usr/include/boost/intrusive/list.hpp:1310: ... iterator_to(reference) ...
  Assertion `!node_algorithms::inited(...)' failed.
  parent: 58 ok, 2 errors, last: update hash tree failed
  child : 1 ok, 2 errors, last: ... Connection refused
  ```
  The jsonrpc agent's report (jsonrpc-5) states that "fork refuses machines with shared address ranges, so a fork
  cannot corrupt the parent via shared mmapped backing files". That statement is incomplete because of this gap.
- Possible solution:
  - In `jsonrpc_fork_handler`, also refuse when the hash tree is shared. Add for example
    `bool machine::has_shared_backing_store() const { return has_shared_address_range() || m_c.hash_tree.shared; }`.
    Note that `m_c.hash_tree.shared` must reflect the effective sharing after `adjust_backing_stores`/dir-create.
  - Alternatively, in the forked child, remap the hash tree privately (copy the sht/phtc into anonymous memory, close
    the inherited fds) before serving requests.
  - Independently, make cache hits self-validating, as HT-3 also proposes. Compare the entry's root hash with the
    dense-tree page node, or memcmp the entry page with memory, and rehash on mismatch.
- Severity: High. The API returns wrong hashes/proofs for unchanged memory, the honest party cannot produce proofs,
  and a server can crash. The precondition is a non-default (but documented) shared hash tree combined with fork.
- Risks: Unfixed, any deployment that persists the hash tree and forks servers gets cross-process cache corruption.
  The proposed fixes do not change any root hash. Refusing fork for shared hash trees changes API behavior (it
  becomes an error) only for configurations that are currently broken.

---

### CONC-2: Hash tree shared + ranges private: one session pollutes the snapshot's `hash_tree.phtc`, and every later load returns wrong word proofs (cmio/uarch proofs cannot be produced)
- Status: PROVEN. Same root cause as HT-3 (cache hits trusted without validation), with a new trigger. HT-3 covers
  "range shared, hash tree private". This is the reverse configuration, and it also poisons loads made with
  `CM_SHARING_NONE`. Merge with HT-3 if preferred.
- Area: hash-tree / store-load
- Category: wrong proofs, honest prover cannot produce proofs
- Where: `src/hash-tree.cpp:101-124`, `:566-585` (hits trusted); `src/page-hash-tree-cache.hpp:477-490` (the
  persisted LRU/entries are reloaded and indexed as valid); `machine_config::adjust_ht_backing_store_config`
  (`src/machine-config.cpp:94-111`, the hash tree can be shared independently of ranges).
- Problem: A stored machine whose config has `hash_tree.shared=true` and private ranges (the default for RAM) is
  loaded with `CM_SHARING_CONFIG`:
  - Memory writes are private and discarded, but the page-cache entries created while hashing them go to the
    snapshot's `hash_tree.phtc` (MAP_SHARED).
  - On the next load, the snapshot's (private) dirty-page trees say those pages are clean, and the reloaded cache
    maps them to entries holding the discarded contents.
  - `get_root_hash` is right, but word-level hashes/proofs are of memory the machine does not have.
  - Because the polluted file is the snapshot's, loads with `CM_SHARING_NONE` (private mapping of the polluted file)
    are affected too.
- Scenario: An operator configures a persistent hash tree (`--hash-tree=...,shared`) for a template and runs
  sessions from it with `CM_SHARING_CONFIG` (RAM private, so the template is not modified). A later honest
  `cm_log_send_cmio_response` (or `log_step_uarch` touching such a page) on a fresh load of the template fails its
  own proof check. The honest party cannot produce the input-response or leaf proof.
- Evidence: `<SCRATCH>/work/concurrency/shared-ht-reload/run.sh` and `run_cmio.sh`:
  ```
  snapshot root hash           53d9d9ee...     reloaded root hash   53d9d9ee...   reloaded memory byte 0x11
  expected word hash           b569321de72d0af89c2fb48a484de3fc9343f31600ae1f3e13d633cb48cbf816
  reloaded word hash           c4bd59e1394781d1c7bf20a2c0b30c2acc9fbdd52dc5e0d76917de4034ebdf59
  hash of discarded 0x22 word  c4bd59e1394781d1c7bf20a2c0b30c2acc9fbdd52dc5e0d76917de4034ebdf59
  BUG REPRODUCED: reloaded machine returns a word hash/proof of memory contents it does not have
  ---
  fresh machine (reference):         verify_send_cmio_response -> accepted
  reloaded snapshot (clean):         verify_send_cmio_response -> accepted
  reloaded snapshot (CM_SHARING_CONFIG): log_send_cmio_response FAILED: Mismatch in root hash of 6th access
  reloaded snapshot (CM_SHARING_NONE): log_send_cmio_response FAILED: Mismatch in root hash of 6th access
  BUG REPRODUCED: honest party cannot produce a valid cmio-response proof from the reloaded snapshot
  ```
- Possible solution: Validate cache hits, as in HT-3: a 32-byte compare of the entry root with the dense page node,
  rehash on mismatch. Optionally reject or normalize configs that share the hash tree while any hash-tree-covered
  range is private, since the persisted tree can never be consistent with discarded memory.
- Severity: High. Wrong proofs, and the honest party cannot prove an input transition. It needs a non-default
  config.
- Risks: The fix changes no root hash and costs one compare per hit.

---

### CONC-3: JSON-RPC server handles SIGBUS through Boost.Asio `signal_set`. A synchronous SIGBUS (disk full / truncated backing file) turns into an infinite busy loop
- Status: PROVEN
- Area: JSON-RPC server / process lifecycle / signals
- Category: DoS (hang)
- Where: `src/jsonrpc-remote-machine.cpp:318-323` (`install_termination_signal_handlers`: `signals.add(SIGBUS)`),
  installed for the server's whole life at `:2145`.
- Problem: Asio's handler (`boost_asio_signal_handler`) only writes the signal number to a non-blocking pipe and
  returns. SIGBUS from a memory access (the guest or the server touching a mmapped backing file page that cannot be
  provided) is synchronous. Returning from the handler re-executes the faulting instruction, which faults again,
  forever:
  - The pipe fills, after which writes return EAGAIN.
  - The event loop never runs, so the "termination" handler never executes.
  - SIGTERM/SIGINT also only write to the same full pipe, so the process is unkillable except with SIGKILL.

  Without the handler the process would die and the client would see a connection error. With it, the server spins
  at 100% CPU forever. The client's default JSON-RPC timeout is -1, so the node blocks forever.
- Scenario: A node runs a big machine created or loaded with sharing (sparse `MAP_SHARED` backing files), and the
  disk fills up. The next guest store to an unallocated page (or the creation of the 24 MiB `hash_tree.phtc`) raises
  SIGBUS. Other triggers are a backing image truncated or replaced underneath, or a storage I/O error. The node hangs
  indefinitely, with no error and no exit, instead of failing fast and recovering.
- Evidence:
  - `<SCRATCH>/work/concurrency/sigbus-hang/run.sh` truncates the flash image under a running server:
    ```
    local machine: killed by SIGBUS (expected)
    server pid 20386 read flash ok: 11
    cm_read_memory -> -6 (jsonrpc error: post error contacting 127.0.0.1:45699 (jsonrpc error: timeout))
    server state R -> R, cpu ticks 83 -> 136 (+53 in 3s)
    BUG REPRODUCED: server neither died nor answered; it is spinning on a re-raised SIGBUS
    ```
    strace of the server shows the loop:
    `--- SIGBUS {si_code=BUS_ADRERR, si_addr=0x7f418050a000} --- / write(7, "\7\0\0\0", 4) = -1 EAGAIN / rt_sigreturn / --- SIGBUS ...`
  - `run_diskfull.sh` (root; private mount namespace with a 16 MiB tmpfs): `cm_create(m, {ram 64MiB}, NULL, dir)`
    on a full filesystem gives
    `cm_create -> -6 (... timeout)`, `server state R -> R, cpu ticks 161 -> 209`, `BUG REPRODUCED`. Without the
    explicit 10 s timeout the client blocks forever. The first attempt of this PoC without a timeout hung until it
    was killed.
- Possible solution: Do not put synchronous fault signals in the Asio `signal_set`. Remove `SIGBUS` from
  `install_termination_signal_handlers()`, so the default action terminates the process and the client gets
  ECONNRESET. If graceful handling is desired, install a real `sigaction` handler that does async-signal-safe
  cleanup and `_exit()`s, or `siglongjmp`s out of `machine.run` to return a JSON-RPC error.
- Severity: Medium. Infinite hang (DoS) of the node's machine server under realistic operational faults (disk
  full).
- Risks: Removing SIGBUS from the set only changes the behavior on real SIGBUS (crash instead of hang). A
  `kill -BUS` used for graceful shutdown in tests would also terminate the process immediately.

---

### CONC-4: Spawned JSON-RPC servers inherit every socket of the client (no CLOEXEC, no spawn file actions). Leaked listening sockets break concurrent fixed-port spawns and keep ports bound
- Status: PROVEN
- Area: JSON-RPC client (spawn) / fd management
- Category: resource leak, spurious failures (DoS-ish)
- Where: `src/jsonrpc-machine.cpp:466-486`:
  - The acceptor `a` and all `m_stream` sockets are created by Boost.Asio, which calls `::socket()` without
    `SOCK_CLOEXEC` (`boost/asio/detail/impl/socket_ops.ipp:1830`).
  - `posix_spawnp(&child_pid, bin, nullptr, nullptr, args, environ)` has no file actions.
  - The server never closes unknown inherited fds, and its fork child (`fork_server`, used by every spawn) inherits
    them again.
  - Commit 642703c fixed exactly this class for file locks (O_CLOEXEC in os-filesystem.cpp) but not for sockets.
- Problem: Every spawned server holds duplicates of:
  - (a) all client connections to other servers that were open at spawn time;
  - (b) any listening acceptor that another thread of the client created for its own concurrent spawn.

  For (b), a sibling server keeps the other spawn's port in LISTEN state until that sibling (and its forked
  grandchild) exits. A spawn on a fixed address then fails with `bind: Address already in use`. Either the client's
  acceptor or the grandchild's `rebind` to the requested address fails.

  For (a), `shutdown_and_close_socket` relies on `close()` with `SO_LINGER=0` to RST the connection. That does
  nothing while another process holds a dup, so peers never see the close. Server fds and ports also accumulate.
- Scenario: A multi-threaded node spawns machine servers concurrently (one per app/epoch/tournament) on configured
  ports. Spawns fail intermittently with EADDRINUSE, and long-lived servers hold unrelated sockets and ports.
- Evidence: `<SCRATCH>/work/concurrency/spawn-fd-leak/run.sh`:
  ```
  server 0 (pid 694) holds 3 sockets
  server 1 (pid 696) holds 4 sockets
  server 2 (pid 698) holds 5 sockets
  server 3 (pid 700) holds 6 sockets
  => server 3 inherited 3 client sockets connected to servers 0..2
  control (one thread alone): 0/25 spawns failed
  thread 0: 1/25 spawns failed, first error: bind: Address already in use [system:98 ...]
  thread 1: 25/25 spawns failed, first error: bind: Address already in use [system:98 ...]
  thread 2: 16/25 spawns failed, first error: bind: Address already in use [system:98 ...]
  BUG REPRODUCED: sibling servers inherited listening sockets; fixed-port spawns fail
  ```
  In an earlier run, the diagnostic showed the culprit: `port 60888 still LISTENing in pid 18953
  (cartesi-jsonrpc-machine) as fd 6`, a sibling server. The fixed-port part is a race (failure counts vary from run
  to run). The socket inheritance in the first part is deterministic.
- Possible solution:
  - In `cartesi-jsonrpc-machine` `main()`, right after parsing `--server-fd`, close every fd except 0/1/2 and the
    server fd (`close_range(3, ~0U, 0)` after moving the server fd to 3).
  - In the client, use `posix_spawn_file_actions_adddup2` to place the acceptor at a fixed fd plus
    `posix_spawn_file_actions_addclosefrom_np` (glibc ≥ 2.34), and/or open Asio sockets with `SOCK_CLOEXEC`.
- Severity: Medium (limited). Spurious spawn failures and leaked sockets/ports for multi-threaded clients. There is
  no state corruption.
- Risks: The fix is low-risk. The server must not close the inherited server fd or stdio.

---

### CONC-5: `const` C API queries are not thread-safe. Concurrent `cm_get_proof`/`cm_get_root_hash` on one machine corrupt the heap and fail spuriously
- Status: PROVEN
- Area: C API / hash-tree
- Category: memory-safety (heap corruption), spurious errors
- Where:
  - `src/cm.h:671,691,707`: `cm_get_root_hash`, `cm_get_node_hash`, `cm_get_proof` take `const cm_machine *`, and
    cm.h has no thread-safety statement.
  - `src/machine.cpp:1533-1537`: each of these runs `update_hash_tree()` on `mutable` state (`machine.hpp:74-75`,
    `mutable machine_address_ranges m_ars; mutable hash_tree m_ht;`).
  - That update marks always-dirty pages, borrows page-cache entries and rewrites the sparse tree.
  - The hash tree allocates its batches from `std::pmr::unsynchronized_pool_resource m_memory_pool`
    (`src/hash-tree.hpp:230`).
- Problem: Even on an idle machine, every "read-only" query rehashes the always-dirty shadow pages and mutates the
  page cache, the dirty-page trees and the pmr pool without synchronization. The C++ convention that const member
  functions are safe to call concurrently (and the C signatures taking `const cm_machine *`) does not hold. Two
  threads asking for proofs of the same machine:
  - race on the `borrowed` flags ("page hash-tree cache entry already borrowed"), and
  - corrupt the unsynchronized pool (heap corruption, `free(): invalid pointer`).
- Scenario: A node or PRT bot answers proof requests for several tournaments or clients from a thread pool, or a
  monitoring thread calls `cm_get_root_hash` while another thread computes proofs on the same machine. Because the
  calls are `const` and nothing in cm.h says otherwise, they are not serialized. The process crashes or proofs fail.
- Evidence: `<SCRATCH>/work/concurrency/const-race/run.sh` (2 threads × 400 × `cm_get_proof` + `cm_get_root_hash` on
  the same, otherwise untouched machine):
  ```
  thread 0: 400 ok, 0 wrong, 0 errors
  thread 1: 228 ok, 0 wrong, 173 errors (last: page hash-tree cache entry already borrowed
  BUG REPRODUCED: concurrent const queries on one machine fail / return wrong data
  ```
  One release run aborted with `free(): invalid pointer`. Under the ASan build (`run_asan.sh`,
  `asan_lsan_report.txt`), LeakSanitizer reports blocks lost from the pool. This is free-list corruption:
  `Direct leak of 98304 byte(s) ... std::pmr::memory_resource::allocate ... std::vector<hash_tree::dirty_page>::reserve ... hash_tree::update_dirty_pages hash-tree.cpp:373 ... cm_get_proof`.
- Possible solution: Either document clearly in cm.h that a machine object must not be used from more than one
  thread at a time (including `const` functions), or make the C++ `machine` serialize its internally mutating const
  paths with a per-machine `std::mutex` around `update_hash_tree()` and the following proof/node-hash read. A mutex
  costs nothing measurable compared with hashing. Also use `synchronized_pool_resource` or a per-call arena.
- Severity: Medium. Crash or DoS of the node from a natural but undocumented usage pattern. No silent wrong proof was
  observed.
- Risks: A mutex changes no results. Documenting the restriction alone leaves the trap in place.

---

### Rejected / verified-safe hypotheses
- R-1 fork() after libgomp created its thread pool (JSON-RPC fork): REJECTED.
  - `jsonrpc_fork_handler` calls `omp_pause_resource_all(omp_pause_hard)` before `fork()`. On this libgomp
    (GCC ≥ 10) that is `gomp_pause_host()`, which really tears down the calling thread's pool (checked in the
    disassembly), and the server is single-threaded.
  - `work/concurrency/omp-fork/t.c` hashes a 64 MiB machine with 2048 dirty pages per generation (parallel path)
    across 4 nested forks. Output: no hang, all root hashes equal to a local reference.
- R-2 Determinism vs thread count: REJECTED. Identical root hashes and proofs (md5 of all outputs equal) for
  `OMP_NUM_THREADS=1,2,4,16`, `concurrency.update_hash_tree=1,3,8` and `phtc_size=1,3,33` on a 64 MiB machine with
  random page writes (`work/concurrency/omp-determinism/`).
- R-3 Two different machines in parallel threads (`work/concurrency/threads/thr.c`): REJECTED.
  - Each of 4 machines runs a guest, with root hashes, proofs, `log_step` + `verify_step`, `collect_mcycle_root_hashes`,
    uarch run, `log_step_uarch` and `reset_uarch`. Sequential and concurrent results are identical.
  - Under a private TSan build of libcartesi (`work/concurrency/tsan/`) with `update_hash_tree=1` there were 0
    reports.
  - With OpenMP enabled, TSan reports only libgomp-internal false positives: TSan does not model libgomp barriers,
    and every report pairs a master thread with its own pool threads.
  - The only mutable globals are thread_local (`cm.cpp:70,160`) or mutex-protected (`os.cpp` TTY).
- R-4 fd/mmap/heap leaks over create/hash/store/load/fork/destroy/failure loops (40 iterations, local and remote;
  plus LSan with the ASan build): REJECTED. fds and maps are constant (`work/concurrency/leaks/`).
- R-5 Returned `const char *` lifetimes: REJECTED. They are documented as valid until the next CM_API call on the
  same thread (thread_local storage), and the Lua bindings copy them immediately.
- R-6 `cm_remove_stored`/`cm_rename_stored`/`cm_clone_stored` on a directory in use: by design. "Must not be in
  use" is documented, and clone/copy take `LOCK_SH` per file, which fails against a sharing-all instance's
  `LOCK_EX`.

### Other observations (Low, not separately reported)
- `runtime.concurrency.update_hash_tree` is narrowed with `static_cast<int>` (`hash-tree.cpp:930`). A value such as
  `4294967295` or `UINT64_MAX` becomes `-1`. `update_dense_trees` (`hash-tree.cpp:459`) then computes
  `std::min(-1 << 10, 16384)`, which is cast to a huge `size_t`, so `reserve()` throws. Every `cm_get_root_hash` fails
  with `vector::reserve` (`omp-determinism/conc.c`). A natural "unlimited" value bricks hashing. Clamp the value in
  `get_concurrency`.
- `concurrency.update_hash_tree` is read only when the hash tree is constructed. `cm_set_runtime_config` silently
  does not apply it.
- With a small `phtc_size` (16), each 16-page batch opens an OpenMP region. On an oversubscribed host, one root hash
  of a 4 MiB machine took 17-26 s instead of 0.75 s (libgomp barrier spinning). Performance only.
