# Findings: hash-tree angle (state hashing, page hash-tree cache, dirty/dense trees, collect hashes)

Work dir / PoCs: `<SCRATCH>/work/hash-tree/` (`<SCRATCH>` = `<SCRATCH>`).
Build everything once: `cd <SCRATCH>/work/hash-tree && ./build.sh`. Then each PoC runs with `./tN` (exit 1 and the
line `BUG REPRODUCED` mean the bug is present). All PoCs link the default build in `/home/user/machine-emulator/src`.

`ref.h` provides an independent root hash. It reads every address range with `cm_read_memory` and rebuilds the 2^64
Merkle tree from scratch (32-byte words, pristine subtrees, `cm_get_hash`/`cm_get_concat_hash`). Its hash primitives were
cross-checked against a pure-Python Keccak-256 and hashlib SHA-256 for every input length from 0 to 1100 and for the
concat hash (`hashlen.c` + `keccak_ref.py`: `ALL OK`). `ref_check()` also prints `cm_verify_hash_tree`.

Summary:

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| HT-1 | A crash during `update()` leaves a sharing:all stored machine with a permanently wrong root hash (and `verify_hash_tree` says true) | PROVEN | High |
| HT-2 | Write-TLB-resident dirty pages are never recorded when a partially shared machine is destroyed, so the reloaded machine has a stale root hash | PROVEN | High |
| HT-3 | Page hash-tree cache entries for clean pages are trusted without validation: stale entries after `replace_memory_range` with hash files or a partially shared reload give wrong word proofs and make `log_step_uarch` fail | PROVEN | High |
| HT-4 | A crash during `update()` leaves "borrowed" entries in the shared `hash_tree.phtc`, so every later hash computation on that stored machine fails | PROVEN | Medium |
| HT-5 | `cm_verify_hash_tree` misses stale inner dense/sparse nodes and stale cache entries | PROVEN | Medium |
| HT-6 | Full-shadow `cm_write_memory(0, ..., 0x8000)` does not mark the shadow-TLB padding page dirty | PROVEN | Medium |
| HT-7 | `collect_uarch_cycle_root_hashes` resets the uarch only partially and diverges from `reset_uarch` when the uarch state is not pristine | PROVEN | Medium |
| HT-8 | `back_merkle_tree` allocates `log2_max_leaves+1` hashes before validating them, so a partial-bundle JSON drives multi-GB allocations | PROVEN | Medium |
| HT-9 | `cm_replace_memory_range` leaves dangling hot-TLB host pointers | DUPLICATE of mmu-tlb-1 | (High) |
| HT-10 | Word-level `get_proof` in the power-of-two padding of a range returns a wrong proof | DUPLICATE of STEP-PROOF-5 | (Medium) |
| HT-11 | `cm_get_node_hash` on a padding word aborts the process (assert) | DUPLICATE of STEP-PROOF-1 | (High) |

The investigated invariants that hold are listed at the end. They include collect-vs-run equivalence (rx-rejected
substitution, fixed points at boundaries, partial bundles, console breaks), uarch-vs-mcycle equivalence, Keccak/SHA-256
correctness and SIMD determinism.

Relation to `capi-storeload-3` (tampered store loads with a stale root hash): HT-1, HT-2, HT-3 and HT-4 need **no
tampering**. A crash, or the documented sharing modes and API calls, produce the inconsistent on-disk state.

---

### HT-1: A crash during `update()` leaves a sharing:all stored machine with a permanently wrong root hash (and `verify_hash_tree` says true)
- Status: PROVEN
- Area: hash-tree / store-load
- Category: data-loss (silent hash corruption), crash-consistency
- Where: `src/hash-tree.cpp:263-351` (`return_updated_dirty_pages` writes new page hashes into the dense tree and marks
  pages whose hash "did not change" clean), `src/hash-tree.cpp:694-706` (`update`: the dirty-page trees are cleaned only
  after the dense and sparse updates succeed), `src/hash-tree.cpp:502-529` (`update_sparse_tree`, the `marked` flag).
