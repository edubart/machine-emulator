# Independent verification — angle `uarch` (verifier: verify-uarch)

Repo treated read-only. All work under `<SCRATCH>/verify/verify-uarch/`.
`<SCRATCH>` = `<SCRATCH>`.

## Summary table

| id | title | verdict | my severity |
|----|-------|---------|-------------|
| uarch-1 | uarch WRITE_TLB ecall: unchecked `set_index` → OOB host write (write-what-where) | CONFIRMED | High |
| verify-uarch-NEW-1 | Non-pristine uarch template (RAM image or registers) accepted with `uarch_cycle==0` → `cm_run` vs uarch big-step divergence; malicious transition is on-chain-provable | CONFIRMED (NEW) | High (Critical ceiling) |
| uarch-2 (hunter REJECTED) | equivalence fuzzing found no divergence | rejection correct **but scope too narrow** (pristine-only) — see NEW-1 | - |
| uarch-3 (hunter REJECTED) | verify_reset_uarch revert-hash soundness | concur: sound | - |
| uarch-4 (hunter REJECTED) | uarch boundary behaviour | concur (the pc-divergence angle it missed is folded into NEW-1) | - |

---

### uarch-1: uarch `WRITE_TLB` ecall passes an unchecked `set_index` into a native array index (OOB host write)
- **Verdict: CONFIRMED.**
- **Independent reproducer:** `<SCRATCH>/verify/verify-uarch/poc_uarch1/run.sh` (+ `poc.c`).
  - *Different technique* from the hunter (who assembled a RAM-image ELF and used a wild index `0x10000`). Mine builds the uarch state entirely through the public C API — writes a single `ecall` word to uarch RAM, sets `uarch_pc`, and sets the uarch a-registers (`CM_REG_UARCH_X17=a7=4`, `CM_REG_UARCH_X10=a0=set_index`, …) — then `cm_run_uarch`. No cross-compiler needed. It uses `set_index=3` (the *first* invalid index) to prove a controlled one-past-the-end write, not just a wild crash.
  - Actual output (hardened/ASan lib): `/usr/include/c++/14/array:208: ... _Nm = 3 ... Assertion '__n < this->size()' failed.` → `BUG REPRODUCED (exit 134)`.
  - Release lib characterization (`poc_uarch1/poc_rel`): `set_index=3` and `4` **return OK = silent OOB write** into adjacent host memory; `set_index=0x10000` segfaults. So it is a genuine bounded write-what-where (offset `set_index*sizeof(set)` + `slot_index*sizeof(slot)`, 24 attacker-chosen bytes), silent for small offsets.
