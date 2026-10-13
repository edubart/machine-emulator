# Dynamic-analysis / fuzzing findings (angle: `dynamic`)

Work dir: `<SCRATCH>/work/dynamic`. ASan+UBSan build used throughout (`<SCRATCH>/asan/src`),
plus a private clang `fuzz=yes` static-lib build in `<SCRATCH>/work/dynamic/tree/src` for the libFuzzer harnesses.

---

### DYNAMIC-1: host interpreter fast store path ignores the read-only / protected attribute of a WRITE-TLB target, so `cm_run` (and `cm_log_step`/`cm_verify_step`) write to a host-read-only memory range that `cm_run_uarch` refuses — a fraud-proof divergence, and a host SIGSEGV on a loaded machine
- Status: PROVEN
- Area: interpreter / MMU-TLB / uarch / step-proof (cm_run vs uarch vs log_step+verify_step)
- Category: divergence, proof-soundness, memory-safety
- Where:
  - `src/shadow-tlb.hpp:153` (`shadow_tlb_verify_slot`) — validates a shadow TLB slot using only
    `ar.is_memory()`, alignment, `zero_padding==0`, and `paddr_page ∈ [start, end-PAGE]`. It does **not**
    check `ar.is_writeable()` / `ar.is_host_read_only()` / `pmas_is_protected(...)`, even for the `TLB_WRITE` set.
  - `src/machine.cpp:262` (`machine::init_hot_tlb_slot`) and `src/state-access.hpp:504` promote a shadow WRITE
    slot to a hot slot using that same check, then
  - `src/interpret.cpp:1170-1174` (`write_virtual_memory`, fast "whit" path) writes straight through the hot
    host pointer via `state_access::do_write_memory_word` (`src/state-access.hpp:479`), bypassing the
    read-only/protected guard that `machine::write_word` (`src/machine.cpp:1953/1959`, used by the uarch bridge)
    and the slow store path `write_virtual_memory_slow` (`src/interpret.cpp:1107`, which checks `ar.is_writeable()`)
    both enforce.
