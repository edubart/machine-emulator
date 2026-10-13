# verify-dave: independent verification of the dave-flows candidates

Verifier: `verify-dave`. Hunter report: `<SCRATCH>/findings/dave-flows.md`. All my files are in
`<SCRATCH>/verify/verify-dave/` (`<SCRATCH>` = `<SCRATCH>`).
Emulator under test: the repo release build at `927673b` (v0.22.0-test2). Dave checkout: `<SCRATCH>/work/dave-flows/dave` @ `0656c30`,
which pins emulator commit `bd09538` (v0.21.0). I checked that the code involved in both candidates is the same at `bd09538`.
I ran everything as root (uid 0, full capability set), and ran the non-root cases with `setpriv --bounding-set=-all --inh-caps=-all`.

| ID | Verdict | My severity |
|----|---------|-------------|
| DAVE-FLOWS-1 (`cm_clone_stored` hard-links writable-range files of a read-only stored machine) | **CONFIRMED** (emulator defect). Some impact claims are corrected and some impacts are added (see below). | **High** (conditional: root + read-only stored files). Without root it degrades to a loud load failure (Low/Medium). |
| DAVE-FLOWS-2 (= CM-06 exposure: a damaged/tampered snapshot passes Dave's root checks) | **CONFIRMED** as the CM-06 exposure (not a new defect). The exposure is wider than reported: an untrusted *template* also passes Dave's on-chain-hash check and its CM-02 gate. | **High** (inherits CM-06). Medium for the post-publication-damage trigger alone. |
| Exposure-table spot checks: CM-02, CM-20, CM-22 | CM-20 "no": **confirmed**. CM-22 "cond": **confirmed**, and persisted impact is in practice limited to swept scratch dirs. CM-02 "no": **holds only for honestly built templates**, because the gate can be bypassed through CM-06 (shown). | n/a |

---

### DAVE-FLOWS-1: `cm_clone_stored` picks hard link vs reflink by file permission bits; a SHARING_ALL load of the clone writes through to the source stored machine

- **Verdict: CONFIRMED.** I re-derived it from the code, reproduced it independently with different code and a different technique (the Lua API, no Dave code), confirmed it in Dave's reject path, and validated a fix.
  Corrections to the hunter's write-up:
  1. *"Rollup nodes very commonly run as root in containers"* is not supported by the evidence. Both official Cartesi images run as non-root:
     - the emulator `Dockerfile:89-95` (`useradd ... cartesi`, `USER cartesi`);
     - `cartesi/rollups-node` `build/Dockerfile` ("Set user to low-privilege. USER cartesi", seen through GitHub code search).

     Dave ships no container image. Running as root is common in self-built deployments, but it is not the default.
     Without `CAP_DAC_OVERRIDE` the outcome is a **loud** failure, not corruption (see below).
  2. *"a Nix store path (Dave's docs make the Nix devshell the default provider)"*: Dave's Nix devshell provides
     `libcartesi`, not the machine template (`docs/build-system.md:11,206`). A Nix-packaged template is plausible but
     speculative. Also, on NixOS `/nix/store` is a read-only bind mount, so `link()` would fail with `EXDEV`, and
     `clone_file` would fall back to `copy_file`, which keeps mode 0444. The first clone would then be independent, but
     every later clone inside the state dir would hard-link, so the CAS epoch-0 boundary, not the template, would be
     corrupted. This is reasoning only; I did not test it on Nix.
  3. In Dave's **reject** path the defect is loud, not silent. `MachineStf::restore_rejected` (`machine_stf.rs:284`,
     `self.machine = Machine::load(&checkpoint, ...)`) builds the new machine before the old SHARING_ALL machine is
     dropped. The checkpoint shares its inode with that live working clone, so the `LOCK_SH` request hits the held
     `LOCK_EX` and fails: `unable to lock backing file ... Resource temporarily unavailable`. With a read-only template
     run as root, every rejected input therefore stops Dave's runner, while accepted inputs silently corrupt the
     template and the CAS boundary.
  4. **Additional impact that the hunter did not report (emulator CLI/API):** the emulator's own stored-revert scheme
     loses rollbacks. This covers `cartesi-machine --load=dir,clone:tpl --revert-mode=stored` (`src/cartesi-machine.lua:3693-3723`)
     and the documented recipe `doc/recipes/run-rolling-calculator-from-storage.lua`. With a read-only template:
     - `snapshot()` = `clone_stored(machine, machine.revert)` hard-links the live files;
     - so `revert()` renames back a "snapshot" that already contains the rejected input's writes;
     - the rejected input's effects silently persist (root, RAM and `iflags_H` all post-input), and the template is modified too.

     No lock conflict occurs here, because the machine is destroyed before the clone and before the rename.
