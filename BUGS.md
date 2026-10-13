# Cartesi Machine Emulator — Bug Report (v0.22.0)

> **Status: work in progress.** This file is updated as the audit continues; entries marked *(test pending)* will get
> their regression test in a later commit.

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
| CM-02 | High (Critical if a canonical uarch is not enforced) | uarch / config | Non-pristine uarch state is accepted, so `cm_run` and the uarch big-step compute different transitions | `uarch-non-pristine-state` *(test pending)* |
| CM-03 | High | uarch | `WRITE_TLB` uarch ecall does not bound-check `set_index`: out-of-bounds host write | `uarch-write-tlb-set-index` *(test pending)* |
| CM-04 | High | RISC Zero step verifier | `risc0_replay_steps` wraps `mcycle_end` instead of saturating: accepts a forged no-op step, rejects the honest one | `risc0-mcycle-end-wrap` *(test pending)* |
| CM-05 | High | memory / TLB | `cm_replace_memory_range` leaves dangling host pointers in the hot TLB (crash or silent wrong state) | `replace-memory-range-stale-tlb` *(test pending)* |
| CM-06 | High | store / load | Stored machines can carry a hash tree that does not match their data (write-TLB dirty marks lost); loads trust it without verification | `stored-hash-tree-stale` *(test pending)* |
| CM-07 | High | JSON-RPC / hash tree | `fork` is allowed when the hash tree is shared: parent and child corrupt each other's hashes and proofs | `fork-shared-hash-tree` *(test pending)* |
| CM-08 | High | hash tree | Shared hash tree with private ranges pollutes the stored page-hash cache: wrong proofs, honest uarch/CMIO logs cannot be produced | `shared-hash-tree-cache-pollution` *(test pending)* |
| CM-09 | Medium | JSON parsing | JSON integers equal to 2^64 (or 2^63) hit an undefined float-to-int conversion: host-architecture-dependent machines | `json-uint64-float-cast` *(test pending)* |
| CM-10 | Medium | CLI | `--load-config` ignores command-line fallbacks for missing fields: different machine and template hash | `cli-load-config-fallback` |
| CM-11 | Medium | CLI | `--revert-mode=stored` silently undoes `--replace-memory-range`; printed initial hash is not the machine that runs | `cli-revert-stored-replace` |
| CM-12 | Medium | Lua bindings | Nested JSON/table conversion overflows the Lua stack (heap buffer overflow) | `lua-json-stack-overflow` |
| CM-13 | Medium | VirtIO | Cyclic virtqueue descriptor chain hangs the host forever | `virtio-descriptor-loop` *(test pending)* |
| CM-14 | Medium | VirtIO 9P | Guest can create symlinks pointing outside the shared directory and follow them on the host | — (code review) |
| CM-15 | Medium | JSON-RPC | Deeply nested JSON request crashes the server | `jsonrpc-deep-nesting` *(test pending)* |
| CM-16 | Medium | JSON-RPC | A batch containing `fork` keeps executing in the child: duplicated operations, 2^N servers | `jsonrpc-batch-fork` *(test pending)* |
| CM-17 | Medium | JSON-RPC | Unbounded allocation sized by request (`read_memory`, `read_virtual_memory`, `read_console_output`) | `jsonrpc-unbounded-read` *(test pending)* |
| CM-18 | Medium | JSON-RPC | Fault-generated SIGBUS makes the server spin forever | `jsonrpc-sigbus-spin` *(test pending)* |
| CM-19 | Medium | C API | `const` queries (`cm_get_root_hash`, `cm_get_proof`) mutate shared state without synchronization | `const-api-thread-safety` *(test pending)* |
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
| CM-L07 | C API | `cm_read_virtual_memory`/`cm_write_virtual_memory` skip any request whose last byte is in the top 4 KiB page (and requests that wrap) and still report success | `machine::read_virtual_memory`/`write_virtual_memory` (`src/machine.cpp:1795-1857`) | `virtual-memory-top-page` *(test pending)* |
| CM-L08 | C API | `cm_log_step` on an empty machine object dereferences NULL | `local_machine::do_log_step` uses `m_machine->` instead of `get_machine()` (`src/local-machine.cpp:113`) | `log-step-empty-machine` *(test pending)* |
| CM-L09 | C API | `cm_create`/`cm_load` on a non-empty object leak the previous machine (fds, mappings, exclusive locks) | `local_machine::do_create`/`do_load` (`src/local-machine.cpp:46-53`) | `create-load-nonempty-leak` *(test pending)* |
| CM-L10 | C API | `cm_translate_virtual_address` writes through `paddr` without a NULL check | `src/cm.cpp:1136` | `translate-virtual-address-null` *(test pending)* |
| CM-L11 | config | `std::bit_ceil` on unvalidated huge lengths in `machine_config::adjust_defaults`/`adjust_starts` (aborts hardened builds; release rejects the config later) | `src/machine-config.cpp` | — |
| CM-L12 | Lua bindings | Table→JSON conversion with numeric keys converts keys in place during `lua_next` (errors, dropped fields or infinite loop); sparse arrays push up to max-index nulls | `src/clua-i-machine.cpp:271`, `386-389` | `lua-tojson-numeric-keys` *(test pending)* |
| CM-L13 | CLI | Unvalidated `last_output_proof.target_address = 2^64−1` hangs the CLI | `src/cartesi-machine.lua:3364-3370`, `src/cartesi/hash-tree.lua:395-399` | `cli-last-output-proof-hang` *(test pending)* |
| CM-L14 | CLI | `--print-uarch-cycle-root-hashes=count:N` without `start:` prints nothing for a machine loaded past mcycle N | `src/cartesi-machine.lua:2432`, `3831` | `cli-uarch-hashes-count` *(test pending)* |
| CM-L15 | CLI | `parse_ipv4` shifts the second octet by 18 instead of 16 (`127.1.2.3` → `127.4.2.3`) | `src/cartesi-machine.lua:1370` | `cli-parse-ipv4` *(test pending)* |
| CM-L16 | CLI (gdb stub) | GDB `M` (memory write) replies are inverted: error on success, OK on failure | `src/cartesi/gdbstub.lua:412` | `gdbstub-write-reply` *(test pending)* |
| CM-L17 | JSON-RPC | `delay_next_request` accepts any delay and freezes the single-threaded server for all clients | `src/jsonrpc-remote-machine.cpp:1058`, `1959` | `jsonrpc-delay-unbounded` *(test pending)* |
| CM-L18 | JSON-RPC client | Spawned servers inherit the client's sockets (no close-on-exec); concurrent spawns on fixed ports can fail with `EADDRINUSE` | `posix_spawnp` without file actions; Asio sockets without `SOCK_CLOEXEC` | `spawn-socket-leak` *(test pending)* |
