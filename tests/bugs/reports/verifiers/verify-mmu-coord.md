# Verification report: verify-mmu-coord

Verifier: `verify-mmu-coord`. Work dir: `<SCRATCH>/verify/verify-mmu-coord/`
(`<SCRATCH>` = `<SCRATCH>`).
Hunter PoCs were copied to `verify-mmu-coord/hunter/` and re-run from clean copies; all three reproduce as documented.
Private patched build (release flags, both mmu-tlb fixes applied): `verify-mmu-coord/build/src` (`cartesi.so`, `libcartesi.so`).

| id | verdict | severity (mine) | hunter's |
|---|---|---|---|
| mmu-tlb-1 | CONFIRMED (worse than claimed: silent divergence shown without a crash, also under ASan) | High | High |
| mmu-tlb-2 | CONFIRMED (broader trigger than claimed); the proposed fix is wrong | Low | Medium |
| COORD-1 | CONFIRMED (the precondition is wider than claimed) | High | Medium |

---

### mmu-tlb-1: `replace_memory_range` leaves stale host pointers in the hot TLB
- **Verdict: CONFIRMED.** I re-ran the hunter's PoC: SEGV (exit 1). The control with a cold TLB is consistent. Under the ASan build it shows as
  `AddressSanitizer: SEGV on unknown address ... WRITE` in `write_virtual_memory` at `interpret.cpp:1173`, reached from `cm_run`. That is a write
  to munmapped memory, so ASan reports a SEGV rather than a heap-use-after-free.
- **Independent reproducer:** `verify-mmu-coord/mmu-tlb-1/run.sh`. It is Lua, with hand-encoded RV64 code and no toolchain. It has three modes, and every mode
  compares against a reference that runs the same hashed-state sequence:
  - `divergence`: run 100 cycles (the TLB_WRITE slot for flash0 is now warm), then replace flash0, then replace flash1 (same size), then run to halt.
    The new flash1 mmap lands in the address range freed by the old flash0. The guest's stores to flash0 then go **silently into flash1**. There is no crash, and none under ASan either,
    and the root hash is wrong.
  - `logstep`: the same in-place sequence, but the reference is `log_step` on the same kind of machine. `log_step` calls `init_hot_tlb_contents()`
    (machine.cpp:2176), so the step-proof path computes the correct state while `cm_run` computes a different one.
  - `crash`: replace flash0 only, then SIGSEGV.
  ```
  == mode: divergence
  reference  halted=true mcycle=3007 t3=1000 flash0[0]=999 flash1[0]=0 root=096f48ea9cfae402
  in-place   halted=true mcycle=3007 t3=1000 flash0[0]=0 flash1[0]=999 root=a4485889c9aa2382
  BUG REPRODUCED: replace_memory_range after run silently diverges from the reference ...
  == mode: logstep
  log_step   halted=true mcycle=3007 t3=1000 flash0[0]=999 flash1[0]=0 root=096f48ea9cfae402
  in-place   halted=true mcycle=3007 t3=1000 flash0[0]=0 flash1[0]=999 root=a4485889c9aa2382
  BUG REPRODUCED: ...
  == mode: crash
  Segmentation fault
  BUG REPRODUCED: lua crashed with signal 11 ...
  ```
  The divergence mode gives identical results against the ASan build (`flash1[0]=999`, wrong root, no ASan report).
  JSON-RPC variant (`mmu-tlb-1/jsonrpc.lua`): spawn a server, then `create`, `run(100)`, `replace_memory_range`, `run`. The remote server process dies
  (`State: Z (zombie)`, client gets `end of stream`).
- **Root cause:** `machine::replace_memory_range` (src/machine.cpp:628-673) ends with `m_ars.replace(resolved)`. In
  `machine_address_ranges::replace` (src/machine-address-ranges.cpp:648-649), `ar = std::make_unique<memory_address_range>(...)` maps new memory
  and destroys, and so munmaps, the old range. Nothing resets `m_s->penumbra.tlb[*][*].vh_offset`. Those raw host pointers are used as-is by the fast paths
  (`state_access::do_read_tlb_vf_offset`, src/state-access.hpp:484-487; interpret.cpp:1069-1072 / 1171-1174 / 5599). The shadow TLB
  (`pma_index`, `vp_offset`) stays valid, and `mark_write_tlb_dirty_pages` (machine.cpp:1507-1531) marks the new range's page dirty from
  the shadow slot. The hash tree therefore hashes the new memory, while the guest reads and writes the old, or reused, host address. That gap is why the divergence is silent.
  Other paths that swap host memory already handle this: the constructor (machine.cpp:313) and the full-shadow restore (machine.cpp:1743) both call
  `init_hot_tlb_contents()`. `replace_memory_range` was missed. No other code path replaces an address range (checked all `make_unique<memory_address_range>`).