- **Independent reproducer:** `<SCRATCH>/verify/verify-dave/repro1/run.sh`. It contains `repro.lua` (Lua API, bare-metal
  guest embedded as hex; source in `guest.S`). It exits 1 with `BUG REPRODUCED` while the defect is present and 0 when
  fixed (`LIBDIR=<build>` tests another build). Actual output (root):
  ```
  === clone of a read-only template, run the clone
  template root 66d1583c7612c20c, RAM file mode 444 inode 1860880, marker 0x5555555555555555
  clone RAM file inode 1860880 nlink 2  (hard link to the template)
  after running the clone: clone root 1536c7136d21df72; template marker 0x1122334455667788, template loads with root 1536c7136d21df72
    -> the template's RAM data changed and it now IS the clone's post-run state
  BUG REPRODUCED: ...
  === only the RAM file read-only (silent: stale stored hash tree)
  after running the clone: ... template marker 0x1122334455667788, template loads with root 66d1583c7612c20c
    -> the template's RAM data changed while its load still reports the ORIGINAL root (stale stored hash tree: silent)
  BUG REPRODUCED: ...
  === stored revert scheme (--revert-mode=stored / storage recipe)
  snapshot root 66d1583c7612c20c; after the input root 1536c7136d21df72
  after revert: root 1536c7136d21df72, marker 0x1122334455667788, iflags_H 1 (expected: snapshot root 66d1583c7612c20c, marker 0x5555555555555555, H 0)
    -> the revert did not restore the snapshot: the rejected input's effects persist
    -> and the template itself changed (marker 0x1122334455667788)
  BUG REPRODUCED: ...
  === same, without capabilities (non-root equivalent)
  LOAD REFUSED: SHARING_ALL load of .../nocap/work failed: unable to open backing file '.../work/0000000000000000-8000.bin': Permission denied when initializing shadow state
  BUG REPRODUCED (liveness variant): without CAP_DAC_OVERRIDE the clone of a read-only stored machine cannot be loaded SHARING_ALL
  ```
  - The silent variant needs a stored hash tree that is clean at store time. Dave hashes before storing, and so does my
    script (`get_root_hash` before `store`). If the template was stored without hashing first, the changed page is
    rehashed on load and the change shows up.
  - Dave-flow reject variant: `<SCRATCH>/verify/verify-dave/dave-reject/run.sh` (my `ro_reject.c` on the hunter's C
    mirror of Dave's runner). The template is `chmod -R a-w`; input 0 is rejected and input 1 accepted. It prints
    `unable to lock backing file ...snapshots/0x8753.../0000000000000000-8000.bin: Resource temporarily unavailable` and then
    `BUG REPRODUCED` (exit 1).
  - The hunter's PoC, re-run from a clean copy (`<SCRATCH>/verify/verify-dave/hunter/run.sh`): `ro_template ram` and
    `ro_template all` both print BUG REPRODUCED. The output matches the hunter's report (nlink 3; "silent" for ram and
    "loud" for all). The PoC is sound. It uses only the public C API with Dave's call order, and the read-only template is
    an explicit, stated precondition.
- **Root cause:**
  - `os::clone_file` (`src/os-filesystem.cpp:585`) hard-links any file whose mode has no write bit. Its contract in
    `src/os-filesystem.hpp:125-131` assumes "read-only file ⇔ read-only range".
  - `machine::clone_stored` (`src/machine.cpp:507-535`) passes every file through it: writable-range data, all
    `.dht/.dpt`, `hash_tree.sht/.phtc`.
  - `os::mapped_memory` (`src/os-mapped-memory.cpp:95,119,165`) decides `O_RDWR` + `MAP_SHARED` from the **config's**
    `read_only`, not from the file mode. `CAP_DAC_OVERRIDE` lets `open(O_RDWR)` succeed on a 0444 file.
  - The emulator keeps the "file mode ⇔ range writability" invariant in two places:
    - `machine::store` with SHARING_ALL: `create_file` gives 0644, then `change_writable(false)` for read-only ranges
      (`src/machine.cpp:425-452`);
    - create-into-dir: `change_writable(!read_only)` (`src/machine-address-ranges.cpp:226`).

    It never enforces the invariant on clone. In addition, `store`'s SHARING_NONE/CONFIG copy path
    (`src/machine.cpp:438`) inherits the source mode through `os::copy_file` (`src/os-filesystem.cpp:408-409`) and never
    restores writability, so a 0444 source propagates into new stored directories.
  - The CLI's documented contract is range-based (`src/cartesi-machine.lua:878-880`: "writable address ranges use reference
    links ... read-only address ranges use hard links"). `cm.h:569-570` states the per-file behaviour. The implementation
    violates the range contract.
  - The same logic is present at Dave's pinned `bd09538` (`os-filesystem.cpp:583-586`, `os-mapped-memory.cpp:95,119`).
