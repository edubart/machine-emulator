# Verification report: `gaps` candidates (verifier `verify-gaps`)

`<SCRATCH>` = `<SCRATCH>`.
Work dir: `<SCRATCH>/verify/verify-gaps/`. No fuzzing. The repository was not modified.

| ID | Verdict | Hunter severity | My severity |
|----|---------|-----------------|-------------|
| GAPS-1 | CONFIRMED (and a 5th trigger, create-with-directory, plus permanence after a `SHARING_ALL` load) | Medium | **Medium** (upper end; High where templates are built with per-range `dpt_filename` and no `dht_filename`) |
| GAPS-2 | CONFIRMED | Low | **Low** |
| GAPS-3 | CONFIRMED | Low | **Low** |

---

### GAPS-1: a persisted dirty-page tree with clean marks is trusted over a dense hash tree that was never computed; the root hash does not commit to the range contents

- **Verdict: CONFIRMED.** I reproduced every claimed trigger with the hunter's PoCs (run from a clean copy) and with
  my own independent reproducer, which uses a different technique and a different API. I also found one more
  trigger, and showed that the damage becomes permanent once a `SHARING_ALL` load has run on the directory.
  The hunter's fix is validated: all cases pass, and no correct root hash changes.

- **Independent reproducer:** `<SCRATCH>/verify/verify-gaps/gaps1/run.sh` (Lua API, about 1 s) and
  `<SCRATCH>/verify/verify-gaps/gaps1/run_cli.sh` (plain CLI `--store`/`--load` flow, no guest execution, a few seconds).
  Technique: `run.sh` does not compare against a second machine. It computes the expected Merkle root of the drive
  directly from the bytes of its data file, using the shipped helper `cartesi.hash-tree.get_data_root_hash`. It then
  rolls that hash up through the machine's own `get_proof(drive_start, 16)` and compares the result with
  `get_root_hash()`. Output on the release build:
  ```
  [A] shared drive with dpt_filename and no dht_filename (CLI help: dht omitted => tree built from scratch)
    session 2, dpt only        drive node 0x0000000000000000 expected 0xdee09540108b8668 root 0xd847bc04edbc3346 => ROOT HASH DOES NOT COMMIT TO DRIVE DATA
  [A-control] same flow with both dht_filename and dpt_filename
    session 2, dht+dpt         drive node 0xdee09540108b8668 expected 0xdee09540108b8668 root 0xf85f92419a7bc6c8 => ok
  [B] create-with-directory from a config whose drive brings d.bin + d.dpt (no dht)
    machine created in directory B  drive node 0x0000000000000000 expected 0x5999fb874bbf38e1 root 0xd847bc04edbc3346 => ROOT HASH DOES NOT COMMIT TO DRIVE DATA
  [C] stored machine: the flash drive's .dht file is missing
    removed ./0000000080010000-10000.dht
    load with SHARING_NONE: refused (missing file)
    load with SHARING_ALL      drive node 0x0000000000000000 expected 0x69b2a37b04deae8b root 0xd847bc04edbc3346 => ROOT HASH DOES NOT COMMIT TO DRIVE DATA
    later load of the same dir, SHARING_NONE  drive node 0x0000000000000000 ... root 0xd847bc04edbc3346 => ROOT HASH DOES NOT COMMIT TO DRIVE DATA
  BUG REPRODUCED: 4 case(s) where the root hash does not commit to the drive data        (exit 1)
  ```
  The drive's node hash is literally 32 zero bytes. The root hash `d847bc04…` is the same in A, B and C, although the
  drive contents differ in each case: the root does not depend on the data at all.
  ```
  $ gaps1/run_cli.sh
  removed flash drive file ./0000000088000000-100000.dht from the stored machine
  hash when created and stored        : 0: 0xd34c04fc199fa45663b45511f1d22552663fb70de65176be2960335266279429
  --load=S,sharing:all --initial-hash : 0: 0xd6b6c724c852ce2d4356e1f03deba735a90177a1fe14808c828abfe593d14907
  later --load=S (sharing:none)       : 0: 0xd6b6c724c852ce2d4356e1f03deba735a90177a1fe14808c828abfe593d14907
  BUG REPRODUCED: loaded initial hash does not commit to the stored drive contents         (exit 1)
  ```
  The hunter's `dht-missing/run.sh` (4 cases) and `run_cli.sh` (Linux guest writing a shared drive configured with
  only `dpt_filename`; the second session's `--initial-hash` is `0xb787d6da…` instead of `0x6aab2fbd…`) both reproduce
  exactly as documented. The unpatched ASan build reproduces all cases with no sanitizer report.