- Problem: The three canonical execution paths disagree on the *same committed machine state* when a shadow
  `TLB_WRITE` slot points at an in-bounds but host-read-only (or protected) **memory** range. For the always-present
  "PMAs" shadow range at `0x10000` (`host_read_only=true`, DID shadow_state, but flagged memory):
  - `cm_run` performs the store, mutates the read-only region, and the committed root hash changes.
  - `cm_log_step` + `cm_verify_step` (page-based fraud proof) produce and **accept** a log of the very same write
    (obtained root hash == `cm_run`'s new hash).
  - `cm_run_uarch` (the micro-architecture, i.e. the on-chain / Solidity step reference) **refuses** with
    `attempted memory write to read-only PMAs at address 0x10000`.
  A shadow WRITE-TLB entry to a non-writable range is **not** produced by honest guest execution (the slow store
  path installs a WRITE-TLB entry only after `ar.is_writeable()`), so this requires a crafted committed state:
  reachable via `cm_write_memory` of the full shadow block (as the emulator's own `tests/fuzz/fuzz-interpret*`
  harnesses do), or by loading a crafted/corrupt stored machine. The guest cannot write the shadow TLB directly.
- Scenario:
  1. **Fraud-proof divergence (soundness).** The PRT dispute flow proves one-step transitions. The micro-architecture
     step verifier (`cm_run_uarch` / `verify_step_uarch`, mirrored on-chain) and the page-based step verifier
     (`cm_log_step`/`cm_verify_step`, used by the RISC Zero replay) must agree on the transition out of any committed
     state. Here they do not: from one committed "before" hash, `cm_run`+page-proof compute a *valid* next state
     (the write succeeds) while the uarch step declares the step *impossible*. A party that commits to a state whose
     preimage carries such a TLB entry forces the two verifiers to different verdicts; a node that drives its
     expected-commitment sequence from `cm_run` (or page proofs) cannot back it with a uarch step proof.
  2. **Host crash (DoS / memory-safety).** On a machine **loaded** from a stored directory the read-only range is
     mapped `PROT_READ`. The same crafted WRITE-TLB entry makes `cm_run`'s fast store path write to read-only host
     memory → SIGSEGV. A node that loads an untrusted stored machine and runs it crashes.
- Evidence:
  - Divergence PoC: `<SCRATCH>/work/dynamic/poc-rotlb/poc.c` (+ `run.sh`). Builds against the ASan and the release
    libcartesi and prints, identically on both:
    ```
    read-only PMAs range is PMA index 7
    cm_run: err=0 break=5  read-only region changed=1  root-hash changed=1
    cm_run_uarch (3 mcycles): err=-6 (attempted memory write to read-only PMAs at address 0x10000(65536))
    cm_log_step (3 mcycles): err=0 (ok)
    cm_verify_step: err=0  matches-cm_run=1
    root before      f22b6da8...   root after cm_run c757fd8b...
    BUG REPRODUCED: cm_run wrote to a host-read-only memory range via a WRITE-TLB entry
                    (root hash changed) while cm_run_uarch refused the same step.
    ```
    Run: `bash <SCRATCH>/work/dynamic/poc-rotlb/run.sh` (exit 1 == bug present).
  - SIGSEGV PoC: `<SCRATCH>/work/dynamic/poc-rotlb/poc_segv.c` (+ `run_segv.sh`, saved trace `segv.log`):
    ```
    ==ERROR: AddressSanitizer: SEGV ... caused by a WRITE memory access.
      #0 aliased_aligned_write<unsigned long> strict-aliasing.hpp:32
      #2 cartesi::state_access::do_write_memory_word<...> state-access.hpp:480
      #4 write_virtual_memory<..., state_access> interpret.cpp:1173
      #6 execute_SD ... #10 cartesi::machine::run ... #13 cm_run
    ```
  - Independently reached by the structural differential fuzzer `fuzz-diff` (below) on seed
    `rv64ui-v-lwu-snap213` and others (saved `diverge-uarch-err-*.bin`).
  - Second consequence, found by the cross-build/run-vs-step check on fuzz corpus input
    `<SCRATCH>/work/dynamic/corpus/interpret/0460d753805156218571af6d3f04f9a6f9f292be`: the crafted WRITE-TLB store
    makes `cm_run` overwrite a word of the read-only PMA table itself (the CMIO tx-buffer entry's `ilength`,
    `0x10028: 0x0000000000200000 -> 0x0`, shown by `<SCRATCH>/work/dynamic/bin/pmacheck`). `cm_run` keeps using
    its in-memory address map and returns success (identical final hash on GCC release, clang, GCC ASan), but the
    committed PMA table now contradicts that map. `cm_log_step` over the same 2000 cycles then fails its own replay
    self-check with `empty range with length 0 must start at 0 when initializing DID.cmio_tx_buffer`, because the
    replay rebuilds address ranges from the (now corrupt) committed PMA table. So the honest prover cannot produce a
    page-based proof for a transition `cm_run` considers valid, and the interpreter's behavior is no longer a function
    of the committed state alone (it depends on the stale in-memory ranges).
  - A third instance from `fuzz-diff` (`<SCRATCH>/work/dynamic/crashes/diff-crash-769364b1c1b2d3f7bfa196e666d155daf32b9633`):
    `cm_run` rewrites PMA entry 0 (the RAM range) `istart` `0x00000000800000fd -> 0x0000000080000340`, i.e. it changes
    the committed flags of main RAM; `cm_log_step` then fails with `incompatible mock address range`.
- Possible solution: enforce the target's writability when a `TLB_WRITE` slot is verified/promoted. Either make
  `shadow_tlb_verify_slot` set-aware and, for `TLB_WRITE`, return `TLB_INVALID_PAGE` when `!ar.is_writeable()`,
  `ar.is_host_read_only()`, or `pmas_is_protected(ar.get_driver_id())`; or add that check in
  `machine::init_hot_tlb_slot` / `do_init_hot_tlb_slot<TLB_WRITE>` and in the uarch/replay cold-verify for the WRITE
  set, so a non-writable WRITE slot forces a miss and the slow path raises the store access fault (matching the uarch).
  Honest WRITE entries are unaffected (the slow path already gates them on `is_writeable()`).
- Severity: High. Two fraud-proof paths that must agree diverge on identical committed state (uarch refuses while
  cm_run + page-based verify_step accept), plus a host SIGSEGV when running a loaded machine. Downgraded from
  Critical only because the triggering committed state is not reachable by honest guest execution (it needs a
  crafted shadow TLB via the C API or a crafted/loaded stored machine), so it is not purely guest-triggerable.
- Risks: if unfixed, implementations that must agree (interpret / page-step / uarch-step / on-chain) disagree about
  which transitions are valid out of a crafted state, and loading an untrusted machine can crash the host. The fix
  only makes the fast/page paths reject what the uarch already rejects; it changes no root hash for any state an
  honest machine can reach, and brings `cm_run`/`verify_step` into agreement with the uarch/on-chain verifier.
- Note on an existing "OK" conclusion: `findings/mmu-tlb.md` checked crafted shadow TLBs and concluded they are safe
  because `shadow_tlb_verify_slot` bounds-checks reads. That analysis covered out-of-bounds *reads* only; it did not
  cover the *writability* of a WRITE-set target, which is the gap exploited here.

---

## Test-suite results against the ASan+UBSan build (no sanitizer reports)

All run with `LD_PRELOAD="$(gcc -print-file-name=libasan.so) $(gcc -print-file-name=libstdc++.so)"`,
`LUA_CPATH` pointing at `<SCRATCH>/asan/src/cartesi.so`, `ASAN_OPTIONS=detect_leaks=0`. Logs in
`<SCRATCH>/work/dynamic/t1`.

- **RISC-V machine tests** `cartesi-machine-tests.lua run` and `run_step` (keccak256 & sha256): all pass except the
  ~107 `rv64*-v-*` mcycle-off-by-3 baseline noted in the guide (toolchain, not a bug). No ASan/UBSan report.
- **misc C API tests** (`tests/misc/test-machine-c-api.cpp`, `test-machine-c-jsonrpc-api.cpp`) built against the ASan
  libs: `153 test cases ... *** No errors detected` and `42 test cases ... *** No errors detected`, exit 0, clean.
- **Lua spec/program tests** (`spec-*.lua`, plain lua programs): all clean under ASan. The only non-passes are test
  infrastructure, not emulator defects, and produce no sanitizer output:
  `spec-verify-uarch-failure` (7 cases) and the TLB-ecall tests need `tests/build/uarch/rv64ui-uarch-ecall-write-tlb.bin`,
  which is not built locally; `spec-cm-cli` needs the CLI harness env; `spec-runtime-console` needs a TTY;
  `spec-collect-hashes` timed out under ASan (slow, not a crash).
- **Linux boot via the CLI** (`cartesi-machine.lua`, ASan `cartesi.so`): clean boot to `Halted`, and clean
  `--store`/`--load`, `--log-step`, `--log-step-uarch`, `--print-mcycle-root-hashes`,
  `--print-uarch-cycle-root-hashes`, and `--virtio-net=user`. No sanitizer report. (virtio-console needs a TTY,
  the 9p scenario's guest `mount` returned non-zero, and one cmio invocation used a wrong CLI option name — all
  my harness/environment issues, not emulator faults.)
- **Determinism**: full Linux boot (keccak256 and sha256) run with `update_hash_tree` concurrency = 1/2/4/auto gives
  identical root hashes at every checkpoint (`<SCRATCH>/work/dynamic/nondet/nondet.lua`: `deterministic`).
- **Cross-build determinism** (`<SCRATCH>/work/dynamic/harness/hashdump.cpp`, results in `work/dynamic/xbuild`):
  295 fuzz-corpus states (seed corpus + new interpret corpus) run for 2000 mcycles via `cm_run` and via
  `cm_log_step`, against GCC `-O2` release, clang `-O1` fuzz build and GCC ASan `-O1`: identical error code, break
  reason, mcycle, pc and final root hash for every input in all builds (0 differences); no sanitizer output.
  Within a build, `cm_run` and `cm_log_step` agree on the final state for 269/270; the single exception is the
  DYNAMIC-1 PMA-table corruption described above.

## Fuzzing campaign (ongoing)

Built with clang-18 libFuzzer (`libclang-rt-18-dev`, `libomp-18-dev` installed; hashers compiled without
`-fsanitize` to avoid a clang-18 miscompile/slow-build of the SIMD hashers). Harness sources in
`<SCRATCH>/work/dynamic/harness`, binaries in `<SCRATCH>/work/dynamic/bin`, corpora in `<SCRATCH>/work/dynamic/corpus`.

Existing harnesses (`tests/fuzz`): `fuzz-interpret`, `fuzz-interpret-step`, `fuzz-config` built and run against the
clang fuzz build with the generated seed corpus.

New harnesses I added (consume untrusted input not previously fuzzed):
- `fuzz-steplog` — mutates a binary `cm_log_step` log (structure-aware mutator + root-hash fix-up) and calls
  `cm_verify_step`. Oracle: on CM_ERROR_OK, obtained root must equal the logged after-root; determinism check.
- `fuzz-uarchlog` — mutates JSON access logs of real `cm_log_step_uarch` / `cm_log_reset_uarch` /
  `cm_log_send_cmio_response` runs and calls `cm_verify_step_uarch` / `cm_verify_reset_uarch` /
  `cm_verify_send_cmio_response`. Oracle: any accepted mutated log must yield the original after-root (no forged
  transition accepted).
- `fuzz-jsonconfig` — mutates machine + runtime JSON config, `cm_create_new` + run + store/load round-trip oracle
  (sandboxed: lengths clamped, filenames redirected, net devices dropped).
- `fuzz-diff` — builds the same fuzzed machine three times and compares root hashes after each mcycle across
  `cm_run`, `cm_run_uarch`+`cm_reset_uarch`, and `cm_log_step`+`cm_verify_step`, plus `cm_verify_hash_tree` on each.
  This is what surfaced DYNAMIC-1; it now records-and-continues on the known read-only-TLB asymmetry so it keeps
  looking for divergences where all paths succeed.

Results so far (machine load average 40-60 from other agents, so exec rates are low):
- `fuzz-interpret`: 596,843 execs (1 h), cov 3625, corpus +5089 — no crash.
- `fuzz-steplog`: 359,121 execs (1 h), cov ~1740 — no crash, no oracle violation. Sampled corpus outcomes show most
  mutated logs reach full replay (`final root hash mismatch` after interpreting), so the replay code is well covered.
- `fuzz-interpret-step` (upstream harness): one libFuzzer timeout (402 s) — REJECTED as a harness-speed artifact, not
  an emulator hang: the stack is inside `cm_verify_reset_uarch` → `from_json<access_log>` decoding the 4 MiB uarch
  state (the harness requests `CM_ACCESS_LOG_TYPE_LARGE_DATA` reset logs every mcycle; base64 bytes are pushed one by
  one into a `small_vector`). `fuzz-diff` covers the same four-path differential much faster.
- `fuzz-diff`: surfaced DYNAMIC-1; otherwise clean (libFuzzer "slow-unit" reports only).
- `fuzz-uarchlog` (77 base logs: uarch steps, resets, cmio responses), `fuzz-jsonconfig`, `fuzz-config`: running /
  queued; clean so far.

Other things checked and found OK: the PMA table file of a stored machine is validated against the address ranges on
load; `.sht` sparse-node structure is validated on load; `.phtc` LRU pointers are range/alignment-checked on load
(hash *values* in these caches are trusted — already reported as capi-storeload-3).
