# Angle `mmu-tlb` — virtual memory / TLB / PMA audit

Scope: translate-virtual-address.hpp, hot-tlb.hpp, shadow-tlb.hpp, find-pma.hpp,
pmas.hpp, address-range.hpp, state-access.hpp and the other *-state-access.hpp TLB/PMA
lookups, the load/store/fetch paths in interpret.cpp, and the machine.cpp functions that
touch the TLB.

Summary of candidates:
- mmu-tlb-1: cm_replace_memory_range leaves stale host pointers in the hot TLB (use-after-munmap + divergence) — PROVEN — High
- mmu-tlb-2: cm_read/write_virtual_memory do not validate vaddr+length overflow (silent no-op / uninitialized buffer) — PROVEN — Medium

---

### mmu-tlb-1: `cm_replace_memory_range()` does not invalidate the hot TLB, leaving dangling host pointers
- Status: PROVEN
- Area: MMU / C API / store-load
- Category: memory-safety (use-after-free), divergence/nondeterminism
- Where:
  - `src/machine.cpp` `machine::replace_memory_range` (~628-673) → `src/machine-address-ranges.cpp` `machine_address_ranges::replace` (630-654)
  - stale pointer consumed in `src/interpret.cpp` fast paths `read_virtual_memory`/`write_virtual_memory`/`fetch_translate_pc` (the `vf_offset = vaddr + vf_offset` reads/writes, ~lines 1068-1072, 1170-1174, 5599) via `state_access::do_read_tlb_vf_offset` / `do_read_tlb_pma_index` (`src/state-access.hpp` ~470-490), which return the hot `penumbra.tlb` entry.
- Problem:
  The hot TLB (`processor_state::penumbra.tlb`, `hot_tlb_slot::vh_offset`) caches raw host
  pointers (`host_addr`) into the mmap backing each memory address range. It is NOT part of
  the hashed state; it is kept in sync with the shadow TLB by `write_verified_tlb` and is
  rebuilt from the shadow TLB by `init_hot_tlb_contents()` whenever the backing memory may
  have moved (e.g. the whole-shadow-state restore path at machine.cpp:1742-1743, and
  `log_step` at machine.cpp:2175).

  `replace_memory_range` destroys the old `memory_address_range` object and constructs a new
  one (`ar = std::make_unique<memory_address_range>(...)` in `machine_address_ranges::replace`),
  which creates a brand new mmap and `munmap`s the old one. It does NOT call
  `init_hot_tlb_contents()` and does not flush the TLB. Any hot TLB slot (CODE/READ/WRITE)
  that was populated for a page in the replaced range keeps its old `vh_offset`, which now
  points into freed/unmapped host memory. The next guest load/store/fetch that hits that slot
  dereferences the dangling pointer → segfault (or silent read/write of freed memory).

  Independently, even when it does not crash, the machine's observable behaviour diverges from
  its own hashed state: the shadow TLB + the (new, zeroed) range define the canonical state and
  root hash, but the interpreter still reads/writes the OLD memory through the stale hot
  pointer. This is a nondeterminism/divergence between what the Merkle root commits to and what
  `cm_run` actually executes.
- Scenario:
  A Cartesi Rollups node routinely runs the machine (`cm_run`) and then swaps a flash drive /
  memory range with `cm_replace_memory_range` (e.g. to install a new dApp image or input blob)
  before continuing. After the first run the hot TLB is warm for the flash page; the replace
  frees that mapping; the next `cm_run` crashes the node (DoS) or silently operates on stale
  memory whose contents are no longer reflected in the root hash. No guest cooperation is
  required — a guest that merely touched the range before the operator replaced it is enough.
- Evidence:
  - PoC: `<SCRATCH>/work/mmu-tlb/replace-uaf/` (`poc.c`, `prog.S`, `run.sh`), control `poc_control.c`.
  - Run: `cd <SCRATCH>/work/mmu-tlb/replace-uaf && ./run.sh` (exit 1 = bug). Output:
    ```
    before replace: flash[0]=249
    after replace:  flash[0]=0 (new zeroed range)
    BUG REPRODUCED: cm_run crashed with signal 11 (Segmentation fault) after
    cm_replace_memory_range: stale hot TLB host pointer into unmapped memory
    ```
  - Control (TLB cold — replace BEFORE any cm_run): `./poc_control prog.bin` →
    `control (cold TLB): flash[0]=499 guest t1=499 -> consistent` (exit 0).
    This isolates the hot TLB as the cause: identical replace with a cold TLB is correct and
    does not crash; only a warm TLB crashes.
- Possible solution:
  In `machine::replace_memory_range` (after `m_ars.replace(resolved)` returns), call
  `init_hot_tlb_contents();` so every hot slot is marked `TLB_UNVERIFIED_PAGE` and re-validated
  against the new range on next access (same remedy already used by the whole-shadow-state
  restore path). A plain TLB flush of the three sets would also work. The shadow TLB itself
  stays valid (same start/length/pma_index), so only the hot side needs rebuilding.
