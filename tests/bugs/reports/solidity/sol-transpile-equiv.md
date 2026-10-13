# Angle `sol-transpile-equiv`: semantic equivalence of the sed-based C++ → Solidity translation

Scope: does the generator (`helper_scripts/generate_UArchStep.sh`, `generate_UArchReset.sh`,
`generate_SendCmioResponse.sh`) plus the two compat layers (`src/EmulatorCompat.sol` and
`src/uarch-solidity-compat.hpp`) preserve the semantics of `uarch-step.cpp`, `uarch-reset-state.cpp` and
`send-cmio-response.cpp`? Target: machine-solidity-step **PR #104** (v0.16.0-test2), pinned to emulator
**v0.22.0-test2** (the branch audited here). PORTABILITY-1 / ASSERTS-1 (`require` → `assert`) is already
reported and excluded.

Work dir: `<SCRATCH>/work/sol-transpile-equiv/` (`<SCRATCH>` =
`<SCRATCH>`). One-command
reproducer: `work/sol-transpile-equiv/run.sh` (prints `BUG REPRODUCED`, exits 1). All emulator-side logs are
produced with the **upstream** library `<SCRATCH>/sol/upstream/root/usr` so the pristine uarch hash equals the
Solidity constant `UARCH_PRISTINE_STATE_HASH` (`fa022ea7…`).

Method (all three parts of the task):
1. **Static diff** (`static/static_diff.py`): lists every arithmetic/cast/shift/compare expression in the
   three generated C++ files that does **not** go through an `EmulatorCompat` helper, with inferred C++
   operand types, plus the generator's sed delete-patterns and the non-`unchecked` arithmetic in
   `EmulatorCompat.sol`.
2. **Single-step differential** (`single/`): 35,678 vectors — 20k random legal RV64I of every uarch class,
   every distinct 32-bit word of the official `uarch-ram.bin` (8,543), 5k random words, 2,141 directed edge
   cases (shift amounts 0/31/32/63, sign boundaries, rd=x0, every load/store width at every leaf offset, JALR
   odd targets, branches to pc±2^12, ECALL fn values, WRITE_TLB, cycle limit, halt, misaligned pc) — each run
   once through the **real** `src/uarch-step.cpp` (`single/cpp_step`, `require` routed to a throw) and through
   the committed `UArchStep.sol` on the **mock** `AccessLogs` (`make generate-mock` model, as `UArchInterpret`
   uses); the (status, revert, reason, per-word memory diff) tuples are compared bit-exact (`single/compare.py`).
3. **Program-level differential** (`prog/`): random uarch programs + random uarch register files; each uarch
   cycle is logged with `cm_log_step_uarch` (upstream lib, `runprog.lua`) and (a) replayed through
   `UArchStep.step` with the **prod** `AccessLogs` (`mss/test/ProgReplay.t.sol`) — root hash, status and buffer
   consumption must equal the emulator's — and (b) re-run under the **mock** `AccessLogs`
   (`mssmock/test/ProgMock.t.sol`) — final uarch register file / RAM / shadow-TLB must match, and when the
   emulator's next step errored the next Solidity step must revert with the same reason. 900 programs over
   three campaigns (`prog/campaign.sh` seeds 11/23/5, 200+400+300), ~28k replayed cycles.
+. **Decoder** (`prog/decode.sh`): every 32-bit word of the official `uarch-ram.bin` classified by the real
   C++ dispatcher (`prog/decode_cpp`, runs `executeInsn`) and by an independent transcription of the committed
   Solidity `UArchStep.executeInsn` dispatch order (`prog/decode_ref.py`).

## Results summary

| Check | Volume | Divergences |
|---|---|---|
| decoder classification (C++ dispatcher vs Solidity-order transcription) | 156,614 words (8,543 distinct; 132,213 ILLEGAL) | **0** |
| single-step differential (real uarch-step.cpp vs UArchStep.sol/mock) | 35,678 vectors | **2**, both `writeTlbECALL` overflow |
| program-level prod replay (cm_log_step_uarch → UArchStep.step) | 900 programs, ~28k cycles | **0** (0 emulator verify failures) |
| program-level mock run (final register/RAM/TLB + error-reason) | 900 programs | **0** |