- Problem: With `sharing:all`, or a machine created with a directory, the dense hash trees (`.dht`), dirty-page trees
  (`.dpt`) and sparse tree (`hash_tree.sht`) are MAP_SHARED files. `update()` has three steps:
  (1) per batch, write each dirty page's new hash into its dense-tree leaf;
  (2) recompute the inner dense nodes;
  (3) recompute the sparse tree, then clean the dirty-page trees.
  Suppose the process dies after (1) but before (2)/(3) complete. On reload, the pages are still marked dirty, but
  `return_updated_dirty_pages` finds `cache root == dense leaf` (the leaf was already written), sets `changed=false`,
  and calls `mark_clean_page_and_up()`. The address range is never added to `changed_ars`, so the stale inner dense
  nodes and the sparse path are never recomputed. Dying inside `update_sparse_tree` after `marked=1` was stored for a
  sparse node has the same effect: `marked` is never reset, and that node is never enqueued again (`if
  (parent.marked == 0)`), so its hash stays stale.
- Scenario: An operator uses persistent stored machines, for example `cartesi-machine --load=dir,sharing:all`,
  `--revert-mode=stored`, or the C API with `CM_SHARING_ALL`. The node process is killed by the OOM killer, a container
  stop timeout, or another crash while it computes a root hash. After restart it loads the directory. The machine now
  reports a root hash that does not match its state, permanently, in every later reload. Claims and proofs built on
  this hash are wrong, and `cm_log_step` / `log_step_uarch` fail with root-hash mismatches. `cm_verify_hash_tree`
  still returns true (HT-5), so the operator gets no warning. The release documentation explicitly cares about crash
  durability of stored directories (see the `sync` key).
- Evidence: `./t8`. A gdb SIGKILL is injected deterministically when `hash_tree::update_dense_trees` is entered, while
  `t8_child` hashes 8 MiB of freshly written RAM. Then `./t8 hash-tree.cpp:530` kills inside `update_sparse_tree`
  after the marks are set.
  ```
  injecting a crash (SIGKILL) at cartesi::hash_tree::update_dense_trees ...
  [reloaded after crash] root DIFFERS FROM reference, verify_hash_tree=true
     machine:   33a447723de11dba18b0550c939ddd25465844a289392747dc800a3c8cbb3d86
     reference: b8311bf801b9eb6402b3b5232d0b54a18b5d125c8ce6d27fec701b37b0e7dcd7
  [reloaded again (sharing:all)] root DIFFERS FROM reference, verify_hash_tree=true
  [reloaded a third time] root DIFFERS FROM reference, verify_hash_tree=true
  BUG REPRODUCED: stored machine root hash permanently inconsistent with its memory after an interrupted update
  ```
  The same result occurs with the kill at `hash-tree.cpp:530`. Killing at the entry of `update_sparse_tree` (before any
  mark is set) recovers correctly. This confirms the two windows described above.
- Possible solution: Make `update()` idempotent across crashes.
  - (a) Compute `changed` against a value that is not persisted before the inner nodes. For example, keep the
    per-batch page hashes in memory and write the dense leaves together with the inner nodes. Alternatively, always
    add the AR of every dirty page to `changed_ars` and recompute the ancestors of every dirty leaf, not only of
    changed ones. The second option is cheap because only dirty paths are touched.
  - (b) In `update_sparse_tree`, enqueue a node when its child hash differs, regardless of a stale `marked`. Or reset
    all `marked` flags when the sht is mapped (the constructor already validates `marked <= 1`).
  - (c) Alternatively, keep a "hash tree consistent" flag in the stored directory. Clear it before `update()` and set
    it after. If it is clear on load, mark everything dirty.
- Severity: High. State is silently corrupted on the store/load path (wrong root hashes and proofs forever) after an
  ordinary process crash.
- Risks: The fix does not change any correct root hash. Option (a) adds negligible work.

### HT-2: Write-TLB-resident dirty pages are never recorded when a partially shared machine is destroyed, so the reloaded machine has a stale root hash
- Status: PROVEN
- Area: hash-tree / store-load
- Category: data-loss (silent hash corruption)
- Where: `src/machine.hpp:687-694` and `src/machine.cpp:1507-1531` (pages written through the write TLB are marked
  dirty only when they leave the TLB, or in `update_hash_tree()`), `src/machine.cpp:730-733` (`~machine` does not flush
  them), `src/machine-config.cpp:68-112`, `machine-config.hpp:237` (`adjust_backing_stores` defaults to
  `sharing_mode::config`).