- **Root cause (my words):** `src/uarch-step.cpp:883` `executeECALL` reads `set_index` from uarch reg a0 and forwards it via `src/uarch-solidity-compat.hpp:165` `writeTlbECALL` → `a.write_tlb(static_cast<TLB_set_index>(set_index), …)`. In the run path `src/machine.hpp:709` `write_unverified_tlb` checks only `slot_index >= TLB_SET_SIZE` (256); `set_index` is never bounded before indexing `m_s->penumbra.tlb[set_index][slot_index]` and `m_s->shadow.tlb[set_index][slot_index]`. Both arrays are `std::array<…, TLB_NUM_SETS_>` with `TLB_NUM_SETS_ = 3` (`src/shadow-tlb.hpp:34`). The record path (`uarch-record-state-access.hpp:254`) and collect path (`collect-uarch-cycle-hashes-state-access.hpp:106`) forward the same unchecked value.
- **Q2 (reachable on the FIRST big step by an honest node?): YES.** The OOB is hit by the very first uarch instructions (set a0 + ecall) of a malicious uarch RAM image. An honest validator that advances the uarch of such a template — `cm_run_uarch`, `cm_log_step_uarch`, or `cm_collect_uarch_cycle_root_hashes` — corrupts/crashes its own process on big step #1, uarch_cycle 0. Confirmed via ASan (hardened-array assertion) and release segfault.
- **Severity: High.** Memory-corruption (silent OOB write, escalating to crash) reachable from untrusted machine state (uarch RAM image / uarch registers) via the standard uarch APIs used by nodes and verifiers. Not reachable in honest pristine operation (canonical uarch only emits `set_index ∈ {0,1,2}`), so not Critical, but it is a real in-process memory-safety hole on any party that advances the uarch of an attacker-supplied machine. Matches the guide's "memory corruption reachable by untrusted inputs" = High.
- **Risks:** Left unfixed: a malicious snapshot/template crashes or corrupts a node/verifier process (DoS, potential RCE). Also a host-vs-chain divergence: the generated Solidity step models `write_tlb` as a Merkle write at `shadow_tlb_get_abs_addr(set_index, slot_index)` = `AR_SHADOW_TLB_START + set_index*8192 + …` (a well-defined leaf; e.g. `set_index=3` → `0x7000`), whereas the reference C++ does a native OOB array access — so a host-side-only guard would *introduce* a new divergence (host errors where the chain proves a write).
- **Fix assessment — VALIDATED in a private build.** I placed the guard in the **shared** `executeECALL` path (so host and Solidity reject identically), not host-only:
  `src/uarch-step.cpp`, WRITE_TLB branch: after reading `set_index`, `if (set_index >= TLB_NUM_SETS_) { throwRuntimeError(a, "invalid TLB set index"); }`.
  Built a sanitized `libcartesi.so` with the patch at `<SCRATCH>/verify/verify-uarch/fixbuild/src` (`make sanitize=yes -j2 libcartesi.so`). Results against the fixed lib:
  - `set_index=3` → `cm_run_uarch rejected: "invalid TLB set index"` (no OOB).
  - `set_index=0x10000` → rejected (no segfault).
  - `set_index=2` (valid) → still works.
  - Pristine-uarch equivalence root hash unchanged (`2d3efcae…` before and after the fix), i.e. **no legitimate root-hash / on-chain-compatibility change.** The fix only rejects inputs an honest uarch never produces. This is correct and complete *for the memory-safety bug*; it does **not** by itself fix NEW-1 (see below).

---

### verify-uarch-NEW-1: a non-pristine uarch template (custom uarch RAM image, or non-reset uarch registers) is accepted with `uarch_cycle==0`, breaking the documented `cm_run == (run-uarch-to-halt + reset_uarch)` equivalence; the divergent transition is provable to the on-chain step verifier
- **Verdict: CONFIRMED (new finding).** Covers my Q1 and the coordinator/crafted-state register leads, verified independently.
- **Area:** uarch / divergence / proof-soundness.
- **Category:** divergence (interpret vs uarch vs on-chain step), input-validation, proof-soundness.
- **Where:**
  - `src/machine.cpp:107` `init_uarch_processor` — writes `uarch_pc/cycle/halt/x[]` from config via `write_reg` and only validates `x[0]==0`; nothing requires the pristine reset values.
  - `src/machine-address-ranges.cpp:348` `push_back_uarch_ram` — loads `uarch.ram.backing_store` verbatim; no pristine check.
  - `src/machine.cpp:2217` (`run`), `:2171` (`log_step`), `:2495`/`:2648` (collect) — the only equivalence precondition checked is `uarch_cycle != 0`. There is **no** check that the uarch RAM equals the embedded `uarch_pristine_ram`, nor that the uarch registers are at their init values.
  - `src/cm.h` — the C API exposes **no** pristine-uarch hash constant and **no** "is uarch pristine" predicate (Lua exposes `UARCH_PRISTINE_STATE_HASH`; C callers have nothing).
  - Docs state the equivalence unconditionally (`doc/README.md` §microarchitecture: "executing the uarch until it halts, and then resetting the uarch to its pristine state, is equivalent to executing one instruction of the main processor"), with the pristine `uarch.bin` premise only implicit.
