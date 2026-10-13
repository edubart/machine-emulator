# Independent verification: hash-tree candidates HT-1 .. HT-8 (verify-hashtree)

Verifier: `verify-hashtree`. Work dir: `<SCRATCH>/verify/verify-hashtree/` (`<SCRATCH>` =
`<SCRATCH>`).
Hunter report: `<SCRATCH>/findings/hash-tree.md`. Hunter PoCs were copied to `verify-hashtree/hunter/`, rebuilt with
their `build.sh`, and re-run. `t8` (both kill points), `t6`, `t10`, `t11`, `t12`, `t5`, `t1` and `t9` all print their
`BUG REPRODUCED` lines as documented. Killing `t8` at the entry of `update_sparse_tree`, before any mark is set,
recovers correctly, as the hunter says. HT-9..HT-11 were skipped (duplicates verified elsewhere).

Every candidate has an independent reproducer of my own. Each one uses a different technique from the hunter's PoC:
random `fork`/`SIGKILL` instead of gdb, a Linux guest and the CLI instead of bare-metal C, Lua/JSON-RPC instead of C,
and a from-scratch "rebuild from data files" reference instead of `ref.h`. Each runs with `./run.sh` and prints
`BUG REPRODUCED` with exit 1 when the bug is present.

Fixes were validated in a private copy of the tree, `verify-hashtree/fix/`. It is built on verify-capi's copy, which
already contains the HT-2 write-TLB flush. Diffs: `verify-hashtree/fix-hash-tree.diff` (HT-1, HT-3),
`fix-phtc.diff` (HT-4) and `fix-machine.diff` (HT-2, by verify-capi). Re-runs against that build are in
`verify-hashtree/fixtest/`.

## Summary

| ID | Verdict | Hunter severity | My severity |
|----|---------|-----------------|-------------|
| HT-1 crash during `update()` of a shared tree => permanently wrong root hash | CONFIRMED | High | **High** |
| HT-2 write-TLB dirty pages lost when a partially shared machine is destroyed | CONFIRMED (reachable from a Linux guest via the CLI) | High | **Medium** |
| HT-3 stale page hash-tree cache entries trusted | CONFIRMED, **broader than claimed**: also corrupts `collect_uarch_cycle_root_hashes` output | High | **High** |
| HT-4 crash leaves "borrowed" phtc entries | CONFIRMED, with a nuance: one variant turns into silent HT-1 corruption on retry | Medium | **Medium** (merge into HT-1) |
| HT-5 `cm_verify_hash_tree` misses stale inner nodes and cache entries | CONFIRMED (property) | Medium | **Low** (fold into HT-1/HT-3) |
| HT-6 full-shadow `write_memory` does not mark the padding page dirty | CONFIRMED | Medium | **Low** |
| HT-7 uarch collector resets only touched words | CONFIRMED | Medium | **Low** |
| HT-8 `back_merkle_tree` allocates before validating | CONFIRMED (client and JSON-RPC server) | Medium | **Low** |

### How ordinary are the triggering flows (docs, CLI, downstream node)

- **Shared trees are a promoted feature.**
  - `doc/README.md` (~l.4380) says that when the dht/dpt/sht/phtc files are shared "the tree is maintained
    up-to-date on disk ... it is now possible to operate a machine entirely from disk".
  - The manual's "Rolling Cartesi Machines directly from storage" (~l.2478, ~l.5395) recommends
    `--load=machine,clone:...,sharing:all` with `--revert-mode=stored`. The Lua recipe uses `cartesi.SHARING_ALL`.
  - The CLI help says `--create` is "the only safe way ... to propagate 'shared' backing stores to configuration
    files". It also documents `sharing:config` ("MUST BE USED WITH --revert-mode=none") and `--replace-memory-range`
    with `dht_filename`/`dpt_filename` ("typically used in conjunction with --load").
