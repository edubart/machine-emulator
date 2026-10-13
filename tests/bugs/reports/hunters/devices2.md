# Angle `devices2`: execution-focused pass over the deterministic devices and special address ranges

Work dir: `<SCRATCH>/work/devices2/` (`<SCRATCH>` = `<SCRATCH>`).
Everything below comes from running bare-metal guest programs. No claim rests on reading code alone.
Environment for all commands: `eval $(make -C /home/user/machine-emulator -s --no-print-directory env)`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| DEVICES2-1 | The host API can turn on HTIF console getchar in a *reproducible* machine (`cm_write_reg(htif_iconsole)`, `cm_set_runtime_config(console.input_source)`). Afterwards `cm_run` returns host console bytes to the guest, while the uarch, `cm_log_step`/`cm_verify_step` and `cm_collect_mcycle_root_hashes` return "no character". So their root hashes diverge, and `cm_store` writes a directory that `cm_load` rejects | PROVEN | Low |
| DEVICES2-R1 | Device / special-range MMIO matrix: 8 execution paths agree on every test, with per-mcycle root hashes compared | REJECTED (no divergence) | - |
| DEVICES2-R2 | Guest-visible device semantics match the reference model built from the device sources in every recorded access | REJECTED (no deviation) | - |
| DEVICES2-R3 | Console-output and automatic-yield breaks do not change the state. The fast path breaks on every putchar; uarch, step and collect never break | REJECTED (no divergence) | - |
| DEVICES2-R4 | Sanitizer (ASan+UBSan) pass of the device paths | REJECTED (clean) | - |
| DEVICES2-O1..O3 | Deterministic spec deviations that are consistent across paths. Noted, not reported | Observations | Low |

No Critical, High or Medium defect was found in this angle. The main value of the pass is the negative evidence:

- The device layer is shared code. `htif-`, `clint-` and `plic-address-range.cpp` are reached through `device_state_access<STATE_ACCESS>`, or through `mock_address_range` in the replay and in the uarch.
- Every accessor produced identical states for every device access exercised:
  - big-machine accessors: `state_access`, `record_step_state_access`, `replay_step_state_access`, `uarch_bridge_state_access` running inside the uarch, and `collect_mcycle_hashes_state_access`;
  - uarch-level accessors: `uarch_state_access`, uarch record/replay, and `collect_uarch_cycle_hashes_state_access`.
- The only divergence found (DEVICES2-1) needs the host to break the reproducible-mode invariant through the API.

---

## Harness and test programs

`cmp4.c` (binary `cmp5`/`cmp6`) runs one RAM image in each selected way and compares the results:

| Path | What it runs | Compared |
|---|---|---|
| A | `cm_run(max)`, resumed after automatic yields and console breaks | final state |
| B | `cm_run(mcycle+1)` once per mcycle | **root hash after every mcycle** |
| C | `cm_run_uarch(UINT64_MAX)` + `cm_reset_uarch` per mcycle (uarch big steps) | per-mcycle hash, or final only with `C_FINAL_ONLY=1` (cost) |
| D | `cm_log_step(DSTEP)` + `cm_verify_step` (verified hash must equal the machine hash) | per-mcycle hash when `DSTEP=1` |
| E | `cm_collect_mcycle_root_hashes(period 2^0)`, resumed after automatic yields and console breaks | per-mcycle hash |
| F | one `cm_log_step(remaining)` + `cm_verify_step`, re-issued after automatic yields (ROLLUP-FLOW-1) | final state |
| G | for every uarch cycle `cm_log_step_uarch` + `cm_verify_step_uarch`, then `cm_log_reset_uarch` + `cm_verify_reset_uarch` | per-mcycle hash |
| H | `cm_collect_uarch_cycle_root_hashes(mcycle+1)` per mcycle; last entry = hash after the reset | per-mcycle hash |

Final-state comparison covers:

- the root hash;
- 25 registers: pc, mcycle, icycleinstret, mstatus, mip, mie, mcause, mepc, mtval, iprv, iflags X/Y/H, tohost, fromhost, mtimecmp, girqpend, girqsrvd, ilrsc, a0..a5;
- the guest result area.

Guest programs, all generated (`gen.py`, `gen_vm.py`, `fuzz.py`):

- **Recording.** Each test does one access and records `[id, mcause|-1, mtval, value, mcycle-before, mip]` in RAM. A tiny M-mode trap handler records the trap and skips the instruction (it handles both 2- and 4-byte instructions). On fetch faults it resumes at a continuation label. On interrupts it records `mepc`, so the test can check that the interrupt was taken *exactly* after the triggering instruction.
- **Expectations.** `check.py` compares every record with a reference model of the device semantics, written from `htif/clint/plic-address-range.cpp` and the RISC-V access/misalignment/PMA rules.

| Program | Content | Tests | mcycles |
|---|---|---|---|
| `t_main` | Every range × widths lb/lbu/lh/lhu/lw/lwu/ld/flw/fld/c.lw/c.ld/c.fld, stores sb/sh/sw/sd/fsw/fsd/c.sw/c.sd/c.fsd, AMO .w/.d (swap/add/or/and/maxu), LR/SC pairs, instruction fetch (details below) | 639 | 21607 |
| `t_plic` | PLIC with `girqpend` preset to 0x100800000A7 (bits 0,1,2,5,7,31 and bit 40 outside the 32-bit view) | 46 | 1078 |
| `t_vm` | Device MMIO through Sv39 4 KiB pages from S-mode (details below) | 51 | 1696 |
| `small` | 59-mcycle device-dense program for the expensive per-uarch-cycle paths G and H | - | 59 |
| `console` | 40 HTIF putchars interleaved with automatic yields; run with 3 console runtime configs, including `to_buffer` size 4 `every_char` and size 1 `when_full`, so the fast path breaks on every putchar | - | 340 |
| `fz1..fz3` | Random sequences of 150 MMIO ops each over the same address set (`fuzz.py`) | ~155 each | ~5500 |

`t_main` address coverage:

- **HTIF** 0x40008000, offsets 0/8/0x10/0x18/0x20/0x28/0x30/0xff8/misaligned. 12 tohost commands that must not halt or yield manually: unknown device, halt with even data, halt with cmd≠0, getchar disabled, putchar, console cmd 2/65, yield cmd 2/64, automatic yield, device 0xff.
- **CLINT** 0x2000000: msip, msip+4, msip+8, mtimecmp, mtimecmp+4/+8, 0xbff0, mtime, 0xbffc, 0xc000, 0x10000, last word.
- **PLIC** 0x40100000: priority 0/1/31/32, 0xffc, pending, pending+4, enabled, enabled+4, 0x2080, threshold, claim/complete, 0x200008, 0x201000, last word; complete with 0/1/31/32/-1.
- **PMA array** 0x10000.
- **Shadow state, shadow TLB and holes:** 0x0, 0x8, 0xfe0, 0x1000, 0x6ff8, 0x7ff8, 0x8000, 0x11000.
- **Shadow uarch, uarch RAM and nearby holes:** 0x400000..0x401000, 0x600000..0x800000.
- **Holes around device/CMIO/RAM ranges:** the CLINT end, the VirtIO window 0x40010000/0x4001fff8/0x40020000, the PLIC end, the CMIO ends, below the DTB, RAM end, RAM end+4K.
- **Huge addresses:** 2^56-8, 2^56, 2^63, 2^64-8.
- **DTB 0x7ff00000:** read, write, AMO; code written into the DTB and executed; self-modifying DTB code without fence.i.
- **Boundary-straddling fetches:** a 4-byte instruction straddling the DTB→RAM PMA boundary at 0x7ffffffe; a 4-byte instruction straddling RAM end → hole; `c.jr` in the last 2 bytes of RAM.
- **CMIO rx/tx:** loads, stores, AMOs, LR/SC, fetch; `ret` written to tx and executed.
- **Automatic yield** via tohost.
- **MSIP interrupt delivery** right after msip set by sw, amoor.w, amoswap.w, sc.w, c.sw and fsw, and right after `csrs mie` / `csrsi mstatus.MIE` with MSIP already pending.

