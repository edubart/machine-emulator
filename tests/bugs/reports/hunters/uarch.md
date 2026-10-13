# Angle: `uarch` — microarchitecture path for PRT dispute resolution

Scope: `src/uarch-step.cpp`, `uarch-interpret.cpp`, `uarch-{state,record,replay}-state-access.hpp`,
`uarch-reset-state.cpp`, `uarch-solidity-compat.hpp`, `shadow-uarch-state.hpp`,
`collect-uarch-cycle-hashes-state-access.hpp`, `machine.cpp` (run/log/verify/reset/collect uarch),
and `uarch/*` (the in-uarch `interpret.cpp` build). Keccak hash tree, release build.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| uarch-1 | uarch `WRITE_TLB` ecall: `set_index` not bounds-checked → OOB host write (write-what-where) | PROVEN | High |
| uarch-2 | Equivalence (cm_run 1 mcycle == uarch-until-halt + reset_uarch) — differential fuzzing | REJECTED (no divergence found) | - |
| uarch-3 | `verify_reset_uarch` revert-root-hash read soundness | REJECTED (sound) | - |
| uarch-4 | uarch `slot_index` / misaligned pc / `ebreak` behaviour | REJECTED (handled / deterministic) | - |

---

### uarch-1: uarch `WRITE_TLB` ecall passes an unchecked `set_index` into a native array index (OOB host write)
- Status: PROVEN
- Area: uarch / memory-safety
- Category: memory-safety (out-of-bounds write, write-what-where), host-vs-chain divergence
- Where:
  - `src/uarch-step.cpp:executeECALL` (`UARCH_ECALL_FN_WRITE_TLB` branch) reads `set_index` from guest reg a0 and forwards it.
  - `src/uarch-solidity-compat.hpp:165` `writeTlbECALL`: `a.write_tlb(static_cast<TLB_set_index>(set_index), ...)` — raw cast, no range check.
  - `src/machine.hpp:711` `machine::write_unverified_tlb`: checks only `slot_index >= TLB_SET_SIZE`; **`set_index` is never checked**, then indexes
    `m_s->penumbra.tlb[set_index][slot_index]` and `m_s->shadow.tlb[set_index][slot_index]`.
    Both `shadow_tlb_state` and `hot_tlb_state` are `std::array<..., TLB_LAST_+1>` i.e. exactly 3 entries (valid indices 0=CODE,1=READ,2=WRITE).
  - Same unchecked forwarding in the record path `src/uarch-record-state-access.hpp:254-262` (`do_write_tlb` → `write_unverified_tlb`) and the collect path `src/collect-uarch-cycle-hashes-state-access.hpp:111`.
- Problem: The uarch `WRITE_TLB` ecall takes `set_index` (a0), `slot_index` (a1), `vaddr_page` (a2),
  `vp_offset` (a3), `pma_index` (a4) from guest-controlled uarch registers. `slot_index` is bounds-checked;
  `set_index` is cast directly to the 3-element `TLB_set_index` enum and used as an array index with no
  bound. A uarch program that sets a0 to an arbitrary 64-bit value causes an out-of-bounds write of
  attacker-controlled data: `shadow.tlb[set_index][slot_index]` stores `vaddr_page`, `vp_offset`,
  `pma_index` (three attacker-chosen 8-byte words) at host offset `set_index * sizeof(shadow_tlb_set)` =
  `set_index * 8192` bytes past the shadow TLB base, i.e. a classic bounded write-what-where primitive
  (8192-byte-granular offset, 24 controlled bytes). The hot (penumbra) TLB is corrupted the same way.
- Scenario: The uarch RAM image is attacker-controllable through the public config / CLI
  (`uarch.ram.backing_store.data_filename`, `cartesi-machine.lua --uarch-ram-image=`) and is carried
  inside every stored machine snapshot. A node operator, verifier, or tool that loads an untrusted
  machine (store/load, or a received snapshot) and then advances the microarchitecture — via
  `cm_run_uarch`, `cm_log_step_uarch`, or `cm_collect_uarch_cycle_root_hashes` /
  `cm_collect_uarch_cycle_bundle` — suffers host memory corruption in-process. In honest PRT operation
  the uarch is the fixed pristine interpreter and only ever issues `set_index ∈ {0,1,2}`, so this is not
  hit by legitimate machines; it is a memory-safety hole reachable from untrusted uarch images. There is
  also a host-vs-chain divergence: the generated Solidity step verifier models `write_tlb` as a Merkle
  write at `shadow_tlb_get_abs_addr(set_index, slot_index)` (a well-defined, if unusual, leaf), whereas
  the reference C++ emulator performs a native OOB array access and crashes/corrupts — so the reference
  emulator cannot faithfully reproduce a transition the on-chain verifier would accept.
- Evidence: PoC dir `<SCRATCH>/work/uarch/poc_tlb/` — `run.sh` builds a 10-instruction uarch program
  (`uprog.S`: `li a7,4; li a0,0x10000; ... ; ecall`) and drives it through all three entry points on both
  the release and the ASan/UBSan libraries. Command: `bash <SCRATCH>/work/uarch/poc_tlb/run.sh`
  Actual output:
  ```
  === plain release build ===
  [run] CRASHED (exit 139) -> BUG REPRODUCED
  [log] CRASHED (exit 139) -> BUG REPRODUCED
  [collect] CRASHED (exit 139) -> BUG REPRODUCED
  === ASan/UBSan build ===
  .../array:208: ... std::array<std::array<cartesi::hot_tlb_slot,256>,3>::operator[]: Assertion '__n < this->size()' failed.
  [run] BUG REPRODUCED (hardened array bound tripped)
  [log] BUG REPRODUCED (hardened array bound tripped)
  [collect] BUG REPRODUCED (hardened array bound tripped)
  ```
  (The hardened `_GLIBCXX_ASSERTIONS` array in the ASan build catches `penumbra.tlb[0x10000]`, `_Nm=3`;
  the release build does the raw OOB write and segfaults.)
