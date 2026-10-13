# Angle `gaps`: completeness critic (coverage map, under-audited areas)

Work dir: `<SCRATCH>/work/gaps/` (`<SCRATCH>` = `<SCRATCH>`).
No fuzzing was run. All reproducers are single-command `run.sh` scripts.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| GAPS-1 | A dirty-page tree with "clean" marks is trusted over a dense hash tree that was never computed (`dht_filename` omitted while `dpt_filename` is given, or a missing `.dht` silently recreated as zeros). The root hash then ignores the memory contents entirely; the CLI prints a wrong template hash | PROVEN (fix validated, no root-hash change) | Medium |
| GAPS-2 | `cartesi.evmu.decode_calldata` rejects valid calldata (that `evmu` itself encodes) when an empty dynamic array has dynamic elements (`bytes[]`, `string[]`, `(uint256,bytes)[]`) | PROVEN | Low |
| GAPS-3 | A read-only flash drive whose image is shorter than the drive (page-aligned) is refused with "possible non zero partial page"; the writable equivalent is accepted | PROVEN | Low |

Negative results for the three chosen areas are at the end. No duplicate of any `BUGS.md` entry or `findings/*.md` item:
GAPS-1 is related to the CM-06 family ("persisted hash-tree files are trusted") but has a different trigger and code
location: the emulator itself fabricates the inconsistent dht/dpt pair, with no tampering, no crash, and no
write-TLB involvement, through a documented option combination.

---

## 1. Coverage map

Method: for each tracked source file in `src/` and `uarch/` (excluding `third-party` and generated files), I counted how
often each report names it (`findings/*.md` and `tests/bugs/reports/verifiers/*.md`; raw per-file table with report
names in `<SCRATCH>/work/gaps/coverage_raw.txt`). I then read the scope sections and negative results of every report
to judge depth: *deep* means a dedicated angle plus execution evidence, usually re-verified; *moderate* means one angle,
or behavioural evidence only; *shallow* means only incidental mentions or a review sentence.