- **Realism.** The CLI calls `replace_memory_range` only right after create/load and before any run (src/cartesi-machine.lua:3100-3103).
  The docs (doc/README.md.template:917, 2595-2603; doc/recipes/run-calculator-with-new-drives.lua) show the same "load template, replace, run"
  flow. A freshly loaded machine has a cold hot TLB (constructor), so the documented flows are **not** affected. `cm.h:629-650` puts no
  ordering restriction on the call, so these are affected:
  - C/Lua/JSON-RPC integrations that reuse a running instance, for example a long-lived remote machine server that runs a job, swaps the input drive and runs again.
    The server crashes (DoS), or computes wrong state with no error.
  - A PRT node that did this would compute commitments with `cm_run`/collect-hashes that disagree with its own `log_step` proofs (logstep mode above),
    and would lose its dispute.

  I could not grep the external rollups-node or dave repositories from this sandbox (GitHub code search is blocked). To my knowledge they use
  load/run/send_cmio_response and do not call replace.
- **Severity: High** (kept). It is host memory corruption with guest-controlled data and addresses: guest stores land in whatever mapping later reuses the
  freed range, which can be another memory range or, in principle, malloc'd mmap chunks. It also produces silently wrong root hashes, and a legitimate, undocumented-as-forbidden API sequence triggers it.
  It is not Critical because no documented or production flow, and no guest action alone, triggers it.
- **Fix assessment:** the proposed fix is correct and complete. I added `init_hot_tlb_contents();` after `m_ars.replace(resolved);` in the private build.
  All three modes of my reproducer, the hunter's PoC and the JSON-RPC case then pass (exit 0, identical root `096f48ea...`). The fix touches only the
  non-hashed penumbra, so there is **no root-hash, step-log or on-chain change**. It costs nothing measurable, since slots are lazily re-verified from the shadow TLB.

---

### mmu-tlb-2: `read/write_virtual_memory` mishandle ranges that end in the last page of the address space or wrap past it
- **Verdict: CONFIRMED.** The trigger is broader than described, but the impact is lower than claimed. The hunter's PoC reproduces.
- **Independent reproducer:** `verify-mmu-coord/mmu-tlb-2/run.sh` (Lua). It builds a real Sv39 mapping for the two top virtual pages
  `0xffffffffffffe000` and `0xfffffffffffff000` to RAM, switches to S-mode, and shows that requests on **fully mapped, non-wrapping** ranges are silently
  skipped:
  ```
  control write [..e000,+0x800):  written
  write [..e800,+0x1000): ok=true err=nil data_written=false
    BUG: success reported, nothing written (mapped pages)
  read  [..f000,+0x1000): ok=true correct_data=false
    BUG: success reported but returned buffer is not the page contents
  write [..f000,+0x2000) wraps: ok=true err=nil
    BUG: wrapping write reported success
  BUG REPRODUCED
  ```
- **Root cause:** src/machine.cpp:1803-1807 (read) and 1834-1838 (write) compute `vaddr_limit = vaddr_start + length` and
  `vaddr_page_limit = (vaddr_limit + 0xfff) & ~0xfff`. Both overflow to a small value whenever the range's last byte is in the top page, not only when
  `start + length` wraps. The loop `vaddr_page < vaddr_page_limit` then runs zero times and the call returns success. `[0xfffffffffffff800, +0x800)`,
  the hunter's case 1, is a valid range that ends exactly at 2^64 and should be serviced.