- **Severity: High (conditional).** When triggered as root, this is silent corruption of a stored machine through
  clone/load: the guide's High class.
  - The template and the CAS boundaries are modified, possibly while still reporting their old root.
  - The stored-revert scheme silently fails to revert, which leads to wrong state and wrong claims.
  - In Dave, accepted inputs corrupt the epoch-0 boundary and template, and rejected inputs stall the runner.

  Preconditions, which keep it below Critical:
  - (a) the stored files of writable ranges must be read-only on disk. The emulator never produces this in its normal
    flows (SHARING_ALL store gives 0644). It needs an operator `chmod a-w`, a read-only package, or propagation of such
    files through a SHARING_NONE/CONFIG store;
  - (b) clone + SHARING_ALL load (Dave, `--load=...,clone:`, `--revert-mode=stored`, the storage recipe);
  - (c) `CAP_DAC_OVERRIDE`. Without it, the outcome is an immediate EACCES on load (Dave: the node cannot start on that
    template). That is a Low/Medium liveness issue that the operator can fix with `chmod u+w`.
- **Fix assessment:** the hunter's primary fix is correct: choose by range writability, not by file mode. I implemented
  and validated it (`<SCRATCH>/verify/verify-dave/fixbuild/fix.diff`, build with `fixbuild/build.sh`, about 1 min,
  private ASan build).
  - What the patch does: new `os::clone_file(from, to, bool writable)`. When `writable`, it never hard-links (reflink or
    sparse copy only) and adds `u+w` to the clone. `machine::clone_stored` passes `writable = !read_only` for range data
    (PMAS and read-only flash/NVRAM keep their hard links) and `writable = true` for all `.dht/.dpt/.sht/.phtc` files.
  - Results with the fix:
    - `repro1/run.sh`: all 4 scenarios OK, exit 0, including the no-capability case, which now loads.
    - `dave-reject/run.sh`: OK; the committed boundary equals the reference `6fab138b...`.
    - The hunter's `ro_template ram|all`: OK.
    - `tests/lua/spec-backing-stores.lua`: 19/19 pass under ASan+UBSan.
  - No root hash changes: the hunter's committed boundary is `0dfc6fbf...` both with and without the fix.
  - Side effects of the fix:
    - on non-CoW filesystems, cloning a read-only template now copies its writable ranges. This costs the same as cloning
      a writable template today, and it is the only correct behaviour;
    - the clone's writable files get `u+w` (owner only, not `change_writable`'s `a+w`), which is intended for a private
      working copy.
  - Also recommended:
    - make `machine::store`'s copy path call `change_writable(data_filename, !read_only)`, as create-into-dir already
      does, so that stored directories never carry 0444 writable ranges;
    - reword `cm.h:569-570` in range terms.
  - The hunter's alternatives are weaker. Refusing `nlink > 1` in `map_memory` is defense in depth only, and it would also
    refuse deliberate external hard links. Copy-on-first-map is complex.
  - Interim workaround for Dave: keep template and snapshot files writable, or load the template SHARING_NONE and re-store it.
- **Risks if unfixed:** a protected (read-only) template run as root is destroyed by its first clone. The documented
  stored-revert flow keeps rejected inputs' effects, so the node's claims diverge from honest nodes and it loses disputes.
  Dave stalls on the first rejected input.

### DAVE-FLOWS-2 (= CM-06 exposure): a damaged committed snapshot passes Dave's root-hash checks because loads trust the stored hash tree

- **Verdict: CONFIRMED as the exposure of CM-06** (no new emulator defect).
  - The hunter's `torn.c`, re-run from my copy, prints BUG REPRODUCED:
    - boundary-2 row `29378229...` = loaded root, but the data hashes from scratch to `878afce2...`;
    - the runner then publishes `deab14b7...` vs the honest `63cc2d8d...`.
  - The mechanism is present at Dave's pinned `bd09538`: there is no root comparison in its load path. Hash-tree
    persistence dates from 0.20.0 (`CHANGELOG.md:174,219`), so it is not v0.22-only.
- **Independent reproducer:** `<SCRATCH>/verify/verify-dave/repro2/run.sh` (Lua). It hashes and stores a snapshot, flips
  one bit of a data page in its RAM file, then loads it and runs on:
  ```
  row 546baa7dd910ae07 | damaged snapshot: loaded root 546baa7dd910ae07, from-scratch root of its data 1ddff1e448294aa9
  final root after running: honest 30d67f702ec0509b, resumed from the damaged snapshot 045d09603ecb7704
  BUG REPRODUCED: the damaged snapshot loads with its row's root hash (stored hash tree trusted, CM-06); ...
  ```
  `cm_verify_hash_tree` (Lua `verify_hash_tree`) **does** return false on this damage (page-level data vs leaf mismatch).
  It is a usable Dave-side mitigation on resume or template intake, at the cost of a full page rehash, although
  `cm.h:1143` documents it as an internal-test helper.