| Depth | Files / areas | Audited by |
|---|---|---|
| Deep | `interpret.cpp`, `soft-float.hpp`, `riscv-warl.hpp`, `translate-virtual-address.hpp`, `shadow-tlb.hpp`, `find-pma.hpp` | interp-isa, interp-priv, fp, mmu-tlb, dynamic, portability, devices2, arm64 |
| Deep | `uarch-step.cpp`, `uarch-solidity-compat.hpp`, `uarch-reset-state.cpp`, `uarch-*-state-access.hpp` | uarch, uarch-isa, asserts, sol-transpile-equiv, sol-proof-codec, sol-onchain-impact |
| Deep | `hash-tree.cpp`, `page-hash-tree-cache.hpp`, `hash-tree-proof.hpp`, `access-log.hpp`, `record/replay-step-state-access.hpp`, `record/replay-send-cmio-state-access.hpp`, `send-cmio-response.cpp` | hash-tree, step-proof, concurrency, rollup-flow, sol-proof-codec |
| Deep | `machine.cpp` (run, log/verify, collectors, store/load), `cm.cpp`, `local-machine.cpp` | nearly every angle |
| Deep | `jsonrpc-remote-machine.cpp`, `jsonrpc-machine.cpp`, `cm-jsonrpc.cpp` | jsonrpc, concurrency, lua-lifecycle |
| Deep | `json-util.cpp` (numbers, configs, access logs, bundles) | fp, sol-proof-codec, dtb-config, capi-storeload, arm64 |
| Deep | `dtb.cpp`, `fdt-builder.hpp`, `machine-config.cpp` | dtb-config |
| Deep | `htif/clint/plic-address-range.cpp`, `device-state-access.hpp`, CMIO | devices, devices2 |
| Deep | `cartesi-machine.lua`, `clua-i-machine.cpp`, `clua-cartesi.cpp`, `cartesi/hash-tree.lua`, `cartesi/gdbstub.lua` | cli-lua, cli-hashes, lua-lifecycle |
| Moderate | `collect-mcycle-hashes-state-access.hpp`, `collect-uarch-cycle-hashes-state-access.hpp`, `back-merkle-tree.*` | behavioural only (hash-tree, cli-hashes, rollup-flow) |
| Moderate | `dirty-page-tree.hpp`, `dense-hash-tree.hpp` | hash-tree, concurrency (crash consistency, sharing modes) |
| Moderate | `machine-address-ranges.cpp` (replace, PMA/hash-tree registration) | mmu-tlb, hash-tree, capi-storeload |
| Moderate | `virtio-address-range.cpp`, `machine-console.cpp` | devices (descriptor loop, bounds review), repro-guards |
| Shallow | **Hash primitives**: `keccak-256-hasher.cpp`, `sha-256-hasher.cpp`, `simd-hasher.hpp`, `keccakf.hpp`, `i-hasher.hpp`, `is-pristine.cpp` (0 named mentions) | indirect only: `cm_get_hash` for 0..1100 bytes; tree hashing on one AVX-512 host; arm64 NEON |
| Shallow | **Per-range hash-tree files and backing-store modes**: `memory-address-range.cpp`, `prepare_ar_backing_store*` (`machine-address-ranges.cpp:157-224`), `i-dirty-page-tree.hpp`, `i-dense-hash-tree.hpp` (0); `os-filesystem.cpp`, `os-mapped-memory.cpp` (1 angle); `machine::clone_stored/rename_stored/remove_stored/sync_stored` (no angle executed them) | capi-storeload (size checks, path handling review) |
| Shallow | **uarch-side runtime**: `uarch/uarch-bridge-state-access.hpp` (1), `uarch-runtime.cpp` (0), `uarch-ecall.c` (0), `uarch-run.cpp` (incidental), `mock-address-range.hpp` (incidental) | behaviourally covered by the cm_run-vs-uarch differentials, never reviewed as code |
| Shallow | `virtio-p9fs-address-range.cpp` (2414 lines; only symlink containment plus 2 notes, and the hunter lost shell access), `virtio-net-user/tuntap-*.cpp` (0 named; one review sentence), `virtio-console-address-range.cpp` (1) | devices |
| None | `cartesi/evmu.lua` (831 lines, shipped Lua module used by the rollup recipes), `cartesi/bash.lua`, `cartesi/util.lua` (1), `os.cpp` (2), `rng-seed.hpp` (a constant) | - |

## 2. Areas chosen and why

1. **Per-range hash-tree files, backing-store modes and stored-machine lifecycle (persisted state).** Since v0.22 the
   root hash is read back from persisted `.dht/.dpt/.sht/.phtc` files. Other angles studied what *store/load* writes
   (CM-06, CM-08, CM-22), but not how a range's `dht`/`dpt` pair is created and combined from the documented
   `backing_store` options, nor the clone/rename/remove/sync operations that the CLI's stored revert mode and node
   snapshot flows use. The defect found here is GAPS-1, plus GAPS-3 (Low).
2. **Hash primitives (Keccak-256/SHA-256 SIMD hashers, `is_pristine`).** They underlie every hash and proof but no
   report reviewed them. On x86-64 only the runtime-dispatched variant of this AVX-512 host had ever run, so the
   generic and AVX2 variants used by other node hosts had never been compared directly. No defect was found.
3. **Execution-path accessor parity, including the uarch-side runtime** (`uarch-bridge-state-access.hpp`,
   `uarch-runtime.cpp`, `uarch-run.cpp`, `uarch-ecall.c`, `mock-address-range.hpp`, `collect-mcycle-hashes-state-access.hpp`).
   This code is compiled into the uarch image or produces PRT commitments, so any divergence is Critical. It had wide
   behavioural coverage but no code review. Code review found no defect.

