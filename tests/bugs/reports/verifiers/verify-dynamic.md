# Verification report: verify-dynamic

Verifier: `verify-dynamic`. Work dir: `<SCRATCH>/verify/verify-dynamic/`. No fuzzers were run.

| ID | Verdict | Severity (mine) |
|----|---------|-----------------|
| DYNAMIC-1 | PARTIALLY CONFIRMED: the defect is real, but the hunter's description of which side is "canonical" is wrong (see below) | High (crafted template state only) |

### DYNAMIC-1: shadow WRITE-TLB slot to a non-writable memory range passes `shadow_tlb_verify_slot`
- Verdict: PARTIALLY CONFIRMED.
  - Confirmed: on the same committed state, `cm_run`, `cm_collect_mcycle_root_hashes`-style host paths and
    `cm_log_step`/`cm_verify_step` perform the store. The host C++ uarch driver (`cm_run_uarch`, and by the same
    code `cm_log_step_uarch`/`cm_collect_uarch_cycle_root_hashes`) refuses it. On a loaded machine (read-only range
    mapped `PROT_READ`) the host store faults the process (SIGSEGV).
  - Corrected: the hunter calls the uarch refusal the "on-chain reference". It is not. The refusal comes from a
    host-only guard in `machine::write_word` (`src/machine.cpp:1953`, `is_host_read_only()`), which is not part of
    the proven semantics. The uarch replay verifier (`uarch-replay-state-access.hpp:359` `do_write_word` →
    `check_write_word_access`) and the Solidity step (`EmulatorCompat.sol:127` `writeWord` →
    `AccessLogs.writeWord`) do no read-only check. The interpreter compiled into the uarch RAM image validates the
    slot with the same `shadow_tlb_verify_slot` (`uarch/uarch-bridge-state-access.hpp:180`), so it also takes the
    fast store. So the on-chain verifier agrees with `cm_run`. The stock host emulator is the one that cannot follow
    it: it cannot produce uarch-level commitments or uarch step proofs for that mcycle. That is a
    proof-completeness/liveness gap for the honest prover, not "cm_run accepts what the chain rejects".
  - Secondary effect (agrees with the hunter, from code reading): the always-present target is the PMA table
    (0x10000). The fast path can rewrite committed PMA entries. After that, `cm_run` keeps using its in-memory
    address map. The uarch, the replay and on-chain decode ranges from the committed table (`do_read_pma` reads
    istart/ilength from memory), so later steps can diverge between `cm_run` and the on-chain step. A stored copy of
    such a machine also fails to reload (`init_pmas_contents`: "PMA state is inconsistent"). I did not reproduce
    this independently.
- Independent reproducer: NOT COMPLETED. My work on my own reproducer was cut short, so the evidence here is the
  hunter's PoCs, re-run unchanged from a clean copy in `<SCRATCH>/verify/verify-dynamic/hunter-copy/`, plus my
  source review:
  - `bash hunter-copy/run.sh` (ASan and release builds give identical output):
    ```
    cm_run: err=0 break=5  read-only region changed=1  root-hash changed=1
    cm_run_uarch (3 mcycles): err=-6 (attempted memory write to read-only PMAs at address 0x10000(65536))
    cm_log_step (3 mcycles): err=0 (ok)
    cm_verify_step: err=0  matches-cm_run=1
    BUG REPRODUCED ...   exit=1
    ```
  - `bash hunter-copy/run_segv.sh`: `AddressSanitizer: SEGV ... WRITE` at `state-access.hpp:480` ←
    `write_virtual_memory interpret.cpp:1173` ← `cm_run`.
  - I checked the PoC itself. It uses only the public API: a full-shadow `cm_write_memory(0, ..., 0x8000)`, which
    the code explicitly allows (`machine.cpp:1730` "allowing manual snapshots"). It does not depend on toolchain
    differences.
