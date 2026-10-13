# Verification report: verify-capi (candidates capi-storeload-1 .. -5)

`<SCRATCH>` = `<SCRATCH>`
Work dir: `<SCRATCH>/verify/verify-capi/` (hunter PoC copies in `hunter/`, my reproducers in `c1`..`c5`, `cli2`,
private fixed build in `fix/` (release `relwithdebinfo` tree with the candidate fixes applied, see the end of this report).
capi-storeload-6 (duplicate of mmu-tlb-1) was not verified here, as instructed.

| ID | Verdict | Hunter severity | My severity |
|----|---------|-----------------|-------------|
| capi-storeload-1 | CONFIRMED | Medium | Low |
| capi-storeload-2 | CONFIRMED | Medium | Low |
| capi-storeload-3 | CONFIRMED, and broader than claimed (also happens with no tampering) | Medium | **High** |
| capi-storeload-4 | PARTIALLY CONFIRMED (UB is real, but crashes only on `_GLIBCXX_ASSERTIONS` builds) | Medium | Low |
| capi-storeload-5 | CONFIRMED | Low | Low |

All hunter PoCs were re-run from clean copies (`hunter/p2_forged_cache`, `p3_api_misc`, `p5_cfg`, `p6_translate`,
`p7_logstep`). Each one printed its `BUG REPRODUCED` line as documented. p5 does this only against the ASan/UBSan build.

---

### capi-storeload-1: `cm_log_step()` on an empty machine object dereferences NULL
- **Verdict:** CONFIRMED.
- **Independent reproducer:** `<SCRATCH>/verify/verify-capi/c1/run.sh`. It goes through the Lua bindings, which is a
  different path from the hunter's C PoC: `cartesi.new()` creates an empty local object, and then `machine:log_step()` is called on it.
  ```
  machine:run on empty object -> false no machine
  machine:get_root_hash on empty object -> false no machine
  machine:log_step on empty object ...
  ./run.sh: line 6: 17776 Segmentation fault      lua5.4 t.lua
  BUG REPRODUCED: lua process killed by signal 11 in machine:log_step on an empty machine object (other methods return 'no machine')
  ```
- **Root cause:** `src/local-machine.cpp:112-114`. `local_machine::do_log_step` uses `m_machine->` directly. Every other
  `do_*` method uses `get_machine()` (`local-machine.cpp:60-72`), which throws `"no machine"` when the object is empty.
- **Reachability:** The JSON-RPC server guards against this case: `jsonrpc_machine_log_step_handler` returns `"no machine"`
  (`jsonrpc-remote-machine.cpp:1161-1164`). The CLI never calls `log_step` on an empty object. The case can be reached from
  C API callers and from Lua scripts (`cartesi.new()`, `m:destroy()`, `m:move()` all leave an empty object), and both of
  those are trusted code. `cm.h` documents the precondition "Pointer to a non-empty machine object".
- **Severity: Low.** I downgraded it from Medium. It is a crash on API misuse that breaks a documented precondition, and
  no untrusted party can reach it. It is still a real robustness inconsistency, because every other entry point fails cleanly.
- **Fix assessment:** `return get_machine()->log_step(...)` is correct and complete. It has no hash or behaviour impact.
  I validated it in `fix/`: `log_step` now returns `false  no machine`.

### capi-storeload-2: `cm_create()`/`cm_load()` on a non-empty object leak the existing instance
- **Verdict:** CONFIRMED.
- **Independent reproducer:** `<SCRATCH>/verify/verify-capi/c2/run.sh`. It is written in Lua and compares the local
  transport with the JSON-RPC transport. It also counts the process's fds and re-locks the shared backing file.
  ```
  remote: create() on non-empty object ->	false	machine exists
  local : create() on non-empty object ->	true	cartesi machine object: 0x55991e0884c8
  local : word at 0x80000000 after 2nd create =	0	(instance #1 silently replaced)
  local : open fds before=8 after create+create+destroy=11
  local : re-opening the shared flash after destroy ->	false	unable to lock backing file 'shared-flash.bin': Resource temporarily unavailable when initializing flash drive 0
  BUG REPRODUCED: create() on a non-empty local machine object leaks the previous instance
  ```
- **Root cause:** `src/local-machine.cpp:48-55`. `do_create`/`do_load` overwrite `m_machine` and never check
  `m_machine != nullptr`. The JSON-RPC server does reject this case (`jsonrpc-remote-machine.cpp:907-909, 937-939`).
- **Severity: Low.** I downgraded it from Medium. It needs a caller bug that breaks the documented precondition
  ("Pointer to an empty machine object"). The `cartesi.machine{...}` Lua constructor and `cm_create_new`/`cm_load_new`
  always start from a fresh object, and the CLI calls `destroy()` before `load()`. When the bug is hit, the impact is
  silent loss of the in-progress instance plus leaked fds, mmaps and flocks.
- **Fix assessment:** Throwing `"machine exists"` in `do_create`/`do_load` is correct and matches JSON-RPC behaviour.
  I validated it in `fix/`: the second create fails, fds are not leaked, and the shared file can be re-opened.

### capi-storeload-3: `cm_load()` trusts the persisted hash tree
- **Verdict:** CONFIRMED. The hunter only showed the tampering scenario. I found that the emulator itself can produce
  stored or on-disk machines whose persisted tree does not match their data. This happens through documented workflows,
  with no tampering and no crash, and in those cases the API returns a wrong root hash. This raises the severity.

**Independent reproducers:**
- **`<SCRATCH>/verify/verify-capi/c3/run.sh`** (bare-metal guest, release build; deterministic; scenario D is for reference only).
  The guest writes a counter to 16 flash pages and 1 RAM page.
  ```
  == A: shared flash drive with persisted dht/dpt files, session closed normally after running
     session 1 initial root hash      : a62233a1697af1701bccc164cd75a5636412ce294cad9b57d5edf321f7bdf4d6
     session 2 root hash (from files) : a62233a1697af1701bccc164cd75a5636412ce294cad9b57d5edf321f7bdf4d6
     true root hash of same contents  : a21756ea7f13a582f9af070dd4998df2372e60cf46aeae4b027a2c0ec9f96d6f
     flash word 0 = 10 (written by guest in session 1); cm_verify_hash_tree = false
     BUG REPRODUCED: root hash computed from persisted dht/dpt differs from the true root hash of the data
  == B: on-disk machine (flash shared:true), loaded with sharing=config, run, closed, reloaded
     loaded root hash     : ba1cda0b8345f5c34cefba66d4e747847c53848b4d01a3890c1631bd35b0b0e3
     cm_verify_hash_tree  : false
     recomputed root hash : ed3ee0974321f76bec6d24f461f9ecfcf89802d51e32725e54f6df4d64715c4d
     INCONSISTENT: persisted hash tree does not match stored data
  == C: same machine loaded with sharing=config, run, stored with cm_store(CM_SHARING_CONFIG)
     loaded root hash     : ba1cda0b...   recomputed root hash : ed3ee097...   INCONSISTENT
  == D (reference, tampering): change one byte of a page of the stored RAM .bin not touched by the guest
     loaded root hash 9eb73286...  recomputed a64c998e...  INCONSISTENT
  BUG REPRODUCED: emulator-produced stored state whose persisted hash tree does not match its data (no tampering)
  ```
  The scenarios use these features:
  - **A:** the documented flash-drive options `dht_filename`/`dpt_filename` + `shared`. The CLI help says "shared: target
    modifications to flash drive modify the memory and hash tree files", and for `dht_filename` it says "when omitted …
    the hash tree will be built from scratch".
  - **B:** the documented `--create=<dir>` flow followed by `--load=<dir>,sharing:config --revert-mode=none`. The CLI help
    calls `--create` "the only safe way … to propagate 'shared' backing stores to configuration files".
  - **C:** `cm_store(..., CM_SHARING_CONFIG)`.
  - **How "true" is computed:** the stored directory is copied, the `.dht/.dpt/.sht/.phtc` files are zero-filled (which
    forces a rebuild), and the copy is reloaded.
- **`<SCRATCH>/verify/verify-capi/cli2/run.sh`:** the same as A but with a **Linux guest** (`yes | dd of=/dev/pmem1 oflag=direct`),
  where session 1 is stopped at mcycle 65,500,000:
  ```
  hash from persisted dht/dpt:	0x8360fb2a87cd20867599ac141dc20fc8fa3e39537bcaf936744bb82192245568
  hash rebuilt from data     :	0x4a471a9d7b4937e71f0be8dc54be563b408768327c769f1a3433dd2b5cf469c8
  BUG REPRODUCED: stale persisted hash tree (Linux guest)
  ```
  With Linux the window is narrower, because the kernel flushes the TLB on every context switch. `cli2/tlb.lua` measures
  how many write-TLB slots point into the data drive: at the sampled stop points it found 0–1 slots, against 16 for the
  bare-metal loop. The bug therefore shows up only when the machine stops shortly after a flash write.
  `cli2/cli_sweep.sh`, which runs through the CLI with different stop points, did not hit such a window.
- **`<SCRATCH>/verify/verify-capi/c3/killtest.sh`:** a crash survey. `kill -9` hits the process that runs the machine
  on disk, then the machine is reloaded and checked. Representative output:
  ```
  sharing=1 gethash=0 chunk=100000 t=0.4: loaded: mcycle=2 flash[0]=390816 INCONSISTENT
  sharing=2 gethash=0 chunk=20000000 t=0.9: loaded: mcycle=120000002 flash[0]=1363264 CONSISTENT   <- torn state, see below
  sharing=2 gethash=1 chunk=100000 t=0.4: cm_get_root_hash -> -6: page hash-tree cache entry already borrowed
  ```

**Root cause.**
1. *The tampering aspect (the hunter's claim)* is a deliberate v0.22 design change.
   - `doc/README.md` (section "Persistent Cartesi Machines" / ~line 4376) says that in past releases "the root hash was
     computed from scratch and compared against what was stored". In v0.22, `load` maps the persisted `.dht/.dpt/.sht/.phtc`
     files back in and trusts them.
   - I checked upstream v0.19.0: `machine::machine(dir, r)` recomputed the tree and threw "stored and restored hashes do
     not match" unless the runtime option `skip_root_hash_check` was set.
   - In v0.22 both the check and that option are gone. `machine_runtime_config` only has `skip_version_check`, and there
     is no verify-on-load option.
   - The only detection API is `cm_verify_hash_tree`, which is weak:
     - It is documented as "used only for emulator internal tests" (`cm.h:1143`).
     - It hashes every page of every range (`hash-tree.cpp:628-692`), so it costs about as much as rebuilding the tree.
       Get_root_hash alone takes ~120 ms on a 1 MiB machine here.
     - It is incomplete: it checks only page leaves and range dirty flags. It does not check interior dense-tree nodes or
       the sparse tree. A sparse-leaf mismatch only prints a message and does not fail.
     - I observed a stale root hash with `cm_verify_hash_tree == true`; see the crash case below.
   - The truncated-data-file part of the claim is confirmed. A half-length `.bin` loads with `sharing=none` and is
     zero-padded through `backing_gap`. It is rejected with `sharing=all`, and a 0-byte file is rejected in both modes.
2. *Non-tampering inconsistency (new evidence).*
   - Dirty-page marking for the hot write TLB is deferred:
     - `machine::write_verified_tlb` marks the page only when the slot is evicted (`machine.hpp:687-692`).
     - `update_hash_tree()`/`verify_hash_tree()` flush the pending marks with `mark_write_tlb_dirty_pages()`
       (`machine.cpp:1533, 1605`).
     - Until then, the only record of those pages is the shadow TLB inside the processor backing store.
   - When a range's dirty page tree is persisted but the processor state is not persisted with it, the pending marks are
     lost. On reload those pages count as clean, and their stale dense-tree hashes are trusted. Three cases:
     - shared flash with dht/dpt files in an otherwise in-memory machine;
     - `sharing=config`, where the processor is private;
     - `store(CONFIG)`, which copies the processor from the initial state.
   - Specifically:
     - `machine::~machine()` (`machine.cpp:730-733`) does not flush the pending marks.
     - `machine::store()` (`machine.cpp:396-475`) dumps `ar.get_dirty_page_tree().get_storage_data()` without calling
       `mark_write_tlb_dirty_pages()` first.
   - With `sharing=all` and a clean exit, the store stays consistent: the shadow TLB is persisted too and is re-marked
     on reload. This matches the hunter's `p4_fidelity` negative result.
3. *Crash during a hash-tree update with shared tree files (sharing=all) — additional evidence.*
   - The persisted `hash_tree.phtc` keeps entries flagged "borrowed" (`page-hash-tree-cache.hpp:516-568`). After reload,
     every `get_root_hash` fails with "page hash-tree cache entry already borrowed", so the snapshot is unusable.
     In 20 of 20 random kills during a hash-heavy loop, this is what happened.
   - If the phtc is discarded, the update's "page unchanged → mark clean and up" shortcut (`hash-tree.cpp:334-341`)
     skips recomputing dense interior nodes whose leaves the crashed process had already written. The root hash then
     stays stale (the hash of the previous update) while `cm_verify_hash_tree` returns true.
   - If the kill lands after the page phase, the stale-root outcome may also happen without any manual step. It is rare
     in my runs.
4. *kill -9 during `cm_run` with sharing=all (observation, outside the original claim).*
   - The tree stays consistent with the data, but the stored state is torn. The registers come from the last `cm_run`
     return, while memory reflects the moment of the kill. For example, mcycle=120000002 is stored while the guest
     counter matches about 137M cycles.
   - The reloaded machine is a state that never existed, and this cannot be detected. The docs only warn about host
     crashes and durability (`sync`).

**Impact.**
- The cases are:
  - an in-memory machine with a data drive whose hash-tree files are persisted (A);
  - the `--create` + `sharing:config` template workflow (B);
  - `store(CONFIG)` (C);
  - a crash while running in `sharing=config` (B under kill -9, every time).
- In all of these, the emulator itself produces a machine directory or tree files whose reported root hash does not
  match the contents. No attacker or disk corruption is involved.
- Consequences:
  - `cm_get_root_hash`, `cartesi-machine-stored-hash` and `--initial-hash` report a hash that corresponds to no real state.
  - Untouched stale pages stay stale in later hashes, so the node publishes wrong claims.
  - `cm_log_step` then fails with "initial root hash mismatch" (shown by the hunter's p2), so the node cannot produce proofs.
- For an honest PRT node using these modes, that means losing disputes with no warning.
- The standard path (store with `sharing=all`/`none`, clean exit, load) is consistent. With Linux guests, the pending-mark
  window is small.
- The tampering-only aspect is a documented trade-off that needs write access to the snapshot directory. On its own I
  would rate it Low/Medium, plus "add an opt-in verify-on-load".

**Severity: High.** The severity guide puts "state silently … corrupted (store/load …), wrong hashes/proofs returned by
the API" at High, and that is what happens here, without tampering, in documented workflows. It is not Critical:
- the default `sharing=all`/`none` flows are consistent on clean exit;
- the affected modes (`config`, persisted per-drive trees, `store(CONFIG)`, crashes) are less common in node deployments.

**Fix assessment.**
- The hunter's options are (a) recompute and compare on load, or (b) force everything dirty. Either fixes only the trust
  question, at a full rebuild cost per load.
- For the non-tampering cases, a cheap fix is to flush pending write-TLB marks before the dpt is persisted or closed:
  - call `mark_write_tlb_dirty_pages()` at the start of `machine::store()`;
  - call it in `~machine()`, best-effort inside try/catch.
- I applied both in `<SCRATCH>/verify/verify-capi/fix/src/machine.cpp` and rebuilt. Scenarios A, B and C and the Linux
  reproducer now pass:
  - `c3/run.sh <fix>/src` → `OK`;
  - `FIXED_SO_DIR=<fix>/src cli2/run.sh` → the persisted hash equals the rebuilt hash, `0x4a471a9d…`.
- That fix does not cover crashes. For robustness against crashes with shared dpt files, these are also needed:
  - mark write-TLB pages dirty when the slot is filled, not only on eviction, whenever the target range's dpt is shared;
  - make phtc "borrowed" flags harmless after reload (clear the cache on load);
  - do not take the "unchanged leaf → clean" shortcut when the leaf was dirty in a persisted dpt.
- An opt-in verify-on-load restores the v0.19 safety net for snapshots from untrusted sources. For example, rebuild the
  sparse root from the data, or bring back `skip_root_hash_check` semantics inverted.
- None of these change the root hash of any honest state, so there is no on-chain or step-verifier impact.

### capi-storeload-4: `std::bit_ceil` UB on lengths > 2^63 in `adjust_defaults()`/`adjust_starts()`
- **Verdict:** PARTIALLY CONFIRMED.
  - The precondition violation is real. `src/machine-config.cpp:198` (`adjust_starts`) and `:233` (`adjust_defaults`)
    call `std::bit_ceil` before any length validation, and only `hash_tree::check_address_ranges` guards it
    (`hash-tree.cpp:987`).
  - It crashes only on builds that define `_GLIBCXX_ASSERTIONS`.
- **Independent reproducer:** `<SCRATCH>/verify/verify-capi/c4/run.sh [libdir]`. It runs three configs (flash 2^63+4096,
  nvram 2^64-4096, RAM 2^64-4096) in forked children, plus a standalone `std::bit_ceil` probe built with release flags
  and with hardened flags.
  - On the hardened build (`<SCRATCH>/asan/src`): `Assertion '__shift_exponent != __int_traits<_Tp>::__digits' failed`,
    the child is killed by signal 6, and the script prints `BUG REPRODUCED`.
  - On the default release (relwithdebinfo) build:
    ```
    std::bit_ceil(0x8000000000001000) = 0x1
    -> -1: unable to map memory: Cannot allocate memory when initializing flash drive 0
    -> -1: 0x80001000:0xfffffffffffff000 is out of bounds when initializing nvram 0 ...
    -> -1: 0x80000000:0xfffffffffffff000 is out of bounds when initializing RAM ...
    OK: all invalid lengths rejected with an error
    ```
- **What the release build does:** I read the disassembly of `machine-config.o`. `bit_ceil` compiles to `bsr(x-1)+1; shl %cl`
  with a count of 64. x86 masks that count to 0, so the result is 1.
  - `adjust_starts` was optimised to `start & (po2-1)`, which is a no-op for po2=1. There is no division by zero.
  - The invalid range is then rejected cleanly by the `address_range` checks, the mmap, or the 56-bit checks.
  - So the release build shows no observable misbehaviour. ARM64 `lsl` with a register count also masks modulo 64.
- **Severity: Low.** I downgraded it from Medium.
  - The input is a trusted machine config.
  - The release builds the project ships are unaffected.
  - The abort happens only in debug, sanitize and fuzz builds, or in distribution builds that add `-D_GLIBCXX_ASSERTIONS`.
- **Fix assessment:** Reject `length > 2^63` before calling `bit_ceil`. This is correct and has no hash impact. I validated
  it in `fix/` (`length of flash drive 0 is too large`, `RAM length is too large`).

### capi-storeload-5: `cm_translate_virtual_address()` writes through a NULL `paddr`
- **Verdict:** CONFIRMED.
- **Independent reproducer:** `<SCRATCH>/verify/verify-capi/c5/run.sh`. It uses fork + waitpid instead of a signal
  handler, and compares against `cm_read_reg`:
  ```
  cm_read_reg(..., NULL):                      returned -1 (invalid val output)
  cm_translate_virtual_address(0xdead0000, NULL) [bare mode]:  child killed by signal 11
  cm_translate_virtual_address(0x80000000, NULL):              child killed by signal 11
  BUG REPRODUCED: cm_translate_virtual_address dereferences a NULL paddr on success
  ```
- **Root cause:** `src/cm.cpp:1134-1137` writes `*paddr` without a NULL check. Note that with `satp=0` every address
  "translates", so any vaddr crashes.
- **Reachability:** The Lua binding (`clua-i-machine.cpp:1027`) and the JSON-RPC server handler always pass a valid
  pointer. Only C callers can pass NULL.
- **Severity: Low.** I agree with the hunter.
- **Fix assessment:** The `invalid_argument` check is correct. I validated it in `fix/`: the call now returns
  `-1 (invalid paddr output)`.

---

## Fixed build used for validation
- **Location:** `<SCRATCH>/verify/verify-capi/fix/`. It is a copy of the repo (release objects reused) with these patches:
  - `src/local-machine.cpp`: issues -1 and -2;
  - `src/cm.cpp`: issue -5;
  - `src/machine-config.cpp`: issue -4;
  - `src/machine.cpp`: issue -3, by calling `mark_write_tlb_dirty_pages()` in `store()` and in `~machine()`.
- **Rebuild:** `nice -n 10 make -j2 libcartesi.so cartesi.so`.
- **Results:** all of my reproducers exit 0 against it.
  - Run C reproducers with `run.sh <fix>/src`, without `LD_LIBRARY_PATH` set, because the env's `LD_LIBRARY_PATH`
    overrides RUNPATH.
  - Run Lua reproducers with `LUA_CPATH_5_4="<fix>/src/?.so;;"`.