Opportunistic: `cartesi/evmu.lua` had no coverage at all; differential testing found GAPS-2 (Low). I also reviewed part of
`virtio-p9fs` (see the remaining gaps).

---

## 3. Findings

### GAPS-1: A stale dirty-page tree is trusted over a never-computed (zeroed) dense hash tree: the root hash ignores the memory contents
- Status: PROVEN (release build, ASan build and plain CLI; the fix is validated in a private build)
- Area: hash-tree / store-load / backing stores
- Category: wrong root hash (state not committed by the root hash), data integrity
- Where:
  - `src/memory-address-range.cpp:62-76` (constructor): `m_dpt` is mapped from `dpt_filename` whenever it is given,
    while `m_dht` is anonymous (zero-filled) when `dht_filename` is empty. Nothing checks that the pair is consistent.
  - `src/machine-address-ranges.cpp:172-182` (`prepare_ar_backing_store`): a missing `.dht` file is recreated
    zero-filled ("Create dht storage only if needed"), but an existing `.dpt` is kept with its clean marks.
  - `src/machine-address-ranges.cpp:207-221` (`prepare_ar_backing_store_for_share`, create-with-directory): the `.dht`
    and `.dpt` are copied or recreated independently, with the same result.
- Problem: the dirty-page tree says which pages' hashes in the dense hash tree (dht) are up to date. If a `.dpt`
  persisted from an earlier session (pages marked clean) is combined with a dht that was never computed (all-zero),
  `update_hash_tree()` rehashes nothing and uses zeroed page hashes. The resulting root hash does not depend on the range
  contents: two drives with different data give the same root hash (`d847bc04…` in the test), `cm_get_proof` and word
  proofs are wrong, and `cm_verify_hash_tree` returns false, but nothing calls it. There is no error. The
  asymmetric case is handled correctly: a missing `.dpt` with an existing `.dht` gets a fresh all-dirty dpt and the
  hash is correct. Loading a stored machine with a missing `.dht` is *refused* under `CM_SHARING_NONE`/`CONFIG`
  ("unable to open backing file … .dht") but *silently accepted with a wrong root hash* under `CM_SHARING_ALL`, which is
  the reference node's mode.
- Scenario:
  - A developer follows the CLI help, which says for `dht_filename` "when omitted or set to the empty, the hash tree
    will be built from scratch". The developer uses a shared data drive with only a dirty-page tree file:
    `--flash-drive=label:data,data_filename:drive.bin,shared,dpt_filename:drive.dpt`. The first session writes the
    drive and computes a hash. In every later session with the same options, `--initial-hash` prints a template hash
    that does not commit to the drive (`0xb787d6da…` instead of `0x6aab2fbd…` for identical contents). If that hash is
    registered on chain, nobody can prove any state from it, and honest uarch/CMIO step logs fail on the wrong word
    proofs.
  - An operator deletes the `.dht` files of a stored or on-disk machine to "force a rehash" (they look like caches), or
    a partial restore loses one. The next `SHARING_ALL` load publishes commitments for a root hash that does not match
    the machine.