- **Wider exposure than reported:** Dave's template intake has the same weakness, so the trigger is not only "bit rot or
  external write after publication".
  - `args.rs:326-334` checks `Template::inspect(...).hash() == address_book.initial_hash`, where the hash is the
    **trusted stored root**. A template downloaded from an untrusted mirror, or handed out by a malicious party, whose
    data differs from its stored hash tree passes the on-chain initial-hash check.
  - The same trust defeats the CM-02 gate (see the spot check below).
- **Severity:** High, inheriting CM-06. Medium for the post-publication-damage trigger alone, which needs an external
  write to the node's own storage. High or arguably Critical for the untrusted-template trigger, where an honest node
  that verified its download against the chain still computes unprovable or wrong commitments. That second case is
  conditional on obtaining the template through an untrusted channel.
- **Fix assessment:** this needs CM-06's opt-in verify-on-load (recompute and compare), applied at least to template
  intake (`Template::inspect`) and to resuming a durable boundary. Until then, Dave can call `cm_verify_hash_tree`, or
  re-create the template from its `.bin` data, at intake. No root hashes change.

### Exposure-table spot checks (against `<SCRATCH>/work/dave-flows/dave`)

- **CM-20 "no": CONFIRMED.**
  - The Rust wrapper defines `log_step` and `verify_step` (`machine/rust-bindings/cartesi-machine/src/machine.rs:711,794`).
  - A repo-wide grep (`.rs/.lua/.c/.cpp/.sol`, excluding the wrapper) finds zero call sites of `log_step(`,
    `verify_step(` or `cm_log_step(`.
  - Proving uses only `log_step_uarch`: node `engine/machine_stf.rs:539,887,1078,1088`; Lua client
    `prt/client-lua/computation/machine.lua:509,517,526`.
- **CM-22 "cond": CONFIRMED, with a nuance.**
  - Working clones are loaded SHARING_ALL (`storage/rollups_machine.rs:267-279`) and hashed. They are `.work-*` scratch
    swept at startup before any worker runs (`lib.rs:58-66` → `storage/snapshots.rs:281+`).
  - Publication (`snapshots.rs:203-245`) loads the closed clone **SHARING_NONE**, compares its root, syncs and renames,
    so it never maps a published dir writable.
  - A crash during `update()` can therefore only damage swept scratch. A persisted wrong boundary would need the
    clone↔boundary inode sharing of DAVE-FLOWS-1.
- **CM-02 "no": holds for honestly built templates only.**
  - Production calls `Template::inspect` on the template (`storage/open.rs:106-121`; `args.rs:326`): load SHARING_NONE,
    root, `reset_uarch`, refuse if the root changed. Mid-epoch `resume` asserts `ucycle == 0` (`engine/machine_stf.rs:150-153`).
  - The gate compares **trusted stored roots**. My `<SCRATCH>/verify/verify-dave/spot/gate.lua` stores a machine, then
    overwrites the first uarch RAM instruction in the `.bin` only (`.dht/.dpt` untouched). Output:
    `template root (loaded) 453070db..., original 453070db...; after reset_uarch 453070db... -> gate PASSES`.
    `verify_hash_tree` is false. On the first big cycle `cm_run` gives `fd9eac57...`, while the uarch run aborts ("uarch aborted").
  - So a crafted template with a stale stored tree passes both Dave's initial-hash check and its pristine-uarch gate and
    then diverges between `cm_run` and the uarch. The row should read "no for honest templates; cond (yes) for untrusted
    templates via CM-06".

### Files
- `<SCRATCH>/verify/verify-dave/repro1/{run.sh,repro.lua,guest.S}`: DAVE-FLOWS-1 independent reproducer (4 scenarios).
- `<SCRATCH>/verify/verify-dave/dave-reject/{run.sh,ro_reject.c}`: DAVE-FLOWS-1 in Dave's reject flow (uses the hunter's `lib/`).
- `<SCRATCH>/verify/verify-dave/repro2/{run.sh,repro.lua,guest.S}`: DAVE-FLOWS-2 / CM-06 exposure reproducer.
- `<SCRATCH>/verify/verify-dave/spot/gate.lua`: CM-02 gate bypass through a stale stored tree.
- `<SCRATCH>/verify/verify-dave/fixbuild/{fix.diff,build.sh}`: validated fix (private ASan build; built libraries deleted after the runs).
- `<SCRATCH>/verify/verify-dave/hunter/`: clean copy of the hunter's `ro_template.c`, `torn.c`, `lib/`, `guest/`, `run.sh` (re-run).