- Problem: Guest stores through a write-TLB hit do not touch the dirty-page tree. The page is recorded only when its TLB
  slot is replaced (`write_verified_tlb` → `mark_write_tlb_dirty_page`) or on the next `update_hash_tree()`. This is
  safe only if the shadow TLB (in the processor backing store) is persisted together with the data, dht and dpt of the
  written range. A machine created with a directory (`cm_create(..., dir)` / `--create=dir`) stores a `config.json`
  whose `shared` flags are the user's flags. So loading it with `CM_SHARING_CONFIG` shares, for example, a flash drive
  configured `shared:true`, including its `.dht`/`.dpt`, but not the processor. If the machine is destroyed without a
  final `get_root_hash()`, the store reaches the flash data file, but the page stays clean in the persisted `.dpt` and
  the `.dht` keeps the old hash. The only record that the page is dirty (the shadow TLB) is discarded with the
  unshared processor state. Every later load computes the root hash from the stale dense tree.
- Scenario: A user runs the cartesi-machine `--load=dir,sharing:config` session with a persistent (shared) data drive
  and exits normally. The C API equivalent is `cm_load(dir, CM_SHARING_CONFIG)` followed by `cm_run` and
  `cm_delete`. Afterwards, `cm_get_root_hash`, `cm_get_proof`, `cm_log_step` and collect results from that directory
  are inconsistent with its memory.
- Evidence: `./t6`
  ```
  flash word after run: 0x1122334455667788
  flash word after reload: 0x1122334455667788
  page 0x100000000 (in flash drive 0) is not marked dirty but is dirty
  [reloaded machine] root DIFFERS FROM reference, verify_hash_tree=false
     machine:   890f2ca1b545c61d41f396cb2db414f75d92e4a74d0f4f25097c7c4e4e910aa9
     reference: 2ccd1565ff4b896212b36ace2f0489b5d7b6a2ee8c19ecc522225ffc449c7971
  BUG REPRODUCED: stored machine root hash is stale with respect to its memory contents
  (config.json: processor shared False, flash shared True, hash_tree shared False)
  ```
  The same happens with a config that gives explicit `dht_filename`/`dpt_filename` for a shared range, because the
  shadow TLB is never persisted then.
- Possible solution: Call `mark_write_tlb_dirty_pages()` in `machine::~machine()` (wrapped in try/catch), and before
  `store`/`sync_stored`/`clone_stored` of the live directory. Alternatively, mark a page dirty when it **enters** the
  write TLB instead of when it leaves. Both are cheap and make the dpt self-sufficient.
- Severity: High. Root hashes and proofs from a stored machine are silently wrong after a normal (non-crash) session in
  a documented sharing mode.
- Risks: No root hash changes. Marking on TLB insertion may slightly increase rehash work.

### HT-3: Page hash-tree cache entries for clean pages are trusted without validation: stale entries after `replace_memory_range` with hash files or a partially shared reload give wrong word proofs and make `log_step_uarch` fail
- Status: PROVEN
- Area: hash-tree (page hash-tree cache) / C API / uarch step logs
- Category: wrong proofs / honest prover cannot produce proofs
- Where: `src/hash-tree.cpp:101-124` (`get_page_proof`) and `src/hash-tree.cpp:566-585` (`get_dense_node_hash`). On a
  cache **hit** both use the entry's hashes as-is. `update()` only refreshes entries of *dirty* pages. The cache is not
  invalidated by `machine_address_ranges::replace` (`src/machine-address-ranges.cpp:630-654`), and it is persisted
  separately in `hash_tree.phtc`.
- Problem: The cache is keyed only by physical page address. It is correct only if every cached entry for a *clean* page
  equals that page's memory. Two ordinary API flows break this:
  1. `cm_replace_memory_range` with a backing store that brings its own `dht_filename`/`dpt_filename` (for example the
     files of a stored machine). The new pages are clean, so the old range's cache entries at the same addresses
     survive.
  2. A stored machine whose range is shared but whose hash tree is not (`CM_SHARING_CONFIG`, as in HT-2). Updates
     persist in the range's `.bin/.dht/.dpt`, but `hash_tree.phtc` keeps the old page contents and hashes. On the next
     load those pages are clean.

  In both flows `get_root_hash` is correct, but `cm_get_proof`/`cm_get_node_hash` with `log2 < 12` return hashes of
  the **old** page contents. `uarch_record_state_access` builds the logs with exactly these calls
  (`get_proof(skip_hash_tree_update, paddr, 5)`). The same goes for `record_send_cmio_state_access`. So
  `cm_log_step_uarch` emits wrong siblings and then fails its own verification.