- Severity: High — guest-independent memory-safety bug (use-after-free / crash) reachable from a
  standard node API sequence, plus a root-hash/execution divergence if it does not crash.
- Risks if unfixed: node crash (DoS); on a non-crashing hit, the executed state silently
  diverges from the committed root hash. The fix only resets an out-of-hash cache, so it does
  NOT change any root hash and is compatible with the on-chain step verifier.

---

### mmu-tlb-2: `cm_read_virtual_memory` / `cm_write_virtual_memory` do not validate `vaddr + length` overflow
- Status: PROVEN
- Area: C API / MMU
- Category: input-validation, data-integrity
- Where: `src/machine.cpp` `machine::read_virtual_memory` (~1796-1823) and
  `machine::write_virtual_memory` (~1825-1857).
- Problem:
  Both compute `vaddr_limit = vaddr_start + length` and
  `vaddr_page_limit = (vaddr_limit + AR_PAGE_SIZE - 1) & ~(AR_PAGE_SIZE - 1)` with no overflow
  check, then loop `for (vaddr_page = vaddr_page_start; vaddr_page < vaddr_page_limit; ...)`.
  When `vaddr_start + length` wraps past 2^64 (or the page-forward rounding wraps), the limit
  becomes smaller than the start, the loop body never runs, and the function returns
  `CM_ERROR_OK` having transferred nothing. For reads the caller's buffer is left untouched
  (uninitialized/stale) rather than zero-filled or an error; for writes the data is silently
  dropped. This differs from the non-overflowing unmapped case, which either zero-fills (read)
  or reports an error — so the result is inconsistent and misleading.
- Scenario:
  A node/tool uses `cm_write_virtual_memory` to inject input into guest virtual memory. For a
  range near the top of the address space the call reports success but writes nothing; the node
  proceeds believing the data is present. `cm_read_virtual_memory` can hand back an
  uninitialized caller buffer while reporting success.
- Evidence:
  - PoC: `<SCRATCH>/work/mmu-tlb/vmem-wrap/` (`poc.c`, `run.sh`).
  - Run: `cd <SCRATCH>/work/mmu-tlb/vmem-wrap && ./run.sh` (exit 1 = bug). Output:
    ```
    read  vaddr=0xfffffffffffff800 len=0x800 -> err=0 first byte=0xaa
      BUG: reported success but buffer was never filled
    write vaddr=0xfffffffffffff000 len=0x2000 (wraps) -> err=0
      BUG: wrapping write reported success
    read  vaddr=0xffffffffffffe000 len=0x800 (no overflow) -> err=0 (ok)
    BUG REPRODUCED: virtual memory API range overflow is not validated
    ```
- Possible solution:
  Validate up front: reject (CM_ERROR_INVALID_ARGUMENT) when `length != 0` and
  `vaddr_start > UINT64_MAX - length` (or when the page-forward rounding would overflow), before
  entering the per-page loop.
- Severity: Medium — API misbehavior with realistic but limited impact (silent data loss /
  uninitialized buffer on near-max addresses); not memory-unsafe. No root-hash impact.
- Risks if unfixed: silent data-integrity failure for callers near the top of the address
  space. The fix only adds rejection of an out-of-range request; no compatibility impact.

---

Notes / things checked and found OK (not bugs):
- Direct `cm_write_memory` to the shadow TLB region (0x1000) is correctly rejected
  ("protected memory range shadow state"); the whole-shadow-state restore path
  (write 0x0 len 0x8000) re-inits the hot TLB and re-validates every slot through
  `shadow_tlb_verify_slot`, which bounds-checks `pma_index`, alignment, and
  `paddr_page ∈ [ar.start, ar.end-PAGE]` with `ar.is_memory()`. A crafted shadow TLB cannot
  make the interpreter read host memory out of the range's bounds.
- `cm_translate_virtual_address` and `read/write_virtual_memory` use
  `translate_virtual_address<...,UPDATE_PTE=false>`, so inspection has no A/D side effects and
  does not fill the TLB — no root-hash change from merely translating.
- Sv39/48/57 walk: reserved bits 60:54 / PBMT / N fault; R=0&W=1 and W&X reserved combos fault;
  non-canonical VA faults (arithmetic-shift canonicalization check); misaligned superpage
  faults; U/SUM/MXR and S-from-U-page-execute checks match the privileged spec. A/D updates go
  through the same `translate_virtual_address` template in interpret/record/replay/collect/uarch,
  so they are consistent across execution paths.
- TLB coherence on satp (MODE/ASID), mstatus (MXR/SUM/MPRV/MPP), SFENCE.VMA (all variants) and
  privilege changes all flush the appropriate sets; fetch cache is invalidated on priv change.