- **What the docs promise about crashes.**
  - They warn only about *host* crashes and durability (the `sync` key).
  - Nothing says a process crash can corrupt the hash tree.
  - A kill during `cm_run` already leaves a torn state (pc/mcycle are committed only when the interpreter loop
    breaks, `interpret.cpp:5735-5742`). A kill during hashing, however, happens while the data is quiescent and
    consistent.
- **Downstream PRT node (`cartesi/dave`, `cartesi-rollups/node`), found with GitHub code search.**
  - It uses `SHARING_ALL` working clones: "Loads a working clone SHARING_ALL: the directory IS the live state"
    (`storage/rollups_machine.rs`). It runs window-sized `collect` calls on them (`machine_runner/mod.rs`).
  - It **sweeps working clones after a crash** ("Startup ritual: removes staging leftovers a crash orphaned ...
    working clones (.work-*)", `storage/snapshots.rs`). It also requires a pristine uarch at template load
    (`engine/machine_stf.rs`).
  - So the reference node, by design, is not exposed to HT-1/HT-4 (it discards crashed live directories). It is not
    exposed to HT-2/HT-3 either (it does not use `sharing:config` or replace with dht files) or to HT-7. CLI and Lua
    users of the documented stored/shared workflows are exposed.

### Merge recommendation with capi-storeload-3

- capi-storeload-3 is the "tampering / no verify-on-load" design trade-off. Persisted trees are trusted on load, and
  the v0.19 recompute-and-compare check was removed.
- verify-capi already appended the HT-2 write-TLB mechanism and the HT-1/HT-4 crash observations to storeload-3 as
  "non-tampering evidence", and rated it High on that basis.
- I recommend **separate write-ups**, cross-referenced, so that the same defect is not counted twice:
  - **HT-1 + HT-4 (+ HT-5 as a note): "crash during a shared hash-tree update".** The root cause is the non-idempotent
    `update()`, persisted `marked`/`borrowed` flags. The fix is specific (see HT-1). A storeload-3 style
    "verify on load" would not even catch HT-1 with today's `cm_verify_hash_tree`.
  - **HT-2: "write-TLB dirty marks are lost when the dpt is persisted without the shadow TLB".** This is the canonical
    entry for that mechanism (verify-capi's cases A/B/C are this bug). Its fix is the TLB flush in `~machine()`/`store()`.
  - **HT-3 (+ CONC-2, and the cache part of CONC-1): "page hash-tree cache hits trusted without validation".** It
    affects a different structure with different symptoms: the root is correct, but proofs and uarch-collect hashes
    are wrong. One fix covers all triggers. Rehash-on-load would not fix the `replace_memory_range` trigger or the
    fork trigger.
  - **capi-storeload-3 proper** should be the tampering/no-verify-on-load issue, Low/Medium on its own. It should
    reference the above as emulator-produced inconsistencies that a verify-on-load option would detect, provided
    that option recomputes inner nodes and the cache.

---

### HT-1: A crash during `update()` leaves a sharing:all stored machine with a permanently wrong root hash, and `verify_hash_tree` says true
- **Verdict: CONFIRMED.** No debugger is needed. Almost any kill inside the hash computation corrupts the directory.
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht1/run.sh` (`ht1.c` + `fill.S`).
  - A 64 MiB machine is created with a directory, the same as `--create`.
  - A child process `cm_load`s it with `CM_SHARING_ALL`, runs a guest that dirties every RAM page to halt, signals
    "ready", and calls `cm_get_root_hash`.
  - The parent sends `SIGKILL` at a uniformly random delay in [0, 1.2 × the measured duration of the hash].
  - The directory is compared with two independent references:
    - (1) a replay of the same session on an in-memory machine;
    - (2) a fresh machine built from the crashed directory's `.bin` data files only, with no dht/dpt/sht/phtc.
      This is a from-scratch hash of exactly the bytes on disk.
  - Control: an uninterrupted session matches both references.
  ```
  expected root hash (in-memory replay): 0xc91bdd48d919edfcd590047c350680b636795a9cca7ec45d44abd2d4f998c49b
  control (no kill): reload matches, rebuild-from-data matches; cm_get_root_hash in child took 1911.5 ms
  attempt  0: SIGKILL  570.3 ms after cm_get_root_hash started: reload: cm_get_root_hash FAILS ("update hash tree failed"); after zeroing hash_tree.phtc: WRONG root hash, cm_verify_hash_tree=true; data on disk is correct (rebuild matches replay); second reload (sharing:all) returns the same wrong hash
  attempt  2: SIGKILL 1930.6 ms after cm_get_root_hash started: WRONG root hash, cm_verify_hash_tree=true; data on disk is correct (rebuild matches replay); second reload (sharing:all) returns the same wrong hash
  attempt  3: SIGKILL 1509.9 ms ...: WRONG root hash, cm_verify_hash_tree=true; ...
  attempt  4: SIGKILL 1816.0 ms ...: WRONG root hash, cm_verify_hash_tree=true; ...
  attempt  5: SIGKILL  922.5 ms ...: reload: cm_get_root_hash FAILS (...); after zeroing hash_tree.phtc: WRONG root hash, cm_verify_hash_tree=true; ...
  summary: 6 attempts, 5 wrong root hash (silent), 2 hashing failure after reload, 0 correct, 1 finished before kill
  BUG REPRODUCED: a crash during cm_get_root_hash leaves a sharing:all directory whose root hash permanently disagrees with its own data
  ```
  - An earlier 128 MiB run gave 10/10 wrong out of 10 kills (7 of those first failed with HT-4 symptoms).
  - No kill produced a correct reload. Only kills before the first 4096-page batch returns, or inside the short
    pre-mark part of `update_sparse_tree`, can recover.
- **Root cause (re-derived):**
  - `hash_tree::return_updated_dirty_pages` (`src/hash-tree.cpp:300-311`) writes each dirty page's new hash into its
    dense-tree leaf. With sharing:all that leaf lives in the MAP_SHARED `.dht`, so it survives `SIGKILL` in the page
    cache.
  - The dirty-page trees are cleaned only after the dense and sparse updates succeed (`hash-tree.cpp:698-704`).
  - On reload, the pages are still dirty, but `changed = !equal(entry root, dense leaf)` is false, so the page is
    `mark_clean_page_and_up` (`:334-343`) and its range is never added to `changed_ars`. The stale inner dense nodes
    and the sparse path are never recomputed.
  - The second window: `update_sparse_tree` persists `marked = 1` (`:508-511`, `:552-555`). A node whose parent mark
    survived a crash is never enqueued again (`if (parent.marked == 0)`).
  - The constructor (`:940-946`) accepts `marked <= 1` and does not reset it.
- **Severity: High.**
  - The API returns wrong root hashes and proofs, silently and permanently, after an ordinary process crash (OOM
    kill, container stop timeout, SIGKILL) in the documented sharing:all/`--create`/`--revert-mode=stored` workflows.
  - The window is essentially the whole update, and hashing is a large share of run time with collect or
    per-input hashes.
  - The provided checker (`cm_verify_hash_tree`) returns true (HT-5).
  - It is not Critical, because a crash is required and the reference PRT node discards crashed SHARING_ALL working
    clones by design.
  - If the maintainers consider resuming a crashed live directory unsupported, Medium is defensible, but that is
    nowhere documented.
- **Risks:** Claims or proofs built on such a directory are wrong. `cm_log_step` fails with root mismatches. A
  validator resuming from it loses its dispute.
- **Fix assessment:**
  - The hunter's (a)+(b) are correct and do not change any correct root hash. I implemented and validated both:
    - (a) always add the range of every returned dirty page to `changed_ars`, instead of `mark_clean_page_and_up`;
    - (b) reset `marked` on all persisted sparse nodes in the constructor (see `fix-hash-tree.diff`).
  - With the fix, `fixtest/ht1` gives `summary: 6 attempts, 0 wrong root hash (silent), 2 hashing failure after
    reload, 2 correct, 2 finished before kill` (the 2 failures are HT-4, which was not fixed in that build).
  - Cost: inner-node rehash along the paths of dirty-but-unchanged pages, small next to page hashing.
  - Option (c), a persisted "update in progress" flag that forces everything dirty and clears the phtc on load, is
    more robust. It also covers HT-4, torn LRU-list splices in the shared phtc, and `update_words`/`update_page`
    windows, which (a)+(b) do not cover.

### HT-2: Write-TLB-resident dirty pages are never recorded when a partially shared machine is destroyed
- **Verdict: CONFIRMED, including with a Linux guest through the plain CLI.**
- **Independent reproducers:**
  - `<SCRATCH>/verify/verify-hashtree/ht2/run.sh` (Lua API, Linux guest).
    - A machine is created on disk with a persistent data drive `shared=true` and gets an initial hash, as
      `--create=dir --initial-hash` does.
    - It is loaded with `SHARING_CONFIG`. The guest runs `dd if=/dev/pmem0 of=/dev/pmem1 iflag=direct oflag=direct`
      and the session stops at a max-mcycle while modified drive pages are still in the write TLB.
    - The machine is destroyed without a hash, then reloaded.
    ```
    (cm_verify_hash_tree reported 24 pages/ranges 'not marked dirty but is dirty')
    session stopped at mcycle 66000000 with 23 modified data-drive pages still in the write TLB
    stored machine root hash: 0xb68a89477ebec335dd54af0245183f22b9dbaf719a952921cfe6b922a35734a3
    from-scratch root hash:   0xac480cf56e7dbdf48d8b5997f63b1e7fc07c855c7ecda420032ec8cd9830871a
    verify_hash_tree:         false
    BUG REPRODUCED: stored machine root hash is stale after a sharing:config session
    ```
  - `<SCRATCH>/verify/verify-hashtree/ht2/cli-flow.sh` (pure `cartesi-machine.lua`).
    - The flow is `--create=dir --initial-hash` with `--flash-drive=label:data,...,shared`, then
      `--load=dir,sharing:config --max-mcycle=N`, then `--load=dir --initial-hash`. The result is compared with a
      from-scratch CLI run on the same drive bytes.
    - `DATASIZE=64M MAXMC=70000000|75000000|80000000|85000000 ./cli-flow.sh "dd if=/dev/pmem0 of=/dev/pmem1 bs=1M
      count=60 iflag=direct oflag=direct"` gives `STALE ROOT HASH` 4/4 (`verify_hash_tree: false`,
      `flagged: 248 (in flash drive 1)`).
    - Sessions that end in a normal Linux halt were consistent in all my runs (`echo > /mnt/data/f && sync`, short
      `dd`). The shutdown path writes `satp`, and `flush_all_tlb` then marks the pages.
    - So with Linux the bug needs a session that stops while the guest is still writing: a max-mcycle stop, a yield
      or break right after a write, or bare metal (hunter's `t6`).
- **Root cause (re-derived):**
  - A page enters the write TLB without being marked (`replace_tlb_entry`, `interpret.cpp:931-939`). It is marked
    only when its slot is overwritten (`machine.hpp:687-692`, `write_unverified_tlb` `:715-718`), when the TLB is
    flushed, or in `update_hash_tree()`/`verify_hash_tree()` (`machine.cpp:1527-1535, 1605`).
  - `machine::~machine()` (`machine.cpp:730-733`) and `machine::store()` do not flush.
  - With `sharing:config` the range's `.dpt/.dht` persist, but the shadow TLB, which is the only record of those
    pages, is in the unshared processor store and is discarded.
  - Note: the dpt must be clean beforehand, that is, some hash was computed on the stored machine. A freshly
    `--create`d machine with no hash has an all-dirty dpt and hides the bug (`ht2` therefore takes an initial hash).
- **Severity: Medium** (hunter: High).
  - The outcome is a permanently wrong root hash from a documented flow without a crash, which would be High.
  - But: the mode is `sharing:config`, which the CLI restricts to `--revert-mode=none` ("don't use in production").
    The reference node never uses it (SHARING_ALL persists the shadow TLB and is safe). Normal Linux halts are
    unaffected. `cm_verify_hash_tree` does detect it.
  - It is High if stored `sharing:config` machines are used to build templates whose hash is registered on chain.
- **Fix assessment:**
  - Calling `mark_write_tlb_dirty_pages()` in `~machine()` (try/catch) and at the start of `store()` is correct and
    does not change root hashes. Validated: `fixtest/ht2-run.sh` gives `stored == from-scratch, verify_hash_tree:
    true` (patch by verify-capi, `fix-machine.diff`).
  - It does not cover a *crash* during a `sharing:config` session. Marking the page dirty when it **enters** the write
    TLB covers that too, at a small rehash cost.

### HT-3: Page hash-tree cache entries for clean pages are trusted without validation
- **Verdict: CONFIRMED, and more severe than claimed.** Besides wrong word-level proofs and failing
  `log_step_uarch`, the stale entry corrupts the uarch-cycle root hashes returned by `collect_uarch_cycle_root_hashes`.
  That is the uarch-level commitment an honest PRT node publishes.
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht3/run.sh`. The guest is a persistent counter, built
  with the CLI plus Lua checks.
  - Flow 1: `--create=d` (shared data drive) `--initial-hash`, then one `--load=d,sharing:config --final-hash` session
    (counter 0→1), then load `d`.
  - Flow 2: `cm_replace_memory_range` with another stored machine's drive `.bin+.dht+.dpt`.
  - Flow 1b: as flow 1, with a guest that fills a whole drive page, followed by `collect_uarch_cycle_root_hashes`.
  - Controls: the same directories with `hash_tree.phtc` zero-filled; a replace with the data file only.
  ```
  == flow 1: stored machine as left by the two CLI sessions
  [d] root hash matches from-scratch hash, verify_hash_tree=true
  [d] counter=1: word node hash WRONG, word proof target WRONG, proof folds to root NO
  [d] cm_log_step_uarch through mcycle 6 (ld + sd of the counter): FAILED: ... siblings and read hash do not match root hash before 6th access to memory
  == control 1: same directory, hash_tree.phtc zero-filled
  [d-ctl] counter=1: word node hash ok, word proof target ok, proof folds to root yes
  [d-ctl] cm_log_step_uarch through mcycle 6 (ld + sd of the counter): ok
  == flow 2: replace the data drive with e's drive (data+dht+dpt)
  [after replace (data+dht+dpt)] root hash matches from-scratch hash, verify_hash_tree=true
  [after replace (data+dht+dpt)] counter=7: word node hash WRONG, word proof target WRONG, proof folds to root NO
  == control 2: replace with e's data file only
  [after replace (data file only)] counter=7: word node hash ok, word proof target ok, proof folds to root yes
  == flow 1b: uarch-cycle root hash collection on the stored machine
  [p] collect_uarch_cycle_root_hashes to mcycle 12: 9780 hashes, 671 differ from the fresh machine (first at index 9110)
  == control 1b: same directory, hash_tree.phtc zero-filled
  [p-ctl] collect_uarch_cycle_root_hashes to mcycle 12: 9780 hashes, 0 differ from the fresh machine
  BUG REPRODUCED: stale page hash-tree cache entries give wrong word hashes/proofs, break cm_log_step_uarch and corrupt collected uarch-cycle root hashes
  ```
- **Root cause (re-derived):**
  - The cache is keyed only by physical page address. Hits are used as-is in `get_page_proof` (`hash-tree.cpp:101-124`)
    and `get_dense_node_hash` (`:566-585`).
  - `update()` refreshes only entries of *dirty* pages. On a dirty hit, `enqueue_hash_entry` compares all words, so
    full updates self-heal.
  - `update_words` (`:777-807`, used by the uarch collector at `machine.cpp:2732, 2791`) is different. On a hit it
    re-hashes only the words it was told are dirty, then **copies the entry's root into the dense leaf** (`:805-807`).
    A stale entry therefore contaminates the dense tree and the collected root hashes for the rest of that mcycle.
  - The cache is never invalidated by `machine_address_ranges::replace`.
  - The cache is persisted in `hash_tree.phtc` independently of the ranges' `.bin/.dht/.dpt`. This happens with
    `sharing:config` (range shared, tree private) and with CONC-2 (tree shared, ranges private).
- **Relationship to CONC-2:** same root cause, mirrored trigger. My HT-3 fix also fixes CONC-2: the hunter's
  `<SCRATCH>/work/concurrency/shared-ht-reload/poc.c` and `poc_cmio.c`, rebuilt against my fix build
  (`fixtest/conc2/`), print `NOT REPRODUCED`, and `verify_send_cmio_response -> accepted`. Against the release build
  they print `BUG REPRODUCED`.
- **Severity: High.**
  - Wrong proofs are returned. An honest node cannot produce uarch/cmio step logs, and its collected uarch-cycle
    commitment is wrong, which in a dispute means losing at leaf level.
  - It is not rated Critical only because every known trigger is a non-default sharing configuration or a
    replace-with-dht call, and the reference node's SHARING_ALL clones keep the cache consistent.
- **Fix assessment:**
  - The hunter's main fix is correct and complete for all triggers I know of (flows 1, 2, CONC-2): validate a hit
    against the dense-tree page hash and rehash on mismatch. It must also be applied in `update_words`, which the
    hunter's write-up does not mention.
  - I implemented it in `get_page_proof`, `get_dense_node_hash` and `update_words` (`fix-hash-tree.diff`; a 32-byte
    compare). With it, `fixtest/ht3-run.sh` passes every check, including `9780 hashes, 0 differ`.
  - No root hash changes. Invalidating the range in `replace` is a good complement, but not sufficient alone (it
    does not cover the reload triggers).

### HT-4: A crash during `update()` leaves "borrowed" entries in the shared `hash_tree.phtc`
- **Verdict: CONFIRMED, with a nuance the hunter missed.** There are two symptoms, depending on where the persisted
  borrowed entry is found:
  - `borrow_entry` finds it via `m_map` and **throws** "page hash-tree cache entry already borrowed"
    (`page-hash-tree-cache.hpp:527-551`). That skips `m_page_cache.clear()`, so the failure is permanent across calls
    and loads (a DoS).
  - It is at the LRU tail and `borrow_entry` returns "no entry". `update_dirty_pages` then fails with "update hash
    tree failed" **and clears the cache** (`hash-tree.cpp:416-419`). Under sharing:all that clear is persisted, so
    the **next call succeeds with a silently wrong root hash** (HT-1).
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht4/run.sh`. It uses the same random-kill harness and
  then reloads with sharing:all, as the owner would, and calls `cm_get_root_hash` three times.
  ```
  attempt  1: ... call 1: WRONG; call 2: WRONG; call 3: WRONG; next load: WRONG (silent)
  attempt  2: ... call 1: FAILS (update hash tree failed); call 2: WRONG; call 3: WRONG; next load: WRONG (silent)
  attempt  3: ... call 1: FAILS (page hash-tree cache entry already borrowed); call 2: FAILS (...); call 3: FAILS (...); next load: page hash-tree cache entry already borrowed
  summary: 5 attempts, 8 calls wrong, 4 calls failed, 0 calls correct, 1 finished before kill
  ```
- **Severity: Medium** (as rated). It is the same trigger as HT-1, so merge it into HT-1 as a second symptom. The
  "fail-stop" behaviour cannot be relied on, because one variant degrades into silent corruption after a retry.
- **Fix assessment:**
  - Dropping the cache in the constructor when any persisted entry is borrowed is correct (the cache is only a cache).
  - Making `update_dirty_pages`/`update_words` exception-safe is good hygiene.
  - HT-4 must be fixed together with HT-1: clearing the cache alone exposes the silent HT-1 result.
  - Validation of the constructor fix: see the addendum at the end.

### HT-5: `cm_verify_hash_tree` misses stale inner dense/sparse nodes and stale cache entries
- **Verdict: CONFIRMED as a property.**
  - `verify` (`hash-tree.cpp:628-692`) checks only page leaves against memory and the dirty flags.
  - A dense-root vs sparse-leaf mismatch only prints a message (`:685-687`) and never sets `ret=false`.
  - Inner nodes and the cache are not checked.
- **Independent reproducer:** `ht1/run.sh` (`cm_verify_hash_tree=true` on every wrong reload) and `ht3/run.sh`
  (`verify_hash_tree=true` with wrong proofs and wrong collected hashes).
- **Severity: Low** (hunter: Medium).
  - `cm.h:1143` documents the function as "used only for emulator internal tests".
  - The weakness matters only as a missing detection tool for HT-1/HT-3. Fold it into those write-ups.
- **Fix assessment:**
  - Recomputing inner nodes bottom-up and comparing the cache entries of clean pages is correct.
  - Set `ret=false` on the sparse/dense mismatch.
  - Worth doing if a "verify on load" option (storeload-3) is added on top of it.

### HT-6: Full-shadow `cm_write_memory(0, ..., 0x8000)` does not mark the padding page dirty
- **Verdict: CONFIRMED.** The special case (`machine.cpp:1732-1745`) memcpys the whole shadow. It relies on
  `mark_always_dirty_pages` (`machine-address-ranges.cpp:128-133`), which covers 0x0-0x6fff only, so page
  0x7000-0x7fff (`tlb_padding_`) keeps its old hash.
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht6/run.sh`. In Lua, it reads the shadow, sets one
  padding byte, writes it back, and compares `get_node_hash(0x7000,12)` with `cartesi.hash-tree.get_data_root_hash`
  of the page.
  ```
  page hash in hash tree : 0x292c23a9...   hash of the page bytes : 0x6cb38d4d...   verify_hash_tree : false
  BUG REPRODUCED: full-shadow write leaves the padding page's hash stale
  ```
- **Severity: Low** (hunter: Medium).
  - The padding is always zero in any machine. Guests and the uarch cannot write it, and a snapshot read from a
    machine has zero padding.
  - Only a hand-crafted buffer triggers the bug, and `verify` detects it.
- **Fix:** mark 0x0-0x7fff dirty after the memcpy, or reject non-zero padding. Either is correct and has no hash
  impact.

### HT-7: `collect_uarch_cycle_root_hashes` resets the uarch only partially
- **Verdict: CONFIRMED.** The "direct reset" (`machine.cpp:2766-2794`) restores only `reset_dirty_words`. The entry
  check (`:2648`) tests only `uarch_cycle == 0`.
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht7/run.sh`. In Lua, the default uarch image is used,
  with a single `write_memory` of `0xdeadbeef` to uarch RAM 0x7f0000 beyond the image.
  ```
  collector post-reset hash : 0xedb47ed5...   run_uarch + reset_uarch : 0x9844e6da...   run_uarch + log_reset : 0x9844e6da...
  uarch RAM word after: collector 0xdeadbeef, canonical 0x0
  BUG REPRODUCED: collector reset diverges from the canonical uarch reset
  ```
- **Severity: Low** (hunter: Medium).
  - It requires a non-pristine uarch at the start of collection: a custom uarch image or an API write into uarch RAM.
  - Such a machine already diverges from the on-chain reset after its first canonical reset.
  - The reference node explicitly checks for a pristine uarch at template load.
- **Fix:** reject collection unless the uarch subtree equals the pristine uarch hash (cheap: one node-hash compare),
  or fall back to the full `reset_uarch()`. Either is correct and does not change default-machine hashes.

### HT-8: `back_merkle_tree` allocates `log2_max_leaves+1` hashes before validating
- **Verdict: CONFIRMED** on both sides of JSON-RPC.
  - The constructor runs `m_context(std::max(1, log2_max_leaves + 1))` before its range checks
    (`back-merkle-tree.hpp:44-55`).
  - The JSON parser narrows a uint64 to int (`json-util.cpp:2213`).
  - For `log2_max_leaves = INT_MAX`, `+1` is a signed overflow (UB).
  - `cm_collect_mcycle_root_hashes` parses the bundle in the client (`cm.cpp:756`), and the server handler parses it
    again (`jsonrpc-remote-machine.cpp:973`).
- **Independent reproducer:** `<SCRATCH>/verify/verify-hashtree/ht8/run.sh`. It sends a raw JSON-RPC request with curl
  to a spawned server, then makes the same call through the C API.
  ```
  server: reply {"error":{"code":-32603,"data":-4,"message":"log2_max_leaves is too large"},"id":1,"jsonrpc":"2.0"}
  server pid 3945 peak RSS: 58 MiB -> 315 MiB
  client: ... log2_max_leaves is too large; client peak RSS: 16 MiB -> 272 MiB
  BUG REPRODUCED: 257 MiB (server) / 256 MiB (client) allocated for a partial bundle that is then rejected
  ```
  The default value is bounded to 256 MiB on purpose. 2^28 would zero-fill 8 GiB.
- **Severity: Low** (hunter: Medium).
  - JSON-RPC clients are trusted by design: they can already `shutdown` the server or create arbitrarily large
    machines.
  - The C API caller passes its own data. A corrupted saved partial bundle (resumable epochs) would only make the
    local CLI fail with OOM.
  - It is still a real input-validation defect, with UB at INT_MAX.
- **Fix:** validate `0 <= log2_max_leaves < 64` (and the uint64 range in the JSON parser) before constructing
  `m_context`. Also validate `log2_bundle_*_count` in the collectors. Trivial, no side effects.

## Fix validation addendum (all fixes together)

The private build is `verify-hashtree/fix/src`. It contains:
- HT-1 (a)+(b) and HT-3 in `hash-tree.cpp` (`fix-hash-tree.diff`);
- HT-4 in the `page_hash_tree_cache` constructor (`fix-phtc.diff`): when any persisted entry is borrowed, it calls
  `clear()`;
- HT-2, verify-capi's `mark_write_tlb_dirty_pages()` in `~machine()` and `store()` (`fix-machine.diff`).

Re-runs from `verify-hashtree/fixtest/`:
- HT-1 random kills: `summary: 6 attempts, 0 wrong root hash (silent), 0 hashing failure after reload, 6 correct`.
  With only the HT-1 fix: 0 wrong, 2 HT-4 failures.
- HT-4 random kills plus sharing:all retries: `summary: 6 attempts, 0 calls wrong, 0 calls failed, 18 calls
  correct`.
- HT-2 (Linux guest): `stored == from-scratch`, `verify_hash_tree: true`.
- HT-3 (all flows): `no stale cache entries observed`, including the collector check
  `9780 hashes, 0 differ from the fresh machine`.
- CONC-2 PoCs (`fixtest/conc2`): `NOT REPRODUCED`, `verify_send_cmio_response -> accepted`.
- Regression sanity: the hunter's store/load/clone/run/write fuzzer (`fuzz_sl`, phtc_size 3, which forces cache
  evictions) prints `OK` for seeds 1-4 × 25 steps against the fixed build.

None of the fixes changes any correctly computed root hash, so on-chain/step-verifier compatibility is unaffected.

Object files and test data were removed from the fix copy (the libraries needed by `fixtest/` were kept). The
reproducers regenerate all stored machines they need and delete them afterwards.
