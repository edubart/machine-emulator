# Independent verification: concurrency candidates CONC-1 .. CONC-5 (verifier `verify-conc`)

All reproducers are in `<SCRATCH>/verify/verify-conc/conc<N>/run.sh`. Each one prints `BUG REPRODUCED` and exits 1
when the defect is present, and exits 0 otherwise. Copies of the hunter's PoCs were re-run from
`<SCRATCH>/verify/verify-conc/hunter/` and all reproduced as documented.
The validated fix is in `<SCRATCH>/verify/verify-conc/fix.patch` (apply with `git apply` to src/, then rebuild). The private build was deleted to save disk.

`<SCRATCH>` = `<SCRATCH>`

| ID | Verdict | Severity (mine) | Hunter |
|----|---------|-----------------|--------|
| CONC-1 | CONFIRMED, and worse than reported: the forked server's **root hash** also becomes wrong after a post-fork write | High | High |
| CONC-2 | CONFIRMED (same root cause as HT-3, different trigger; `cm_verify_hash_tree` returns true) | High (merge with HT-3) | High |
| CONC-3 | CONFIRMED (guest-triggered too; the default private flash mapping is enough; SIGTERM is ignored) | Medium | Medium |
| CONC-4 | CONFIRMED (deterministic socket inheritance; fixed-port EADDRINUSE race re-observed) | Low (Medium only for multi-threaded fixed-port spawners) | Medium |
| CONC-5 | CONFIRMED (spurious errors in every run; glibc heap-corruption abort in 4/20 runs of the hunter PoC) | Medium (Low if the one-thread-per-machine contract is documented) | Medium |