- **Root cause (my reading of the code):**
  - `src/memory-address-range.cpp:72-75`: `m_dpt` is file-backed (and `MAP_SHARED` when the range is shared) whenever
    `dpt_filename` is set. `m_dht` is anonymous, so all zeros, when `dht_filename` is empty. Nothing checks that the
    pair is consistent.
  - `src/dirty-page-tree.hpp:106-115`: a persisted dpt counts as "initialized" (position 0 is dirty), so its clean
    marks are kept as they are. A fresh dpt (all zeros) is reinitialized as all-dirty. This is the only reason the
    reverse case (a dht without a dpt) is safe.
  - `src/machine-address-ranges.cpp:172-182` (`prepare_ar_backing_store`): with `shared`, a missing `.dht` is silently
    recreated zero-filled even without `create`, while an existing `.dpt` is kept. Loads of stored machines with
    `SHARING_ALL` go through this path. `SHARING_NONE`/`CONFIG` open the file privately, so they refuse a missing
    file, which is the correct behaviour.
  - `src/machine-address-ranges.cpp:207-221` (`prepare_ar_backing_store_for_share`, create-with-directory): a missing
    or wrong-size source `.dht` becomes a zero file, while the source `.dpt` is copied. This is trigger B, which the
    hunter named but did not test separately; I confirmed it.
  - `src/hash-tree.cpp:389` (`update_dirty_pages`) rehashes only pages marked dirty. `:502-527` (`update_sparse_tree`)
    copies each range's dht root, here zero, into the sparse tree. The root hash, proofs and node hashes therefore
    use zeroed page hashes for every "clean" page.
  - Permanence: after a `SHARING_ALL` session the zeroed `.dht` exists on disk next to the clean `.dpt`, so every later
    load, including `SHARING_NONE`, reports the wrong hash (case C). If the guest writes some pages in such a session,
    their paths are rehashed on top of zero siblings: the dht root becomes non-zero but is still wrong.
  - Documentation: the `--flash-drive` CLI help (`src/cartesi-machine.lua:235-239`; `--nvram` and the other range options
    say "semantics are the same as for the --flash-drive option", e.g. `:330-331`) says
    of `dht_filename`: "when omitted or set to the empty, the hash tree will be built from scratch". It is not rebuilt
    when a persisted `dpt_filename` is given. `doc/README.md.template:2254-2255` says these files "support the
    efficient computation of state hashes" and are "normally left empty". Nothing documents that a dpt without its
    dht is unsupported, and no test asserts this behaviour. `spec-backing-stores.lua` "replace memory range with
    existing clean page tree" always passes both files.
  - Detection: `cm_verify_hash_tree` returns false and prints "is not marked dirty but is dirty" (hunter case 1/2),
    but nothing calls it on load.