The single divergence found is **SOL-TRANSPILE-EQUIV-1** below. Every other construct the task asked about is
equivalent (see the "Checked and equivalent" section).

---

### SOL-TRANSPILE-EQUIV-1: `EmulatorCompat.writeTlbECALL` uses CHECKED arithmetic (reverts on overflow) where `uarch-step.cpp` wraps, and omits the slot/set range check that the emulator's record path enforces
- Status: **PROVEN** (single-step differential + focused forge test + emulator probe)
- Area: uarch / Solidity transpiler / EmulatorCompat / divergence
- Category: divergence (transpile fidelity); input-validation (missing range check)
- Where:
  - `src/EmulatorCompat.sol:353-357` (`writeTlbECALL`):
    `paddress = AR_SHADOW_TLB_START + (setIndex * TLB_SET_LENGTH) + (slotIndex * TLB_SLOT_LENGTH)` —
    Solidity 0.8 **checked** `*` and `+` (outside any `unchecked` block), and **no** `slotIndex < 256` / set
    bound.
  - vs `src/uarch-solidity-compat.hpp:245` (`writeTlbECALL` → `a.write_tlb(...)`) and
    `src/shadow-tlb.hpp:106` (`shadow_tlb_get_abs_addr` = `AR_SHADOW_TLB_START + set_index*sizeof(shadow_tlb_set)
    + slot_index*sizeof(shadow_tlb_slot)`), plain **wrapping** `uint64` arithmetic, used by the replay accessor
    `src/uarch-replay-state-access.hpp:374` with **no** slot check.
- Problem: for a `WRITE_TLB` ECALL (a7=4) whose `set_index` (a0) or `slot_index` (a1) is large enough to
  overflow the 64-bit multiply, the generated Solidity `UArchStep.step` **reverts** with an arithmetic panic
  (0x11), while the C++ source computes a **wrapped** address. Thresholds: `setIndex*TLB_SET_LENGTH` (×8192)
  overflows for `set_index ≥ 2^51`; `slotIndex*TLB_SLOT_LENGTH` (×32) overflows for `slot_index ≥ 2^59`.
- Evidence (`run.sh`):
  - Single-step differential, the only 2 mismatches out of 35,678 vectors:
    ```
    #35676 [D 00000073]  C++: ok, writes 0x3000 (set*8192 wrapped)   Sol: revert panic:0x11   (x10=2^51+1)
    #35677 [D 00000073]  C++: ok, writes 0x1020 (slot*32 wrapped)    Sol: revert panic:0x11   (x11=2^59+1)
    writeTlbECALL-overflow mismatches: 2  other mismatches: 0
    ```
  - Focused forge test `mssmock/test/TlbOverflow.t.sol` (4/4 pass): `testSetIndexOverflowReverts` and
    `testSlotIndexOverflowReverts` assert `UArchStep.step` reverts with `Panic(0x11)`;
    `testInRangeControl` (set 2 slot 0 → writes 0x5000) and `testSlot256NoRevert` pass.
  - Emulator probe `tlb/probe.lua` (upstream lib): `set_index = 2^51+1` → the real `cm_log_step_uarch`
    **segfaults** (OOB host write `m_s->shadow.tlb[2^51+1][0]` in `machine::write_unverified_tlb`); this is
    exactly **uarch-1**. `slot_index = 256` and `2^59+1` → `cm_log_step_uarch` **throws** `TLB slot index out
    of bounds` (`machine.hpp:712`). In-range set 0/3 slot 0 log and verify fine (writes 0x1000 / 0x7000).