## How realistic is a shared hash tree (CONC-1, CONC-2)?
- `hash_tree.shared` defaults to `false`. Nothing in the CLI or the docs recommends it for nodes.
- It is a documented option:
  - CLI `--hash-tree=...,shared` (help text in `src/cartesi-machine.lua:377-405`: "target modifications to machine
    state modify the sparse hash tree file").
  - C API config `hash_tree.{shared,create,sht_filename,phtc_filename}` (doc/README.md around line 3366).
  - The CLI's `--hash-tree` parser accepts no `create` key, so the files must already exist with the right size.
- A stored machine keeps the flag. `machine::store` writes `config.json` with `m_c.store(dir)`, which uses the default
  `sharing_mode::config` (`src/machine.cpp:410`, `src/machine-config.hpp:249`). So `hash_tree.shared=true` and private
  ranges survive in `config.json`, and `CM_SHARING_CONFIG` loads reproduce the combination.
- Machines created with a directory (`cm_create(..., dir)`, CLI `--create`) or loaded with `CM_SHARING_ALL` also share
  all address ranges. For those, the fork guard `has_shared_address_range()` already refuses the fork, so CONC-1 does
  not apply to them. CONC-1 needs exactly "hash tree shared, ranges private".
- The CLI deliberately forbids fork-mode revert for shared *loads* (`src/cartesi-machine.lua:2801-2806`: "shared stored
  machines require --revert-mode=stored or none"). It does **not** check `--hash-tree=...,shared`. The default
  `--revert-mode=fork` (`src/cartesi-machine.lua:1096`, `:3660-3680`) with a remote server is therefore allowed with a
  shared hash tree. The intent to keep shared state away from fork is visible, but this case slipped through.

---

### CONC-1: JSON-RPC `fork` is allowed when only the hash tree is shared, so parent and child share the page hash-tree cache
- Verdict: **CONFIRMED**. The impact is larger than reported: besides wrong word-level hashes/proofs, the server that
  goes on computing after the other side has hashed computes a **wrong root hash** for its own later writes.
- Independent reproducer: `<SCRATCH>/verify/verify-conc/conc1/run.sh` (Lua, `cartesi.jsonrpc`, 1 MiB RAM,
  `phtc_size=32`; a local unshared machine performs the same operations as the reference). Output:
  ```
  fork of a machine with a shared hash tree was accepted
  parent root (unchanged state)  bcd60666...  (ok)
  parent word target hash        2604321f7cc9a15aaa10ebb431d37da6f712ef8ad5ba8c5a6d899ae624d5566a
  reference word target hash     c798ebb3fda3b30573ced679a1f0f0a6a8e61a7d82564e8666eac5dbcbf01474
  => parent word proof is wrong
  parent verify_hash_tree        true   (state unchanged, word proof wrong)
  parent root after write        ebd4b8b89a9b678a686ed8e823983ea74320e0c6c9f78620ab9a075789098045
  reference root after write     e3c99cf1130c5ad2fb976d3095f2660c2975bf85d6aef19ef1edb8d31786982c
  => parent ROOT HASH is wrong after a post-fork write
  parent verify_hash_tree        false  (server stderr: "page 0x8000A000 (in RAM) is not marked dirty but is dirty")
  parent root after 2nd write    f2577e91...   reference 9c3df7ec...   (stays wrong)
  BUG REPRODUCED: forked server with shared hash tree returns wrong hashes
  ```
  The hunter's `fork-shared-ht/run.sh` also reproduced as documented: 6 wrong word hashes/proofs, root hash correct.
- Root cause (my reading):
  - `jsonrpc_fork_handler` refuses only when `machine::has_shared_address_range()` is true
    (`src/jsonrpc-remote-machine.cpp:825`, `src/machine.hpp:833`). The hash tree's own backing stores are mapped
    `MAP_SHARED` when `hash_tree.shared` is set (`src/hash-tree.cpp` constructor, `os::mapped_memory_flags{.shared =
    config.shared}`). These are `hash_tree.sht` and `hash_tree.phtc`.
  - The phtc holds the LRU list, the `borrowed` flags, each entry's `paddr_page`, the page copy and the page hash tree.
    The index `m_map` (paddr to entry) is private heap memory (`src/page-hash-tree-cache.hpp:418-493`). After the fork,
    each process's `m_map` points into the same shared entries.
  - When one side hashes new pages, `borrow_entry` evicts LRU entries and rewrites their `paddr_page` and contents
    (`page-hash-tree-cache.hpp:529-569`). The other side's `m_map` still maps its old pages to those entries.
  - Word queries on a hit use the entry as-is (`hash-tree.cpp:101-124`, `:566-585`), so they return the other
    process's data.
  - Root-hash path: the other side then writes page P. `update_dirty_pages` borrows P's entry (a hit in its own
    `m_map`), but `enqueue_hash_dirty_page` / `return_updated_dirty_pages` use the entry's **foreign** `paddr_page`
    (`hash-tree.cpp:216-228`, `:285-299`). They rehash and compare a different page, and P's dense leaf is never
    updated. If any other page in the range changed, `update()` calls `dirty_page_tree().clean()` on the whole range
    (`hash-tree.cpp:700-703`). P is then marked clean with a stale leaf, and the root hash stays wrong permanently.
  - If the foreign `paddr` lies outside the range being updated, the update fails instead ("update hash tree failed").
    The hunter observed this, and it also `clear()`s the shared cache under the other process.
  - The shared sparse tree (`.sht`) is mostly self-healing when the two sides run sequentially: each `update_sparse_tree`
    resyncs every range leaf with its private dense root (`hash-tree.cpp:510-525`). Concurrent use races on `marked`.
- What is wrong, precisely:
  - **Word-level node hashes and proofs** (`cm_get_node_hash`/`cm_get_proof` with log2 < 12, and the proofs used
    internally by `log_step_uarch` and `log_send_cmio_response`) for pages whose entries were recycled by the other
    process. The root hash is still correct at that point, and `cm_verify_hash_tree` returns **true** (it does not
    check cache entries of clean pages; see HT-5).
  - **The root hash** (and all proofs above page level) after the stale side writes to such a page. Here
    `cm_verify_hash_tree` returns **false**, so it detects this case, but nothing calls it automatically.
  - Other effects: spurious "update hash tree failed" and "entry already borrowed" errors, and boost::intrusive
    assertion aborts under concurrent use (hunter's `run_stress.sh`).
- Realism:
  - Needs `hash_tree.shared=true` with private ranges. This is not the default, but it is documented and expressible
    from the CLI (`--hash-tree=...,shared`).
  - With such a config, the CLI's default `--revert-mode=fork` and a remote server, every advance/inspect does
    `fork_server()` (`cartesi-machine.lua:3660-3680`). After a revert, the backup server keeps working from a shared
    cache that the main server modified. I did not get a wrong root on the backup side in a quick attempt (pages
    8-13 hashed before the fork; main hashed 6-41 other pages; backup then wrote one of pages 8-13). The direction
    proven above (stale side writes after the other side hashed) is fully deterministic. Whether the revert flow hits
    it depends on which entries get recycled. Treat the CLI path as plausible, not demonstrated.
  - The Rollups node and PRT tooling use `cm_jsonrpc_fork_server` for snapshots. They would be affected only if their
    template config enables `hash_tree.shared`.
- Severity: **High** (agree). Wrong root hashes and proofs from the API and silently corrupted hash state in a
  documented configuration. Not Critical because the configuration is non-default and the CLI/docs do not recommend
  it.
- Fix assessment:
  - Validated: refuse the fork when the hash tree is shared. I added to `jsonrpc_fork_handler`
    `if (machine && machine->get_initial_config().hash_tree.shared) throw std::domain_error("cannot fork machines with
    shared hash tree");`.
  - With the patched server the reproducer prints `fork refused: cannot fork machines with shared hash tree` /
    `NOT REPRODUCED` (exit 0).
  - `m_c.hash_tree.shared` reflects the effective sharing for configs and for `machine_config::load(dir, sharing)`.
    For dir-created machines `m_c` keeps the user's flag, but those machines are already refused through their
    shared ranges.
  - A cleaner fix is `machine::has_shared_backing_store()` covering both, also used by `cm_clone_empty`-like paths
    if any. No root-hash or on-chain change. Forking such machines becomes an error, which is the only safe behavior.
  - The hit-validation fix proposed for HT-3/CONC-2 does **not** fix the root-hash part, because it lives in
    `update_dirty_pages` with a foreign `paddr`. The fork refusal (or re-mapping the phtc privately in the child) is
    required.
  - The CLI could additionally reject `--hash-tree=...,shared` with `--revert-mode=fork`, mirroring its existing check.

### CONC-2: Shared hash tree with private ranges pollutes the snapshot's `hash_tree.phtc`; later loads return wrong word proofs
- Verdict: **CONFIRMED**. This is the same root cause as HT-3 (cache hits for clean pages are trusted without
  validation, and the persisted phtc can disagree with the persisted memory), reached through the mirror-image
  configuration. Merge with HT-3. I did not verify HT-3 itself.
- Independent reproducer: `<SCRATCH>/verify/verify-conc/conc2/run.sh` (Lua; a different consequence than the
  hunter's cmio PoC: a guest `ld` and `log_step_uarch`). `lua5.4 repro.lua <dir> control` runs the same flow without a
  shared hash tree and prints `NOT REPRODUCED`.
  ```
  snapshot root             0e559eea...   reloaded root 0e559eea... (ok)
  reloaded memory at page   0x11
  get_node_hash(P,5)        c4bd59e1...   == keccak256(0x22 word), the discarded session's data
  keccak256(actual word)    b569321d...
  verify_hash_tree          true
  log_step_uarch failed at uarch step 708: siblings and read hash do not match root hash before 6th access to memory
  BUG REPRODUCED: polluted snapshot phtc gives wrong word hashes; honest uarch step log cannot be produced
  ```
  The hunter's `run.sh` and `run_cmio.sh` also reproduced as documented (honest `log_send_cmio_response` fails for
  both `CM_SHARING_CONFIG` and `CM_SHARING_NONE` reloads).
- Root cause:
  - Config `hash_tree.shared=true` plus the default private RAM. The stored `config.json` keeps both flags.
  - Loading with `CM_SHARING_CONFIG` maps the snapshot's `hash_tree.phtc` `MAP_SHARED`
    (`machine-config.cpp:94-111`) while RAM stays private.
  - A session's writes are discarded, but the cache entries created by hashing them are written into the snapshot's
    phtc.
  - On the next load (any sharing mode, because the file itself changed) the private `.dpt` says those pages are clean.
    The reconstructed `m_map` (`page-hash-tree-cache.hpp:477-490`) maps them to entries holding the discarded
    contents.
  - `get_page_proof`/`get_dense_node_hash` trust hits (`hash-tree.cpp:101-124`, `:566-585`).
  - The root hash is unaffected: a later write to such a page compares the entry's internally consistent page copy
    with memory and rehashes the differing words, so dense leaves stay correct. Only clean-page word-level queries are
    wrong. `cm_log_step` (page-level proofs, `record-step-state-access.hpp:205`) is unaffected. `log_step_uarch`
    (`uarch-record-state-access.hpp:103`) and `log_send_cmio_response` (`record-send-cmio-state-access.hpp:97,134`)
    are affected.
- What is wrong: `cm_get_proof`/`cm_get_node_hash` at log2 < 12 for clean pages, plus the uarch and cmio step logs
  built from them. `cm_get_root_hash` is correct. `cm_verify_hash_tree` returns **true** (it misses this; HT-5).
- Severity: **High** (agree). An honest party cannot produce the leaf-level proofs it needs in a PRT dispute, and the
  failure persists across every later load of that snapshot. The configuration is non-default.
- Fix assessment:
  - Validated: on a cache hit, compare the entry root with the dense-tree page node and rehash the entry from memory
    on mismatch, without touching the dense tree. This is a 32-byte compare per hit. I applied it as a macro in
    `get_page_proof` and `get_dense_node_hash` of my private `hash-tree.cpp`. Results are in the "Patched-build
    results" section below.
  - No root-hash change and no on-chain impact.
  - Optional hardening: refuse or normalize configs that share the hash tree while any hashed range is private, since
    the persisted phtc/sht can never be consistent with discarded memory. Or truncate (reset) the phtc on load when the
    sharing modes of ranges and hash tree differ.

### CONC-3: The JSON-RPC server routes SIGBUS through Boost.Asio `signal_set`, so a synchronous SIGBUS becomes an endless busy loop
- Verdict: **CONFIRMED**.
- Independent reproducer: `<SCRATCH>/verify/verify-conc/conc3/run.sh` (Lua; bounded: 3 s RPC timeout, server
  SIGKILLed at the end). The fault comes from **guest execution** (`ld` from a flash drive whose default, *private*
  backing image is truncated while the machine runs), not from `read_memory` as in the hunter's PoC.
  ```
  local machine (control):   exit 135 (killed by SIGBUS: fail-fast, expected)
  server pid 25398: run ->   error: jsonrpc error: post error contacting 127.0.0.1:43099 (jsonrpc error: timeout)
  server state R -> R, cpu ticks 67 -> 109 in 2 s
  after SIGTERM: state R -> R, cpu ticks 129 -> 150 in 1 s
  BUG REPRODUCED: server spins on a re-raised SIGBUS; no reply, no exit, SIGTERM ignored
  ```
  The hunter's `run.sh` reproduced as documented.
- Root cause:
  - `install_termination_signal_handlers()` adds `SIGBUS` to an `asio::signal_set` (`src/jsonrpc-remote-machine.cpp:
    318-323`), installed for the server's lifetime (`:2145`).
  - Asio's handler only writes the signal number to a pipe and returns. For a fault-generated SIGBUS, returning
    re-executes the faulting load forever, and the event loop never runs.
  - SIGTERM/SIGINT go through the same pipe, so they are never acted on either. Only SIGKILL stops the process.
  - The client's default timeout is infinite (`-1`), so the caller blocks forever.
  - There is no comment or test explaining why SIGBUS was added. The history is squashed (`dee69a8`).
- Severity: **Medium** (agree). Realistic operational triggers: disk full on sparse `MAP_SHARED` files, or an image
  truncated/replaced underneath. The default private flash mapping is affected too, because untouched private file
  pages still fault in from the file. The result is an indefinite hang of the node's machine server instead of a
  detectable crash. It needs no attacker, and it does not corrupt state.
- Fix assessment: removing `signals.add(SIGBUS)` restores the default action (the process dies, and the client gets a
  connection error). This is simple and correct. A `sigaction` handler that `_exit()`s or reports is an alternative. No
  hash or compatibility impact. Results with the patched server are below.

### CONC-4: Spawned servers inherit the client's sockets (no CLOEXEC, no spawn file actions)
- Verdict: **CONFIRMED**.
- Independent reproducer: `<SCRATCH>/verify/verify-conc/conc4/run.sh` (Lua, single-threaded, deterministic; matches
  socket inodes):
  ```
  client pid 29518 holds 1 socket(s) (its connection to server A 127.0.0.1:40455, pid 29520)
  server B pid 29524 (127.0.0.1:36777) holds 3 socket(s)
    client socket inode 331642 (client fd 6) is also open in server B as fd 6
  BUG REPRODUCED: spawned server inherited the client's connection to another server
  ```
  The hunter's multi-threaded fixed-port PoC reproduced again: control 0/25 failures; threads 1/25, 3/25 and 25/25
  failures with `bind: Address already in use`; the ports were held in LISTEN by sibling servers.
- Root cause:
  - Asio creates sockets with plain `::socket()`/`accept()` (`/usr/include/boost/asio/detail/impl/socket_ops.ipp:1830`).
  - The emulator never sets `FD_CLOEXEC`/`SOCK_CLOEXEC`, and `posix_spawnp(&child_pid, bin, nullptr, nullptr, args,
    environ)` has no file actions (`src/jsonrpc-machine.cpp:466-486`). The server's forked grandchild keeps them.
  - Because of the dup, `shutdown_and_close_socket` (`jsonrpc-machine.cpp:113-122`, which relies on close + SO_LINGER
    0) no longer resets the connection while a sibling holds it.
  - Side observation: a test client that exited without shutting down its servers left both servers alive past
    SIGTERM for over 1 s. This is consistent with sessions kept open by inherited dups.
- Severity: **Low**, or Medium only for multi-threaded clients that spawn concurrently on *fixed* ports. With the
  usual `127.0.0.1:0` the only effects are leaked fds, sockets and ports. There is no state corruption or wrong result.
- Fix assessment: as proposed. In the server, `close_range(3, ~0U, 0)` after moving `--server-fd` to a known fd. In the
  client, spawn file actions (`addclosefrom_np`) and/or CLOEXEC sockets. Low risk, no hash impact.

### CONC-5: `const` C API queries are not thread-safe on one machine
- Verdict: **CONFIRMED**.
- Independent reproducer: `<SCRATCH>/verify/verify-conc/conc5/run.sh` (C; a monitor thread polls `cm_get_root_hash`
  while a worker asks for word-level `cm_get_node_hash`; each trial runs in a forked child). `./run.sh locked`
  serializes every call with an external mutex and is clean in all 4 trials.
  ```
  mode: unsynchronized const queries
    worker : 142 ok, 0 wrong, 158 errors  last: page hash-tree cache entry already borrowed
    monitor: 634 ok, 0 wrong, 553 errors  last: page hash-tree cache entry already borrowed
  BUG REPRODUCED: concurrent const queries on one machine are not thread-safe
  mode: calls serialized by an external mutex (control) ... NOT REPRODUCED
  ```
  The hunter's PoC, run 20 times on the release build, aborted 4 times with
  `malloc_consolidate(): unaligned fastbin chunk detected` (glibc heap corruption). I observed no silently wrong
  hash or proof: the `borrowed` check turns most races into errors.
- Root cause:
  - `machine::update_hash_tree() const` (`src/machine.cpp:1533-1537`) runs before every `get_root_hash`,
    `get_node_hash` and `get_proof`. It marks the always-dirty and write-TLB pages and calls `m_ht.update()` on
    `mutable` members (`src/machine.hpp:74-75`).
  - That mutates the dirty-page trees, the phtc LRU and `borrowed` flags, the `std::unordered_map` index, and a
    `std::pmr::unsynchronized_pool_resource` (`src/hash-tree.hpp:230`), all without a lock.
- Contract: `cm.h` makes no thread-safety statement for machine objects. It only documents per-thread lifetimes of
  returned strings and error messages, which implies multi-threaded use of the library in general. The `const
  cm_machine *` signatures invite bindings to treat these calls as concurrent-safe readers, for example an `RWMutex`
  read lock in a Go wrapper or a `Sync` Rust handle. The JSON-RPC server is single-threaded and not affected.
- Severity: **Medium** (agree), conditional. It is a process crash or spurious failure, not a silent wrong proof.
  Concurrent proof requests on one machine from a thread pool are plausible but not the typical node architecture,
  which uses one machine per app with sequential access. If maintainers choose to document "one machine object must
  not be used from more than one thread at a time, including const calls", it becomes Low.
- Fix assessment: either a per-machine mutex around `update_hash_tree()` plus the subsequent read (cheap compared with
  hashing; changes no results), or explicit documentation in `cm.h`, preferably both. Switching only the pool to
  `synchronized_pool_resource` is insufficient (the phtc/LRU/map races remain). I did not validate this in a build. The mechanism is
  unambiguous, and the external-mutex control shows that serialization is enough.

## Patched-build results
Private build of `fix.patch` (release flags, incremental rebuild of `hash-tree.o` and
`jsonrpc-remote-machine.o` only). It has three changes:
1. `jsonrpc_fork_handler`: refuse when `get_initial_config().hash_tree.shared` (CONC-1).
2. `get_page_proof` / `get_dense_node_hash`: on a cache hit, if `entry.root_hash != dense page node`, rehash the
   entry from memory (no dense-tree write) (CONC-2/HT-3).
3. `install_termination_signal_handlers`: drop `signals.add(SIGBUS)` (CONC-3).

| Reproducer | Stock build | Patched build |
|------------|-------------|---------------|
| conc1/repro.lua | BUG REPRODUCED (wrong word proof, wrong root after write) | `fork refused: cannot fork machines with shared hash tree`, NOT REPRODUCED |
| conc2/repro.lua | BUG REPRODUCED (`log_step_uarch` fails at step 708) | `log_step_uarch ok for 804 steps`, NOT REPRODUCED |
| hunter shared-ht-reload/poc_cmio | log_send_cmio_response FAILED (CONFIG and NONE) | all four cases `accepted`, NOT REPRODUCED |
| conc3/repro.lua | server spins, SIGTERM ignored | server process terminates; client gets `end of stream` immediately, NOT REPRODUCED |
| tests/lua/spec-backing-stores.lua | - | 19 successes / 0 failures (includes the upstream phtc regression from 4bbedaf) |

The hit-validation patch is a sketch (a macro, to avoid touching `hash-tree.hpp`). A real fix should be a private
member helper. Note that patch 2 alone does not fix CONC-1's root-hash corruption (see CONC-1 fix assessment).

## Cleanup
Every server started by my reproducers is shut down or SIGKILLed. Three servers left over from early runs of my own scripts
(pids 28750, 28754, 2321) were killed. Servers 6352 and 18478 belong to `verify-capi` and were left alone. The private
build tree was deleted after validation, and only `fix.patch` was kept. The verify-conc dir is 716K.
