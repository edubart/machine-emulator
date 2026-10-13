# Angle `asserts`: live assert() in the default (relwithdebinfo) build

Scope: every `assert()` / assert-like construct in `src/*.cpp|hpp` (non-third-party): plain `assert`,
`require()` (uarch-solidity-compat.hpp, which is an `assert`), `ABRTF`/`__builtin_trap` (address-range.hpp,
mock-address-range.hpp), `__builtin_unreachable`, plus noexcept/destructor `std::terminate` paths.
Default build: `src/Makefile:205-212` defines `-DNDEBUG` only for `interpret.cpp`, so every other translation unit
(including `uarch-step.cpp` and `machine.cpp`) keeps `assert()` → `abort()`. The uarch build keeps asserts on
everywhere (`uarch/Makefile:49-50`), and there `abort()` is `ebreak`, which the host reports as "uarch aborted".

PoC dir: `<SCRATCH>/work/asserts/`, where `<SCRATCH>` = `<SCRATCH>`

| ID | Title | Status | Severity |
|---|---|---|---|
| ASSERTS-1 | `require()` in `uarch-step.cpp` is a live `assert`: a misaligned uarch pc or uarch load/store address aborts the process. This covers `cm_run_uarch`, `cm_log_step_uarch`, `cm_collect_uarch_*`, and the static `cm_verify_step_uarch` on an untrusted log, including the JSON-RPC server with no machine loaded. A `release` build instead executes a shifted instruction word and proves it, while the Solidity `require` reverts | PROVEN | High |
| ASSERTS-2 | `assert(mcycle_reached == mcycle_target)` in `collect_uarch_cycle_root_hashes` aborts the process when the uarch state is not pristine (e.g. `uarch_halt=1`) | PROVEN | Medium |
| (known) | `hash-tree.cpp:567` `get_dense_node_hash` on padding / non-pow2 tail | DUPLICATE of STEP-PROOF-1 / HT-11 | - |
| (known) | `hash-tree.cpp:105/573/846` `assert(opt_br)`: a persisted "borrowed" phtc entry at the LRU tail makes `borrow_entry` return nullopt and abort instead of throwing | variant of HT-4 (same root cause, crash-left `borrowed` flags) | - |

---

### ASSERTS-1: `require()` in uarch-step.cpp aborts the host process on a misaligned uarch access (default build); release build silently diverges from the Solidity step
- Status: PROVEN
- Area: uarch / C API / JSON-RPC / step verification
- Category: DoS (process abort from API input and from untrusted step logs), build-dependent divergence
- Where: `src/uarch-solidity-compat.hpp:251-254` (`require` = `assert((condition) && (message))`), used by
  `src/uarch-step.cpp:36-101` (`readUint64/32/16`, `writeUint64/32/16`, `copyBits`). The instruction fetch in
  `uarch_step` (`uarch-step.cpp:~1103`, `readUint32(a, pc)`) is the first one reached. `uarch-step.cpp` is compiled
  without `NDEBUG` in the default build.
- Problem:
  - `require()` is meant to mirror Solidity's `require` (revert the step). In C++ it is an `assert`, which gives
    three different behaviours for the same input:
    - Default (`relwithdebinfo`, packaged) build: `abort()` kills the whole process.
    - `release=yes` build (`-DNDEBUG`): the check disappears. `readUint32(0x600002)` reads bits 16..47 of the
      aligned word and executes them as an instruction. The step is logged and `cm_verify_step_uarch` accepts it.
    - On-chain Solidity step: `require` reverts.
  - The uarch pc is only 4-byte aligned in the pristine uarch. It becomes misaligned through:
    - uarch registers from config (`uarch.processor.registers.pc`), `cm_write_reg(CM_REG_UARCH_PC)` or a stored
      machine;
    - a custom uarch RAM image (documented `uarch.ram.backing_store.data_filename` / `--uarch-ram-image`), e.g.
      `jalr x0, 2(rs)` (JALR clears only bit 0) or a branch with an offset of 2 mod 4;
    - misaligned `ld/sd/lw/sw/lh/sh` in such an image.
  - `cm_verify_step_uarch` is static: it takes `root_hash_before` and the log from the caller. A log whose first
    three accesses (uarch_cycle, uarch_halt and uarch_pc, all in the same 32-byte word) carry valid proofs for a
    state with uarch_pc=0x600002 reaches the `require` before the 4th access. So a verifier that receives
    (root hash, log) pairs from another party aborts instead of rejecting them. The JSON-RPC method
    `machine.verify_step_uarch` needs no machine, so any client can stop the shared server with one request.