- Reachability (checked, as the task requires):
  - **Not reachable in the honest/pristine flow.** The official `uarch-ram.bin` only ever issues `WRITE_TLB`
    with `set_index ∈ {0,1,2}` and `slot_index = (vaddr>>12) & 255 ∈ [0,255]` (`tlb_slot_index`,
    `shadow-tlb.hpp:47`). For every in-range (set,slot) the Solidity multiply does **not** overflow and the
    chain computes the same in-range address as the emulator (the 900-program and set-0/3 probes confirm
    agreement). So an honest node's logs are unaffected and the chain matches `cm_run` there.
  - **No on-chain soundness break.** The divergence only occurs for out-of-range indices, and for those the
    emulator's **record** path (`cm_log_step_uarch`) crashes (large set_index — this is uarch-1) or throws
    (slot_index ≥ 256) *before emitting a log*. So there is **no** valid emulator log that the chain then
    rejects; the chain reverting (= rejecting) on such a crafted step keeps it sound.
  - **Residual (crafted-log) consequence, same class as PORTABILITY-1 / uarch-1 / DYNAMIC-1.** The emulator's
    **replay** verifier `cm_verify_step_uarch` has no slot/set check and wraps the address, so a *hand-crafted*
    `(root, log, root')` with a `WRITE_TLB` of `slot_index = 2^59+1` would be **accepted off-chain** (wrapped
    write to 0x1020) while the on-chain `MetaStep.step` **reverts** — an off-chain-accept / on-chain-revert
    split reachable only with a non-pristine committed uarch register (the SOL-ONCHAIN-1 envelope). A secondary
    wrinkle: for `slot_index = 256` both the replay verifier and the chain compute 0x3000 (set 1 slot 0) and
    *agree*, yet the honest record path throws — i.e. the replay accessor and the Solidity `writeTlbECALL`
    both lack the `slot_index < 256` bound that `write_unverified_tlb` enforces, so they accept a
    crafted WRITE_TLB that the honest generator refuses. Neither case lets the chain accept a wrong transition.
- Possible solution: make the compat layers byte-consistent. In BOTH `EmulatorCompat.writeTlbECALL` and
  `uarch-step.cpp`/`shadow.hpp`, add the identical bound `require(setIndex < 3 && slotIndex < 256, ...)` (the
  same `throw` on the host, matching `write_unverified_tlb`, and a `require` on-chain), and compute the slot
  address in `unchecked { }` in Solidity so the in-range arithmetic matches C++ exactly. This also closes
  uarch-1's host OOB write with a single shared check. (Changes the uarch image only if the C++ side adds the
  check inside the stepped code; adding it in `write_unverified_tlb` — where the throw already lives — is
  image-neutral and is uarch-1's recommended fix.)
- Severity: **Low**. Honest/pristine flow unaffected; chain stays sound (reverts); the reachable consequences
  fold into already-reported findings (uarch-1 host OOB for large set_index; PORTABILITY-1-style
  off-chain-accept/on-chain-revert for crafted logs). Reported as a transpile-fidelity gap and as the Solidity
  side of uarch-1's missing range check.
- Risks if left unfixed: a release/packaged off-chain `cm_verify_step_uarch` can validate a crafted uarch step
  the chain reverts (verifier-vs-chain disagreement, confusing dispute tooling); combined with uarch-1 a
  crafted large `set_index` is a host crash. Risk of the fix: adding the check to the *stepped* C++ code would
  change the uarch image / pristine hash and break the committed `UARCH_PRISTINE_STATE_HASH` — so the host
  check belongs in `write_unverified_tlb` (already present for slot) and the Solidity check mirrors it.

---

## Checked and equivalent (negative results)

Every other construct the task flagged was examined and found equivalent; the single-step (35,678 vectors) and
program (900 programs) differentials exercise them with 0 divergence beyond SOL-TRANSPILE-EQUIV-1.