- **Overlap with BUGS.md:** this is not a duplicate. It belongs to the same family as **CM-06** ("loads trust the
  persisted hash-tree files"), but its root cause and fix are different:
  - CM-06 (and its addendum) is about write-TLB dirty marks that are lost when the dpt is persisted without the
    processor state, plus tampered stores. Its validated fix, flushing `mark_write_tlb_dirty_pages()` in `store()`
    and `~machine()`, does not affect GAPS-1.
  - In GAPS-1 the emulator itself creates the inconsistent pair: it recreates a missing `.dht` as zeros, or uses an
    anonymous dht beside a file-backed dpt. No tampering is needed, and in triggers A and B no file is lost either:
    the option combination is documented.
  - CM-06's suggested opt-in verify-on-load would detect GAPS-1 only when a user opts in.
  - **CM-22** (a crash during a shared update) needs a process crash, and there `cm_verify_hash_tree` returns true.
    Its fixes (a)+(b)+(c), and the alternative "update in progress" flag, do not touch how a range is built, so they
    do not fix GAPS-1.
  - The CM-08 addendum (replace with dht/dpt files) is about stale page-cache entries, a different mechanism.

  Recommendation: file GAPS-1 as its own entry, or as a separate addendum to CM-06 with its own fix.

- **Severity: Medium (upper end).**
  - Why not Low: the emulator silently returns a wrong root hash, wrong proofs and a wrong CLI template hash, with no
    error. The cause is either an option combination that the CLI help explicitly describes, or the loss of one
    cache-like file followed by a `SHARING_ALL` load. After that, the wrong state persists for every later load.
    If such a template hash is registered on chain, nobody can prove steps that read the affected pages: their leaves
    would need a preimage of the zero hash. The honest node's uarch/CMIO step logs would fail.
  - Why not High or Critical:
    - Trigger A/B (a dpt without a dht) has no practical use: the dpt is only useful together with a persisted dht.
    - Trigger C needs a deleted or lost `.dht`. `clone_stored`, which the CLI's stored revert mode and node snapshot
      cloning use, *refuses* a source with a missing `.dht`. I checked: "unable to clone file … .dht: No such file
      or directory". `SHARING_NONE`/`CONFIG` loads also refuse.
    - It is a liveness and commitment failure, not a way to make an invalid transition provable: the zero leaf has
      no preimage for a dishonest party either.
    - `cm_verify_hash_tree` detects it.
    - No untrusted party can trigger it without write access to the node's files, and with that access CM-06
      tampering applies anyway.
  - Treat it as High in deployments that build templates with per-range `dpt_filename` and no `dht_filename`.

- **Fix assessment (validated):** the hunter's fix (`<SCRATCH>/work/gaps/fixbuild/fix.diff`) is correct and covers
  all four triggers (A, B, C, and replace with a dpt-only backing store) at the single place where every range is
  built. In the `memory_address_range` constructor, if every byte of `m_dht.root_hash_view()` is zero, it calls
  `m_dpt.mark_dirty_pages_and_up(0, length)`. A computed Keccak/SHA-256 root is never all-zero, so this cannot fire
  for a valid dht.
  - I rebuilt it privately, with ASan and with both the Lua module and the shared library:
    `<SCRATCH>/verify/verify-gaps/fixbuild/build.sh`, about 1-2 min (the binaries were deleted after the run to save
    disk).
  - Results with the patched build:
    - `gaps1/run.sh`: OK in all cases, exit 0.
    - `gaps1/run_cli.sh`: OK, and the stored hash `0xd34c04fc…` is identical to the release build's.
    - The hunter's `run.sh` with `LIBDIR=`: 4 of 4 OK, and `cm_verify_hash_tree` is true.
    - The hunter's stored-machine lifecycle suite, relinked against the patched library: 0 failures.
    - `tests/lua/spec-backing-stores.lua`: 19/19 pass, with `os.tmpname` redirected into my work dir.
  - Side effects: no root-hash or on-chain change. The fix only decides which pages are rehashed. The cost is one
    full rehash of a range whose dht was never computed, which is needed for correctness anyway. When the dpt is
    already all dirty, the loop stops early.
  - Limits:
    - It does not repair directories that an unpatched build has already damaged. If a session ran on a zeroed dht
      and wrote pages, the dht root is now non-zero but wrong. Recovery needs a forced rehash, for example by zeroing
      the range's `.dht/.dpt`.
    - It does not address partially corrupted dht files (the CM-06/CM-22 territory).
  - Recommended complements:
    - `prepare_ar_backing_store` should refuse a configured but missing `.dht` when the `.dpt` exists and `create` is
      not set (fail closed, as `SHARING_NONE` already does), or reset the `.dpt` whenever it recreates the `.dht`.
    - `prepare_ar_backing_store_for_share` should do the same.

---

### GAPS-2: `cartesi.evmu.decode_calldata` rejects an empty dynamic array of dynamic elements
- **Verdict: CONFIRMED.**
- **Independent reproducer:** `<SCRATCH>/verify/verify-gaps/gaps2/run.sh`. The calldata is built by hand, word by word,
  with the selector from `cartesi.keccak256`; the `evmu` encoder is not used. Two controls, `f(uint256[])` with `[]`
  and `f(bytes[])` with `[0x]`, are accepted:
  ```
  f(bytes[])              68 bytes: REJECTED: .../src/cartesi/evmu.lua:821: calldata too long
  f(string[],uint256)    100 bytes: REJECTED: .../src/cartesi/evmu.lua:821: calldata too long
  f(uint256[])            68 bytes (control): decoded
  f(bytes[])             132 bytes (control): decoded
  BUG REPRODUCED: 2 valid calldata rejected            (exit 1)
  ```
  The hunter's `rt.lua` (3 cases, including `(uint256,bytes)[]`) also reproduces.
- **Root cause:** `src/cartesi/evmu.lua:732`. In `decode_array`'s dynamic-element branch, `last_offset` is only
  assigned inside the element loop, so for `size == 0` the function returns `nil` as the end offset.
  `decode_tuple` (`:766`) propagates it as the tuple end, and `decode_calldata` (`:821`) fails
  `assert(offset == #calldata_raw)`. The bug is hidden when another dynamic component follows, because that
  component overwrites `new_offset`.
- **Severity: Low (agree).** The library fails closed in tooling. The shipped recipes (`doc/recipes/*.lua`) decode
  only fixed signatures without arrays (`EvmAdvance`, `Voucher`, `DelegateCallVoucher`, `Notice`). The emulator and
  the proofs are not affected.
- **Fix assessment:** `local last_offset = new_offset + size * 32` is correct. For `size == 0` it is the end of the
  length word; for `size >= 1` the loop overwrites it. I validated it with a patched copy
  (`gaps2/fix/cartesi/evmu.lua`, put first on `LUA_PATH`): my reproducer and the hunter's `rt.lua` both print OK.
  No compatibility risk.

---

### GAPS-3: a read-only drive with a shorter, page-aligned image is refused ("possible non zero partial page")
- **Verdict: CONFIRMED.**
- **Independent reproducer:** `<SCRATCH>/verify/verify-gaps/gaps3/run.sh`. A 12288-byte image backs a 64 KiB drive:
  it is accepted when writable, and the gap reads back as zeros. The same image is refused when read-only. A
  12000-byte image, which really has a partial page, is refused when read-only, as designed:
  ```
  aligned.bin    read_only=false accepted
  aligned.bin    read_only=true  refused: ... possible non zero partial page when mapping backing file '.../aligned.bin' ...
  unaligned.bin  read_only=true  refused: ... possible non zero partial page ...
  BUG REPRODUCED: page-aligned short image refused only when read-only     (exit 1)
  ```
  The hunter's `ro-short/run.sh` also reproduces.
- **Root cause:** `src/os-mapped-memory.cpp:217-226`. When `backing_file_length % page_size == 0`,
  `partial_page_remaining = min(page_size - 0, length - backing_file_length)` is a whole page, so the read-only branch
  throws, although the file mapping ends on a page boundary and the rest is anonymous zero memory. Short images are
  explicitly supported for private mappings (comment at `:158-160`).
- **Severity: Low (agree).** It fails closed with a clear error. It can only be reached through C API or Lua configs,
  because the CLI requires the image size to equal the drive length. There is no state or hash impact.
- **Fix assessment:** `partial_page_remaining = partial_page_size != 0 ? std::min(page_size - partial_page_size,
  length - backing_file_length) : 0;` is correct by inspection. I did not rebuild for this Low item. No root-hash
  change.

---

## Files
- `verify-gaps/gaps1/{repro.lua,run.sh,run_cli.sh}`: independent GAPS-1 reproducers. `LUA_CPATH_DIR=<dir>` selects
  another build; ASan builds need the `LD_PRELOAD` given in `fixbuild/build.sh`.
- `verify-gaps/fixbuild/{fix.diff,build.sh}`: private patched ASan build (the hunter's fix) used for validation.
- `verify-gaps/hunter/`, `hunter-evmu/`, `hunter-ro/`, `life/`: clean copies of the hunter's PoCs as I re-ran them.
- `verify-gaps/gaps2/{repro.lua,run.sh,fix/cartesi/evmu.lua}`: GAPS-2 reproducer and the validated fix.
- `verify-gaps/gaps3/run.sh`: GAPS-3 reproducer.