- Root cause: `src/shadow-tlb.hpp:153` `shadow_tlb_verify_slot` checks only invalid marker, padding, alignment,
  `ar.is_memory()` and page bounds. It does not check the set-specific permission. The slow paths do check it:
  W in `interpret.cpp:1108`, R in `:992`, X in `:5551`. The verified slot becomes a hot entry in
  `machine::init_hot_tlb_slot` (`machine.cpp:262`), `replay-step-state-access.hpp:548` and the uarch
  `do_verify_cold_tlb_slot`. The fast store `interpret.cpp:1170-1174` then writes with no further check.
  - Which ranges are affected: only PMA-visible memory ranges with W=0. These are the PMA table (always present,
    host_read_only), read-only flash drives and NVRAMs (host_read_only; mapped `PROT_READ` when backed by a file, so
    a write faults the process even on a freshly created machine), and the CMIO rx buffer. The rx buffer is W=0 but
    not host_read_only, so every path, including the host uarch, writes it consistently: a guest-semantics
    violation, not a cross-path divergence. Every PMA memory range is readable, so the READ set has no practical
    gap. A CODE slot pointing at X=0 memory (flash, CMIO) would execute consistently on all paths.
- How such a slot reaches committed state:
  - Full-shadow `cm_write_memory`: yes. This is an intended API (snapshot restore). The design defends it by lazy
    validation, and that validation is incomplete here.
  - Stored machine directory: yes. Load performs no eager TLB validation (`init_hot_tlb_contents` only marks slots
    unverified). The easy route is to build the state with the API and then call `cm_store`, which gives consistent
    hashes.
  - Config: no TLB fields. `cm_write_reg`: TLB slots are not registers.
  - Step-log replay: uses the same verify function, so it accepts the slot (consistent with `cm_run`). Pages are
    bound to the root hash, so the slot must already be in committed state.
  - Non-pristine uarch `WRITE_TLB` ecall (`write_unverified_tlb`): yes, but that is already covered by
    verify-uarch-NEW-1.
  - Honest guest execution and `cm_replace_memory_range`: no. The slow path gates on W, and replace refuses
    read-only targets and preserves flags.
- Reconciling with mmu-tlb: its conclusion was correct for its scope. Bounds checks stop out-of-range host
  accesses. It did not consider permissions per TLB set. DYNAMIC-1 is that gap, and it is in-bounds.
- Severity: High, same model as verify-uarch-NEW-1 (a crafted template). Reasons:
  - The state is reachable only through a crafted committed state, not from honest guest execution, so I do not
    rate it Critical.
  - For an honest PRT node that loads such a template, the node's own `cm_run` can crash. Its uarch commitment and
    proof generation fail for a transition the on-chain verifier would accept, which can cost the honest party the
    dispute through inability to prove.
  - Through the PMA-table write, `cm_run` can drift from on-chain semantics on later steps.
  - Rises toward Critical if the surrounding system does not vet templates. Note that the fix itself changes the
    on-chain constant (see below).
- Fix assessment:
  - The proposed fix is correct: in `shadow_tlb_verify_slot`, reject `TLB_WRITE` slots whose range is not
    `is_writeable()`, and for completeness `TLB_READ` without `is_readable()` and `TLB_CODE` without
    `is_executable()`. To do this, make the function a template on SET, or pass the set index.
  - `is_writeable()` alone is sufficient. It is decoded from committed PMA istart flags, so the uarch, replay and
    Solidity can all evaluate it, and `host_read_only` implies W=0 (`memory-address-range.cpp:49`).
  - It must be done in the shared header. A host-only fix (`machine::init_hot_tlb_slot`/replay) would create a new
    divergence: the host would raise a store fault while the uarch and on-chain still store.
  - Side effects: the uarch RAM image is compiled from this code, so the fix changes `uarch-ram.bin`, the pristine
    uarch hash, every machine root hash, and the Solidity `UARCH_PRISTINE_STATE_HASH`. A coordinated uarch/on-chain
    release is required.
  - Behaviour for honest states does not change, because honest W-slots always point at W=1 ranges.
  - The `machine::write_word` host guard should stay as defence in depth.
  - NOT validated in a private build. That was not done before my work stopped.