- **Checked arithmetic that cannot overflow in context (so the Solidity revert is dead code):**
  - `cycle = cycle + 1` (`uarch-step.cpp:1103`): `uarch_step` returns `UArchCycleOverflow` when
    `cycle >= UARCH_CYCLE_MAX (0xFFFFF)` *before* the increment, so `cycle ≤ 0xFFFFE` here; `+1` cannot
    overflow uint64. Exercised by the cycle-limit edge vectors (status matches: overflow takes precedence).
  - `copyBits`: `offset + count` (`:81`) is guarded by `require(offset+count<=64)`; `uint64ShiftLeft(1,count)-1`
    (`:82`) has `count ∈ {8,16,32}` so the subtraction is ≥ 1 (no underflow). Exercised by every store width
    at every leaf offset.
  - `send-cmio-response.cpp`: `writeLengthLog2Size += 1` (`:59`, uint32, value ≤ 32), `1<<48 - 1`, `1<<16 - 1`,
    `1<<32 - 1`, `maxUint64 - maxMcycles` and `mcycle + maxMcycles` (the add is in the taken branch of a
    ternary guarded by `mcycle > maxUint64 - maxMcycles`, so it never overflows), and the Solidity
    `uint8(writeLengthLog2Size - 5)` (`writeLengthLog2Size ∈ [5,21]` there, so `-5 ∈ [0,16]`). None can
    over/underflow on the reachable path. (CMIO equivalence is also a negative result of `sol-onchain-impact`
    and `sol-proof-codec`; not re-run here.)
- **Integer promotion (uint8/uint16/int8/int16) and signed-immediate assembly** (`operandImm12/20/Jimm20/
  Sbimm12/Simm12/Shamt5/6`, `int32ShiftRight` on negative values, `int16/int8/int32 → uint64` sign-extension,
  the load/store width casts): 0 mismatches over the sign-boundary, load/store-every-width, branch-±2^12 and
  JAL/JALR edge vectors and the 900 programs. Solidity's fixed-width `int32`/`uint32` arithmetic shift and the
  explicit casts reproduce the C++ promoted results.
- **`~uint64(...)` bit-not** (`readUintN` alignment masks, `executeJALR` `& ~uint64(1)`): the operand is
  already `uint64` (not a narrow type), so no promotion difference; 0 mismatches.
- **Decoder table order and masks** (`insnMatchOpcodeFunct3Funct7Sr1` uses the 6-bit funct7 `0x3f<<26` for the
  RV64 shamt6 shifts SLLI/SRLI/SRAI, vs full funct7 `0x7f<<25` for SLLIW/SRLIW/SRAIW): all 156,614 image words
  classified identically by both dispatchers, and the shift-immediate edge vectors (including illegal
  funct7-bit encodings) produce identical results.
- **`uint32Log2`**: Solidity `require(value > 0)`; C++ `__builtin_clz(0)` is UB — but `send_cmio_response`
  only calls it under `if (dataLength > 0)`, so the argument is ≥ 1 and neither the revert nor the UB is
  reachable. Equivalent on the live path.
- **`readIflagsY` returns `bool` (Solidity) vs `uint64` (C++)**: used only as `if (!readIflagsY(a))`; both
  sides branch iff the IFLAGS_Y word is 0. Equivalent.
- **`putchar` is a no-op in Solidity**: `putCharECALL` does not change Merkle-covered state in C++ either (the
  record/replay accessors' `do_putchar` return false; host stdout is not hashed). The ECALL-fn=2 vectors
  produce identical state (advancePc + cycle) on both sides. Equivalent.
- **`UArchReset` / `SendCmioResponse`**: generated byte-identically (coordinator-verified) and their only
  non-compat arithmetic is covered above; no divergence (CMIO covered by other angles).

## Files
- `run.sh` — one command; prints `BUG REPRODUCED`, exits 1.
- `static/static_diff.py`, `static/static_diff.out` — part 1.
- `single/genvec.py`, `single/cpp_step.cpp`, `single/mkcopy.sh`, `single/compare.py`,
  `mssmock/test/SingleStepDiff.t.sol` — part 2.
- `prog/genprog.py`, `prog/runprog.lua`, `prog/campaign.sh`, `mss/test/ProgReplay.t.sol`,
  `mssmock/test/ProgMock.t.sol` — part 3 (`prog/sample/` holds a 3-program sample).
- `prog/decode_cpp.cpp`, `prog/decode_ref.py`, `prog/decode.sh` — decoder equivalence.
- `tlb/probe.lua`, `tlb/ecall.bin`, `mssmock/test/TlbOverflow.t.sol` — SOL-TRANSPILE-EQUIV-1 reproducer.
- `mss/` (prod AccessLogs) and `mssmock/` (mock AccessLogs) — private copies of the PR #104 tree.