- Evidence: `<SCRATCH>/work/gaps/dht-missing/run.sh` (C API, about 1 s; `LIBDIR=<dir>` selects another build) and
  `run_cli.sh` (plain CLI, boots the test Linux image twice):
  ```
  (1) shared drive, dpt_filename given, dht_filename omitted
    session 1 root hash                                        55d5bce2d5152fc1
    session 2 root hash (same config, same files)              d847bc04edbc3346
    reference: identical drive contents, no hash-tree files    55d5bce2d5152fc1
    => WRONG ROOT HASH (cm_verify_hash_tree in session 2: false)
  (2) shared drive with dht+dpt files, .dht deleted between sessions
    ... session 2 root hash d847bc04edbc3346, reference 55d5bce2d5152fc1 => WRONG ROOT HASH
  (3) repeat (1) with different drive contents
    session 2 root hash, contents A                            d847bc04edbc3346
    session 2 root hash, contents B                            d847bc04edbc3346
    => different drive contents, identical root hash
  (4) stored machine with the RAM .dht file missing
    root hash when stored                                      3fce5cb72572310b
    sharing 0: load refused (unable to open backing file 'S2/0000000080000000-10000.dht': ...)
    sharing 1: load refused (...)
    sharing 2: loaded root hash                                f3add8783f58391b
    => WRONG ROOT HASH
  BUG REPRODUCED: 4 case(s) ...                                (exit 1)

  $ ./run_cli.sh
  session 2 initial hash : 0: 0xb787d6daab045e49d332fec25da39ab047501df415da9d4e4e1eeda93c8e2169
  reference initial hash : 0: 0x6aab2fbda3ec026db629dd9fa7b79bbe029595c8feada18a37dccf3e3a811848
  BUG REPRODUCED: CLI initial hash does not commit to the shared drive contents
  ```
  The unpatched ASan build reproduces all 4 cases with no sanitizer report.
- Possible solution (validated): a dense hash tree whose root node is all-zero has never been computed, because a
  Keccak/SHA-256 node is never zero. In that case the dirty-page tree must not claim any page clean. In the
  `memory_address_range` constructor (`<SCRATCH>/work/gaps/fixbuild/fix.diff`):
  ```cpp
  if (std::ranges::all_of(m_dht.root_hash_view(), [](unsigned char b) { return b == 0; })) {
      m_dpt.mark_dirty_pages_and_up(0, length);
  }
  ```
  This one check covers all triggers: an omitted `dht_filename`, a recreated `.dht`, and create-with-directory copies.
  `fixbuild/build.sh` relinks the ASan library with the patched object, and `LIBDIR=<fixbuild>/src ../dht-missing/run.sh`
  then prints `OK` in all 4 cases. With the patch, the Linux template root hash and the hash after 2M cycles are
  unchanged (`d2ffcada…`, `00fc59fe…`), and the lifecycle suite below still passes. For defence in depth, optionally
  make `prepare_ar_backing_store` (re)create the `.dpt` whenever it (re)creates the `.dht`, and correct the CLI help
  text.
- Severity: Medium. Silent wrong root and template hashes and wrong proofs, through a documented option combination or
  the loss of one cache-like file, with no error, and in the reference `SHARING_ALL` load path. Not High because it
  needs a non-default configuration or a missing file, and `cm_verify_hash_tree` detects it. Treat it as High where
  templates are built with per-drive `dpt_filename` without `dht_filename`.
- Risks: if left unfixed, commitments and template hashes can be published that the machine cannot prove. The fix
  changes no valid root hash. Its only cost is a full rehash of a range whose dht is uninitialized, which happens
  anyway when both files are fresh.

### GAPS-2: `evmu.decode_calldata` rejects empty dynamic arrays of dynamic elements
- Status: PROVEN
- Area: Lua library (`src/cartesi/evmu.lua`, shipped as `cartesi.evmu`, used by the `doc/recipes` rollup tooling)
- Category: input-validation (fails closed)
- Where: `decode_array` (`src/cartesi/evmu.lua:717-749`): in the dynamic-element branch, `last_offset` is only set inside
  the element loop, so for `size == 0` it returns `nil` as the end offset. `decode_tuple` propagates it and
  `decode_calldata` fails at `:821` ("calldata too long").
- Problem: valid ABI calldata, including calldata `evmu.encode_calldata` produced itself, is rejected for
  `f(bytes[])` with `[]`, `f(string[],uint256)` with `([],5)`, and `f((uint256,bytes)[])` with `[]`. It works when the
  empty array is followed by another dynamic value, or when the elements are static.
- Scenario: tooling that decodes application outputs or inputs that carry an empty `bytes[]`/`string[]` gets an error
  instead of the value. The rollup output formats (`Voucher`, `Notice`, `DelegateCallVoucher`, `EvmAdvance`) have no
  arrays, so the official recipes are not affected.