- Scenario:
  1. A node or tool that loads a template or snapshot with non-pristine uarch state (the attack surface already
     accepted for uarch-1 / crafted-state-1) and calls `cm_run_uarch`, `cm_log_step_uarch` or
     `cm_collect_uarch_cycle_root_hashes|bundle` dies with SIGABRT instead of getting an error.
  2. Any service that verifies uarch step logs it receives from others (C API `cm_verify_step_uarch(NULL, ...)` or
     a shared `cartesi-jsonrpc-machine`) can be terminated by a single crafted log. This affects every client of
     that server.
  3. Release-built binaries accept and produce proofs for a step that the on-chain verifier reverts. That
     contradicts uarch-4 (REJECTED on the assumption that `require` is compiled out, which only holds for
     `release=yes`).
- Evidence: `bash <SCRATCH>/work/asserts/uarch-require/run.sh` (exit 1 = bug). The log for `verify` /
  `jsonrpc-verify` is built from `cm_get_proof` data of a machine with uarch_pc=0x600002 (`poc.lua:make_log`).
  ```
  [run] exit=134 :: lua5.4: uarch-solidity-compat.hpp:253: void cartesi::require(T1, T2) [...]: Assertion `(condition) && (message)' failed.
  [log] exit=134 :: ... same assertion
  [collect] exit=134 :: ... same assertion
  [verify] exit=134 :: ... same assertion   (static verify_step_uarch on the crafted 3-access log)
  [jsonrpc-verify] server died with exit=134 :: cartesi-jsonrpc-machine: uarch-solidity-compat.hpp:253: ... Assertion ... failed.
  BUG REPRODUCED: misaligned uarch pc aborts the process (assert in uarch-step.cpp require())
  ```
  Release vs default build (`<SCRATCH>/work/asserts/uarch-require/rel.c`, release lib from `work/step-proof/rel`).
  It puts `addi x1,x0,1` in bits 16..47 of the uarch RAM word at 0x600000 and sets uarch_pc=0x600002:
  ```
  ./rel_release:  cm_log_step_uarch(uarch_pc=0x600002): OK (step executed and logged)
                  cm_verify_step_uarch: ACCEPTED
                  after step: uarch_pc=0x600006 uarch_cycle=1 uarch_x1=1
  ./rel_default:  rel_default: uarch-solidity-compat.hpp:253: ... Assertion `(condition) && (message)' failed.  (exit 134)
  ```
- Possible solution: make `require` a deterministic runtime error on the host, matching Solidity's revert:
  ```cpp
  template <typename T1, typename T2>
  void require(T1 condition, T2 message) {
      if (!condition) { throw std::runtime_error(message); }   // host; in the uarch/ZK builds keep abort()
  }
  ```
  An alternative is an explicit check in `uarch_step` before the fetch (`if (pc & 3) throwRuntimeError(a,
  "misaligned uarch pc")`). Either way, record/replay/collect all report the same error, and no root hash changes
  for pristine uarch states.
- Severity: High. A process abort is reachable from untrusted inputs (a single static JSON-RPC request or a
  verifier input log) and from non-pristine machine images. The release build also proves transitions the chain
  rejects.
- Risks: unfixed, any shared JSON-RPC server or log verifier can be terminated remotely, and release vs default vs
  on-chain behaviour differ. The fix only changes behaviour for inputs the pristine uarch never produces.

---

### ASSERTS-2: `collect_uarch_cycle_root_hashes` asserts that one uarch run advances mcycle by exactly 1
- Status: PROVEN
- Area: uarch / hash collection (PRT commitments)
- Category: DoS (process abort), unchecked state assumption
- Where: `src/machine.cpp:2807` `assert(mcycle_reached == mcycle_target)`. Related asserts at `machine.cpp:2755-2756`
  (`uarch_cycle_reached == uarch_cycle_target`, reachable when uarch code stores to its own `uarch_cycle` shadow
  word) and `machine.cpp:2763`.
- Problem: the only preconditions checked are `uarch_cycle == 0`, a keccak hash function and a reproducible
  machine. If the uarch is already halted (`uarch_halt=1` with `uarch_cycle=0`), `uarch_interpret` returns
  `uarch_halted` immediately, the collector resets the uarch, and mcycle has not advanced. The assert then fires
  and the default build aborts. `release` builds silently emit an extra (bogus) mcycle period. The equivalent
  `run_uarch` path returns normally (`uarch_halted`). `collect_uarch_cycle_bundle` calls the same function and
  aborts too.
- Scenario: a template or stored machine with non-pristine uarch registers (same input class as crafted-state-1;
  `uarch_halt` is settable via config, `cm_write_reg` or a stored directory). The honest node that computes
  uarch-level commitments with `cm_collect_uarch_cycle_root_hashes|bundle` crashes instead of getting an error.