`t_vm` coverage:

- HTIF/CLINT/PLIC pages mapped with RW, R-only, X-only and U PTEs (SUM 0/1), and with A/D clear and preset.
- PMA array, hole, shadow, shadow uarch and uarch RAM mapped with RW PTEs (the PMA must still refuse the access).
- rx/tx mapped RWX (the PMA must still refuse fetch).
- Code in the DTB executed via a virtual address.
- A/D updates of a RAM page.
- A RAM page remapped to HTIF *without* `sfence.vma` (stale-TLB semantics), then with it, then back.
- An MSIP interrupt delivered to M while in S-mode.

---

### DEVICES2-1: Host API can enable HTIF console getchar in a reproducible machine; `cm_run` then diverges from uarch / step log / hash collection
- **Status:** PROVEN
- **Area:** devices (HTIF console), C API
- **Category:** divergence / nondeterminism (host-API reachable), data-loss (store/load asymmetry)
- **Where:**
  - `src/machine.cpp:325-332` (`machine::init_console`): the only place that enforces "console input ⇒ unreproducible". It runs only at construction and load.
  - `src/machine.cpp:1356-1357` (`machine::write_reg`, `reg::htif_iconsole`): accepts any value.
  - `src/machine.cpp` (`machine::set_runtime_config` → `m_console.set_config`): accepts `input_source` other than `from_null` with no reproducibility check.
  - `src/device-state-access.hpp:153-158` (`do_getchar`): serves real input whenever the accessor is interactive. Only `state_access` (cm_run) is interactive.
  - By contrast, `machine::poll_external_interrupts` is correctly gated by `is_unreproducible()`.
- **Problem:**
  - A reproducible machine (`iunrep=0`) normally cannot have HTIF getchar. `cm_create`/`cm_load` throw "TTY stdin is only supported in unreproducible machines".
  - However, `cm_write_reg(CM_REG_HTIF_ICONSOLE, 3)` (and also the full-shadow `cm_write_memory(0, ..., 0x8000)`) enables the getchar command afterwards, and `cm_set_runtime_config` can switch console input to a host buffer.
  - The guest's HTIF getchar is then served by `machine_console::getchar()` only in the fast interpreter:
    - With input closed (`from_null`) it returns EOT (4), so fromhost data = 5.
    - With `from_buffer` it returns host-supplied bytes.
  - Every non-interactive accessor returns `-1` (fromhost data 0) and never asks for a refill. These are the uarch (and therefore the on-chain step), `record/replay_step_state_access` (`cm_log_step`/`cm_verify_step`, the risc0 replay) and `collect_mcycle_hashes_state_access` (`cm_collect_mcycle_root_hashes`).
  - These calls all accept the machine as reproducible. They only refuse `iunrep != 0`, which is taken from the config.
  - `cm_store` also succeeds, but the stored directory cannot be loaded again.
- **Scenario:** An operator or tooling that pokes registers through the C API or JSON-RPC (for example to "enable console input for debugging" on a reproducible template) gets a machine whose `cm_run` results cannot be proven:
  - the state after `cm_run` differs from the uarch / step-log / `collect_mcycle_root_hashes` state for the same mcycle;
  - a snapshot saved with `cm_store` is unloadable.
  - The guest cannot trigger this by itself: `iconsole` is read-only to the guest (`sd` to HTIF+0x18 raises a store access fault, verified in `t_main`). Only the host API can create the state.