- **Problem:** `cm_run` uses the native host interpreter and **never executes the uarch RAM**; the uarch path (`cm_run_uarch` to halt + `cm_reset_uarch`) **does** execute the committed uarch code, which (via load/store to physical addresses) can read/write the entire big-machine state. The uarch RAM + uarch shadow registers are part of the machine Merkle root (`push_back_uarch_ram` registers with `hash_tree=true`), so a template commits them and the on-chain step verifier executes exactly the committed (possibly non-canonical) uarch. Nothing validates the uarch is pristine, so the two execution paths the emulator offers are silently inequivalent for a non-pristine template even though `uarch_cycle==0`.
- **Scenario:** A party (malicious dapp author, or anyone distributing a machine snapshot) ships a template with a non-pristine uarch. Honest nodes advance state with `cm_run` (the fast path) and compute the RISC-V-correct trajectory; the on-chain verifier and any uarch-stepping party compute the *malicious* trajectory. Because the committed big-machine hash is registered on-chain and the dispute's ground truth is the uarch-level step verifier, the honest `cm_run` user is the odd one out and can lose the dispute / have a fraudulent transition finalized. Also affects any tool that loads an untrusted machine (store/load) and then both `cm_run`s and uarch-steps it.
- **Evidence (independent reproducers):**
  1. **Custom uarch RAM image** — `<SCRATCH>/verify/verify-uarch/q1_template_divergence/run.sh` (exit 1 on divergence). A 7-instruction uarch image writes `mcycle=1` and corrupts big-machine `x5`, then halts. Output:
     - pristine control: `cm_run` hash == uarch-step hash (`2d3efcae…`), invariant holds.
     - malicious: `cm_run` = `c0d3b180…`, uarch-step = `554c7136…` → **DIVERGENT**, yet machine B reports `mcycle=1` (looks like a legitimate one-mcycle advance).
  2. **Non-reset uarch registers** — `<SCRATCH>/verify/verify-uarch/q1_reg_variants/run.sh` (exit 1). From identical configs with `uarch_cycle==0`:
     - `uarch.processor.registers.halt=1` → uarch big-step is a permanent **no-op** (halts immediately, `mcycle` stuck at 0) while `cm_run` advances → DIVERGENT root hash. (This means the uarch-level computation can never advance.)
     - `uarch.processor.registers.pc=0x600008` → `cm_run_uarch` **throws** ("attempted memory write to sentinel at address 0xfffffffffffffff8") while `cm_run` proceeds → one-sided failure (nondeterminism between paths).
     - `uarch.processor.registers.x[10]=0x1234` → EQUAL (the uarch overwrites x10 before use) — noted to show not *every* perturbation diverges; control-flow/halt perturbations do.
  3. **The malicious transition is on-chain-provable** — `<SCRATCH>/verify/verify-uarch/q1_template_divergence/provable.c`: the custom-RAM uarch's 11 steps **all pass `cm_verify_step_uarch`** (the exact check the Solidity step verifier performs), with obtained hashes matching. So the divergent transition is acceptable to the on-chain verifier while `cm_run` yields a different hash.
  4. **A node *could* detect it** — `<SCRATCH>/verify/verify-uarch/q1_reg_variants/detect.c`: `cm_get_node_hash(m, 0x400000, 22)` (the uarch-state subtree) equals the known pristine hash `8c396c5e…` for a pristine machine and differs for every malicious variant. But nothing in the emulator does this automatically, and the pristine constant is not in the C API.
