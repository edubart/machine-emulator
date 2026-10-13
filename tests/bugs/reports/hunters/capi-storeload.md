# Angle: capi-storeload (public C API & machine lifecycle)

Scope: `src/cm.cpp`, `cm.h`, `local-machine.cpp/.hpp`, `i-machine.hpp`, `machine.cpp`
(create/load/store/clone/replace/read-write/registers/destroy), `machine-config.cpp`,
`machine-address-ranges.cpp`, `memory-address-range.cpp`, `os-mapped-memory.cpp`,
`os-filesystem.cpp`, `json-util.cpp`, `dtb.cpp`, `fdt-builder.hpp`.

`<SCRATCH>` = `<SCRATCH>`
PoCs: `<SCRATCH>/work/capi-storeload/`

## Summary
| ID | Title | Status | Severity |
|----|-------|--------|----------|
| capi-storeload-1 | `cm_log_step()` on an empty machine object dereferences NULL (SIGSEGV) | PROVEN | Medium |
| capi-storeload-2 | `cm_create()`/`cm_load()` on a non-empty object silently leak the existing instance (fds/mmaps/exclusive file locks) | PROVEN | Medium |
| capi-storeload-3 | `cm_load()` trusts the persisted hash tree; a tampered/corrupted/truncated store loads and reports a stale root hash inconsistent with its contents | PROVEN | Medium |
| capi-storeload-4 | `std::bit_ceil` UB on unvalidated `ram`/`flash`/`nvram` length in `adjust_defaults()` → abort (DoS) from a single `cm_create`/`cm_load` with untrusted config | PROVEN | Medium |
| capi-storeload-5 | `cm_translate_virtual_address()` writes through `paddr` with no NULL check (NULL-pointer write) | PROVEN | Low |
| capi-storeload-6 | `cm_replace_memory_range()` leaves stale host pointers in the hot TLB | PROVEN (DUPLICATE of mmu-tlb-1) | — |

Store/load fidelity was also stress-tested (sharing none/all, halted machines, mid-uarch, on-disk run then
reload, flash+rootfs Linux boot to halt): no mismatch found — see `p4_fidelity/` (the one anomaly there
is the exclusive-lock behavior of capi-storeload-2, not a fidelity bug).

---

### capi-storeload-1: `cm_log_step()` on an empty machine object dereferences NULL (SIGSEGV)
- Status: PROVEN
- Area: C API / machine lifecycle
- Category: memory-safety, input-validation (DoS)
- Where: `src/local-machine.cpp:112-114` `local_machine::do_log_step`
  ```cpp
  interpreter_break_reason local_machine::do_log_step(uint64_t mcycle_count, const std::string &filename) {
      return m_machine->log_step(mcycle_count, filename);   // <-- raw m_machine, no null check
  }
  ```
- Problem: Every other `local_machine::do_*` method obtains the underlying machine via
  `get_machine()` (`src/local-machine.cpp:60-72`), which throws `std::runtime_error{"no machine"}`
  when `m_machine == nullptr` (the catch in `cm.cpp` then returns `CM_ERROR_RUNTIME` / sets the
  error message). `do_log_step` is the **only** method that dereferences `m_machine` directly. For
  an empty machine object — the state right after `cm_new()`, and also after `cm_destroy()` — this
  is a NULL-pointer dereference. `cm_log_step()` (`src/cm.cpp:861`) only null-checks `log_filename`
  and the machine pointer `m` (non-null object), not the inner instance, so it crashes the process.
- Scenario: A controller/node that calls `cm_log_step()` on a `cm_machine` object before
  `cm_create()`/`cm_load()`, or after `cm_destroy()` (e.g. an error path, or a step-logging service
  that resets then re-fills a machine object), gets a hard crash instead of the documented
  non-zero error code. `cm_log_step` is used by the dispute/step-proof machinery
  (`machine.log_step` is a JSON-RPC method and the basis of fraud-proof logs), so a crash here is a
  node-availability issue.