- Scenario: An honest node needs a uarch step proof for an mcycle that reads such a page. In a PRT dispute this is the
  leaf-level proof. It cannot produce the proof ("siblings and read hash do not match root hash"), which could lose the
  dispute by timeout. Wrong proofs are also returned to any API or JSON-RPC client.
- Evidence:
  - `./t10` (replace with a stored drive's files):
    `word proof verifies against root: 0, target hash correct: 0, node hash correct: 0` / `BUG REPRODUCED`. Here
    `root matches reference` and `verify_hash_tree=true`.
  - `./t11` (sharing:config reload): same output, `BUG REPRODUCED: stale page hash-tree cache entries returned after reload`.
  - `./t12` (consequence, same setup, a guest `ld` from that page):
    ```
    [reloaded] root matches reference, verify_hash_tree=true
    cm_log_step_uarch failed at uarch step 2662: siblings and read hash do not match root hash before 6th access to memory
    BUG REPRODUCED: uarch step log cannot be produced because of stale page hash-tree cache entries
    ```
- Possible solution:
  - Never trust a cache hit for reads without validation. In `get_page_proof`/`get_dense_node_hash`, compare the entry's
    root hash with the dense-tree page node, and rehash from memory (`update_dirty_page`) when they differ. This costs
    one 32-byte comparison.
  - Also invalidate the cache entries of a range in `machine_address_ranges::replace`, and clear the phtc on load when
    the hash tree is not shared but any range is.
- Severity: High. Wrong proofs are returned, and an honest node can be prevented from producing uarch/cmio step logs.
- Risks: No root hash changes. The validation is cheap.

### HT-4: A crash during `update()` leaves "borrowed" entries in the shared `hash_tree.phtc`, so every later hash computation on that stored machine fails
- Status: PROVEN
- Area: hash-tree / store-load
- Category: DoS / crash-consistency
- Where: `src/page-hash-tree-cache.hpp:418-493` (constructor: the persisted `borrowed` flag is kept),
  `src/page-hash-tree-cache.hpp:527-551` (`borrow_entry` throws "already borrowed"), `src/hash-tree.cpp:369-422`
  (`update_dirty_pages` is not exception-safe: the `clear()` recovery path is skipped when `borrow_entry` throws).
- Problem: Entries are flagged `borrowed` inside the MAP_SHARED `hash_tree.phtc` while a batch is hashed. If the process
  dies during that window, the flags persist. After reload, the dirty page that owns such an entry is found in
  `m_map`, and `borrow_entry` throws `page hash-tree cache entry already borrowed`. The throw bypasses
  `m_page_cache.clear()`, so every `get_root_hash`, `get_proof`, collect and `log_*` call fails, in this process and
  in every future load of the directory. The only recovery is to manually delete or truncate `hash_tree.phtc`.
- Scenario: Same crash scenario as HT-1, in the page-hashing window, which is the longest phase of an update. The
  stored machine becomes unusable for any hash, claim or proof.
- Evidence: `./t7` (kills a child with SIGKILL during `cm_get_root_hash` on a sharing:all 64 MiB machine, then reloads):
  ```
  attempt 0: first cm_get_root_hash after reload -> -6 page hash-tree cache entry already borrowed
  attempt 0: second cm_get_root_hash after reload -> -6 page hash-tree cache entry already borrowed
  attempt 0: after another reload -> -6 page hash-tree cache entry already borrowed
  BUG REPRODUCED: stored machine permanently unable to compute its root hash after an interrupted update
  ```
  An earlier 6-attempt run with kill times between 20 and 400 ms gave the same result every time.
- Possible solution: In the `page_hash_tree_cache` constructor, treat any persisted entry with `borrowed != 0` as
  corrupted. Its page/hash pair may be half-updated, so `clear()` the whole cache (or at least drop those entries).
  Make `update_dirty_pages`/`update_words` exception-safe by returning borrowed entries or clearing the cache on
  exception.
- Severity: Medium. A crash permanently bricks hashing for a stored machine (DoS) until manual intervention. It is not
  silent.
- Risks: None. Clearing the cache only costs rehashing.

### HT-5: `cm_verify_hash_tree` misses stale inner dense/sparse nodes and stale cache entries
- Status: PROVEN
- Area: hash-tree / C API
- Category: verification weakness (false negative)
- Where: `src/hash-tree.cpp:628-692` (`hash_tree::verify`)
- Problem: `verify` only checks that pages whose page-level hash differs are marked dirty. It never recomputes inner
  dense nodes or sparse nodes. When the dense root and the sparse leaf disagree it only prints "dense hash tree root
  does not match sparse node hash" (line 685-687) and does not set `ret = false`. It does not check the page
  hash-tree cache either. So it returns `true` for machines whose root hash is wrong (HT-1) and for machines whose
  proofs are wrong (HT-3).
- Scenario: An operator or the node runs `cm_verify_hash_tree` after load or recovery as a sanity check. It passes on
  a corrupted tree, and the corruption propagates into claims and proofs.
- Evidence: `./t8`: `[reloaded after crash] root DIFFERS FROM reference, verify_hash_tree=true`. `./t10` and `./t11`:
  `verify_hash_tree=true` while the word proofs are wrong.
- Possible solution: Recompute bottom-up and compare every dense inner node and sparse node (this check is meant to be
  slow). Set `ret = false` on a dense-root vs sparse-leaf mismatch. For cached entries of clean pages, compare the
  entry's root and page bytes with memory and the dense leaf.
- Severity: Medium. The checker cannot detect the corruption classes above.
- Risks: Slower `verify` (acceptable for a verification call).

### HT-6: Full-shadow `cm_write_memory(0, ..., 0x8000)` does not mark the shadow-TLB padding page dirty
- Status: PROVEN
- Area: hash-tree / C API
- Category: wrong root hash
- Where: `src/machine.cpp:1732-1745` (the special case of `machine::write_memory` for the whole shadow state) and
  `src/machine-address-ranges.cpp:128-133` (`mark_always_dirty_pages` covers only the registers page 0x0-0xfff and the
  TLB pages 0x1000-0x6fff).
- Problem: The special case `memcpy`s all 0x8000 bytes of `shadow_state`, including `tlb_padding_` at 0x7000-0x7fff,
  without marking any page dirty. It relies on the "always dirty" pages, but page 0x7000 is not one of them. Non-zero
  bytes there change the state, but the root hash keeps the old page hash forever: no other path writes that page,
  so it is never re-marked. The same applies when a stored machine is reloaded with that state.
- Scenario: A client restores a "manual snapshot" of the shadow (the use case the code comment names) from a buffer
  that is not byte-identical to one read from a consistent machine, for example a hand-built or patched snapshot. The
  machine's root hash and proofs then disagree with any from-scratch recomputation. Another path is a guest VirtIO DMA
  of exactly 0x8000 bytes to physical address 0, because VirtIO writes go through `machine::write_memory`. That path
  only exists in unreproducible machines.
- Evidence: `./t1`
  ```
  page 0x7000 (in shadow state) is not marked dirty but is dirty
  [after full shadow write] root DIFFERS FROM reference, verify_hash_tree=false
     machine:   e81b85100cd7cb2d21784a3a9285bbd4013397f1ba6c000811725224c0750c45
     reference: 8a21f8b73139551a473ef2c7d0f3d28eca60aea49ef51fa067077ba1e2bb73b3
  ```
- Possible solution: After the `memcpy`, call
  `ar.get_dirty_page_tree().mark_dirty_pages_and_up(0, AR_SHADOW_STATE_LENGTH)`, or reject non-zero padding.
- Severity: Medium. The API returns a wrong root hash for an accepted input. The input is unusual.
- Risks: None.

### HT-7: `collect_uarch_cycle_root_hashes` resets the uarch only partially and diverges from `reset_uarch` when the uarch state is not pristine
- Status: PROVEN
- Area: uarch collect / hash-tree (`update_words`)
- Category: divergence
- Where: `src/machine.cpp:2763-2794`. The "direct" reset restores only `reset_dirty_words`, the uarch RAM words seen
  written during the run. The precondition at line 2648 only checks `uarch_cycle == 0`.
- Problem: The canonical reset (`cm_reset_uarch`, `cm_log_reset_uarch`, and on-chain `resetState`, which writes the
  whole uarch subtree) restores the entire built-in uarch RAM image. The collector restores only the words touched in
  this run. If the uarch RAM is not pristine at the start, untouched non-pristine words survive the collector's
  "reset". The collector then reports a reset state root hash different from the canonical one, and leaves the
  machine in a different state. A non-pristine uarch RAM comes from the documented `--uarch-ram-image` /
  `uarch.ram.backing_store.data_filename`, or from `cm_write_memory` into uarch RAM.
- Scenario: An honest node uses `cm_collect_uarch_cycle_root_hashes` (or `cm_collect_uarch_cycle_bundle`) to build its
  uarch-level commitment. Its "after reset" hash cannot be proven with the reset step verifier. Such templates are
  already inconsistent between cm_run and the uarch path after the first reset, so the severity is limited. The
  collector should reject the state rather than silently produce a third value.
- Evidence: `./t5`
  ```
  [custom uarch RAM image] collect_uarch reset hash = ZoKBxKFT6Qg+LSw5B/Qi7BMG1gZdbXgfnyY0yp9Q7Bs=
  [custom uarch RAM image] get_root_hash after it   = ZoKBxKFT6Qg+LSw5B/Qi7BMG1gZdbXgfnyY0yp9Q7Bs=
  [custom uarch RAM image] run_uarch + reset_uarch  = mETm2iPWBaRQObBPOP+dKr1liETgMPtCtipfpI2pp0I=
  [custom uarch RAM image] run_uarch + log_reset    = mETm2iPWBaRQObBPOP+dKr1liETgMPtCtipfpI2pp0I=
  [custom uarch RAM image] uarch RAM word 0x700000 after: collect path=0xdeadbeef canonical path=0x0
  BUG REPRODUCED
  ```
  The default uarch image gives identical hashes on all paths.
- Possible solution: At the start of collection, require a pristine uarch. Compare the uarch subtree hash
  (`get_node_hash(UARCH_STATE_START, UARCH_STATE_LOG2_SIZE)`) with the pristine uarch state hash, and throw if they
  differ. Alternatively, fall back to the full `reset_uarch()` plus `update_hash_tree()`.
- Severity: Medium. It needs a non-default uarch image, but the collector disagrees with the canonical transition.
- Risks: None for default machines.

### HT-8: `back_merkle_tree` allocates `log2_max_leaves+1` hashes before validating them, so a partial-bundle JSON drives multi-GB allocations
- Status: PROVEN
- Area: back-merkle-tree / C API / JSON-RPC
- Category: DoS (memory)
- Where: `src/back-merkle-tree.hpp:48` (constructor: `m_context(std::max(1, log2_max_leaves + 1))` runs before the
  `log2_max_leaves >= 64` check), `src/json-util.cpp:2195-2215` (`previous_partial_bundle.log2_max_leaves` is a uint64
  narrowed with `static_cast<int>`), plus the direct `log2_bundle_*_count` arguments in `machine.cpp:2348, 2683`.
- Problem: A `previous_partial_bundle` such as `{"log2_max_leaves":2147483647,...}` (or `log2_bundle_mcycle_count`)
  makes the constructor value-initialize up to 2^31 × 32 bytes (64 GiB) before it rejects the value. A request of a
  few GiB succeeds and is zero-filled, so peak RSS reaches the requested size, and the OOM killer can take down the
  `cartesi-jsonrpc-machine` server or a co-located node.
- Evidence: `./t9 33554432`:
  `cm_collect_mcycle_root_hashes -> -4 (log2_max_leaves is too large); peak RSS = 1089 MiB` / `BUG REPRODUCED`
- Possible solution: Validate `0 <= log2_max_leaves < 64` (and the type range when parsing JSON) before constructing
  `m_context`. Validate `log2_bundle_*_count` in the collectors before use.
- Severity: Medium. An API or JSON-RPC client can trigger memory exhaustion.
- Risks: None.

### HT-9: `cm_replace_memory_range` leaves dangling hot-TLB host pointers (DUPLICATE of mmu-tlb-1 / capi-storeload-6)
- Status: DUPLICATE. Reproduced independently: `./t2` (guest store loop to a flash drive, replace, resume) →
  `Segmentation fault` in `aliased_aligned_write` ← `write_virtual_memory` (TLB hit with the old `vh_offset`). This also
  defeats dirty tracking for the replaced range if the old address gets reused. The fix is `init_hot_tlb_contents()`
  after `m_ars.replace()`.

### HT-10: Word-level `get_proof` in the power-of-two padding of a range returns a wrong proof (DUPLICATE of STEP-PROOF-5)
- Status: DUPLICATE. Reproduced independently with `./t3` (3-page flash drive, `phtc_size` 16): proofs for
  `log2_target` 5..11 at the pad page 0x100003000 do not verify and their target is not pristine. Page level and above
  is correct.

### HT-11: `cm_get_node_hash` on a padding word aborts the process (DUPLICATE of STEP-PROOF-1)
- Status: DUPLICATE. `./t4` → `Assertion 'ar.contains_absolute(address, HASH_TREE_WORD_SIZE) ...' failed`, exit 134.

---

## Investigated and found correct (negative results, with evidence)

- **Root hash vs from-scratch recomputation across a full Linux boot**. `cmp_collect linux-config.json 1e12 22 ref`
  (87 M mcycles, 21 period hashes) runs on both Keccak-256 and SHA-256 configs. `collect_mcycle_root_hashes` equals
  `cm_run` to each boundary plus `cm_get_root_hash`, and both final roots equal the independent reference. The runs
  use OpenMP update concurrency 4 and the AVX-512 8-lane hashers (this CPU) with 4/2/1-lane remainders. Logs are in
  `cmp_linux_22.log` and `cmp_linux_sha_22.log`.
- **collect_mcycle_root_hashes / collect_mcycle_bundle semantics**. `collect_test` uses a parameterized bare-metal
  program (`param.S`) doing sd/amoadd/fsd/sw/sh/sb stores, HTIF putchar with to_buffer/every_char console breaks, and
  automatic yields. Each run ends in a halt, rx-accepted, rx-rejected or tx-exception manual yield, a spin, or an
  `imcyclemax` overflow. Splits of 1-5 calls with `previous_partial_bundle` continuation and bundles of 2^0..2^3 are
  compared with a `cm_run` reference that applies the revert-root-hash substitution, pads, and appends the
  fixed-point-only bundle. `collect_mcycle_bundle(k)` is compared with the reference slice.
  - Random samples of this space (`sweep2.sh`): seed 3 ran 30/30 OK. Seeds 1 and 2 were stopped early with no failure.
  - `targeted2.sh` covers a fixed point exactly at a period or bundle boundary (halt or rx-rejected yield at mcycle 128,
    and `imcyclemax`=128, with (lp,lb) in {(0,7),(3,4),(7,0),(2,5)} and 1 or 3 split calls): 24/24 OK.
  - `t13.c` covers `log2_mcycle_period`=63, `mcycle_phase`=2^63-1 and `mcycle_end`=UINT64_MAX: OK.
  - Console I/O errors (`/dev/full` output, `collect_test2` with `RT_A`) give identical hashes.
- **uarch vs mcycle**. `uarch_test`: for halt, manual-yield, rx-rejected (revert tail), automatic yield, putchar and
  `imcyclemax` overflow scenarios split over several calls, every per-mcycle reset hash from
  `collect_uarch_cycle_root_hashes` equals the mcycle-level state hash.
- **Store/load/clone/run/write/collect/uarch fuzzing**. `fuzz_sl` uses random sequences with `phtc_size` 3 and 4096 and
  a non-power-of-2 flash drive, 40 steps per seed: 13/13 seeds OK (`fuzz_sl.log`).
- **Hash primitives**. `cm_get_hash`/`cm_get_concat_hash` match an independent Keccak-256 and SHA-256 for every length
  from 0 to 1100.
- **SIMD queue logic**. `simd_data_hasher`/`simd_concat_hasher` flush levels before dependent nodes, and duplicate
  parents only cost redundant work. The static `optimal_queue_size` is shared by both hash functions but only affects
  the flush timing, never correctness.
- **back_merkle_tree push_back/pad_back/get_root_hash**. These are exercised with all bundle sizes above and match the
  explicit Merkle computation.
- **get_proof sibling ordering and subtree roots** (`log2_root_size` < 64, sparse and pristine regions). The proofs
  verify, except the padding case already reported (HT-10).