- **Evidence:** `<SCRATCH>/work/devices2/getchar/run.sh` (`sh run.sh`, exit 1 = defect present):
  ```
  (A) cm_run                           fromhost seen by guest=0x0100000000000005 root=86747ca5c57ea65c
  (C) uarch run+reset per mcycle       fromhost seen by guest=0x0100000000000000 root=8f386c87fe431907
  (D) cm_log_step + cm_verify_step OK  fromhost seen by guest=0x0100000000000000 root=8f386c87fe431907
  (E) cm_collect_mcycle_root_hashes    fromhost seen by guest=0x0100000000000000 root=8f386c87fe431907
  BUG REPRODUCED: reproducible machine diverges between cm_run and uarch/step/collect
  cm_store: ok; cm_load: TTY stdin is only supported in unreproducible machines
  BUG REPRODUCED: cm_store accepted a machine that cm_load rejects
  ```
  Host-controlled input variant, `getchar/setrc.c` (`./setrc prog.bin`, after `sh run.sh` has built `prog.bin`):
  ```
  cm_create with input_source=from_buffer: TTY stdin is only supported in unreproducible machines
  cm_set_runtime_config(from_buffer) accepted; guest read fromhost=0x010000000000005b (host byte 'Z'+1=0x5b)
  ```
- **Possible solution:** Enforce the invariant at runtime as well as at construction, and make the interactive accessor honour it.
  - `device_state_access::do_getchar` (or `machine::getchar`) returns `{-1, false}` when `!is_unreproducible()`. This mirrors `poll_external_interrupts`.
  - `machine::write_reg(reg::htif_iconsole, v)` and the full-shadow `write_memory` path reject the `HTIF_CONSOLE_CMD_GETCHAR` bit on reproducible machines.
  - `machine::set_runtime_config` applies the same `input_source` check as `init_console`.
- **Severity:** Low. It needs the machine owner to misuse the host API, and the guest alone cannot reach it. It does break the "reproducible ⇒ every path agrees" invariant silently, and it produces unloadable snapshots.
- **Risks:**
  - If left unfixed, any tooling that enables console input on a reproducible machine computes unprovable states.
  - The fix changes no root hash of any legitimately configured machine. Reproducible machines never have getchar enabled through config or load.

---

### DEVICES2-R1: Device / special-range MMIO matrix (REJECTED, no divergence)
RESULTS_R1

### DEVICES2-R2: Device semantics vs. reference model (REJECTED, no deviation)
RESULTS_R2

### DEVICES2-R3: Console-output / automatic-yield breaks (REJECTED, no divergence)
RESULTS_R3

### DEVICES2-R4: Sanitizer pass (REJECTED, clean)
RESULTS_R4

### Observations (Low, deterministic and identical in every path; not reported as findings)
- **O1.** A guest store to `mtimecmp` always clears MTIP (`clint-address-range.cpp`). MTIP is re-evaluated only at the next RTC tick (up to 8191 mcycles later), even when the new `mtimecmp` is already ≤ mtime. The SiFive CLINT keeps MTIP asserted while `mtime >= mtimecmp`. This is a tick-based design and is identical in all paths. It is related to interp-priv-5.
- **O2.** CLINT accepts only 32-bit msip and 64-bit mtimecmp/mtime accesses, and `mtime` is read-only (store access fault). HTIF accepts only 64-bit accesses. PLIC accepts only aligned 32-bit accesses; other PLIC offsets read as 0 and ignore writes. All of this is documented in the source and consistent across paths.
- **O3.** Verified, design-consistent outcomes:
  - The shadow state, shadow TLB, shadow uarch state and uarch RAM are *not* guest-visible: every load, store, AMO and fetch raises an access fault, also through a virtual mapping with RW PTEs.
  - The PMA array is guest-readable and every write faults.
  - CMIO rx is read-only and both rx and tx are non-executable, even with X PTEs.
  - A 4-byte instruction straddling the DTB→RAM PMA boundary executes; one straddling RAM end faults with `mtval` = second half, `mepc` = start (correct per the privileged spec).