- Evidence: `<SCRATCH>/work/capi-storeload/p7_logstep/run.sh`
  ```
  cm_run on empty object: returned -6: no machine
  calling cm_log_step on empty object ...
  BUG REPRODUCED: SIGSEGV in cm_log_step on empty machine object (local_machine::do_log_step dereferences NULL m_machine)
  ```
  (Note `cm_run` on the same object returns the clean `-6 "no machine"`, proving the inconsistency.)
- Possible solution: use `get_machine()` like every other method:
  `return get_machine()->log_step(mcycle_count, filename);`.
- Severity: Medium — reproducible process crash reachable through the public C API on a valid object
  in a legitimate (empty) lifecycle state; DoS, not memory corruption.
- Risks: trivial fix, no behavior/hash change.

---

### capi-storeload-2: `cm_create()`/`cm_load()` on a non-empty object silently leak the existing instance
- Status: PROVEN
- Area: C API / machine lifecycle
- Category: data-loss, resource-leak (fds / mmaps / exclusive backing-file locks)
- Where: `src/local-machine.cpp:46-53` (`do_create`/`do_load`) and `src/cm.cpp:605-634`
  (`cm_create`/`cm_load`)
  ```cpp
  void local_machine::do_create(const machine_config &config, ...) {
      m_machine = new machine(config, runtime, dir);   // overwrites previous pointer; old machine leaked
  }
  void local_machine::do_load(const std::string &directory, ...) {
      m_machine = new machine(directory, runtime, sharing);   // same
  }
  ```
- Problem: Neither `cm_create`/`cm_load` nor `local_machine::do_create/do_load` checks that the
  object is empty before allocating a new `machine`. If the object already holds an instance, the
  pointer is overwritten and the previous `machine` is never `delete`d. The leaked instance keeps
  its `os::mapped_memory` mappings, open file descriptors and — critically — the **exclusive
  `flock`** it holds on every shared backing store (`os-mapped-memory.cpp:126-130`,
  `LOCK_EX|LOCK_NB`). The JSON-RPC server guards exactly this: `jsonrpc_machine_create_handler`
  / `jsonrpc_machine_load_handler` return `"machine exists"` when `session->handler->machine` is
  set (`src/jsonrpc-remote-machine.cpp:907-940`). The local implementation has no equivalent guard,
  so the two transports disagree, and a subsequent `cm_destroy()` only frees the second (visible)
  instance.
- Scenario: A long-running node that reuses a `cm_machine` object (common: `cm_new` once, then
  `cm_create`/`cm_destroy` per request) and accidentally calls `cm_create`/`cm_load` twice without
  an intervening `cm_destroy` will (a) silently discard the in-progress machine and all its unsaved
  work, and (b) permanently leak its fds/memory and hold the exclusive lock on any shared store,
  so that store can never be reopened for the lifetime of the process. Over many requests this is
  an fd/memory exhaustion and lock-starvation DoS.
- Evidence: `<SCRATCH>/work/capi-storeload/p3_api_misc/run_leak.sh`
  ```
  second cm_create on non-empty object returned 0 (expected an error)
  re-opening shared flash after destroy+delete returned -1: unable to lock backing file 'shared-flash.bin': Resource temporarily unavailable when initializing flash drive 0
  BUG REPRODUCED: leaked machine instance still holds the flash-drive lock/mapping
  ```
- Possible solution: in `do_create`/`do_load` (or in `cm_create`/`cm_load`), reject when
  `!is_empty()`: `if (m_machine != nullptr) throw std::runtime_error{"machine exists"};`, matching
  the JSON-RPC behavior.
- Severity: Medium — silent data-loss of an in-progress machine plus an fd/memory/lock leak reachable
  by ordinary API misuse; does not corrupt memory.
- Risks: fix changes an error that currently "succeeds" into a failure; callers relying on the
  accidental overwrite would need `cm_destroy` first (which is the documented contract anyway).

---