- Possible solution:
  - Minimal host fix in `machine::write_unverified_tlb` (and anywhere a runtime `set_index` reaches a
    TLB array), mirroring the existing `slot_index` guard:
    ```cpp
    if (set_index >= TLB_NUM_SETS_) {
        throw std::out_of_range{"TLB set index out of bounds"};
    }
    if (slot_index >= TLB_SET_SIZE) { ... }
    ```
  - Preferable: validate `set_index` (and `slot_index`) deterministically inside
    `executeECALL`/`writeTlbECALL` in `uarch-step.cpp`, so the Solidity-translated step and the reference
    emulator reject the same malformed `write_tlb` consistently (treat as the existing
    `throwRuntimeError`/"uarch aborted" path).
- Severity: High — attacker-controlled out-of-bounds host write reachable from an untrusted machine
  image via the standard uarch APIs used by nodes/verifiers; crash and potential memory corruption /
  code execution in the validating process, plus a reference-vs-on-chain divergence.
- Risks: Left unfixed, a malicious snapshot can crash or compromise a node/verifier process. The fix
  only rejects inputs that an honest uarch never produces, so it does not change any legitimate root
  hash; if the guard is added only host-side (not in the Solidity dialect) the host would error where the
  chain proves a write, so the guard should be placed in the shared `uarch-step.cpp` path to keep host
  and on-chain verifier in agreement.

---

### uarch-2: Equivalence invariant (cm_run 1 mcycle vs uarch-until-halt + reset_uarch)
- Status: REJECTED — no divergence found (reported for coverage, not a bug)
- Area: uarch / divergence
- Evidence: Differential harness `<SCRATCH>/work/uarch/difftest.c` runs two machines from the same
  config; for every mcycle it compares `cm_run(mc+1)` on machine A against
  `cm_run_uarch(CM_UARCH_CYCLE_MAX)`-until-halt + `cm_reset_uarch` on machine B, comparing root hashes and
  (every N cycles) all memory ranges; with `BIG=1` it also compares against a single long `cm_run`.
  Optionally (logevery) it also exercises `cm_log_step_uarch`+`cm_verify_step_uarch` and
  `cm_log_reset_uarch`+`cm_verify_reset_uarch` per uarch cycle. Random-program generator
  `<SCRATCH>/work/uarch/fuzz/gen.py` emits bare-metal RV64GC programs exercising M-mode/S-mode/U-mode,
  Sv39/Sv48 paging, trap handlers, all ALU/M/compressed/AMO/FP/CSR/system instruction classes, random
  junk words, HTIF yields and `imcyclemax` budgets. Ran the standard RISC-V test `rv64ui-p-add.bin`
  (per-cycle hash + mem compare, OK) and ~120 random seeds at 2500-3000 mcycles (seeds 2-120 without
  budget, plus seeds with low `imcyclemax` hitting the mcycle-overflow fixed point, with per-cycle
  comparison). All runs reported `OK` with matching root hashes on every path (cm_run vs uarch big-step
  vs log_step/verify_step vs big cm_run), including across mcycle-overflow fixed points. FP is uniform
  soft-float (`i_sfloat32/64`) on both host and uarch, so no native/soft-float divergence. No equivalence
  or determinism violation was found in the fuzzed corpus.

### uarch-3: `verify_reset_uarch` / revert-root-hash substitution soundness
- Status: REJECTED — appears sound
- Area: uarch / proof-soundness
- Analysis: In `uarch_reset_state` (src/uarch-reset-state.cpp) the reset writes the pristine uarch
  state, then reads `iflags_Y` and `htif_tohost`, and only on an rx-rejected manual yield calls
  `revertState`. In the replay/verify path (`uarch_replay_state_access::do_revert_state` →
  `check_read_revert_root_hash_access`) the revert root hash read at `AR_SHADOW_REVERT_ROOT_HASH_START`
  (0xfe0) is bound: its sibling hashes + read hash are verified against the current root hash
  (`check_access_siblings_and_read_hash`), the read data is checked to hash to that read hash and to be
  exactly `HASH_TREE_WORD_SIZE` bytes (`check_read_data` + explicit size check), and the returned value
  becomes `m_context.root_hash` (the obtained "after" hash). The decision to revert is driven by the
  logged, Merkle-bound values of `iflags_Y`/`tohost`, which a dishonest prover cannot alter without
  invalidating the proof against `root_hash_before`. `finish()` also enforces that the log is fully
  consumed (no missing/extra accesses). I could not construct a tampered reset log that is accepted with
  a wrong "after" hash.

### uarch-4: uarch boundary behaviour (slot_index, misaligned pc, ebreak, cycle overflow/halt)
- Status: REJECTED — handled or deterministic
- Notes: `write_unverified_tlb` rejects `slot_index >= 256` (clean throw). A misaligned uarch `pc`
  (reachable via `jalr`, which only clears bit 0) makes `readUint32` read within the aligned 8-byte word
  with a shift; `require()`/`assert` is compiled out under `-DNDEBUG` but the underlying `read_word`
  rejects misaligned word addresses, and the record path aligns down — no OOB, deterministic.
  `ebreak`/illegal instruction raise `throwRuntimeError("uarch aborted"/"illegal instruction")`
  deterministically. Cycle overflow (`UARCH_CYCLE_MAX = 2^20-1`) and halt are checked before and after
  each step consistently across state-access classes. No defect proven here.