- **Severity: Low** (downgraded from Medium):
  - Only requests touching the last 4 KiB of the 64-bit virtual address space are affected.
  - Linux on riscv64 does not map that page; the kernel image sits at `0xffffffff80000000` and is far smaller than 2 GiB.
  - The Rollups node does not use the virtual-memory API. In-repo users are the gdb stub (`src/cartesi/gdbstub.lua:398,412`) and tests.
  - It is not memory-unsafe. JSON-RPC uses `make_unique_calloc` (jsonrpc-remote-machine.cpp:1437), so it returns zeros and leaks nothing. The Lua binding uses `new unsigned char[length]`
    (clua-i-machine.cpp:793), so it returns uninitialized heap bytes, but only to the same process.
  - No hash impact.
- **Fix assessment:** the proposed fix is **incorrect/incomplete**:
  - `vaddr_start > UINT64_MAX - length` rejects valid ranges ending exactly at 2^64.
  - "Reject when the page-forward rounding would overflow" rejects valid in-range requests.

  The correct fix iterates to an inclusive last address:
  ```cpp
  if (vaddr_start > UINT64_MAX - (length - 1)) throw std::invalid_argument{"virtual address range wraps around"};
  const uint64_t vaddr_last = vaddr_start + (length - 1);
  const uint64_t vaddr_page_last = vaddr_last & ~(AR_PAGE_SIZE - 1);
  for (uint64_t vaddr_page = vaddr_page_start;; vaddr_page += AR_PAGE_SIZE) {
      ... chunklen = std::min<uint64_t>(AR_PAGE_SIZE, vaddr_last - vaddr + 1); ...
      if (vaddr_page == vaddr_page_last) break;
  }
  ```
  I validated this in the private build. My reproducer then prints `OK` (data written/read correctly, wrapping request rejected) and the hunter's PoC prints `not reproduced`.
- **Aside (not assigned, Low, dev tool only):** `src/cartesi/gdbstub.lua:412-413` has inverted logic. `if ok then return self:_send_error() end` reports
  an error to GDB when the memory write succeeded, and OK when it failed.

---

### COORD-1: RISC Zero step replay wraps `mcycle_end` while the host `verify_step` saturates
- **Verdict: CONFIRMED.** The hunter's PoC reproduces from a clean copy.
- **Independent reproducer:** `verify-mmu-coord/coord-1/run.sh`. This is a different and more faithful technique than the hunter's:
  - It compiles the **unmodified** `risc0/cpp/risc0-replay-steps.cpp` for the host. The file is copied verbatim; a stub `zk-runtime.hpp` sits next to it and replaces only the
    zkVM printf/abort shims.
  - It recompiles `interpret.cpp` to get the by-reference instantiation `interpret<replay_step_state_access&>` that the guest actually uses.
  - It calls the real `risc0_replay_steps()` and compares the result with `cm_verify_step`, using SHA-256 machines as the ZK guest requires.

  Output:
  ```
  --- near-max (mcycle_count=16)            [template mcycle = 2^64-4]
  honest: host verify_step ACCEPT | risc0 replay final root hash mismatch      -> BUG
  forged (after==before): host verify_step required page not found | risc0 replay ACCEPT, journal = (before, count, before) -> BUG
  --- run-to-halt (mcycle_count=18446744073709551615)   [ordinary machine, mcycle=1, halts at mcycle 6]
  honest: host verify_step ACCEPT | risc0 replay final root hash mismatch      -> BUG
  forged (after==before): host verify_step required page not found | risc0 replay ACCEPT, journal = (before, count, before) -> BUG
  --- control (mcycle_count=1000)
  honest: ACCEPT | ACCEPT ; forged: rejected | rejected
  BUG REPRODUCED: risc0 step replay wraps mcycle_end (mcycle + mcycle_count > 2^64-1)
  ```
- **Root cause:** `risc0/cpp/risc0-replay-steps.cpp:38` calls `(void) __builtin_add_overflow(a.read_mcycle(), context.logged_mcycle_count, &mcycle_end)`, which
  wraps. Every host path saturates: `log_step` at machine.cpp:2179, `verify_step` at 2206, collect hashes at 2366/2437/2485-2486. With a wrapped `mcycle_end < mcycle`,
  `interpret()` returns at interpret.cpp:6375 with zero cycles executed. The guest therefore commits the journal `(H, n, H)` for any log whose header claims `n`,
  and aborts on the honest log. The Rust prover (`risc0/rust/cartesi-risc0/src/lib.rs:59-80`) checks only the journal against the CLI arguments, so a valid receipt
  for the false statement is produced.