- Evidence: `<SCRATCH>/work/gaps/evmu/run.sh`:
  ```
  f(bytes[])                   encoded  68 bytes, decode: ERROR .../evmu.lua:821: calldata too long
  f(string[],uint256)          encoded 100 bytes, decode: ERROR .../evmu.lua:821: calldata too long
  f((uint256,bytes)[])         encoded  68 bytes, decode: ERROR .../evmu.lua:821: calldata too long
  BUG REPRODUCED: 3 valid encodings rejected by evmu.decode_calldata      (exit 1)
  ```
- Possible solution: initialise `local last_offset = new_offset + size * 32` before the loop, which is the end of the
  offsets area and therefore correct for `size == 0`.
- Severity: Low. It fails closed in tooling only.
- Risks: none. It is a Lua-only change.

### GAPS-3: Read-only flash drive with a shorter, page-aligned image is refused
- Status: PROVEN
- Area: store-load / backing stores (`src/os-mapped-memory.cpp:217-226`)
- Category: input-validation (fails closed)
- Problem: `partial_page_remaining = min(page_size - backing_file_length % page_size, …)` equals a whole page when the
  file length is page-aligned, so the read-only branch throws "possible non zero partial page" although no partial page
  exists. The writable, non-shared equivalent is accepted (the memset hits anonymous zero memory).
- Evidence: `<SCRATCH>/work/gaps/ro-short/run.sh`: `read_only=false created` / `read_only=true refused: possible non
  zero partial page …` / `BUG REPRODUCED` (exit 1).
- Possible solution: `partial_page_remaining = partial_page_size != 0 ? std::min(page_size - partial_page_size, length - backing_file_length) : 0;`
- Severity: Low. The CLI requires the image size to equal the drive length, so only C-API configurations are affected,
  and the failure is a clear error with no state change.

---

## 4. Negative results (chosen areas)

- **Stored-machine lifecycle** (`<SCRATCH>/work/gaps/life/run.sh`, exit 0). The test uses a RAM with a guest store loop,
  a read-only flash drive (exercising the hardlink path of `clone_stored`), and a writable NVRAM written through the
  API. Each check below compares root hashes, and some also run `cm_verify_hash_tree`. All passed:
  - store(ALL), then load with NONE/CONFIG/ALL.
  - `clone_stored`, then load, then run the clone on disk with SHARING_ALL. The source is unaffected (reflink and
    hardlink isolation), and the clone equals an in-memory replay from an independent copy.
  - `rename_stored` plus `sync_stored`, then load. The old directory is gone.
  - Clone, `remove_stored` of the source, then the clone still loads (hardlinked read-only files survive).
  - Create-with-directory, run, destroy, then reload.
  - Zero-filling every `.dht/.dpt/.sht/.phtc` of a clone, then load. The rehash from scratch gives the same hash.
  - `store(NONE)` and `store(CONFIG)` give the documented initial state.
  - A missing `.dpt`, `.sht` or `.phtc` is handled safely: recreated as all-dirty, or refused (only a missing `.dht`
    misbehaves: GAPS-1).
- **OS file layer, by code review** (`os-filesystem.cpp`). `create_file`/`copy_file` handle short writes and sparse
  holes (`SEEK_DATA`), and `clone_file` falls back to a copy on ENOTSUP/EXDEV/EPERM. Every created file uses
  `O_EXCL` and a lock. No defect.