- Evidence: `bash <SCRATCH>/work/asserts/collect-uarch/run.sh`
  ```
  [root] exit=134 :: lua5.4: machine.cpp:2807: ... collect_uarch_cycle_root_hashes(...): Assertion `mcycle_reached == mcycle_target' failed.
  [bundle] exit=134 :: lua5.4: machine.cpp:2807: ... Assertion `mcycle_reached == mcycle_target' failed.
  BUG REPRODUCED: collect_uarch_cycle_* aborts the process on non-pristine uarch state
  ```
- Possible solution: validate the uarch precondition before running: require `uarch_halt == 0` (or, better,
  pristine uarch registers and RAM, as proposed for crafted-state-1) and throw `std::runtime_error`. Replace the
  three "sanity" asserts with `if (!cond) throw std::runtime_error{"uarch did not advance exactly one mcycle"}`.
- Severity: Medium. Process abort through the C API / JSON-RPC from a crafted template or snapshot. The root cause
  is shared with crafted-state-1.
- Risks: none for pristine machines. The checks only turn an abort into an error.

---

## Asserts reviewed and found unreachable (default build), with reason
- `interpret.cpp:577` (`get_highest_priority_irq_num` `assert(false)`, live in the uarch): `read_mip`/`read_mie` go
  through `WARL_mip/mie` (`i-state-access.hpp:247-250`, mask 0xaaa). Even raw `mip=mie=1<<13` set via config is
  masked, so no out-of-list pending bit is possible. Verified: `<SCRATCH>/work/asserts/irq/run.sh`: host, step-log
  and uarch agree (no trap, no uarch abort) for bits 0, 8, 12, 13, 14, 16.
- `interpret.cpp:5703-5713` (`assert_no_brk`, live in the uarch): every CSR write that can enable a pending
  interrupt returns `success_and_serve_interrupts` (mie, mip, sie, sip, mideleg, mstatus/sstatus on SIE/MIE
  change). The same holds for CLINT msip, PLIC claim-complete, and xRET. Traps clear the destination xIE.
  HTIF halt/yield return break statuses. The relaxed S/U-mode rule is the interp-priv-1 behaviour (already
  reported). `interpret.cpp:6411` holds because the inner loop ends exactly at `mcycle_end`.
- `soft-float.hpp:274/291`: see fp-3 (REJECTED, operands bounded).
- `access-log.hpp:59/64`: `access::make_proof` rejects read/written data whose size differs from the proof size
  before any `get_word_access_data`/`replace_word_access_data`, and offsets are in [0,24].
- `replay-step-state-access.hpp:581`: `TLB_UNVERIFIED_PAGE` = 2^64-2 is not page-aligned, so it never equals a
  real vaddr_page (and it is in NDEBUG `interpret.cpp` anyway).
- `hash-tree.cpp:112/183/193/569/606/615/879/886`: parameters validated by `get_proof`/`get_node_hash`. Sparse
  nodes loaded from `hash_tree.sht` are validated against `create_nodes` in the constructor.
- `back-merkle-tree.cpp:136-142`, `machine.cpp:2448/2534/2576/2582/2593/2596/2617/2689/2720-2721/2839/2865`: the
  partial-bundle constructor rejects `leaf_count >= max_leaves`, and `push_back` throws on a full tree. Uarch
  cycles are capped at `UARCH_CYCLE_MAX = 2^20-1` < bundle capacity. The tail size is checked before use.
  Saturated `mcycle_end` always implies a fixed point.
- `record-send-cmio-state-access.hpp:163-174`: addresses are shadow registers (always aligned, in memory).
- `state-access.hpp:92`, `collect-mcycle-hashes-state-access.hpp:95/453`, `uarch-state-access.hpp:54`: x0 is
  never written (all 41 `writeX` sites in `uarch-step.cpp` are guarded by `rd != 0`). PMA indices come from
  `find_pma`.
- `dirty-page-tree.hpp:353`: only reachable with an inconsistent persisted `.dpt` (crash/tamper class, see HT-1).
- `virtio-address-range.cpp:408/409/448/449/506`: callers check `driver_ok`, and every queue handler that returns
  true has consumed a descriptor. Virtio devices are also only allowed in unreproducible machines.
- `ABRTF`/`__builtin_trap` in `address-range.hpp`/`mock-address-range.hpp`: all host abort callbacks throw. The
  mock is only used inside the uarch/ZK builds. `os::mapped_memory` and `machine` destructors do not throw.
- `hash-tree-hash.cpp:134-135`: standalone CLI tool only.