- **Precondition: is `mcycle + mcycle_count > 2^64-1` reachable?**
  - Guest: **no.** Writing the mcycle CSR raises an exception (`write_csr_mcycle`, interpret.cpp:2363-2371). mcycle advances by 1 per instruction
    (interpret.cpp:6297-6345), so reaching 2^64 by execution would take centuries.
  - WFI fast-forward (interpret.cpp:2833-2841) only exists for interactive state access, is capped by `min(mtimecmp, mcycle_end)`, and in
    `poll_external_interrupts` (machine.cpp:2224-2264) advances only by elapsed wall-clock time, and only in unreproducible machines. The other call site
    (interpret.cpp:5775) passes `mcycle_max == mcycle`.
  - `send_cmio_response` changes only `imcyclemax`, and saturates it (send-cmio-response.cpp:70).
  - Through the host/template: initial config `processor.registers.mcycle`, `cm_write_reg(MCYCLE)`, a full shadow-state `cm_write_memory`, or a tampered stored snapshot.
  - **New finding:** a crafted mcycle is not needed when the claimant controls `mcycle_count`. Any machine with `mcycle >= 1` and
    `mcycle_count = UINT64_MAX` triggers it ("run-to-halt" scenario above). In this API, UINT64_MAX is the idiomatic "run to completion" bound.
    For a fixed small leaf step size (a PRT-style use), a template with mcycle near 2^64 is required.
- **Does `imcyclemax` matter?** It does not mitigate the bug. `interpret` checks `mcycle >= imcyclemax` first (interpret.cpp:6360). When it holds, both verifiers
  agree, because no transition happens. Otherwise the host runs to `min(saturated_end, imcyclemax)` while risc0 runs 0 cycles. Since `imcyclemax <= UINT64_MAX`, it
  cannot prevent the window `mcycle < imcyclemax`, `mcycle + n >= 2^64`. In rollups mode it is `saturate(mcycle + 2^LOG2_MAX - 1)`, which also does not help.
- **Solidity, reasoning from the transpiled C++.** The on-chain step is transpiled from `uarch-step.cpp`, `uarch-reset-state.cpp` and
  `send-cmio-response.cpp`. None of them computes a multi-cycle `mcycle_end`:
  - `send-cmio-response.cpp` explicitly saturates `imcyclemax`.
  - The big-machine cycle run inside the uarch (and so by the Solidity uarch interpreter) uses `mcycle_end = read_mcycle() + 1` (uarch/uarch-run.cpp:43). That add wraps,
    but it is harmless: at `mcycle == UINT64_MAX`, `mcycle >= imcyclemax` always holds and `interpret` returns before reading `mcycle_end`.
  - I checked this empirically (`coord-1/uarch-near-max.lua`): uarch stepping 8 big cycles from `2^64-4` gives the same root hash as host `run` (saturates at
    2^64-1). The canonical verifiers (host, uarch, Solidity uarch) agree; only the risc0 guest diverges.
- **Severity: High** (upgraded from Medium). The ZK step verifier produces valid proofs of false transitions and cannot prove honest ones, which is the
  "invalid state transition provable" class. It is not rated Critical because there is no on-chain consumer of the risc0 prover in this repo (`risc0/solidity/` is empty), and the current PRT on-chain path (uarch) is
  unaffected. Exploitation needs either a template with mcycle near 2^64 (author-controlled) or a consumer that accepts large or claimant-chosen
  `mcycle_count`. It would be Critical for a deployment that accepts `mcycle_count` values such as UINT64_MAX.
- **Fix assessment:** the proposed `saturating_add` fix is correct. I validated it: `REPLAY_SRC=coord-1/fixed/risc0-replay-steps.cpp ./run.sh` prints `OK: risc0
  replay agrees with host verify_step` for all three scenarios. A ZK-friendly variant with no new include is
  `if (__builtin_add_overflow(a.read_mcycle(), context.logged_mcycle_count, &mcycle_end)) mcycle_end = UINT64_MAX;`.
  Side effects: no root-hash or step-log format change. It changes the guest binary, and so the **risc0 Image ID**, which any on-chain verifier pins and must be updated.