- **Possible solution:**
  - Emulator-level guard: in the spots that already check `uarch_cycle != 0` before treating the uarch path as equivalent (`machine::run`, `log_step`, the collect entry points), *also* verify the uarch-state subtree hash equals the pristine hash (`cm_get_node_hash(UARCH_STATE_START_ADDRESS=0x400000, log2=22) == uarch_pristine_hash`) — or at minimum expose `uarch_pristine_hash` and a `cm_is_uarch_pristine()` predicate in the C API and document that `cm_run`'s equivalence to uarch-stepping holds only for a pristine uarch. (The existing `uarch_cycle != 0` guard shows the emulator already tries to protect this precondition; it simply guards an incomplete subset.)
  - The `halt`/`pc` register variants are additionally caught by validating the uarch registers are at init values in `init_uarch_processor` (not just `x0`).
- **Severity: High, with a Critical ceiling.** By the guide's wording this is literally "divergence between implementations that must agree (interpret vs uarch vs on-chain step)" and the malicious transition is provable on-chain = Critical territory. I rate the **emulator-level** finding High because the trigger requires a non-canonical uarch, which a correctly-built node/on-chain layer should pin (the uarch is meant to be a fixed canonical component). It **escalates to Critical** end-to-end if the surrounding system does not independently enforce a canonical uarch hash — and the emulator currently gives C-API users no supported way to check, while documenting the paths as equivalent.
- **Risks:** Left unfixed, honest `cm_run`-based validators silently diverge from the on-chain uarch ground truth on a non-canonical template (dispute loss / fraudulent finalization); tooling that loads untrusted snapshots computes wrong results. Fix risk: a pristine-uarch guard would (intentionally) reject research/debug machines that deliberately customize the uarch via `cm_run`; it must therefore guard only the equivalence-dependent entry points (run/step/collect), and it costs one subtree-hash comparison. It changes no legitimate root hash.
- **Responsibility:** shared. The node/on-chain registration owns pinning the canonical uarch; the emulator owns (a) not silently offering two inequivalent execution paths under a documented-equivalent contract and (b) giving C-API callers the means to verify pristineness. An emulator-level guard or at least a documented/API pristine check is warranted.

---

### Review of the hunter's REJECTED items
- **uarch-2 (equivalence fuzzing, REJECTED "no divergence"):** the rejection is correct *for its scope* — but that scope was **pristine uarch only** (the harness runs both machines from the same config and the random programs are big-machine RISC-V; it never perturbs the uarch RAM or uarch registers). This is exactly the gap NEW-1 exploits. So the "no divergence" conclusion was over-broad; divergence exists once the uarch is non-pristine.
- **uarch-3 (verify_reset_uarch revert soundness, REJECTED "sound"):** I concur. `uarch_reset_state` (`src/uarch-reset-state.cpp:32`) drives the revert decision off `iflags_Y`/`htif_tohost` read through the replay state access (Merkle-bound), and `check_read_revert_root_hash_access` binds the revert-hash leaf to the current root (siblings + read-hash + exact `HASH_TREE_WORD_SIZE`) before adopting it as the "after" hash. Nothing dismissed too quickly.
- **uarch-4 (boundary behaviour, REJECTED "handled"):** I concur with the memory-safety claims (slot_index bounded; misaligned pc deterministic). The one thing it under-weighted — a misplaced `uarch_pc` making `cm_run_uarch` throw while `cm_run` proceeds — is a *divergence*, not a memory bug, and is folded into NEW-1.

## Reproducer index (all one-command, exit 1 = bug present)
- uarch-1: `<SCRATCH>/verify/verify-uarch/poc_uarch1/run.sh`
- NEW-1 (custom RAM image): `<SCRATCH>/verify/verify-uarch/q1_template_divergence/run.sh`
- NEW-1 (registers): `<SCRATCH>/verify/verify-uarch/q1_reg_variants/run.sh`
- NEW-1 provability: `<SCRATCH>/verify/verify-uarch/q1_template_divergence/provable.c`
- NEW-1 detectability: `<SCRATCH>/verify/verify-uarch/q1_reg_variants/detect.c`
- Fixed build (uarch-1): `<SCRATCH>/verify/verify-uarch/fixbuild/src` (patch in `uarch-step.cpp` WRITE_TLB branch)