### capi-storeload-3: `cm_load()` trusts the persisted hash tree; a tampered/corrupted store loads with a stale root hash
- Status: PROVEN
- Area: store-load / hash-tree
- Category: proof-soundness / data-integrity (silent)
- Where: `src/machine.cpp:334-336` (`machine(dir,…)` → `machine_config::load`), the hash-tree load
  path `src/hash-tree.cpp:950-977` (maps the persisted `.sht`/`.phtc`), and the per-range
  `.dht`/`.dpt` mapping in `memory-address-range.cpp:60-75`. No step in `load` recomputes the hash
  tree from the backing-store data and compares it against the persisted tree.
- Problem: In v0.22 the Merkle tree is persisted (`.dht` dense hash trees, `.dpt` dirty-page trees,
  `.sht` sparse tree, `.phtc` page-hash cache) and simply mapped back in on load. The dirty-page
  trees are loaded as "all clean", so `update_hash_tree()` (`machine.cpp:1533`) does not rehash any
  page, and `get_root_hash()` returns the persisted root hash verbatim. The actual contents of the
  data `.bin` files are never checked against that hash on load. Consequently a stored directory
  whose data file was modified (malicious tampering, partial/interrupted store, bit-rot, or an
  out-of-band truncation — a short data file is accepted and zero-padded in sharing `none`/unshared
  via the `backing_gap` path in `os-mapped-memory.cpp:150-157`) loads successfully and reports the
  **original** root hash while its memory holds different bytes. The previous release recomputed and
  compared the root hash on load (see `doc/README.md`, "the root hash was computed from scratch and
  compared against what was stored"); that integrity check is gone.
- Scenario: A rollups node or validator that loads a machine snapshot from disk and trusts
  `cm_get_root_hash()` (e.g. to assert the loaded template matches an on-chain template hash) is
  fooled: the loaded machine advertises a hash that does not correspond to its real state. Running
  it then diverges from what the hash claims. `cm_verify_hash_tree()` would catch it, but nothing on
  the `load` path calls it (and it is documented as "for emulator internal tests" — `cm.h:1143`).
- Evidence: `<SCRATCH>/work/capi-storeload/p2_forged_cache/run.sh` — store a machine, flip one byte
  of the stored RAM `.bin`, reload:
  ```
  original root hash        : 5034ce1626b20c535fc7b48299b70fca5d488ccb74484b90bfd71468776956b8
  loaded (tampered) root hash: 5034ce1626b20c535fc7b48299b70fca5d488ccb74484b90bfd71468776956b8   <-- stale, == original
  loaded machine RAM[0x800] = 0x5a (tampered value)
  cm_verify_hash_tree on loaded machine: false                                                     <-- tree IS inconsistent
  true hash of tampered state : 806ea80205d2adc316dc5ea8959cee8417e4ec42ffc3ea56b6065c06dfa4804c   <-- what the hash should be
  BUG REPRODUCED: loaded machine reports the original root hash although its state was modified
  cm_log_step on loaded machine: ERROR: initial root hash mismatch
  ```
- Possible solution: on `cm_load`, after mapping, either (a) recompute the hash tree from the data
  and compare against the persisted sparse-tree root (restore the old behavior, optionally
  opt-out for trusted fast loads), or (b) force all dirty-page trees dirty so `get_root_hash()`
  rehashes, or (c) document loudly that a loaded hash is only trustworthy for stores the caller
  itself produced and expose a cheap "verify on load" flag.
- Severity: Medium — silent integrity failure on the load path (relevant to the financial threat
  model when snapshots come from an untrusted/corruptible source). Marked Medium rather than High
  because the stored artifacts are normally produced by the trusted emulator and tampering requires
  local file access; it is partly a documented performance tradeoff, but it removed a safety check
  with no replacement.
- Risks: adding recompute/verify on load has a performance cost (the reason it was removed); a
  verify-on-load flag avoids regressing the fast path.

---

### capi-storeload-4: `std::bit_ceil` UB on unvalidated config length → abort (DoS) from one `cm_create`/`cm_load`
- Status: PROVEN
- Area: config parsing / machine lifecycle
- Category: input-validation, DoS (abort on hardened builds), undefined-behavior
- Where: `src/machine-config.cpp` — `adjust_defaults()` (`auto ram_length_po2 = std::bit_ceil(ram.length);`,
  ~line 232) and `adjust_starts()` (`auto length_po2 = std::bit_ceil(mr.length);`, ~line 192).
  `adjust_defaults()` runs in the `machine` constructor (`machine.cpp:299`,
  `m_c{std::move(c).adjust_defaults()}`) for both `cm_create` and `cm_load`, **before** any
  length/overflow validation (the `address_range` 56-bit/overflow checks and
  `hash_tree::check_address_ranges`'s `length > 2^63` rejection run later).
- Problem: `std::bit_ceil(x)` is undefined when the next power of two is not representable in the
  type, i.e. for `x > 2^63`. The RAM/flash/NVRAM lengths come straight from untrusted JSON
  (`json-util.cpp` accepts any `uint64_t`, including values decoded from negative integers). No
  guard rejects `length > 2^63` before `bit_ceil` is evaluated. On the project's hardened builds
  (`debug`, `sanitize`, `fuzz` — all set `-D_GLIBCXX_ASSERTIONS`, see `src/Makefile:218-224`) this
  is a guaranteed `std::__bit_ceil` assertion failure → `abort()`, i.e. a single crafted config
  string crashes the process. On the default `relwithdebinfo`/`release` builds (no
  `_GLIBCXX_ASSERTIONS`) it is silent UB (here the downstream 56-bit addressability check happens to
  reject the result, but that is not guaranteed by the language).
- Scenario: Any component that instantiates a machine from a config it did not author (a
  configuration file, a `cm_load` of a store whose `config.json` was crafted, a fuzzing/testing
  harness built with the sanitizer/assertion flags) can be crashed with
  `{"ram":{"length":18446744073709551615}}` or a flash/nvram length `> 2^63`.
- Evidence: `<SCRATCH>/work/capi-storeload/p5_cfg/run_bitceil.sh` (links the ASan lib which has
  `_GLIBCXX_ASSERTIONS`):
  ```
  calling cm_create_new with ram.length=2^64-1 ...
  /usr/include/c++/14/bit:342: ... std::__bit_ceil ...: Assertion '__shift_exponent != __int_traits<_Tp>::__digits' failed.
  Aborted
  BUG REPRODUCED: cm_create aborted/crashed on untrusted ram.length (std::bit_ceil UB)
  ```
  Also seen via `<SCRATCH>/work/capi-storeload/p5_cfg/cfg_asan` for
  `{"ram":{"length":4096},"flash_drive":[{"length":9223372036854775809}]}` (hits `adjust_starts`'
  `bit_ceil`).
- Possible solution: validate `length <= (UINT64_C(1) << 63)` for RAM/flash/NVRAM before calling
  `std::bit_ceil` (or use a checked next-power-of-two helper that throws), reusing the same bound
  `hash_tree::check_address_ranges` already enforces later.
- Severity: Medium — DoS reachable from a single API call with untrusted config on the hardened
  builds used for testing/fuzzing/CI; UB on release builds. Not memory corruption on release.
- Risks: fix is a pure input-validation addition; no hash/behavior change for valid configs.

---

### capi-storeload-5: `cm_translate_virtual_address()` writes through `paddr` with no NULL check
- Status: PROVEN
- Area: C API
- Category: memory-safety (NULL-pointer write), input-validation
- Where: `src/cm.cpp:1134-1143`
  ```cpp
  cm_error cm_translate_virtual_address(cm_machine *m, uint64_t vaddr, uint64_t *paddr) try {
      auto *cpp_m = convert_from_c(m);
      *paddr = cpp_m->translate_virtual_address(vaddr);   // <-- no NULL check on success path
      return cm_result_success();
  } catch (...) {
      if (paddr != nullptr) { *paddr = 0; }               // only the error path checks for NULL
      return cm_result_failure();
  }
  ```
- Problem: On the success path `*paddr` is written unconditionally. Every other out-pointer API in
  `cm.cpp` (`cm_read_reg`, `cm_read_word`, `cm_get_root_hash`'s hash, `cm_read_console_output`'s
  `read_len`, etc.) validates the output pointer and throws `std::invalid_argument` when it is NULL.
  `cm_translate_virtual_address` does not, so passing `paddr == NULL` with a translatable address
  writes to address 0 (SIGSEGV; in other mappings, a controlled-address write).
- Scenario: A caller that only wants to probe whether an address is translatable (and passes
  `NULL`, mirroring the tolerant error path) crashes. Lower impact than the others because the
  caller supplies the bad pointer.
- Evidence: `<SCRATCH>/work/capi-storeload/p6_translate/run.sh`
  ```
  BUG REPRODUCED: NULL-pointer write in cm_translate_virtual_address (no NULL check on success path)
  ```
- Possible solution: add `if (paddr == nullptr) throw std::invalid_argument("invalid paddr output");`
  at the top, consistent with the rest of the API.
- Severity: Low — crash requires the caller to pass a NULL out-pointer; API-robustness inconsistency.
- Risks: trivial, no behavior change.

---

### capi-storeload-6: `cm_replace_memory_range()` leaves stale host pointers in the hot TLB (DUPLICATE)
- Status: PROVEN — but already reported as **mmu-tlb-1** (`<SCRATCH>/findings/mmu-tlb.md`), High.
- Area: C API / MMU-TLB
- Category: memory-safety (use-after-munmap), divergence
- Where: `src/machine.cpp:628-673` `machine::replace_memory_range` →
  `src/machine-address-ranges.cpp:636-656` `machine_address_ranges::replace` (swaps the
  `unique_ptr`, destroying/unmapping the old `memory_address_range`), with no hot-TLB flush /
  `init_hot_tlb_contents()`.
- Problem: After the machine has run (so the hot TLB `processor_state::penumbra.tlb` caches raw host
  `vh_offset` pointers into the replaced range's mapping), `replace_memory_range` frees that mapping
  but leaves the hot TLB pointing into it. The next `cm_run` dereferences the dangling pointer.
- Evidence (independent reproduction): `<SCRATCH>/work/capi-storeload/p1_replace_tlb/run.sh`
  ```
  before replace: value read by guest from flash = 0x0000000000000000
  after replace: flash word via API = 0x4242424242424242
  BUG REPRODUCED: SIGSEGV in cm_run after cm_replace_memory_range (stale hot TLB points to unmapped flash drive memory)
  ```
- Note: Reported here only to record an additional C-API reproducer; no severity change. See
  mmu-tlb-1 for the primary write-up and fix (flush/reinitialize the hot TLB in
  `replace_memory_range`).

---

## Areas checked and found OK (negative results, to save others time)
- Store/load fidelity for sharing none/all, halted and mid-uarch machines, on-disk run then reload,
  full Linux boot to halt: root hash and all registers matched (`p4_fidelity/run.sh`).
- `cm_read_memory` with `paddr+length` wraparound / spanning holes: handled by the pristine-gap
  walk in `machine::read_memory` (`machine.cpp:1655`).
- `cm_write_memory` to shadow/PMA/uarch/device/read-only ranges: correctly rejected or handled via
  the documented full-shadow-overwrite special case (which does call `init_hot_tlb_contents()`).
- `remove_stored`/`clone_stored`/`rename_stored` path handling: filenames are derived from the
  dir-adjusted config (`get_data_filename(dir, …)`), so no traversal/deletion outside the dir.
- `cm_store` into an existing directory: refused (`os::create_directory` uses `mkdir`, fails EEXIST).
- `cm_get_last_error_message` / temp-string lifetime: `THREAD_LOCAL`, documented as valid only until
  the next call — behaves as documented, not a bug.
- Wrong-size `.dht`/`.dpt` backing files on load: rejected by `os::mapped_memory` size checks
  (no OOB).
- `cm_write_reg` to read-only registers (`mvendorid`/`marchid`/`mimpid`/`x0`/`uarch_x0`): rejected.
  Writing out-of-spec values to WARL CSRs (iprv/satp/mstatus/iflags) via `cm_write_reg` stores the
  raw value; whether that causes an interpret-vs-uarch/on-chain divergence is out of this angle's
  scope (register/interpreter semantics) and is left to the interp-priv/uarch angles.
