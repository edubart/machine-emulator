# Cartesi Machine Emulator — Bug Report (v0.22.0)

> **Status:** emulator findings are verified and documented below. Findings from the on-chain Solidity step angle
> (`cartesi/machine-solidity-step` PR #104) are still under independent verification and will be added when confirmed.
> Raw hunter and verifier reports are in `tests/bugs/reports/`.

## Scope and method

- **Target:** the emulator C/C++ sources and C libraries (`src/`, `uarch/`, `risc0/cpp`) and the `cartesi-machine` CLI
  with its Lua bindings, on branch `feature/v0.22.0-test2` (version 0.22.0). The on-chain Solidity step
  (`cartesi/machine-solidity-step` PR #104, generated from this branch) was used as the reference for "what the
  arbiter computes".
- **Threat model:** the Cartesi Rollups Node drives the C API (`cm.h`, `cm-jsonrpc.h`) to run applications and to
  produce or verify PRT (Permissionless Refereed Tournament) fraud proofs. Any divergence between execution paths
  (`cm_run`, the microarchitecture (uarch) big-step, `cm_log_step`/`cm_verify_step`, the hash collectors, the RISC Zero
  replay, the Solidity step), any wrong root hash or proof, and any way to stop an honest party from producing a proof is
  a potential loss of funds.
- **Process:** independent agents hunted from different angles and wrote runnable proofs of concept. A separate batch
  of independent reviewers then re-derived each claim from source, re-ran the proof, wrote their own reproducer, and
  re-rated severity. Only issues confirmed by that second batch are listed. Documentation issues, typos and missing
  tests are deliberately excluded.
- **Severity scale:** *Critical* — an honest party can lose a dispute or an invalid transition becomes provable;
  *High* — wrong hashes/proofs, silent state corruption, or memory corruption reachable from guest code or untrusted
  inputs; *Medium* — realistic API/CLI misbehaviour or denial of service; *Low* — spec deviations or misuse-only defects
  with limited impact.

## Running the regression tests

Every bug with a test has a directory `tests/bugs/<slug>/` with a self-contained `run.sh`. A test prints
`BUG REPRODUCED: ...` and **exits 1 while the bug is present**, prints `OK: ...` and exits 0 once it is fixed, and
exits 77 when a prerequisite is missing.

```sh
make                                # build the emulator (default build type)
make -C tests images                # only needed by tests that boot Linux
tests/bugs/run-all.sh               # run everything
tests/bugs/<slug>/run.sh            # run one test
```

Bare-metal guest programs are assembled with `riscv64-unknown-elf-gcc` (override with `RISCV_PREFIX`).

## Summary

| ID | Severity | Area | Title | Test |
|---|---|---|---|---|
| CM-01 | Critical (conditional) | interpreter | Interrupt selection ignores destination privilege; `cm_run` results depend on how execution is chunked and diverge from the uarch | `interrupt-priority-chunking` |
| CM-02 | High (Critical if a canonical uarch is not enforced) | uarch / config | Non-pristine uarch state is accepted, so `cm_run` and the uarch big-step compute different transitions | `uarch-non-pristine-state` |
| CM-03 | High | uarch | `WRITE_TLB` uarch ecall does not bound-check `set_index`: out-of-bounds host write | `uarch-write-tlb-set-index` |
| CM-04 | High | RISC Zero step verifier | `risc0_replay_steps` wraps `mcycle_end` instead of saturating: accepts a forged no-op step, rejects the honest one | `risc0-mcycle-end-wrap` |
| CM-05 | High | memory / TLB | `cm_replace_memory_range` leaves dangling host pointers in the hot TLB (crash or silent wrong state) | `replace-memory-range-stale-tlb` |
| CM-06 | High | store / load | Stored machines can carry a hash tree that does not match their data (write-TLB dirty marks lost); loads trust it without verification | `stored-hash-tree-stale` |
| CM-07 | High | JSON-RPC / hash tree | `fork` is allowed when the hash tree is shared: parent and child corrupt each other's hashes and proofs | `fork-shared-hash-tree` |
| CM-08 | High | hash tree | Page-hash cache hits for clean pages are trusted without validation (shared hash tree with private ranges, replace with hash-tree files, `sharing:config` reloads): wrong proofs and uarch-cycle hashes, honest uarch/CMIO logs cannot be produced | `shared-hash-tree-cache-pollution`, `page-cache-stale-collect` |
| CM-09 | Medium | JSON parsing | JSON integers equal to 2^64 (or 2^63) hit an undefined float-to-int conversion: host-architecture-dependent machines | `json-uint64-float-cast` |
| CM-10 | Medium | CLI | `--load-config` ignores command-line fallbacks for missing fields: different machine and template hash | `cli-load-config-fallback` |
| CM-11 | Medium | CLI | `--revert-mode=stored` silently undoes `--replace-memory-range`; printed initial hash is not the machine that runs | `cli-revert-stored-replace` |
| CM-12 | Medium | Lua bindings | Nested JSON/table conversion overflows the Lua stack (heap buffer overflow) | `lua-json-stack-overflow` |
| CM-13 | Medium | VirtIO | Cyclic virtqueue descriptor chain hangs the host forever | `virtio-descriptor-loop` |
| CM-14 | Medium | VirtIO 9P | Guest can create symlinks pointing outside the shared directory and follow them on the host | — (code review) |
| CM-15 | Medium | JSON-RPC | Deeply nested JSON request crashes the server | `jsonrpc-deep-nesting` |
| CM-16 | Medium | JSON-RPC | A batch containing `fork` keeps executing in the child: duplicated operations, 2^N servers | `jsonrpc-batch-fork` |
| CM-17 | Medium | JSON-RPC | Unbounded allocation sized by request (`read_memory`, `read_virtual_memory`, `read_console_output`) | `jsonrpc-unbounded-read` |
| CM-18 | Medium | JSON-RPC | Fault-generated SIGBUS makes the server spin forever | `jsonrpc-sigbus-spin` |
| CM-19 | Medium | C API | `const` queries (`cm_get_root_hash`, `cm_get_proof`) mutate shared state without synchronization | `const-api-thread-safety` |
| CM-20 | Critical (conditional) | step logs / RISC Zero replay | `cm_log_step(N)`/`cm_verify_step(N)` and the RISC Zero replay stop at the first automatic yield: an N-mcycle step proof attests the state at the yield, not the state after N mcycles | `log-step-automatic-yield` |
| CM-21 | High (Critical where disputes use `cm_log_step`/ZK) | hash tree / step logs | `cm_log_step` and `cm_get_node_hash` abort on hash-tree nodes in the power-of-two padding of a non-power-of-two range | `step-log-padding-assert` |
| CM-22 | High | hash tree / stored machines | A process crash during a shared hash-tree update leaves the stored machine with a permanently wrong root hash or an unusable page-hash cache | `crash-during-hash-update` |
| CM-23 | High | shadow TLB validation | Committed WRITE-TLB slots that target non-writable ranges are accepted: `cm_run` writes the PMA table or read-only drives (or crashes) while the host uarch driver refuses | `write-tlb-readonly-target` |
| CM-24 | Medium | uarch | uarch `require()` is an `assert()`: a misaligned uarch access aborts the process, including static `cm_verify_step_uarch` | `uarch-require-abort` |
| CM-25 | Medium | hash tree / proofs | Word-level proofs and node hashes in the power-of-two padding of a range are built from a stale page-cache entry | `proof-padding-stale` |
| CM-26 | Low | step logs / reproducibility guard | `cm_log_step` accepts unreproducible machines: logs that disagree with `cm_run`, non-atomic failures, process abort on a VirtIO queue notify | `log-step-unreproducible` |
| CM-27 | Medium | JSON-RPC client / C API / Lua bindings | `cm_clone_empty` on a remote machine (Lua `remote(config)`, the documented remote recipe) forks a server whose handle has cleanup NOTHING and no timeout: every machine created this way, and every failed create, leaks a server process | `remote-clone-empty-leak` |
| CM-28 | Medium | DTB / machine config / store-load | DTB unit addresses, `/aliases` targets and stored file names are formatted with the host process's C++ global locale: locale-dependent template root hash, snapshots unloadable across locales | `dtb-locale-dependence` |
| CM-L* | Low | various | Lower-severity defects (see the last section) | see table |

---

## CM-01 — Interrupt selection ignores destination privilege; `cm_run` results depend on chunking and diverge from the uarch

- **Severity:** Critical, conditional on the M-mode firmware delegating some S-level interrupts but not others. The
  stock Cartesi OpenSBI + Linux stack (`mideleg=0x222`) cannot reach it; a custom or malicious template can.
- **Area:** interpreter (`src/interpret.cpp`). **Category:** divergence between execution paths / proof soundness.
- **Where:** `get_highest_priority_irq_num()` (`src/interpret.cpp:559`) picks the pending interrupt by number only;
  `raise_interrupt_if_any()` (`src/interpret.cpp:5721`) is evaluated only at the top of the outer interpreter loop, i.e.
  at RTC ticks (every `RTC_FREQ_DIV` cycles) or after an instruction returns `success_and_serve_interrupts`.
- **Problem:** when the highest-numbered pending interrupt is delegated to S-mode while a lower-numbered S-level interrupt
  that is *not* delegated (destined to M-mode) is also pending and enabled, the delegated one is taken first and the
  M-destined one stays pending and enabled. The fast loop does not re-check interrupts until the next tick (up to 8191
  cycles), whereas a run that stops every cycle — per-cycle `cm_run`, the uarch big-step, the on-chain step — re-checks
  at the next cycle. The same machine therefore reaches different states after the same number of cycles depending on
  how execution was split into calls. (Separately, taking the S-destined interrupt first also contradicts the
  privileged spec, which services interrupts for the higher privilege level first.)
- **Evidence:** the verifier obtained 5 distinct root hashes at the same mcycle 16384 across 11 execution paths: per-cycle
  `cm_run`, uarch big-steps and `cm_collect_mcycle_root_hashes` with periods 2^0/2^2 agree; a single `cm_run(N)`,
  `cm_log_step(N)`+`cm_verify_step`, and collection with periods 2^10/2^14 give another hash; periods 2^5 and 2^6 and
  7-cycle chunks give three more. An exhaustive enumeration (2520 configurations) found exactly the 18 predicted
  triggering configurations (`mideleg` ∈ {0x002, 0x200, 0x202, 0x220} with specific pending sets, in U-mode or S-mode with
  SIE=1). With stock Linux, a chunking differential over 2·10^9 cycles of a stress workload (≈1500 random chunks per
  trial) gave identical hashes.
  Test: `tests/bugs/interrupt-priority-chunking` (single run vs per-cycle vs uarch vs 7-cycle chunks at mcycle 1024).
- **Scenario:** a template whose firmware uses partial delegation. Honest nodes build PRT commitments with the fast path
  (`cm_collect_mcycle_root_hashes`), whose value depends on the collection period; the dispute is settled by the uarch
  step, which computes different states. Honest commitments become unprovable and a dishonest claimer that computes with
  per-cycle semantics wins.
- **Possible solution:** minimal, hash-preserving fix (validated): after raising an interrupt, if another interrupt is
  still pending and enabled, cap the inner loop at one instruction (or break out to the outer loop) so it is re-checked
  at the next cycle like the per-cycle paths. The fix must be under `#ifndef MICROARCHITECTURE`, otherwise the uarch image
  (part of the state) changes and every root hash changes; it must be included in the ZK (`ZKARCHITECTURE`) build. The
  spec-correct fix (service M-destined interrupts first) changes the uarch image and the on-chain step and belongs in a
  breaking release.
- **Risks:** if unfixed, any template with partial delegation breaks PRT. The minimal fix leaves all current root hashes
  unchanged (verified on Linux workloads); the spec-correct fix changes all root hashes.

## CM-02 — Non-pristine uarch state is accepted; `cm_run` and the uarch big-step compute different transitions

- **Severity:** High; Critical if the surrounding system does not pin a canonical uarch for templates.
- **Area:** uarch / machine configuration. **Category:** divergence / proof soundness.
- **Where:** `machine::init_uarch_processor` (`src/machine.cpp:107-126`) accepts any uarch `pc`, `cycle`, `halt` and
  `x` registers (only `x0` is checked); `machine::write_reg` does not validate uarch registers; the uarch RAM backing
  store can be any image (`uarch.ram.backing_store`, CLI `--uarch-ram-image`); `machine::run` (`src/machine.cpp:2211`),
  `log_step` and `collect_mcycle_root_hashes` only check `uarch_cycle != 0`.
- **Problem:** the host interpreter never executes uarch code and ignores the uarch state, but that state is part of the
  root hash. The uarch big-step executes whatever uarch state/RAM is present on the first big step, then resets it to the
  pristine image. With `uarch.processor.registers.halt=1`, the uarch big-step is a permanent no-op (mcycle stuck at 0)
  while `cm_run` advances; with `uarch_x1 != 0` or `uarch_x11 != 0` the reset zeroes them while `cm_run` keeps them; with
  `uarch_pc=0x600008`, `cm_run_uarch` throws while `cm_run` proceeds; a custom uarch RAM image can modify big-machine
  state arbitrarily. Every such divergent uarch step still passes `cm_verify_step_uarch`, i.e. it is provable on-chain.
- **Evidence:** a sweep of 35 registers × 7 edge values found divergences only in uarch registers (`uarch_x1`, `uarch_x11`,
  `uarch_pc`, `uarch_cycle`, `uarch_halt`); the verifier reproduced the RAM-image, `halt=1` and `pc` variants and showed the
  divergent steps verify. A node can detect it by comparing `cm_get_node_hash(0x400000, 22)` with the pristine uarch
  state hash, but nothing does so and the pristine constant is only exposed to Lua.
- **Scenario:** a dapp developer registers a template with a non-pristine uarch. Honest validators compute commitments
  with `cm_run`; at the bottom of the dispute the on-chain uarch step proves a different transition, so the honest party
  loses.
- **Possible solution:** reject non-pristine uarch state (registers and RAM, i.e. compare the uarch subtree hash with the
  pristine uarch state hash) at create/load and in `run`, `log_step`, `collect_*`; expose `cm_is_uarch_pristine()` and
  the pristine hash in the C API. No valid root hash changes.
- **Risks:** without a guard, PRT soundness depends on every deployment validating templates out of band.

### Addendum to CM-02 — uarch-cycle collection aborts or hangs on a uarch that halts without advancing mcycle

- **Severity:** Low as a separate item; it is a failure mode of CM-02's input class.
- **Area:** uarch-cycle hash collection. **Category:** process abort / hang.
- **Where:** `machine::collect_uarch_cycle_root_hashes` (`src/machine.cpp:2627`) checks only reproducibility, Keccak and
  `uarch_cycle == 0` (`:2635-2649`), then assumes that one uarch run to halt advances mcycle by exactly one and checks it
  with `assert(mcycle_reached == mcycle_target)` (`:2807`). `cm_collect_uarch_cycle_bundle` runs the same code.
- **Problem:** with `uarch.processor.registers.halt=1`, or a custom uarch image that halts without executing a
  big-machine instruction, mcycle does not advance and the default and official builds abort. A `release=yes` build
  emits a bogus extra period (halt register) or never returns (custom image: the collector's partial reset, CM-L20,
  keeps the custom code, which halts again on every iteration). A `uarch_halt == 0` precondition alone does not catch
  the image case. (The assertion at `:2755` is not reachable: `uarch_step` overwrites `uarch_cycle` after each
  instruction.)
- **Evidence:** verifier reproducer (no regression test): the pristine control returns normally; the halt-register and
  custom-image variants abort at `machine.cpp:2807` for root hashes and bundles; `release=yes` gives an extra period or
  times out.
- **Possible solution:** CM-02's entry check (uarch subtree hash equal to the pristine uarch state hash before anything
  runs) prevents it. Also replace the assertion with `throw std::runtime_error{"uarch did not advance exactly one
  mcycle"}` as a last line of defence (validated: all variants return this error, the `release=yes` loop stops, the
  pristine control is unchanged); this throw happens after the uarch ran, so the machine is left modified.

### Addendum to CM-02 — a uarch store to the `uarch_x0` shadow word is refused by the host but accepted by the step verifiers

- **Severity:** Low as a separate item. It needs a custom uarch RAM image, CM-02's input class, and is another
  host-only check in `machine::write_word` of the kind described in CM-23.
- **Area:** uarch / uarch step verification. **Category:** divergence between the host uarch driver and the
  verifiers / spec deviation (x0 not hardwired to zero).
- **Where:** `readX` (`src/uarch-solidity-compat.hpp:91-94`), and its transpiled Solidity counterpart, returns the
  `uarch_x0` shadow word (0x400018) for register 0. A uarch store to that word goes through `writeUint64`
  (`src/uarch-step.cpp:68-72`) to the state access. On the host, `uarch_state_access` and `uarch_record_state_access`
  call `machine::write_word` (`src/uarch-state-access.hpp:92-95`, `src/uarch-record-state-access.hpp:241-246`), which
  forwards uarch shadow words to `write_reg` (`src/machine.cpp:1937-1945`), and `write_reg(uarch_x0)` throws "register
  is read-only" (`:1362-1363`). The replay's `do_write_word` (`src/uarch-replay-state-access.hpp:359-362`) and the
  Solidity `writeWord` only check the proof. The host also rejects a non-zero x0 at construction ("uarch x0 register
  is corrupt", `src/machine.cpp:122-125`), so the intended semantics is a hardwired zero.
- **Problem:** an `sd` to 0x400018 by uarch code aborts the step in `cm_run_uarch`, `cm_log_step_uarch` and the
  uarch-cycle collectors, while `cm_verify_step_uarch` and the on-chain `UArchStep` accept it as an ordinary write: x0
  becomes the stored value, and every later instruction that reads x0 sees it, including every `li`/`mv` idiom
  (`addi rd, x0, imm`). The honest host therefore cannot log a uarch step that the chain accepts. By code reading, the
  same host-only rejection applies to uarch stores to the big machine's `x0`, `mvendorid`/`marchid`/`mimpid` and
  unknown shadow-register words (`src/machine.cpp:1045-1046`, `:1242-1247`, `:1928-1935`); these were not run. The
  pristine uarch image never writes the uarch shadow, and guests cannot reach it (registered with `pmas = false`,
  `src/machine-address-ranges.cpp:307-308`), so the case needs a template with a custom uarch RAM image.
- **Evidence:** the hunter's PoC runs `sd` of 5 to 0x400018 followed by `add t2, x0, x0`: the host fails with
  "register is read-only" at uarch cycle 5, while the Solidity `UArchStep` (mock access logs) halts with x0 = 5 and
  t2 = 10. The verifier used real Merkle proofs: logs from a private build whose `write_reg(uarch_x0)` behaves like
  the replay were judged by the official `libcartesi.so`, whose `cm_log_step_uarch` and `cm_run_uarch` refuse step 3
  while its `cm_verify_step_uarch` accepted all 11 logged steps, the refused one and every later one included (final
  x0 = 7 and t2 = 10, where RISC-V gives x0 = 0 and t2 = 3). Test: `uarch-x0-store`.
- **Possible solution:** CM-02's pristine-uarch check makes the case unreachable. In the shared step, reject stores
  to the uarch shadow range in `writeUint64` (`throwRuntimeError(a, "write to uarch shadow state")`) and, for full
  parity, to the big-machine shadow words the host rejects. This restores host/verifier agreement without changing
  any honest log, the pristine uarch image or its hash, but the transpiled `UArchStep.sol` must be redeployed (not
  validated in a build). Hardwiring `readX(a, 0)` to 0 instead changes the access-log layout of every instruction that
  reads x0, so it is a log-format and on-chain compatibility change.
- **Risks:** as CM-02: where a non-canonical uarch template is accepted, an honest party cannot produce a uarch step
  proof that the chain accepts.

## CM-03 — `WRITE_TLB` uarch ecall does not bound-check `set_index`

- **Severity:** High. **Area:** uarch. **Category:** memory safety / divergence with the on-chain step.
- **Where:** `executeECALL` in `src/uarch-step.cpp` reads `set_index` from uarch register `a0` and passes it through
  `writeTlbECALL` (`src/uarch-solidity-compat.hpp:163`) to `machine::write_verified_tlb`/`write_unverified_tlb`
  (`src/machine.hpp:687-699`), which bound-checks `slot_index` but indexes `m_s->penumbra.tlb[set_index]` and
  `m_s->shadow.tlb[set_index]` (3-element arrays) without checking `set_index`.
- **Problem:** uarch code issuing `write_tlb` with `set_index >= 3` performs an attacker-controlled out-of-bounds write
  into host memory (offset `set_index * 8 KiB` past the TLB, with chosen `vaddr_page`, `vp_offset`, `pma_index`).
  `set_index` 3 or 4 silently corrupts adjacent memory and reports success; larger values crash. The Solidity step
  models the same ecall as a well-defined Merkle write, so the reference emulator cannot reproduce a transition the
  on-chain verifier accepts.
- **Evidence:** reproduced on `cm_run_uarch`, `cm_log_step_uarch` and `cm_collect_uarch_cycle_root_hashes` (release:
  SIGSEGV or silent corruption; ASan build: `std::array<...,3>::operator[]` assertion). Reachable on the very first big
  step of a template with custom uarch RAM (see CM-02).
- **Scenario:** a node that advances the uarch of an untrusted machine (dispute tooling, verification of a counterparty's
  template or snapshot) suffers in-process memory corruption.
- **Possible solution:** validate `set_index < TLB_NUM_SETS` (and `slot_index`) deterministically inside
  `executeECALL`/`writeTlbECALL` so the host and the Solidity step reject the same malformed ecall; keep a defensive check
  in `write_*_tlb`. Validated in a private build: no root-hash change.
- **Risks:** memory corruption in validator processes; host/on-chain disagreement on malformed uarch programs.

## CM-04 — RISC Zero step replay wraps `mcycle_end`

- **Severity:** High (Critical if a deployment accepts claimant-chosen or very large cycle counts).
- **Area:** ZK step verifier (`risc0/cpp`). **Category:** proof soundness / divergence.
- **Where:** `risc0/cpp/risc0-replay-steps.cpp:38` computes
  `__builtin_add_overflow(a.read_mcycle(), context.logged_mcycle_count, &mcycle_end)` and ignores the overflow flag;
  `machine::log_step`/`machine::verify_step` (`src/machine.cpp:2178`, `2205`) use `saturating_add`.
- **Problem:** when `mcycle + mcycle_count` overflows, the ZK guest replays 0 cycles (the wrapped `mcycle_end` is below
  `mcycle`), so it accepts a log claiming *no change* and rejects the honest log. This happens for any machine with
  `mcycle >= 1` when the claimed count is `UINT64_MAX` (the usual "run to completion" value), and for small counts on a
  machine whose mcycle is near 2^64. Host, uarch and the code transpiled to Solidity all saturate and agree.
- **Evidence:** compiling the unmodified `risc0-replay-steps.cpp` for the host and calling `risc0_replay_steps()`:
  honest 16-cycle log → "final root hash mismatch"; forged 0-cycle log with header `mcycle_count=16`,
  `root_hash_after = root_hash_before` → accepted (journal `before, 16, before`), while `cm_verify_step` rejects it with
  "required page not found".
- **Scenario:** a deployment that settles step proofs with the RISC Zero verifier accepts a false transition.
- **Possible solution:** `if (__builtin_add_overflow(...)) mcycle_end = UINT64_MAX;` (or `saturating_add`). Changes the
  risc0 Image ID, which on-chain verifiers pin.
- **Risks:** ZK and canonical verifiers disagree on valid transitions.

## CM-05 — `cm_replace_memory_range` leaves dangling host pointers in the hot TLB

- **Severity:** High. **Area:** memory / TLB. **Category:** memory safety, silent divergence.
- **Where:** `machine::replace_memory_range` (`src/machine.cpp:628-673`) → `machine_address_ranges::replace`
  (`src/machine-address-ranges.cpp`) unmaps the old range and maps the new one, but never calls
  `init_hot_tlb_contents()`; the hot TLB (`processor_state::penumbra.tlb`, not part of the hashed state) keeps raw host
  pointers into the old mapping.
- **Problem:** after any run that warmed the TLB, a replace leaves stale host pointers. The next guest access either
  crashes (SIGSEGV in `interpret.cpp`) or — when the new mapping reuses the freed address (e.g. replace flash0, then
  flash1) — silently reads/writes the wrong range: guest stores to flash0 land in flash1, the root hash is wrong, no error
  is reported, and ASan does not flag it. `cm_log_step` re-initializes the hot TLB first (`src/machine.cpp:2176`), so the
  same machine gives different results under `cm_run` and `cm_log_step`.
- **Evidence:** reproduced by the hunter and an independent verifier (crash and silent-divergence modes, also through a
  JSON-RPC server). Replacing with a cold TLB (before any run) is correct.
- **Scenario:** an integration that replaces a drive (e.g. an input drive) on a machine that has already run. The CLI and
  documentation only replace right after create/load (cold TLB), so their flows are safe; the C API places no such
  restriction.
- **Possible solution:** call `init_hot_tlb_contents()` (or flush the TLB) after `m_ars.replace(...)`, as the
  whole-shadow-state restore path already does. Validated: no root-hash change.
- **Risks:** crash, or silent state corruption leading to wrong commitments that the node's own step proofs contradict.

## CM-06 — Stored machines can carry a hash tree that does not match their data; loads trust it

- **Severity:** High. **Area:** store / load / hash tree. **Category:** wrong root hash / data integrity.
- **Where:** pages written through the write TLB are only marked dirty when evicted or at the next hash update — until
  then the mark lives only in the processor state. `machine::~machine()` (`src/machine.cpp:730`) and `machine::store()`
  (`src/machine.cpp:396`) persist the dirty-page tree without flushing those marks (`mark_write_tlb_dirty_pages()`), and in
  the affected modes the processor state is not saved alongside it. Since v0.22, `cm_load` trusts the persisted
  hash-tree files (`.dht/.dpt/.sht/.phtc`) and never recomputes or compares the root hash (earlier releases recomputed
  it and threw "stored and restored hashes do not match").
- **Problem:** documented workflows write stored machines whose hash tree does not match their data, and later loads
  report a stale root hash: (A) a flash drive with `shared` plus `dht_filename`/`dpt_filename` used by an in-memory machine
  (also reproduced with a Linux guest writing the drive with `dd`); (B) `--create` then `--load=dir,sharing:config`, run,
  exit; (C) `cm_store(..., CM_SHARING_CONFIG)`. A tampered or corrupted store is also accepted with its original root hash.
  `cm_verify_hash_tree` does not reliably detect it (it only checks page-level hashes).
- **Evidence:** all three scenarios are deterministic on the release build; `cm_get_root_hash` differs from a from-scratch
  recomputation, and `cm_log_step` then fails with "initial root hash mismatch".
- **Scenario:** a node that stores and reloads snapshots in these modes publishes claims for a state it cannot prove.
- **Possible solution:** call `mark_write_tlb_dirty_pages()` at the start of `store()` and in `~machine()` (validated, fixes
  A–C, no root-hash change); add an opt-in verify-on-load (recompute and compare) for untrusted snapshots; make
  `cm_verify_hash_tree` check the whole tree.
- **Risks:** silent wrong commitments; inability to produce proofs for one's own claims.

### Addendum to CM-06 — write-TLB dirty marks lost when the dirty-page tree is persisted without the processor state

- **Severity:** Medium for this mechanism on its own; it is the root cause of CM-06 scenarios A–C (CM-06's High rating
  also covers the absence of verification on load). High where stored `sharing:config` machines are used to build
  templates whose hash is registered on chain.
- **Area:** hash tree / store. **Category:** wrong root hash.
- **Where:** a page enters the write TLB without being marked dirty (`replace_tlb_entry`, `src/interpret.cpp:931-941`);
  it is marked only when its slot is overwritten (`write_verified_tlb`/`write_unverified_tlb`,
  `src/machine.hpp:689-691`, `:716-718`), when the TLB is flushed, or by `update_hash_tree()`/`verify_hash_tree()`
  (`src/machine.cpp:1534`, `:1605`). `machine::~machine()` (`:730-733`) and `machine::store()` (`:396`) do not flush the
  pending marks.
- **Problem:** the persisted dirty-page tree is only correct together with the shadow TLB. In modes that persist a
  range's `.dht/.dpt` but not the processor state (`sharing:config` with a shared range, a shared drive with its own
  hash-tree files in an in-memory machine, `cm_store(CM_SHARING_CONFIG)`), the marks are lost and the pages count as
  clean on reload. The dirty-page tree must be clean beforehand (a hash was computed on the stored machine); a freshly
  created directory has an all-dirty tree and hides the bug. Unlike CM-22, `cm_verify_hash_tree` detects this case.
- **Evidence:** the verifier reproduced it with a Linux guest through the plain CLI (`--create=dir --initial-hash` with
  a `shared` data drive; `--load=dir,sharing:config --max-mcycle=N` running `dd … oflag=direct`; `--load=dir
  --initial-hash`): stale root hash at 4 of 4 stop points. Sessions that end in a normal Linux halt were consistent
  (shutdown writes `satp`, which flushes the TLB and marks the pages), so with Linux the session must stop while the
  guest is still writing (a max-mcycle stop, or a yield or break right after a write). Test:
  `tests/bugs/stored-hash-tree-stale` (CM-06 scenarios A–C).
- **Scenario:** `sharing:config` is restricted by the CLI to `--revert-mode=none`, and the reference node uses
  `SHARING_ALL`, which persists the shadow TLB and is consistent on a clean exit; CLI and C API users of the
  `sharing:config` and per-drive hash-tree-file workflows are exposed.
- **Possible solution:** the flush in `~machine()` (inside try/catch) and at the start of `store()` proposed in CM-06
  fixes clean exits (validated; no root-hash change). It does not cover a crash during a `sharing:config` session;
  marking a page dirty when it enters the write TLB, instead of when it leaves, makes the persisted dirty-page tree
  self-sufficient and covers that case too, at a small rehash cost.

## CM-07 — JSON-RPC `fork` is allowed with a shared hash tree

- **Severity:** High. **Area:** JSON-RPC server / hash tree. **Category:** wrong hashes and proofs.
- **Where:** the fork guard (`src/jsonrpc-remote-machine.cpp:825`, via `src/machine.hpp:833`) only rejects shared
  address ranges and ignores `hash_tree.shared` (documented option, CLI `--hash-tree=...,shared`).
- **Problem:** parent and child keep the `.sht`/`.phtc` files `MAP_SHARED` (and their lock) and each keeps a private
  page→entry index into the shared cache. After one side recycles entries, the other returns its data for word-level
  `cm_get_proof`/`cm_get_node_hash` (root hash still correct, `cm_verify_hash_tree` true); after the stale side writes,
  the written page is marked clean with an old hash and the root hash stays wrong permanently. Under concurrent use the
  child server aborts on an intrusive-container assertion.
- **Evidence:** independent reproducers for the wrong-proof and wrong-root modes.
- **Scenario:** a node using a shared hash tree and fork-based snapshots/rollback (`cm_jsonrpc_fork_server`).
- **Possible solution:** refuse fork when `hash_tree.shared` is set (validated), or give the child private copies.
- **Risks:** wrong proofs and commitments from a seemingly healthy machine.

## CM-08 — Shared hash tree with private ranges pollutes the stored page-hash cache

- **Severity:** High. **Area:** hash tree. **Category:** wrong proofs / liveness of honest proofs.
- **Where:** the page hash-tree cache (`src/page-hash-tree-cache.hpp`, used by `src/hash-tree.cpp`) is trusted for clean
  pages without checking the entry against the dense-tree page hash.
- **Problem:** a session that loads a stored machine with the hash tree shared but address ranges private
  (`CM_SHARING_CONFIG` load of a machine stored with `hash_tree.shared`) writes cache entries for memory it then discards
  into the snapshot's `hash_tree.phtc`. Every later load (even `CM_SHARING_NONE`) returns word hashes of the discarded
  data. The root hash and `cm_verify_hash_tree` look correct, but word-level proofs are wrong and honest
  `cm_log_step_uarch` / `cm_log_send_cmio_response` fail ("Mismatch in root hash of 6th access").
- **Evidence:** reproduced by the hunter and an independent verifier (honest `log_step_uarch` fails at uarch step 708).
- **Scenario:** an honest node cannot produce the uarch step or input-delivery proof it needs and loses by timeout.
- **Possible solution:** verify each cache hit against the dense-tree page hash and rehash from memory on mismatch
  (validated), and do not write back cache entries for private (non-persisted) ranges.
- **Risks:** liveness failure in disputes.

### Addendum to CM-08 — further triggers and corrupted uarch-cycle hashes

- **Severity:** unchanged (High). Every known trigger is a non-default sharing configuration or a replace with
  hash-tree files; the reference node's `SHARING_ALL` clones keep the cache consistent.
- **Area:** hash tree (page hash-tree cache) / uarch-cycle hash collection. **Category:** wrong proofs and commitments.
- **Where:** the cache is keyed only by physical page address and persisted separately in `hash_tree.phtc`. Hits are
  used as-is in `get_page_proof` (`src/hash-tree.cpp:101-124`), `get_dense_node_hash` (`:566-585`) and `update_words`
  (`:778-807`, used by the uarch collector at `src/machine.cpp:2732` and `:2791`); `machine_address_ranges::replace`
  (`src/machine-address-ranges.cpp:630-654`) does not invalidate entries, and persisted entries are re-indexed as valid
  on load (`src/page-hash-tree-cache.hpp:490-491`).
- **Problem:** the root cause of CM-08 (cache entries of clean pages trusted without validation) has two further
  triggers: (1) `cm_replace_memory_range` with a backing store that brings its own `dht_filename`/`dpt_filename` (e.g.
  a drive of another stored machine): the new pages are clean, and the entries for the old contents at the same
  addresses survive; (2) the mirror configuration of CM-08, range shared and hash tree private (`CM_SHARING_CONFIG` load
  of a machine created on disk with a `shared` drive): updates persist in the range's `.bin/.dht/.dpt` while
  `hash_tree.phtc` keeps the old contents. Besides wrong word-level proofs and failing `cm_log_step_uarch`,
  `update_words` re-hashes only the words written during a uarch cycle on top of a stale hit and copies the entry's root
  into the dense tree (`:807`), so `cm_collect_uarch_cycle_root_hashes` returns wrong uarch-cycle root hashes (the
  uarch-level commitment). `cm_get_root_hash` and `cm_verify_hash_tree` look correct throughout.
- **Evidence:** in the test, after a drive is replaced with another stored machine's data, dht and dpt files, the root
  hash is correct but the word node hash and proof are wrong, and 668 of 3337 uarch-cycle root hashes up to mcycle 4
  differ from a fresh machine; a replacement with the data file only (control) is correct. The verifier reproduced
  trigger (2) through the CLI: wrong word proofs, `cm_log_step_uarch` failing ("siblings and read hash do not match root
  hash before 6th access to memory") and 671 of 9780 collected hashes wrong; zero-filling `hash_tree.phtc` restores
  correct results. Test: `tests/bugs/page-cache-stale-collect` (`shared-hash-tree-cache-pollution` still covers the
  original trigger).
- **Scenario:** an honest node whose uarch-level commitment is built with `cm_collect_uarch_cycle_root_hashes` on such
  a machine publishes wrong hashes and cannot back them with uarch step proofs.
- **Possible solution:** apply CM-08's hit validation (compare the entry root with the dense-tree page hash and rehash
  from memory on mismatch) in `update_words` as well as in `get_page_proof` and `get_dense_node_hash`. Validated for all
  triggers, including CM-08's: 0 of 9780 collected hashes differ, and no root hash changes. Invalidating a range's
  entries in `replace`, and clearing the phtc on load when ranges and hash tree are shared differently, are useful
  complements but not sufficient alone. Hit validation does not fix the root-hash corruption of CM-07, which still needs
  the fork refusal.
- **Risks:** as CM-08, plus wrong uarch-level commitments.

## CM-09 — JSON integers equal to 2^64 / 2^63 hit an undefined float-to-int conversion

- **Severity:** Medium. **Area:** JSON parsing (`src/json-util.cpp`). **Category:** host-dependent behaviour / input validation.
- **Where:** `src/json-util.cpp:810-817` (uint64; UB at 816) and `843-850` (int64; UB at 850).
- **Problem:** nlohmann parses integers above `UINT64_MAX` (e.g. `18446744073709551616`) and float-form numbers as
  `number_float`. The range check `f > (double)UINT64_MAX` passes for exactly 2^64 because the constant rounds up to
  2^64, and `static_cast<uint64_t>(f)` is undefined behaviour: x86-64 yields 0, AArch64/RISC-V saturate to 2^64−1. For
  uint32/16/8 fields, x86 accepts the value as 0 while ARM/RISC-V reject it.
- **Evidence:** UBSan reports the conversion in the real `json-util.cpp`. `cm_get_default_config` itself emits
  `imcyclemax` and `ilrsc` as `18446744073709551615`; after a JavaScript `JSON.parse`/`JSON.stringify` round trip (which
  produces `18446744073709552000`), an x86 host builds a machine with `imcyclemax = 0` that never executes an instruction
  (MCYCLE_OVERFLOW at mcycle 0) and has a different root hash; ARM hosts run normally. The same applies to JSON-RPC
  `machine.run` (`mcycle_end`) and Lua `fromjson`/`--load-config`.
- **Scenario:** a JavaScript/TypeScript client or tool that round-trips configs or requests through `JSON.parse`.
- **Possible solution:** reject `f >= 18446744073709551616.0` (2^64) and `f >= 9223372036854775808.0` (2^63)
  (validated; no root-hash change).
- **Risks:** platform-dependent machines and template hashes.

## CM-10 — `--load-config` ignores command-line fallbacks

- **Severity:** Medium. **Area:** CLI (`src/cartesi-machine.lua`). **Category:** wrong machine / template hash.
- **Where:** `cartesi-machine.lua:3056/3069` installs a metatable `{__index = <command-line config>}` on the loaded config,
  but `machine:create` serializes it with `clua_tojson`, which iterates with raw `lua_next`
  (`src/clua-i-machine.cpp:384-385`) and never consults `__index`.
- **Problem:** fields missing from the config file get the C++ defaults, not the command-line values, contradicting the
  `--load-config` help text ("...will fall back into the respective command-line argument..."). E.g. with
  `--hash-tree=hash_function:sha256 --no-htif-yield-automatic`, the machine still uses Keccak-256 and both yield types.
- **Evidence:** confirmed by running the CLI and comparing root hashes.
- **Scenario:** a developer builds a template with `--load-config` plus overrides and registers a template hash for a
  machine different from the one intended.
- **Possible solution:** merge the fallback table explicitly in Lua (deep copy with defaults) before calling `create`.
- **Risks:** wrong on-chain template hash; hard-to-debug mismatch between environments.

## CM-11 — `--revert-mode=stored` undoes `--replace-memory-range`

- **Severity:** Medium. **Area:** CLI / C++ (`machine::replace_memory_range`). **Category:** silent data loss, wrong printed hash.
- **Where:** `machine::replace_memory_range` (`src/machine.cpp:673`) does not record the replacement in the machine
  config; with `--revert-mode=stored`, `make_revert_stored`/`snapshot` (`cartesi-machine.lua:3693-3703`) destroys the
  machine and reloads it from the stored directory, discarding the replacement applied at `cartesi-machine.lua:3100-3103`.
- **Problem:** `--initial-hash` (printed at `cartesi-machine.lua:3636`, with the replacement) differs from the machine that
  actually runs (original drive); with 0 cycles executed the final hash differs from the printed initial hash.
- **Evidence:** confirmed from source and the hunter's CLI run.
- **Scenario:** a developer replaces an input drive and uses stored revert mode (required for some clone/sharing setups);
  the run silently uses the original drive while printing the hash of the replaced one.
- **Possible solution:** record replacements in the machine config (so `store`/`get_initial_config` reflect them) or re-apply
  them after the revert reload.
- **Risks:** wrong outputs and hashes in rollup development flows.

## CM-12 — Nested JSON/table conversion overflows the Lua stack

- **Severity:** Medium. **Area:** Lua bindings (`src/clua-i-machine.cpp`). **Category:** memory safety.
- **Where:** recursive converters `clua_push_managed_toclose_json_ref` (`src/clua-i-machine.cpp:364-433`) and
  `clua_push_json_value` (`436-512`) push ~4 Lua slots per nesting level and never call `lua_checkstack`
  (no `lua_checkstack`/`luaL_checkstack` anywhere in `src/clua*`). A C function only has `LUA_MINSTACK` (20) guaranteed slots.
- **Problem:** nesting depth ~8 (tojson) / ~30 (fromjson) writes past the Lua stack allocation (ASan: heap-buffer-overflow
  in `lua_newuserdatauv` ← `clua_push_managed_toclose_json_ref`); the release CLI segfaults on a 1000-level
  `--load-config` JSON.
- **Evidence:** ASan trace with an ASan-built Lua; release CLI exit 139.
- **Scenario:** tooling that feeds JSON from untrusted sources (proof files, epoch frontier files via the CLI) into the
  bindings. Not reachable from guest code or machine-produced data (fixed shallow schemas), nor from the C API.
- **Possible solution:** `luaL_checkstack(L, 8, ...)` at the top of each recursive step plus an explicit depth limit.
- **Risks:** memory corruption in Lua-based tooling.

## CM-13 — Cyclic virtqueue descriptor chain hangs the host

- **Severity:** Medium (development-only feature). **Area:** VirtIO (`src/virtio-address-range.cpp`). **Category:** denial of service.
- **Where:** `virtq::get_desc_rw_avail_len` (`src/virtio-address-range.cpp:157`), `read_desc_mem` (`200`),
  `write_desc_mem` (`247`) follow `desc.next` in `while (true)` loops with no bound; reached from
  `on_device_queue_notify` (`490`) on every `QUEUE_NOTIFY` MMIO write (`726`). `QUEUE_NUM = 0` is also accepted
  (`is_power_of_2(0)` is true).
- **Problem:** a guest that links a descriptor to itself (or a 2-cycle) makes `cm_run` loop forever at 100% CPU.
- **Evidence:** independent reproducer with a 2-node cycle on virtio-console hangs; a terminating chain returns normally.
- **Scenario:** developers or services running untrusted machine images with VirtIO devices (console, 9P, network).
  Reproducible (proof) machines cannot use VirtIO.
- **Possible solution:** bound each chain walk to `vq.num` descriptors (and reset the device / mark it broken on
  overflow); reject `QUEUE_NUM == 0`. No root-hash impact.
- **Risks:** host hang.

## CM-14 — VirtIO 9P: guest symlinks can point outside the shared directory

- **Severity:** Medium (development-only feature). **Area:** VirtIO 9P (`src/virtio-p9fs-address-range.cpp`). **Category:** host isolation.
- **Where:** `op_symlink` (`src/virtio-p9fs-address-range.cpp:1310/1335`) passes the guest-supplied target to
  `symlink(2)` unchanged; `op_lopen` (`1187`) and `op_walk` resolve host paths with plain `open`/`lstat` and no
  `O_NOFOLLOW`/`openat2(RESOLVE_BENEATH)` containment (textual `..` above the root *is* blocked at `2218`).
- **Problem:** a guest speaking raw 9P can create `<share>/x -> /some/host/path` and then open it, reading or writing host
  files outside the share. The stock Linux 9P client resolves symlinks guest-side, so a plain `ln -s` + `cat` from a shell
  does not escape; a custom 9P client in the guest does.
- **Evidence:** confirmed by code review by two reviewers; the stock-client behaviour was confirmed by execution. No
  executable regression test is included.
- **Scenario:** a developer shares a host directory with an untrusted machine image.
- **Possible solution:** resolve every path relative to a pinned root directory fd with `openat2(..., RESOLVE_BENEATH)`
  (or `O_NOFOLLOW` on every component), not only validate symlink targets.
- **Risks:** host file disclosure/modification on developer machines.

## CM-15 — Deeply nested JSON request crashes the JSON-RPC server

- **Severity:** Medium. **Area:** JSON-RPC server (`src/jsonrpc-remote-machine.cpp`). **Category:** denial of service.
- **Where:** unbounded `json::parse` (`:1915`) with no depth limit and `body_limit = UINT64_MAX` (`:202`); the batch path
  copies/destroys recursively (`:1923/1930`).
- **Problem:** a ~200,000-level nested request (~400 KB) overflows the stack (SIGSEGV), killing the server and the machine
  it holds; the signal escapes the try/catch.
- **Evidence:** reproduced independently (wait status 139). Depth 20,000 is answered normally.
- **Scenario:** any local process that can reach the server port (no authentication; default bind is loopback).
- **Possible solution:** SAX depth limit and a sane `body_limit`; same hardening on the client response path
  (`src/jsonrpc-machine.cpp:246/297`).
- **Risks:** loss of in-memory machine state of a node.

## CM-16 — JSON-RPC batch containing `fork` keeps executing in the child

- **Severity:** Medium. **Area:** JSON-RPC server. **Category:** logic error / denial of service.
- **Where:** the batch loop `for (auto ji : j) { ... jsonrpc_dispatch_method(ji, session); }` (`:1930`) and
  `jsonrpc_fork_handler` (`:823`), whose child branch (`:842-859`) falls through to the normal response.
- **Problem:** both parent and child continue the same batch, so every later entry runs in both processes; a batch of N
  forks creates 2^N servers.
- **Evidence:** a 3-fork batch produced exactly 8 persistent servers. The official client never sends batches.
- **Scenario:** raw JSON-RPC clients or other local processes.
- **Possible solution:** in the child, stop processing the batch after the fork (or forbid `fork` inside batches).
- **Risks:** duplicated non-idempotent operations, host resource exhaustion.

## CM-17 — JSON-RPC unbounded allocations sized by the request

- **Severity:** Medium. **Area:** JSON-RPC server. **Category:** denial of service.
- **Where:** `machine.read_memory` / `read_virtual_memory` / `read_console_output` handlers (`:1403/1437/1495`) allocate
  `length`/`max_length` bytes before doing anything else.
- **Problem:** 256 MiB reads drive server peak RSS to ~1 GB; a 2^40 request attempts a 1 TiB allocation (OOM kill under
  default overcommit; clean `bad_alloc` only under `ulimit -v`).
- **Evidence:** independent measurements of peak RSS and the `ulimit -v` behaviour.
- **Possible solution:** cap lengths (e.g. to the size of the addressed range or a configurable limit) and stream large reads.
- **Risks:** node process OOM-killed.

## CM-18 — Fault-generated SIGBUS makes the JSON-RPC server spin forever

- **Severity:** Medium. **Area:** JSON-RPC server. **Category:** denial of service / liveness.
- **Where:** SIGBUS is added to the Boost.Asio `signal_set` (`src/jsonrpc-remote-machine.cpp:321`); Asio's handler only
  writes to a pipe and returns, so the faulting instruction re-executes forever.
- **Problem:** a SIGBUS raised by a memory access (e.g. a guest `ld` from a flash drive whose backing file was truncated, or
  a full disk under a machine stored with sharing) leaves the server at 100% CPU, never replying and ignoring SIGTERM. The
  client's default timeout is infinite, so the node blocks forever. A local machine in the same situation dies with SIGBUS.
- **Evidence:** reproduced from guest code with a truncated backing file.
- **Possible solution:** do not intercept synchronous fault signals (remove SIGBUS from the set) — validated: the server exits
  and the client gets an immediate error.
- **Risks:** node hang.

## CM-19 — `const` C API queries are not thread-safe on one machine

- **Severity:** Medium. **Area:** C API / hash tree. **Category:** data race.
- **Where:** `cm_get_root_hash`/`cm_get_proof` take `const cm_machine *` but run a full hash-tree update on `mutable` state
  and an unsynchronized memory pool.
- **Problem:** two threads querying the same idle machine get spurious "entry already borrowed" errors; 4 of 20 runs aborted
  with glibc heap corruption (`free(): invalid pointer`). `cm.h` makes no thread-safety statement.
- **Evidence:** independent reproducer; serializing with a mutex is clean.
- **Possible solution:** internal locking for these entry points, or document that a machine object must not be used
  concurrently (even through `const` functions).
- **Risks:** heap corruption in multi-threaded node code.

## CM-20 — `cm_log_step(N)`/`cm_verify_step(N)` and the RISC Zero replay stop at the first automatic yield

- **Severity:** Critical, conditional on disputes being settled with step logs or RISC Zero proofs (`cm_log_step` →
  `cartesi-risc0-cli prove` → `CartesiStepVerifier`); High where that path is not used. The in-repo PRT recipe
  (`doc/recipes/prt.lua`) settles the bottom level with uarch steps and is not affected.
- **Area:** step logs / RISC Zero step verifier. **Category:** divergence between execution paths / proof soundness.
- **Where:** `machine::log_step` (`src/machine.cpp:2171-2190`, single `interpret()` call at `:2180`),
  `machine::verify_step` (`:2192-2210`, call at `:2207`) and `risc0_replay_steps`
  (`risc0/cpp/risc0-replay-steps.cpp:38-39`) call `interpret()` once; `interpret()` returns `yielded_automatically` as
  soon as `iflags.X` is set (`src/interpret.cpp:6398-6399`; the loop commits state and returns on `success_and_yield`,
  `:6310-6328`).
- **Problem:** when the guest performs an automatic yield (HTIF yield automatic: tx-output, tx-report, progress)
  strictly inside an N-mcycle step, the logged and replayed transition ends at the yield (mcycle start+k, k < N), while
  the log header still records `mcycle_count = N`. `cm_verify_step` returns, and the RISC Zero journal commits,
  `(root_hash_before, N, state at the yield)`; `CartesiStepVerifier.verifyStep` documents `mcycleCount` as the
  "Expected number of machine cycles executed". Every other path treats the automatic yield as a non-fixed point and
  reaches start+N: `cm_run` resumed by its caller, `cm_collect_mcycle_root_hashes` (loops to the target,
  `src/machine.cpp:2373`), `cm_collect_mcycle_bundle` (documented to continue through automatic yields,
  `src/machine.hpp:281`, `src/cm.h:905-906`) and the uarch (one mcycle per big step). `cm.h` documents the count as the
  number of mcycles to run (`:1040`) and the "Number of mcycles in the step" (`:1098`). `cm_log_step` does report
  `CM_BREAK_REASON_YIELDED_AUTOMATICALLY` with the machine left at start+k, but no single log can cover the N cycles,
  and nothing on the verifier side (log header, journal, `cm_verify_step`) reveals the early stop. Only the automatic
  yield is affected: the record/replay accessors are non-interactive, so console output never breaks the loop
  (`do_putchar` returns false, `src/record-step-state-access.hpp:357`, `src/replay-step-state-access.hpp:598`), soft
  yields are honoured only for interactive accessors (`src/interpret.cpp:3286`), and halt, manual yield and mcycle
  overflow are fixed points on every path.
- **Evidence:** the test runs a bare-metal guest that performs a progress yield at mcycle 37 of a 64-mcycle window.
  `cm_run` resumed after the yield and 64 uarch big steps agree (`6dbcfbaf…`), while `cm_log_step(64)` stops at mcycle 37
  and `cm_verify_step(64)` returns that state (`96050216…`); the same guest without the yield agrees on all paths. The
  hunter and the verifier also reproduced it on a SHA-256 machine (the ZK configuration) and on the Linux test image
  (`yield automatic progress`, 4096-mcycle step), and showed that logs split at the yield (57+7, or 64×1) match `cm_run`;
  console-output and soft-yield events inside a step do not diverge. Test: `tests/bugs/log-step-automatic-yield`.
- **Scenario:** a dispute whose bottom level proves a leaf interval of the mcycle computation hash with one step log or
  RISC Zero proof (SHA-256 machines, which cannot use the uarch, have only this path). Any interval that contains a
  voucher, notice, report or progress yield, i.e. almost every rollup input, is affected: an unmodified emulator
  produces a valid proof that the state at the yield is the state after N mcycles, and the honest leaf cannot be proved
  with a single step log.
- **Possible solution:** continue through automatic yields in all three places, identically for record and replay (loop
  while `interpret()` returns `yielded_automatically`, or until a fixed point or `mcycle_end`), preferably in one helper
  shared by `log_step`, `verify_step` and `risc0_replay_steps`, which would also prevent drift such as CM-04. Validated
  for `log_step`/`verify_step`: the result equals `cm_run`, the uarch, `cm_collect_mcycle_bundle` and the chain of
  1-cycle logs; no root hash changes.
- **Risks:** if unfixed, step-log and ZK proofs over batches are unsound and incomplete for any batch with an output or
  report. The fix changes the RISC Zero image ID, so the `ImageID` pinned by `CartesiStepVerifier` must be updated;
  existing logs that end at an automatic yield before N cycles stop verifying, which is intended.

## CM-21 — `cm_log_step` and `cm_get_node_hash` abort on hash-tree nodes in the padding of a non-power-of-two range

- **Severity:** High; Critical for deployments that settle disputes with `cm_log_step`/ZK proofs. Affects the default
  (`relwithdebinfo`) build, which is also what the Docker/Debian packaging builds (`Dockerfile:62-63`).
- **Area:** hash tree / step logs. **Category:** liveness of honest proofs / process abort.
- **Where:** `hash_tree::get_dense_node_hash` (`src/hash-tree.cpp:566-585`) starts with
  `assert(ar.contains_absolute(address, HASH_TREE_WORD_SIZE))` (`:567`), but `hash_tree::get_node_hash` (`:587-625`)
  passes it any node inside the range's power-of-two span (`:616`). Reached from
  `record_step_state_access::get_sibling_hashes_impl` (`src/record-step-state-access.hpp:199-213`) through `finish()` in
  `machine::log_step` (`src/machine.cpp:2185`), and directly from `cm_get_node_hash` and JSON-RPC
  `machine.get_node_hash`. The default build disables asserts only for `interpret.cpp` (`src/Makefile:204`, `:212`).
- **Problem:** a range's dense tree covers `bit_ceil(page_count)` pages (`src/address-range.hpp:340`); padding leaves are
  marked dirty at creation (`src/dirty-page-tree.hpp:113`) and receive the pristine page hash on update
  (`src/hash-tree.cpp:390-393`), so padding nodes at page level and above hold correct hashes. When a step touches a
  page in the last, partially filled power-of-two block of a range, one of the untouched sibling subtrees that
  `log_step` requests starts at or past the range end, and the assertion aborts the process. In an NDEBUG
  (`release=yes`) build the same call returns the pristine hash and the log verifies, so the assertion is wrong for
  these nodes. For sub-page nodes (reachable only through `cm_get_node_hash`) the assertion hides the wrong-data path of
  CM-25, so it cannot simply be removed. `cm_get_proof` and `cm_log_step_uarch` read the dense tree without this
  assertion and are unaffected.
- **Evidence:** in the test (64 KiB RAM, 3-page flash drive), `cm_log_step(1)` over an `ld` from the drive's last page
  and `cm_get_node_hash` on the padding page abort with the `hash-tree.cpp:567` assertion; the controls (4-page drive;
  load from page 0) verify and match `cm_run`. With the Linux test image (rootfs of 0x15dd1000 bytes at 0xA0000000, span
  2^29), every step touching [0xB0000000, 0xB5DD1000), about 27% of the drive, needs node (0xB8000000, 2^27): the
  verifier saw `cm_log_step(1)` at mcycle 31464660, CLI `--log-step` and a JSON-RPC server (`get_node_hash`) abort,
  while uarch step logs of the same mcycle and the fixed build give the `cm_run` root hash.
  Test: `tests/bugs/step-log-padding-assert`.
- **Scenario:** an honest node must produce a big-step log (CLI `--log-step`, JSON-RPC `log_step`, input to the RISC Zero
  prover) for a cycle that touches the tail of a flash drive whose length is not a power of two, which is common for
  rootfs and application images. With the packaged library the process aborts and no proof is produced; in a ZK-settled
  dispute the counterparty can choose such a cycle.
- **Possible solution:** in `get_dense_node_hash` (or `get_node_hash`), return `m_pristine_hashes[log2_size]` for nodes
  that start at or past `ar.get_end()`, and keep the containment check for the page-cache path. Validated together with
  the CM-25 fix: `log_step` matches `cm_run` and the uarch, and padding node hashes are pristine. No root hash or proof
  changes (NDEBUG builds already return these values) and no on-chain or RISC Zero change. Ship together with CM-25.
- **Risks:** if unfixed, honest parties cannot produce step logs for a large class of steps with packaged builds.
  Removing the assertion without the CM-25 fix turns the sub-page abort into a silent wrong answer.

## CM-22 — A crash during a shared hash-tree update leaves a stored machine with a permanently wrong root hash

- **Severity:** High. Requires a process crash; not Critical because the reference PRT node discards crashed
  `SHARING_ALL` working clones. Nothing documents that resuming a crashed live directory is unsupported.
- **Area:** hash tree / stored machines. **Category:** crash consistency / wrong root hash / denial of service.
- **Where:** with `sharing:all` (or a machine created with a directory), the `.dht`, `.dpt`, `hash_tree.sht` and
  `hash_tree.phtc` files are `MAP_SHARED`, so a partial update survives process death.
  `hash_tree::return_updated_dirty_pages` (`src/hash-tree.cpp:263-351`) writes each new page hash into its dense-tree
  leaf (`:308`) and marks a page whose leaf already equals the new hash clean without queuing its range for the inner
  updates (`:342`); `hash_tree::update` (`:694-706`) cleans the dirty-page trees only after the dense and sparse updates
  succeed (`:702`); `update_sparse_tree` (`:488-560`) persists `marked = 1` before a node is recomputed (`:509`, `:524`,
  `:553`) and never queues a node whose mark is already set, and the constructor accepts persisted marks (`:940-946`).
  The `page_hash_tree_cache` constructor (`src/page-hash-tree-cache.hpp:418-494`) keeps persisted `borrowed` flags;
  `borrow_entry` then throws "page hash-tree cache entry already borrowed" (`:533-536`), bypassing the cache reset in
  `update_dirty_pages` (`src/hash-tree.cpp:416-419`).
- **Problem:** `update()` is not idempotent across a crash. If the process dies after some dense leaves were written but
  before the inner nodes and the sparse tree are recomputed, the reloaded pages are still dirty but their leaves already
  "match", so they are marked clean and their range is never recomputed: the root hash stays wrong in every later load.
  A crash after a sparse node's `marked` flag was persisted has the same effect. Cache entries borrowed by the
  interrupted batch stay borrowed in the shared phtc: hashing then fails permanently, or fails once with "update hash
  tree failed" (which clears the cache) and the retry returns a wrong root hash. `cm_verify_hash_tree` returns true on
  these directories: `hash_tree::verify` (`src/hash-tree.cpp:628-692`) compares only page leaves with memory and dirty
  flags, never inner dense or sparse nodes or cache entries, and reports a dense-root/sparse-leaf mismatch only on stderr
  (`:685-687`) without failing (`cm.h:1143` documents it as an internal-test helper).
- **Evidence:** the test loads a 32 MiB stored machine with `CM_SHARING_ALL` in a child process, dirties all RAM and
  calls `cm_get_root_hash`; the parent sends SIGKILL after a random delay, reloads the directory and compares its root
  hash with a fresh machine built from the RAM data file alone. In a run of the test, all 3 kills that landed during the
  update gave a wrong root hash (2 of them after a first "update hash tree failed"). The verifier's 64 MiB variant gave
  5 silent wrong root hashes and 2 permanent hashing failures in 6 kills (10 of 10 wrong at 128 MiB), with the data on
  disk correct and `cm_verify_hash_tree` true in every wrong case. The hunter placed kills at fixed points and
  confirmed both windows (a kill after the dense trees are complete but before any sparse mark is set recovers).
  Test: `tests/bugs/crash-during-hash-update`.
- **Scenario:** a node or CLI user running a stored machine with `sharing:all` (`--load=dir,sharing:all`,
  `--revert-mode=stored`, `CM_SHARING_ALL`; the documented "rolling from storage" workflow) is OOM-killed or stopped
  while computing a root hash, which is a large share of run time with hash collection. After restart, the directory
  reports a root hash that does not match its data, so claims are wrong and `cm_log_step`/uarch logs fail with root
  mismatches, or the directory cannot be hashed at all.
- **Possible solution:** (a) queue the range of every returned dirty page for the inner updates instead of marking
  unchanged-leaf pages clean; (b) reset persisted `marked` flags when the sparse tree is mapped; (c) clear the page cache
  in its constructor when any persisted entry is borrowed, and make `update_dirty_pages`/`update_words` exception-safe.
  (a)+(b)+(c) validated together: 6 of 6 random kills reload with the correct root hash, and no correct root hash
  changes. (c) must not ship without (a)+(b), otherwise the hashing failure turns into a silent wrong hash. A persisted
  "update in progress" flag that forces all pages dirty and clears the cache on load is a more robust alternative (it
  also covers torn LRU updates and the `update_words` window). Make `cm_verify_hash_tree` recompute inner nodes, fail on
  the dense/sparse mismatch and check the cache entries of clean pages.
- **Risks:** if unfixed, one process crash silently and permanently corrupts a stored machine's commitments. The fix
  only adds inner-node rehashing along dirty-but-unchanged paths.

## CM-23 — Committed WRITE-TLB slots that target non-writable ranges are accepted

- **Severity:** High. Requires crafted committed state (a template or snapshot); honest execution never produces such a
  slot. Rises toward Critical where templates are not vetted.
- **Area:** shadow TLB validation / interpreter. **Category:** divergence between host paths / memory safety.
- **Where:** `shadow_tlb_verify_slot` (`src/shadow-tlb.hpp:152-182`) checks the invalid marker, padding, alignment,
  `ar.is_memory()` and page bounds, but not the permission required by the slot's set. Slots it accepts become hot
  entries in `machine::init_hot_tlb_slot` (`src/machine.cpp:262-285`), in the step replay
  (`src/replay-step-state-access.hpp:547-560`) and in the interpreter compiled into the uarch image
  (`uarch/uarch-bridge-state-access.hpp:179-187`); the fast store path then writes through them
  (`src/interpret.cpp:1170-1173`). The slow paths do check W (`:1108`), R (`:992`) and X (`:5551`).
- **Problem:** a committed `TLB_WRITE` slot that points at an in-bounds memory range with W=0 is used for stores. The
  host interpreter (`cm_run`, `cm_collect_mcycle_*`), `cm_log_step`/`cm_verify_step`, the uarch image and therefore the
  on-chain step all perform the store; the host uarch driver (`cm_run_uarch`, `cm_log_step_uarch`,
  `cm_collect_uarch_cycle_*`) refuses it through a host-only guard in `machine::write_word` (`src/machine.cpp:1953`),
  which the uarch replay (`src/uarch-replay-state-access.hpp:359-361`) and the Solidity step do not have. A node
  therefore cannot produce uarch-level commitments or uarch step proofs for a transition the on-chain verifier accepts.
  Affected targets are the PMA table at 0x10000 (always present), read-only flash drives and NVRAMs. A store into the
  PMA table changes committed PMA entries; `cm_run` keeps using its in-memory address map while the replay, the uarch
  and the on-chain step decode ranges from the committed table, so later steps can diverge (and, per code review, a
  stored copy no longer loads). When the target is mapped read-only on the host (a loaded machine, or a file-backed
  read-only drive), the store kills the process with SIGSEGV. Such slots enter committed state through the full-shadow
  `cm_write_memory(0, …, 0x8000)` "manual snapshot" path (`src/machine.cpp:1732-1745`) or a stored directory (load does
  not validate TLB slots eagerly).
- **Evidence:** in the test, the control (an honest store to the PMA table) raises a store access fault and leaves the
  table unchanged; with a crafted WRITE slot, `cm_run` overwrites the first PMA entry (`0x800000fd` → `0x55`) on a
  created machine, and is killed by SIGSEGV on a stored-and-loaded machine and on a read-only flash drive. The hunter
  also showed `cm_run_uarch` refusing ("attempted memory write to read-only PMAs") while `cm_log_step` and
  `cm_verify_step` accept the `cm_run` result, and a fuzzer-found case where the PMA-table write makes a later
  `cm_log_step` fail its own self-check. The verifier re-ran these PoCs (release and ASan builds agree); the fix was not
  validated in a build. Test: `tests/bugs/write-tlb-readonly-target`.
- **Scenario:** a node that loads a template or snapshot from an untrusted source can crash in `cm_run`, or compute
  commitments it cannot back with uarch proofs, and its `cm_run` state can drift from the on-chain interpretation of the
  committed PMA table.
- **Possible solution:** make `shadow_tlb_verify_slot` set-aware and reject `TLB_WRITE` slots whose range is not
  `is_writeable()` (for completeness also `TLB_READ` without `is_readable()` and `TLB_CODE` without `is_executable()`).
  `is_writeable()` is decoded from committed PMA flags and `host_read_only` implies W=0
  (`src/memory-address-range.cpp:49`), so the host, the replay, the uarch image and the Solidity step can apply the same
  check. It must live in the shared header: a host-only check would make the host fault where the uarch and the chain
  store. Keep the `machine::write_word` guard as defence in depth.
- **Risks:** the fix changes the uarch RAM image, hence the pristine uarch hash, every root hash and the Solidity
  `UARCH_PRISTINE_STATE_HASH`; it needs a coordinated uarch/on-chain release. Honest states are unaffected. If unfixed,
  nodes crash on untrusted snapshots and cannot produce uarch proofs for such states.

## CM-24 — uarch `require()` is an `assert()`: a misaligned uarch access aborts the process

- **Severity:** Medium; High for a service that verifies uarch step logs whose pre-state hash and log are both supplied
  by untrusted parties.
- **Area:** uarch / step verification. **Category:** process abort / build-dependent divergence.
- **Where:** `require(condition, message)` is `assert((condition) && (message))`
  (`src/uarch-solidity-compat.hpp:251-254`). It guards the alignment checks of `readUint64/32/16`, `writeUint64/32/16`
  and `copyBits` (`src/uarch-step.cpp:36-101`), the first being the instruction fetch `readUint32(a, pc)` (`:1101`). The
  default build keeps asserts in `uarch-step.cpp` (`src/Makefile:212`); only `release=yes` disables them (`:215`).
- **Problem:** the same misaligned uarch fetch or access aborts the process in the default build and in the official
  v0.22.0-test2 binaries, is executed and proved in a `release=yes` build (a shifted instruction word; for a misaligned
  `ld`, log and verify accept an aligned-down word while `cm_run_uarch` throws, `src/machine.cpp:1915`), and reverts in
  the Solidity step. All other uarch failures throw `std::runtime_error` and map to a C API error, and the record/replay
  accessors were written to log and verify misaligned accesses "instead of aborting"
  (`src/uarch-record-state-access.hpp:79-80`). The pristine uarch never misaligns. Reachable (a) with non-pristine uarch
  state (custom uarch RAM image, uarch registers in the config or a stored machine, `cm_write_reg`/`cm_write_memory`; the
  CM-02 input class) through `cm_run_uarch`, `cm_log_step_uarch` and `cm_collect_uarch_cycle_*`; (b) through the static
  `cm_verify_step_uarch(NULL, root_hash_before, log)` and the JSON-RPC `machine.verify_step_uarch` handler, which needs
  no machine (`src/jsonrpc-remote-machine.cpp:1229-1238`), when the pre-state hash itself commits to a misaligned uarch
  pc. The chain is never more permissive than the host, so no invalid transition becomes provable on-chain.
- **Evidence:** in the test, a 16-byte custom uarch RAM image (`lui t0,0x600; jalr x0,10(t0)`; JALR clears only bit 0)
  makes the third uarch step fetch from 0x60000a: `cm_run_uarch`, `cm_log_step_uarch` and static `cm_verify_step_uarch`
  on a log built from `cm_get_proof` abort at `uarch-solidity-compat.hpp:253`; a control log for a halted uarch is
  accepted. The verifier saw the same abort for collection, bundles, a JSON-RPC server with no machine loaded and the
  official binaries, and a forge test against machine-solidity-step PR #104 reverts the step ("misaligned readUint32
  address") that a `release=yes` emulator logs and accepts. Test: `tests/bugs/uarch-require-abort`.
- **Scenario:** a verification service or a shared JSON-RPC server that checks uarch step logs received together with
  their pre-state hash terminates on one malformed input, for all its clients; a node that advances the uarch of a
  template with a non-canonical uarch crashes instead of getting an error; `release=yes` tooling produces uarch proofs
  the chain rejects.
- **Possible solution:** make `require` throw on the host (`if (!condition) throw std::runtime_error(message);`), which
  matches Solidity's revert in every build type. Validated: every path returns "misaligned readUint32 address", 2000
  pristine uarch steps give the same root hash, and no on-chain artefact changes (the transpiler maps `require` to
  Solidity's `require` regardless of its C++ body). Every `require` fires before the step's first write. Complementary:
  the pristine-uarch entry check proposed in CM-02, which cannot cover the static verifier.
- **Risks:** if unfixed, denial of service of processes that verify untrusted logs, and build-dependent results.

## CM-25 — Word-level proofs and node hashes in the padding of a range use a stale page-cache entry

- **Severity:** Medium. The result is a detectable wrong answer (the proof does not fold to the root hash), and no
  protocol flow requests padding words.
- **Area:** hash tree / proofs. **Category:** wrong proofs returned by the API.
- **Where:** `hash_tree::get_page_proof` (`src/hash-tree.cpp:101-124`) and the sub-page branch of
  `get_dense_node_hash` (`:568-580`) borrow a page-cache entry even for a page in the power-of-two padding of a range.
  On a miss, `borrow_entry` hands out an evicted LRU entry without clearing it (`src/page-hash-tree-cache.hpp:557-568`);
  `update_dirty_page` returns `false` without filling it because the page is outside the range
  (`src/hash-tree.cpp:232-233`), and both callers ignore the return value (`:106-109`, `:574-577`).
- **Problem:** `cm_get_proof`/`cm_get_node_hash` with `log2_size < 12` for an address in the padding of a
  non-power-of-two range return another page's hashes once the cache is full (default `phtc_size` 4096 pages).
  `cm_get_proof` does so silently in every build; `cm_get_node_hash` aborts in assert-enabled builds (CM-21) and returns
  the wrong hash in NDEBUG builds. Page-level and larger queries, root hashes, and step and uarch logs are unaffected.
  This is a separate defect from CM-21 (wrong data rather than an over-strict assertion) on the same theme.
- **Evidence:** in the test (64 KiB RAM, 3-page flash drive, `phtc_size` 4, cache filled with non-pristine pages),
  `cm_get_proof(0x90003040, 5)` returns target `0x4530df81…` instead of the pristine word hash `0x290decd9…` and folds to
  `0x57fde0fa…` instead of the machine root `0x9e87b220…`; `cm_get_node_hash` on the same word aborts. The hunter
  reproduced it with the default cache size (RAM of 4097 pages). Test: `tests/bugs/proof-padding-stale`.
- **Scenario:** a client asks for a word proof of a padding location (for example to show that a region is empty) and
  receives an invalid proof; verifiers reject it.
- **Possible solution:** when the page is not inside the range, skip the cache and build the proof or node hash from
  `m_pristine_hashes` (the target and all sub-page siblings are pristine); handle the `false` return of
  `update_dirty_page` (return the entry and throw) instead of ignoring it. Validated together with the CM-21 fix; no
  root hash or compatibility change.
- **Risks:** wrong API results; must land with CM-21 so that removing that assertion does not expose this path.

## CM-26 — `cm_log_step` accepts unreproducible machines

- **Severity:** Low (upper end): it requires a machine configured with `iunrep=1`, which cannot be stored and is never a
  rollup template, but the abort comes from a supported call.
- **Area:** step logs / reproducibility guard. **Category:** missing guard / process abort.
- **Where:** `machine::log_step` (`src/machine.cpp:2171-2190`) has no `is_unreproducible()` check, unlike
  `log_step_uarch` (`:2079`), `run_uarch` (`:2124`), the collectors (`:2325`, `:2489`, `:2635`) and `store` (`:400`);
  the CLI asserts `iunrep == 0` for `--log-step-uarch` (`src/cartesi-machine.lua:4675`) but not for `--log-step`
  (`:4644-4649`). `virtio_address_range::do_write_device` is `noexcept` (`src/virtio-address-range.cpp:836-837`) while
  the `record_step_state_access` memory accessors throw (`src/record-step-state-access.hpp:254`, `:262`); the replay has
  no VirtIO mock (`src/mock-address-range.hpp:73`).
- **Problem:** on an unreproducible machine, `cm_log_step` (A) logs, and `cm_verify_step` accepts, a transition that
  differs from `cm_run`: the record accessor is non-interactive, so WFI does not fast-forward with host time and HTIF
  getchar returns no character; (B) on a VirtIO register access, executes the whole step on the live machine and only
  then fails its self-check ("unhandled mock address range"), leaving the machine advanced and the log file written;
  (C) on a VirtIO queue notify (done by every Linux virtio driver), throws through the `noexcept` callback, so
  `std::terminate` aborts the embedding process, the JSON-RPC server or the CLI. Nothing documents that `log_step`
  accepts such machines.
- **Evidence:** in the test, the WFI case logs a step that ends at mcycle 5 (root `a7e232df…`, accepted by
  `cm_verify_step`) while `cm_run` from the same root reaches `47adcab6…`; the VirtIO register write fails after the
  machine moved from mcycle 0 to 6 and a 23112-byte log was written; the queue notify terminates the process (exit 134)
  through the library and through `cartesi-machine --volume=… --log-step=…`; a reproducible control logs and verifies.
  The verifier also killed a JSON-RPC server the same way. Test: `tests/bugs/log-step-unreproducible`.
- **Scenario:** a developer who combines VirtIO devices (`--volume`, `--network`, `-it`, `--virtio-console`) with
  `--log-step` loses the session; tooling can emit step proofs for machines that every other proof path refuses.
  Rollups nodes, which load stored reproducible templates, cannot reach it.
- **Possible solution:** at the top of `machine::log_step`, before `get_root_hash()`/`init_hot_tlb_contents()`, throw
  "cannot log steps of unreproducible machines", and add the matching `iunrep == 0` assertion for `--log-step` in the
  CLI so it fails before running. Validated: every case is refused with the machine unchanged and the server alive;
  reproducible `log_step`/`verify_step` are unaffected; no hash change. Defence in depth: do not let accessor exceptions
  cross the `noexcept` VirtIO callbacks (drop `noexcept`, or catch and fail the access; silently returning `false` would
  re-create (A)). Optionally apply the same guard to `log_send_cmio_response` and `log_reset_uarch`.
- **Risks:** process aborts from a supported call; step proofs whose meaning differs from `cm_run`.

---

## CM-27 — `cm_clone_empty` on a remote machine leaks the server it forks

- **Severity:** Medium (lower end). The documented remote-machine recipe leaks one server process, holding a full
  machine, per machine it creates. No hash, proof or consensus impact.
- **Area:** JSON-RPC client / C API / Lua bindings. **Category:** resource leak / denial of service.
- **Where:** `jsonrpc_machine::do_clone_empty` (`src/jsonrpc-machine.cpp:605-622`) forks the source server and wraps
  the new address in `new jsonrpc_machine(fork_result.address)` (`:607`), which keeps the member defaults
  `m_call{cleanup_call::nothing}` and `m_timeout{-1}` (`src/jsonrpc-machine.hpp:188-190`); the destructor shuts the
  server down or destroys the machine only when `m_call` says so (`src/jsonrpc-machine.cpp:630-648`).
  `cm_jsonrpc_fork_server`, in contrast, copies both settings from the source (`src/cm-jsonrpc.cpp:143-145`), as
  documented in `src/cm-jsonrpc.h:89-92`. Reached from `cm_clone_empty` (`src/cm.cpp:569-581`) and from the Lua class
  constructor `machine_meta_call` (`src/clua-i-machine.cpp:1506-1534`), i.e. `remote(config)` or `remote(dir)` on any
  remote handle.
- **Problem:** the object returned by `cm_clone_empty` on a remote machine is the only handle to a newly forked server
  process, but `cm_delete` of it never shuts that server down, so the process and the machine it holds (RAM and
  drives) outlive every handle. The source handle's SHUTDOWN/DESTROY policy covers only the source server; the fork is
  a separate process. The clone also loses the source's timeout (−1, wait forever), so a stuck server hangs the caller
  even when the source handle had a timeout. A `cm_create`/`cm_load` that fails on the clone leaks an empty server the
  same way, because the caller can only `cm_delete` the object; in Lua every `remote(bad_config)` error does so
  (`machine_meta_call` raises at `:1523-1524` with the new handle still at cleanup NOTHING). `cm_clone_empty`'s
  documentation (`src/cm.h:459-468`) says nothing about cleanup or timeout, and `do_clone_empty`'s own error path
  shuts the forked server down (`src/jsonrpc-machine.cpp:612-619`), which shows that the clone is meant to own it.
- **Evidence:** the test spawns a server, sets SHUTDOWN and a 5000 ms timeout on it, then makes a `cm_clone_empty` +
  `cm_create` object, a `cm_clone_empty` + failing `cm_create` object and a `cm_jsonrpc_fork_server` reference, and
  deletes all of them. The clone reports `timeout=-1 cleanup=NOTHING` where the fork reports `timeout=5000
  cleanup=SHUTDOWN`; afterwards the source and fork servers are gone, while both clone servers still answer (one of
  them holding a machine). The hunter reproduced the leak through the Lua constructor and the verifier through the C
  API, including the failed-create path. Test: `tests/bugs/remote-clone-empty-leak`.
- **Scenario:** `doc/recipes/run-remote-config.lua:9-20`, the documented recipe for remote machines, connects with
  `set_cleanup_call(SHUTDOWN)` ("shut it down automatically on exit") and then creates the machine with
  `cartesi_jsonrpc_machine(config)`; `doc/recipes/run-rolling-calculator.lua:55` and
  `doc/recipes/run-rolling-calculator-output-proofs.lua:66` load templates the same way. Each run leaves an orphan
  `cartesi-jsonrpc-machine` process holding the machine. A long-lived Lua service or C API client that creates
  machines this way leaks one server per machine, and one per failed create, until the host runs out of memory or
  processes. The CLI (`src/cartesi-machine.lua:2735-2738`, `:2783`) and the test suites
  (`tests/lua/machine-bind.lua:259-260`) use `fork_server`/`spawn_server` and are not affected.
- **Possible solution:** in `do_clone_empty`, right after construction, call `clone->set_timeout(m_timeout);
  clone->set_cleanup_call(cleanup_call::shutdown);`. Validated in a private build of `libcartesi_jsonrpc.so`: the clone
  reports the source's timeout and SHUTDOWN, and all servers are gone after `cm_delete`. SHUTDOWN is preferable to
  inheriting `m_call`: a source from `cm_jsonrpc_connect_server` has cleanup NOTHING and would still leak, and the
  forked server exists only for the clone, as with `cm_jsonrpc_spawn_server`. Document the policy in `cm_clone_empty`.
- **Risks:** if unfixed, remote recipes and tools leak server processes that each hold a full machine. The fix only
  changes cleanup: code that relied on the forked server outliving its handle (unlikely, since its address is
  reachable only through that handle) must opt out with `cm_jsonrpc_set_cleanup_call(CM_JSONRPC_NOTHING)`. No hash
  changes.

## CM-28 — The DTB and stored file names follow the host's C++ global locale: locale-dependent template root hash

- **Severity:** Medium (low end). The same config silently produces a different template root hash and different
  execution, and stored machines become unloadable across locales. It needs an in-process C++ host that installs a
  digit-grouping global locale; no first-party or known downstream host does, and no attacker or guest can trigger it.
- **Area:** DTB / machine config / store-load. **Category:** host-environment dependency of the root hash / divergence
  / unloadable snapshots.
- **Where:** three default-constructed `std::ostringstream`s format integers with `std::hex` under the C++ global
  locale: `FDTBuilder::begin_node_num` (`src/fdt-builder.hpp:131-134`), which names every node with a unit address
  (`clint`, `plic`, `htif`, `virtio`, `memory`, `fw_resv`, `pmem`, `uio`, `rx_buffer`, `tx_buffer`; `cpu@0` has a
  single digit and is unaffected); the `/aliases` targets `/pmem@…` and `/uio@…` in `dtb_init`
  (`src/dtb.cpp:209-210`, `:219-220`); and `machine_config::get_data_filename`/`get_dht_filename`/`get_dpt_filename`
  (`src/machine-config.cpp:39-55`), used by `machine::store` (`src/machine.cpp:421-423`) and recomputed on load by
  `adjust_ar_backing_store_config` (`src/machine-config.cpp:88-91`, through `adjust_backing_stores` at `:159`). The DTB
  is written into the hashed DTB range at 0x7ff00000 when the machine is created (`machine::init_dtb_contents`,
  `src/machine.cpp:287-295`).
- **Problem:** libstdc++'s `num_put` applies the locale's digit grouping in every base, including `std::hex`. If the
  process hosting libcartesi has called `std::locale::global(...)` with a grouping locale, the DTB gets
  `clint@2,000,000`, `memory@80,000,000` and alias targets such as `/pmem@80,100,000` (en_US; `clint@2.000.000` under
  de_DE). These are legal node-name characters, so the guest boots normally and nothing reports an error, but the
  template root hash and every later state differ: a Linux boot halts at a different mcycle with a different final
  hash. Stored file names change the same way (`0000000000000000-8,000.bin`); because load recomputes them with the
  loader's locale, a directory stored under one locale cannot be loaded under the other ("unable to open backing
  file"). The C locale alone (`setlocale`, `LANG`/`LC_ALL`) has no effect. `cm_jsonrpc_spawn_server` starts the server
  with `posix_spawnp` (`src/jsonrpc-machine.cpp:485`) and the server never sets a locale, so an affected host
  disagrees even with a server it spawned itself. The verifier audited every other formatting site on hashed or
  persisted paths (`std::to_string`, nlohmann JSON, Boost.Asio endpoints, `snprintf`) and found them
  locale-independent. libc++ also groups hex digits by code reading (not run).
- **Evidence:** the verifier's reproducer toggles the C++ global locale between `cm_create_new` calls in one process,
  using a synthetic grouping `numpunct` facet (no system locale data needed) and decoding the DTB structure block:
  classic gives root `820e9b84…` with no invalid unit addresses; the grouping facet gives `f790c153…` (the same as
  `en_US.UTF-8`) with 15 invalid unit addresses and every alias target grouped; `de_DE.UTF-8` gives `6c59d3a9…`;
  `C.UTF-8` gives the classic hash. Directories stored under one locale fail to load under the other in both
  directions. A Linux boot to halt with a labelled data drive shows the guest alias `/pmem@c0,000,000`, mcycle
  57939550 and final hash `c1101e24…`, against `/pmem@c0000000`, 57849418 and `700b53de…` under the classic locale.
  The hunter showed a local machine (`fd248585…`) and a JSON-RPC server it spawned (`623baeb6…`) disagreeing on the
  same config in one en_US process. Test: `tests/bugs/dtb-locale-dependence`.
- **Scenario:** a template-building, deployment or verification tool written in C++ (or a C++ program that embeds
  Lua and loads `cartesi.so`) adopts the user locale with the common `std::locale::global(std::locale(""))` idiom
  (Boost.Locale documents the same setup) and runs on a desktop with `LANG=en_US.UTF-8`. A template it builds has a
  hash nobody can reproduce from the same config, and its snapshots cannot be loaded by the CLI, the JSON-RPC server
  or a node, nor theirs by it. The CLI (Lua), `cartesi-jsonrpc-machine`, remote machines from any client, and Go,
  Rust, Python, Node and C hosts never set the C++ global locale and are not affected. Loading a canonical template in
  an affected host fails loudly (the file names differ), so the silent part is limited to creating machines from a
  config.
- **Possible solution:** imbue `std::locale::classic()` into the three streams (one line each), or format with
  `std::format("{}@{:x}", …)`/`std::to_chars`, which are locale-independent unless the `L` specifier is used.
  Validated on a relinked `libcartesi.so`: under the grouping facet and `en_US.UTF-8` the template hash is the classic
  `820e9b84…`, cross-locale loads work, and the Linux boot matches the classic run (mcycle 57849418, `700b53de…`). Add a
  regression test that installs a synthetic grouping facet as the global locale (no locale data needed on CI), and
  optionally assert in `dtb_init` that unit addresses match `[0-9a-f]+`.
- **Risks:** for classic-locale hosts (all current tools) the DTB, root hashes and file names stay byte-identical, so
  existing templates and the on-chain step are unaffected. Directories already stored by an affected host have
  grouped file names and a non-canonical DTB: after the fix they load only once the files are renamed, and their root
  hashes remain non-canonical.

---

## Traceability of later findings

Original audit IDs of the findings confirmed after the first draft, the `BUGS.md` entry that covers each, and the raw
reports in `tests/bugs/reports/` with the full evidence.

| Original ID | BUGS.md | Severity (verifier) | Area | Test | Reports |
|---|---|---|---|---|---|
| ROLLUP-FLOW-1 | CM-20 | Critical | step logs / RISC Zero replay | `log-step-automatic-yield` | `hunters/rollup-flow.md`, `verifiers/verify-step.md` |
| STEP-PROOF-1 (= HT-11) | CM-21 | High | hash tree / step logs | `step-log-padding-assert` | `hunters/step-proof.md`, `verifiers/verify-step.md` |
| HT-1 (+ HT-4) | CM-22 | High | hash tree / stored machines | `crash-during-hash-update` | `hunters/hash-tree.md`, `verifiers/verify-hashtree.md` |
| HT-3 (+ CONC-2, extends CM-08) | CM-08 (addendum) | High | hash tree / page-hash cache, uarch-cycle hash collection | `shared-hash-tree-cache-pollution`, `page-cache-stale-collect` | `hunters/hash-tree.md`, `verifiers/verify-hashtree.md`, `verifiers/verify-conc.md` |
| DYNAMIC-1 | CM-23 | High | shadow TLB validation | `write-tlb-readonly-target` | `hunters/dynamic.md`, `verifiers/verify-dynamic.md` |
| STEP-PROOF-5 (= HT-10) | CM-25 | Medium | hash tree / proofs | `proof-padding-stale` | `hunters/step-proof.md`, `verifiers/verify-step.md` |
| ASSERTS-1 | CM-24 | Medium | uarch | `uarch-require-abort` | `hunters/asserts.md`, `verifiers/verify-asserts.md` |
| HT-2 | CM-06 (addendum) | Medium (root cause of CM-06's non-tampering cases) | hash tree / store | `stored-hash-tree-stale` | `verifiers/verify-hashtree.md`, `verifiers/verify-capi.md` |
| ASSERTS-2 | CM-02 (addendum) | Low (part of CM-02) | uarch-cycle hash collection | — | `hunters/asserts.md`, `verifiers/verify-asserts.md` |
| REPRO-2 | CM-26 | Low | step logs / reproducibility guard | `log-step-unreproducible` | `hunters/repro-guards.md`, `verifiers/verify-repro.md` |
| REPRO-1 | CM-L22 | Low | reproducibility flag | `iunrep-shadow-mismatch` | `hunters/repro-guards.md`, `verifiers/verify-repro.md` |
| REPRO-4 | CM-L23 | Low | unreproducible WFI fast-forward | `wfi-fast-forward-overshoot` | `hunters/repro-guards.md`, `verifiers/verify-repro.md` |
| STEP-PROOF-4 | CM-L25 | Low | CMIO response | `send-cmio-response-partial-update` | `hunters/step-proof.md`, `verifiers/verify-step.md` |
| STEP-PROOF-3 | CM-L24 | Low | access-log verification (UB) | — | `hunters/step-proof.md`, `verifiers/verify-step.md` |
| HT-5, HT-6, HT-7, HT-8 | CM-22 (HT-5 note), CM-L19, CM-L20, CM-L21 | Low | hash tree | `shadow-padding-page-dirty` (HT-6), `collect-uarch-partial-reset` (HT-7), `back-merkle-tree-alloc` (HT-8) | `hunters/hash-tree.md`, `verifiers/verify-hashtree.md` |
| lua-lifecycle-1 | CM-27 | Medium (lower end) | JSON-RPC client / Lua bindings | `remote-clone-empty-leak` | `hunters/lua-lifecycle.md`, `verifiers/verify-final.md` |
| DTB-CONFIG-1 | CM-28 | Medium (low end) | DTB / machine config | `dtb-locale-dependence` | `hunters/dtb-config.md`, `verifiers/verify-dtb.md` |
| UARCH-ISA-1 | CM-02 (addendum) | Low (part of CM-02) | uarch | `uarch-x0-store` | `hunters/uarch-isa.md`, `verifiers/verify-final.md` |
| DEVICES2-1 | CM-L26 | Low | C API / HTIF console | `reproducible-getchar-enable` | `hunters/devices2.md`, `verifiers/verify-final.md` |
| cli-hashes-3 | CM-L27 | Low (upper end) | CLI (gdb stub) | `gdb-stepc-automatic-yield` | `hunters/cli-hashes.md`, `verifiers/verify-final.md` |
| cli-hashes-1 | CM-L28 | Low | CLI | `uarch-hashes-print-reject` | `hunters/cli-hashes.md`, `verifiers/verify-final.md` |
| cli-hashes-2 | CM-L29 | Low | Lua helper | `hash-tree-empty-data-root` | `hunters/cli-hashes.md`, `verifiers/verify-final.md` |
| lua-lifecycle-2 | CM-L30 | Low | Lua bindings | `lua-converter-error-leak` | `hunters/lua-lifecycle.md`, `verifiers/verify-final.md` |

Refuted or by design (not bugs): ROLLUP-FLOW-2 (documented and tested), R-1 revert hash check in
`verify_send_cmio_response` (documented; mirrors the on-chain verifier).

---

## Lower-severity defects

| ID | Area | Defect | Where | Test |
|---|---|---|---|---|
| CM-L01 | interpreter | Data TLB not flushed when an M→M trap or MRET changes the effective privilege with `MPRV=1`; loads use stale translations | trap/`MRET` paths write `mstatus.MPP` without the flush done by `write_csr_mstatus` (`src/interpret.cpp`) | `mprv-stale-tlb-on-mret` |
| CM-L02 | interpreter | `minstret` under-counts by one for every interrupt taken (reads 2^64−1 if an interrupt is taken at mcycle 0) | interrupt entry / `icycleinstret` handling (`src/interpret.cpp`) | `minstret-interrupt-undercount` |
| CM-L03 | interpreter | S-mode can set `sip.STIP` and clear `sip.SEIP` (read-only in `sip` per the spec); an SEI raised by M-mode is lost | `write_csr_sip` (`src/interpret.cpp:2181`) | `sip-stip-seip-writable` |
| CM-L04 | interpreter / CLINT | `mtimecmp * RTC_FREQ_DIV` wraps: a timer interrupt fires immediately for `mtimecmp >= 2^51` | CLINT/RTC conversion (`src/rtc.hpp`, `src/interpret.cpp`) | `mtimecmp-overflow` |
| CM-L05 | interpreter | Misaligned `SC.W`/`SC.D` does not trap (returns `rd=1`); the reservation check precedes the alignment check | `execute_SC` (`src/interpret.cpp:1277`) | `sc-misaligned-no-trap` |
| CM-L06 | MMU | A PTE read from a non-memory range raises a page fault (12/13/15) instead of an access fault (1/5/7); A/D write-back to a read-only page table silently does nothing (spec: access fault) | `translate_virtual_address` (`src/translate-virtual-address.hpp:171`, `240`) | `pte-access-fault-cause` |
| CM-L07 | C API | `cm_read_virtual_memory`/`cm_write_virtual_memory` skip any request whose last byte is in the top 4 KiB page (and requests that wrap) and still report success | `machine::read_virtual_memory`/`write_virtual_memory` (`src/machine.cpp:1795-1857`) | `virtual-memory-top-page` |
| CM-L08 | C API | `cm_log_step` on an empty machine object dereferences NULL | `local_machine::do_log_step` uses `m_machine->` instead of `get_machine()` (`src/local-machine.cpp:113`) | `log-step-empty-machine` |
| CM-L09 | C API | `cm_create`/`cm_load` on a non-empty object leak the previous machine (fds, mappings, exclusive locks) | `local_machine::do_create`/`do_load` (`src/local-machine.cpp:46-53`) | `create-load-nonempty-leak` |
| CM-L10 | C API | `cm_translate_virtual_address` writes through `paddr` without a NULL check | `src/cm.cpp:1136` | `translate-virtual-address-null` |
| CM-L11 | config | `std::bit_ceil` on unvalidated huge lengths in `machine_config::adjust_defaults`/`adjust_starts` (aborts hardened builds; release rejects the config later) | `src/machine-config.cpp` | — |
| CM-L12 | Lua bindings | Table→JSON conversion with numeric keys converts keys in place during `lua_next` (errors, dropped fields or infinite loop); sparse arrays push up to max-index nulls | `src/clua-i-machine.cpp:271`, `386-389` | `lua-tojson-numeric-keys` |
| CM-L13 | CLI | Unvalidated `last_output_proof.target_address = 2^64−1` hangs the CLI | `src/cartesi-machine.lua:3364-3370`, `src/cartesi/hash-tree.lua:395-399` | `cli-last-output-proof-hang` |
| CM-L14 | CLI | `--print-uarch-cycle-root-hashes=count:N` without `start:` prints nothing for a machine loaded past mcycle N | `src/cartesi-machine.lua:2432`, `3831` | `cli-uarch-hashes-count` |
| CM-L15 | CLI | `parse_ipv4` shifts the second octet by 18 instead of 16 (`127.1.2.3` → `127.4.2.3`) | `src/cartesi-machine.lua:1370` | `cli-parse-ipv4` |
| CM-L16 | CLI (gdb stub) | GDB `M` (memory write) replies are inverted: error on success, OK on failure | `src/cartesi/gdbstub.lua:412` | `gdbstub-write-reply` |
| CM-L17 | JSON-RPC | `delay_next_request` accepts any delay and freezes the single-threaded server for all clients | `src/jsonrpc-remote-machine.cpp:1058`, `1959` | `jsonrpc-delay-unbounded` |
| CM-L18 | JSON-RPC client | Spawned servers inherit the client's sockets (no close-on-exec); concurrent spawns on fixed ports can fail with `EADDRINUSE` | `posix_spawnp` without file actions; Asio sockets without `SOCK_CLOEXEC` | `spawn-socket-leak` |
| CM-L19 | hash tree / C API | Full-shadow `cm_write_memory(0, …, 0x8000)` ("manual snapshot") does not mark the TLB padding page 0x7000-0x7fff dirty: non-zero padding bytes leave a stale page hash and a root hash that does not commit to memory (`cm_verify_hash_tree` detects it; snapshots read from a machine have zero padding) | special case in `machine::write_memory` (`src/machine.cpp:1732-1745`); `mark_always_dirty_pages` covers only 0x0-0x6fff (`src/machine-address-ranges.cpp:128-133`) | `shadow-padding-page-dirty` |
| CM-L20 | uarch-cycle hash collection | `cm_collect_uarch_cycle_root_hashes` resets only the uarch RAM words written during the mcycle; with a non-pristine uarch RAM its post-reset hashes and final state differ from `cm_reset_uarch`/`cm_log_reset_uarch` and the on-chain reset (prevented by CM-02's pristine-uarch check) | direct reset in `machine::collect_uarch_cycle_root_hashes` (`src/machine.cpp:2766-2794`); entry check only `uarch_cycle == 0` (`:2648`) | `collect-uarch-partial-reset` |
| CM-L21 | hash collection / JSON | `back_merkle_tree` allocates `log2_max_leaves + 1` hashes before validating `log2_max_leaves` (a uint64 narrowed to `int` when parsing `previous_partial_bundle`; signed overflow at `INT_MAX`): a partial bundle that is then rejected drives multi-GiB allocations in the client and the JSON-RPC server | constructor (`src/back-merkle-tree.hpp:44-55`); `src/json-util.cpp:2214`; collector arguments (`src/machine.cpp:2348`, `2683`) | `back-merkle-tree-alloc` |
| CM-L22 | C API / reproducibility flag | `iunrep` has two sources of truth: guards and behaviour use the configured value, the root hash commits to the shadow register, which `cm_write_reg(CM_REG_IUNREP)` and the full-shadow `cm_write_memory` change freely. `cm_store` then writes a directory that `cm_load` rejects, and an unreproducible machine can share the root hash of a reproducible one while `cm_run` performs a different transition | `is_unreproducible` (`src/machine.hpp:818-820`); `write_reg` (`src/machine.cpp:1332-1334`); full-shadow write (`:1732-1745`); `store` checks only the config (`:400`); `validate_processor_shadow` runs only at construction and load (`:196-216`) | `iunrep-shadow-mismatch` |
| CM-L23 | interpreter (unreproducible mode) | WFI fast-forward clamps mcycle to `mcycle_max` and the loop then adds one: `cm_run(N)` returns mcycle N+1 (a repeated `cm_run(N)` fails with "mcycle is past"; assert-enabled builds abort at `src/interpret.cpp:6411`), and a timer deadline on an RTC tick is delivered one tick (8192 mcycles) late | `machine::poll_external_interrupts` (`src/machine.cpp:2261`); `execute_WFI` (`src/interpret.cpp:2833`) | `wfi-fast-forward-overshoot` |
| CM-L24 | access-log verification | An untrusted access log with more sibling hashes than `64 - log2_size` makes proof verification evaluate `1 << 64` (UB) in `cm_verify_step_uarch`, `cm_verify_reset_uarch` and `cm_verify_send_cmio_response`; sanitizer builds abort, release builds reject the log | `access::make_proof` (`src/access-log.hpp:175-200`); `hash_tree_proof::bubble_up` (`src/hash-tree-proof.hpp:188-190`) | — |
| CM-L25 | C API / CMIO | `cm_send_cmio_response`/`cm_log_send_cmio_response` with `data == NULL` and `length > 0` fail ("data is null") after writing `imcyclemax` and the revert root hash, contrary to "validation errors leave the machine unchanged" (`src/cm.h:1028`) | writes at `src/send-cmio-response.cpp:71-73` precede the data write at `:76`; no pointer check in `src/cm.cpp:1325`, `1338` | `send-cmio-response-partial-update` |
| CM-L26 | C API / HTIF console | The host API can enable HTIF getchar on a reproducible machine (`cm_write_reg(CM_REG_HTIF_ICONSOLE, 3)`, the full-shadow `cm_write_memory(0, …, 0x8000)`, `cm_set_runtime_config` with console input); `cm_run` then answers the guest's getchar with host input (EOT, or host-supplied bytes) while the uarch (hence the on-chain step), `cm_log_step`/`cm_verify_step` and `cm_collect_mcycle_root_hashes` answer "no character", so their root hashes diverge, and `cm_store` writes a directory that `cm_load` rejects ("TTY stdin is only supported in unreproducible machines"). The guest cannot set `iconsole`; same class as CM-L22 | invariant enforced only at create/load (`machine::init_console`, `src/machine.cpp:324-331`); accepted by `write_reg(htif_iconsole)` (`:1356-1357`), the full-shadow write (`:1732-1745`) and `set_runtime_config` (`:388-394`); `device_state_access::do_getchar` serves input to interactive accessors (`src/device-state-access.hpp:153-158`); `store` checks only `iunrep` (`src/machine.cpp:400-402`) | `reproducible-getchar-enable` |
| CM-L27 | CLI (gdb stub) | Under `--gdb`, a cycle step (the documented `stepc` macro: `monitor stepc N` + `continue`) that ends exactly on an automatic-yield mcycle never gets a stop reply: on resume the stub runs a zero-length step with `iflags_X` still set. Without breakpoints the zero-length `REACHED_TARGET_MCYCLE` is taken as the CLI's own target, so the CLI exits 0 printing the "final" hash (and storing the machine) of an unfinished run; with any breakpoint the stale `YIELDED_AUTOMATICALLY` is returned and the CLI re-services the same yield forever (3.5 million times before the test killed it); a `--cmio-advance-state` computation-hash run never finishes. Debugging sessions only (upper end of Low) | `GDBStub:_handle_continue` (`src/cartesi/gdbstub.lua:475-521`; step target `:480-483`, yield checks `:495`, `:515`); resumed by `_pump_session` (`:614-616`); returned by `GDBStub:run` (`:648-659`) to `run_to_stop` (`src/cartesi-machine.lua:4344-4355`) | `gdb-stepc-automatic-yield` |
| CM-L28 | CLI | `--print-uarch-cycle-root-hashes` on a machine that reaches an rx-rejected manual yield outside cmio mode (e.g. a snapshot loaded mid-input) prints a fabricated post-rejection group: two entries equal to the revert root hash, the second labelled with an mcycle that never happens, instead of the canonical group (one entry per uarch cycle of the reverted machine, 43 in the test) that `cm_collect_uarch_cycle_root_hashes` with the real tail and `--uarch-cycle-computation-hash` use. Diagnostic output only | fixed `fake_revert_uarch_tail = {R, R}`, on the premise that a rejection "never happens outside cmio mode" (`src/cartesi-machine.lua:3838-3846`); emitted by `append_revert_uarch_tail_period` (`src/machine.cpp:2615-2625`) as documented in `src/cm.h:970-973` | `uarch-hashes-print-reject` |
| CM-L29 | Lua helper (`cartesi.hash-tree`) | `get_data_root_hash("", log2_size)` returns `nil` instead of the pristine root, although the data "need not fill the tree"; the documented recipe then raises in `verify_splice` when the output NVRAM is empty (`string.unpack("z", …)` returns `""`). Fails closed: a valid empty value is rejected, nothing invalid is accepted | `src/cartesi/hash-tree.lua:45-68` (no leaves, so the pairing loop creates no parents and `:67` returns `nil`); recipe `doc/recipes/slice-calculator-output.lua:26`, `:36` | `hash-tree-empty-data-root` |
| CM-L30 | Lua bindings | Every input rejected by a Lua conversion helper (`cartesi.fromjson`/`tojson`/`frombase64`/`fromhex`/`tobase64`/`tohex`, and machine methods that convert config tables) leaks its C++ exception object, about 400 bytes: `luaL_error` is called inside a C++ `catch`, and with Lua built as C its `longjmp` skips `__cxa_end_catch`. Unbounded growth for long-lived Lua services that validate untrusted input (the `doc/recipes/game-transport.lua:583` pattern); LeakSanitizer does not report it | `src/clua-cartesi.cpp:116-184` (also `cartesi_mod_new`, `:193`); `clua_tojson` and `clua_fromjson` (`src/clua-i-machine.cpp:616-618`, `:631-633`); also `:228-233`, `:1159-1161` | `lua-converter-error-leak` |