- **Hash primitives** (`<SCRATCH>/work/gaps/hash/run.sh`, exit 0). Four builds were compared: the shipped
  multiversioned `libcartesi.a`, plus `NO_MULTIVERSIONING` generic SSE2, AVX2 and AVX-512 builds of
  `keccak-256-hasher.cpp`/`sha-256-hasher.cpp`/`is-pristine.cpp`. They produce byte-identical digests. The test covers:
  - data hashes of lengths 0..600 plus 1K/4K±1/64K±1/1M at aligned and unaligned offsets;
  - 400 random two-span concatenations against the hash of the concatenated buffer;
  - word lanes 1x1/2/4/8/16 and node lanes 2x1/2/4/8/16 against the 1x1 path, 200 rounds each;
  - 64-byte data hashes against the 2x1 node hash.

  All 2432 data vectors equal Python `hashlib.sha256` and an independent Keccak-256 (Keccak up to 8 KiB). `is_pristine`
  was checked on all lengths, offsets and single-byte positions, plus a byte just past the end; no defect.
- **Accessor parity, uarch-side runtime, by code review.** Checked:
  - `do_read_pma` out-of-range sentinels: identical in record, replay and bridge; the collector's `assert(index < PMA_MAX)`
    is unreachable because a reproducible machine has at most 24 PMAs and PMA_MAX is 32.
  - The bridge always returns `false` from `do_putchar`; the console-break semantics were already shown equal by
    devices2 and hash-tree.
  - `ua_*_ECALL` inline asm: the clobbers exclude input registers.
  - The uarch `memcpy`/`memmove`/`memset` are correct.
  - The `static mock_address_ranges` in `uarch-run.cpp` is re-zeroed by every uarch reset, including the collector's
    partial reset, because the words it writes are reset.
  - `make_mock_address_range` covers every reproducible device DID.
  - The collector marks all registers on the `mcycle` write and the shadow-TLB page on TLB writes.

  No new divergence; the known PMA-content divergence is CM-23.
- **evmu encoder** (`<SCRATCH>/work/gaps/evmu/run.sh`). Eleven signatures were encoded identically by `evmu` and an
  independent Python ABI encoder: EvmAdvance with payload lengths 0, 1 and 33, Voucher, Notice, DelegateCallVoucher,
  small and negative ints, `bytesN`, nested tuple/array combinations. The selectors match the known values
  (`0x415bf363`, `0x237a816f`, `0xc258d6e5`, `0x10321e8b`).

## 5. Remaining gaps (not audited here)

- `virtio-p9fs-address-range.cpp` / `virtio-net-*`: host-side code that guest-supplied messages reach (development /
  unreproducible mode only). I reviewed only the request decoder (`virtio-serializer.hpp`: every string read is bounded
  by `len + 1 <= N`, and every descriptor read and write goes through `read/write_desc_mem`) and `op_readlink`/`op_readdir`.
  One functional Low note: in `op_readdir` (`:1845`), `first_entry` compares the *request* offset `msg.offset` instead of
  `out_msg.offset`, so errors on the first directory entry return an empty listing instead of an error. A
  sanitizer-backed robustness pass over the remaining ~40 9P handlers is still outstanding.
- `jsonrpc-machine.cpp` response parsing is trusted by design (the client spawns its own server). `cartesi/bash.lua` and
  `cartesi/util.lua` have no security relevance.

## Files
- `<SCRATCH>/work/gaps/coverage_raw.txt`: per-file mention counts with report names.
- `<SCRATCH>/work/gaps/dht-missing/{repro.c,run.sh,run_cli.sh}`: GAPS-1.
- `<SCRATCH>/work/gaps/fixbuild/{fix.diff,build.sh}`: GAPS-1 fix validation (rebuilds a private ASan library from `<SCRATCH>/asan/src/libcartesi.a`).
- `<SCRATCH>/work/gaps/evmu/{run.sh,rt.lua,enc.lua,abi.py,cases.json}`: GAPS-2 and the encoder differential.
- `<SCRATCH>/work/gaps/ro-short/run.sh`: GAPS-3.
- `<SCRATCH>/work/gaps/life/{life.c,run.sh}`: stored-machine lifecycle (negative).
- `<SCRATCH>/work/gaps/hash/{hh.cpp,build.sh,ref.py,run.sh}`: hasher differential (negative).
