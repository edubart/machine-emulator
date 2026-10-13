# verify-repro: independent verification of REPRO-1, REPRO-2, REPRO-3 (brief), REPRO-4, ROLLUP-FLOW-2

Verifier: `verify-repro`. Work dir: `<SCRATCH>/verify/verify-repro/`, where
`<SCRATCH>` = `<SCRATCH>`.
- Hunter PoCs were copied to `hunter/` and re-run unchanged. All of them reproduce.
- My own reproducers are in `repro1/`, `repro2/`, `repro4/` and `rollupflow2/`. They use the Lua API with hand-encoded RV64 instruction words and no assembler. Where possible they use different triggers and devices from the hunter's.
- The patched build used to test the fix is `fixbuild/`: release sources of the repo plus a one-line guard in `machine::log_step`.

| ID | Verdict | Severity (mine) | Hunter's |
|---|---|---|---|
| REPRO-2 | CONFIRMED (all four sub-claims) | **Low** (upper end of Low) | Medium |
| REPRO-1 | CONFIRMED | Low | Low |
| REPRO-4 | CONFIRMED (also aborts the process in assert-enabled builds) | Low | Low |
| REPRO-3 | CONFIRMED as supporting evidence for interp-priv-1 | per interp-priv-1 | dup |
| ROLLUP-FLOW-2 | **REFUTED**: intended behaviour, documented in `--help` and asserted by an upstream test | n/a | Low |

---

### REPRO-2: `cm_log_step` / `--log-step` have no reproducibility guard (wrong-semantics proofs, non-atomic failure, process abort on VirtIO queue notify)
- **Verdict: CONFIRMED.** All of (A), (B) and (C) reproduce, and (C) does so through the library, the JSON-RPC server and the CLI.

- **Independent reproducer:** `<SCRATCH>/verify/verify-repro/repro2/run.sh`. It takes about 4 s and exits 1. Differences from the hunter's PoC:
  - (A) uses WFI with no console at all, instead of HTIF getchar.
  - (B) and (C) use the **VirtIO 9P** device instead of the console.
  - (B) uses an MMIO *write*.
  - The CLI case uses a 40-byte bare-metal image instead of booting Linux.

  Output excerpt:
  ```
  == (A') WFI, unreproducible machine without devices
    initial root (both machines)     0835bc48a593dc84
    log_step_uarch on this machine:  ... microarchitecture cannot be used with unreproducible machines
    collect_mcycle_root_hashes:      ... cannot collect hashes from unreproducible machines
    machine:run(200000)              break=1 a0(mcycle after wfi)=81921 mcycle=81925 root=47adcab6103527d5
    machine:log_step(200000)         break=1 a0(mcycle after wfi)=1 mcycle=5 root=a7e232df1597df31
    verify_step(initial root, log)   ACCEPTED, proven root after=a7e232df1597df31
    BUG REPRODUCED (A') ...
  == (B') VirtIO register write inside the step (9P device)
    machine:log_step(100): error: ... unhandled mock address range
    before: mcycle=0 root=80f50e5037168e88
    after : mcycle=6 iflags_H=1 root=71a11ee1cdb334e3, log file left behind: 23112 bytes
  == (C') VirtIO queue notify inside the step, local library (child process)
    [control] machine:run(100): break=1 halted=1 mcycle=10
    | terminate called after throwing an instance of 'std::runtime_error'
    |   what():  unexpected call to record_step_state_access::read_memory
    | CHILD_STATUS 134
  == (C'') VirtIO queue notify inside the step, JSON-RPC server
    terminate called after throwing an instance of 'std::runtime_error'
    log_step: error: ... jsonrpc error: post error contacting 127.0.0.1:...
    follow-up get_root_hash: error: ... (Connection refused)
  == (C''') cartesi-machine --volume=... --log-step=... with the queue-notify guest
    | Running in unreproducible mode!
    | terminate called after throwing an instance of 'std::runtime_error'
    |   what():  unexpected call to record_step_state_access::read_memory
    cartesi-machine exit status: 134
  BUG REPRODUCED (REPRO-2)
  ```

- **Hunter PoC:** `hunter/r2-logstep/run.sh` reproduces exactly as documented (getchar / vmagic / vnotify / JSON-RPC). I checked the PoC for misuse:
  - Every configuration is a legal unreproducible configuration.
  - The getchar case enables `htif.iconsole` getchar only together with `iunrep=1`.
  - The VirtIO guest sequence (`STATUS=DRIVER_OK`, `QUEUE_SEL`, `QUEUE_READY=1`, `QUEUE_NOTIFY`) is the minimal subset of what a Linux virtio-mmio driver does.

- **Root cause:**
  - The policy is "no proofs or hashes from unreproducible machines". It is enforced in:
    - `log_step_uarch` (`src/machine.cpp:2079`) and `run_uarch` (`:2124`);
    - `collect_mcycle_root_hashes` (`:2325`) and the bundle collectors (`:2489`, `:2635`);
    - `store` (`:400`);
    - in the CLI, by asserts for `--log-step-uarch`, the hashes and the proofs (`cartesi-machine.lua:2704`, `3561`, `4675`, `4685`).
  - `machine::log_step` (`src/machine.cpp:2171-2190`) has no `is_unreproducible()` check, and neither does the CLI `--log-step` path (`cartesi-machine.lua:4644-4649`).
  - (A) Semantic gap. `record_step_state_access` is not an interactive accessor, so `execute_WFI` (`interpret.cpp:2821-2841`) skips `poll_external_interrupts`, and HTIF getchar returns "no char".
    - `cm_run` uses `state_access`, which is interactive. On an unreproducible machine, `machine::poll_external_interrupts` (`machine.cpp:2224-2262`) advances `mcycle` by host time and delivers host bytes.
    - Both logs are self-consistent, so `verify_step` accepts the deterministic transition while `cm_run` performs a different one.
  - (B) Non-atomic failure. The replay creates mock ranges only for CLINT/PLIC/HTIF/memory (`mock-address-range.hpp:57-75`), so any VirtIO PMA hits `abrt("unhandled mock address range")`.
    - This happens only in the self-check `verify_step` after `interpret()` has already run on the live machine.
    - The error therefore surfaces after the machine, the VirtIO device and the log file have all changed.
  - (C) Process abort. The call chain is: `virtio_address_range::do_write_device` is `noexcept` (`virtio-address-range.cpp:836`) → `mmio_write` → `QUEUE_NOTIFY` (`:726-731`) → `on_device_queue_notify` → `virtq_get_avail_header` → `i_device_state_access::read_memory` → `record_step_state_access::do_read_memory`, which throws (`record-step-state-access.hpp:250-255`).
    - The exception crosses the `noexcept` frame, which calls `std::terminate`.
    - `collect_mcycle_hashes_state_access` has the same throwing stubs (`collect-mcycle-hashes-state-access.hpp:437-450`), but its entry points are guarded.
    - I checked the other `noexcept` device callbacks (HTIF/CLINT/PLIC, both record and replay). Their state accesses are register accesses into the shadow page, which the interpreter has already touched, and console `putchars` is itself `noexcept`. So I found no other path to `terminate` from an untrusted step log.
  - Not intentional: no doc, test or comment says that `log_step` should accept unreproducible machines. The README describes unreproducible mode as "giving up state-hash verifiability", and no test logs steps of an unreproducible machine.

- **Severity: Low**, downgraded from Medium. Reasons:
  - Every effect needs a machine *configured* `iunrep=1`, and VirtIO needs that too (`push_back_virtio` checks the config). Such machines cannot be stored (`store` refuses) and cannot be created on disk.
  - The Rollups node only loads stored, reproducible templates, so the node and PRT disputes can never reach this code.
  - (A) has no dispute impact. No honest party can produce commitments for an unreproducible machine because collect refuses, and what `verify_step` checks is the deterministic semantics. That is the meaning the on-chain verifier gives the state anyway. (A) is a policy inconsistency, not a soundness hole.
  - (C) is a real abort, but it needs the host to call `log_step` on an unreproducible VirtIO machine, i.e. a developer debugging flow (`--volume`, `--network`, `-it`, `--virtio-console` together with `--log-step`). A JSON-RPC client that can choose the config can already stop the server with `shutdown`, so the abort crosses no privilege boundary.
  - For comparison, ASSERTS-2 (an abort through API misuse on *reproducible* machines) was rated Low, and devices-1 (a guest-only hang, no host misuse needed) was rated Medium.
  - It sits at the top of Low because the abort is a library-level `std::terminate` from a supported call. The fix is one line and changes no hash.

- **Fix assessment:**
  - The main fix is correct and sufficient: add `if (is_unreproducible()) throw std::runtime_error{"cannot log steps of unreproducible machines"};` at the top of `machine::log_step`, before `get_root_hash()`/`init_hot_tlb_contents()`.
    - It covers the C API, Lua, JSON-RPC (the server calls `machine::log_step`) and the CLI.
    - It changes no root hash, step-log format or on-chain verifier.
    - No existing test logs steps of an unreproducible machine.
    - Validation: see the "Fix validation" block below.
  - Also recommended: a CLI `assert(initial_config.processor.registers.iunrep == 0, ...)` before the run for `--log-step`. Without it, the CLI with the library fix runs the whole `--max-mcycle` window and only fails afterwards.
  - Defence in depth (optional): do not let accessor exceptions cross the `noexcept` VirtIO MMIO callbacks. Either drop `noexcept` from `virtio_address_range::do_read_device`/`do_write_device`, or catch in those callbacks and fail the access.
    - I prefer this over the hunter's "return false" idea. Silently returning false would make the record accessor produce a log whose device behaviour (NEEDS_RESET) differs from `cm_run`'s, which re-creates (A) without the crash.
  - Optional for uniformity: the same guard in `log_send_cmio_response` / `log_reset_uarch`. These are harmless today: no host-time dependence, and uarch is already refused.
  - **Fix validation:** `fixbuild/src` is a copy of the release build with only the guard added to `machine::log_step`. I rebuilt `libcartesi`, `cartesi.so`, `cartesi/jsonrpc.so` and `cartesi-jsonrpc-machine`, then ran `CARTESI_SRC=<SCRATCH>/verify/verify-repro/fixbuild/src sh repro2/run.sh`, which exits 0:
    ```
    machine:log_step(200000)         refused: ... cannot log steps of unreproducible machines
    (B') machine:log_step(100): error: ... cannot log steps of unreproducible machines
         after : mcycle=0 iflags_H=0 root=80f50e5037168e88 (unchanged), log file left behind: -1 bytes (none)
    (C') LOG_STEP_RETURNED false ... cannot log steps of unreproducible machines ; CHILD_STATUS 0
    (C'') log_step: error: ... cannot log steps of unreproducible machines ; follow-up get_root_hash: 6df093103f56bea4 (server alive)
    (C''') lua5.4: cartesi-machine.lua:4647: cannot log steps of unreproducible machines ; exit status 1 (no abort)
    OK: log_step refuses unreproducible machines
    ```
    Sanity check: on the patched build, `log_step(10)` + `verify_step` of a reproducible machine still agree (`OK`).

---

### REPRO-1: `iunrep` has two sources of truth (config used by guards and behaviour, shadow register committed by the root hash)
- **Verdict: CONFIRMED.**

- **Independent reproducer:** `<SCRATCH>/verify/verify-repro/repro1/run.sh` (exit 1).
  - It uses a different route from the hunter's `cm_write_reg(IUNREP)`: the documented "manual snapshot" special case of `write_memory`. The comment at `machine.cpp:1732` reads "allowing manual snapshots for machines with shared layouts via read_memory()/write_memory()".
  - It copies the full 0x8000-byte shadow between a reproducible and an unreproducible machine of otherwise identical config.
  ```
  == (A) reproducible machine receives the shadow snapshot of an unreproducible one
    shadow iunrep now=1, initial config iunrep=0
    store: ok
    load : ... iunrep mismatch between shadow state and config
    BUG REPRODUCED (A): store accepted a machine whose directory can never be loaded
  == (B) unreproducible machine receives the shadow snapshot of a reproducible one
    root reproducible=8fcb70ce63b9f429 root unreproducible=8fcb70ce63b9f429 (IDENTICAL)
    collect on the unreproducible one: cannot collect hashes from unreproducible machines
    run(1e6): reproducible mcycle=6 root=ae5bce11a60d31de ; unreproducible mcycle=163846 root=1a627812289ef321
    BUG REPRODUCED (B): same root hash, different transition under run()
  ```
  The hunter's `hunter/r1-iunrep/run.sh` also reproduces as documented.

- **Root cause:**
  - `machine::is_unreproducible()` reads `m_c.processor.registers.iunrep` (`machine.hpp:818`). The doc comment says it is "determined at construction from the config, never changes at runtime". This was the deliberate fix of an earlier fuzzer bug (`tests/lua/spec-fuzzer-bugs.lua:297-323`, "Bug 5").
  - However, the shadow `iunrep`, which is what the Merkle root commits to, stays freely writable:
    - through `write_reg(reg::iunrep)` (`machine.cpp:1332-1334`), unlike `mvendorid`/`marchid`/`mimpid`/`x0`, which throw "register is read-only";
    - through the full-shadow `write_memory` memcpy (`machine.cpp:1734-1745`).
  - `validate_processor_shadow` enforces shadow == config (`machine.cpp:213-216`), but it only runs at construction and load. `store()` checks only the config (`:400`).
  - The result:
    - a snapshot that `store` accepts and `load` always rejects;
    - an unreproducible machine whose root hash is byte-identical to a reproducible one.

- **Severity: Low** (agree).
  - It needs host-side writes, and the guest cannot reach it.
  - (A) is the most concrete effect: silent creation of an unloadable directory, through a documented snapshot technique. The data is still on disk, but no API loads it.
  - (B) matters only to someone who trusts a root hash of an unreproducible machine. Nobody should, and none of the guarded paths will compute one for it.

- **Fix assessment:** the hunter's items 1-3 are correct.
  1. Make `iunrep` read-only in `write_reg`.
  2. Validate the incoming buffer in the full-shadow `write_memory` with the same checks as `validate_processor_shadow` (iunrep, x0, mimpid, padding).
  3. Call those checks in `store()`.

  They change no hash of a legitimately created machine. The existing fuzzer test "Bug 5" calls `write_reg("iunrep", 1)` and expects success; with fix 1 it would need updating, since the call would then throw. Item 4 ("fail closed" OR of both values) is not needed once 1-3 are in place.

---

### REPRO-4: unreproducible WFI fast-forward lands one cycle past its deadline
- **Verdict: CONFIRMED.** The hunter under-reported one consequence, described below.

- **Independent reproducer:** `<SCRATCH>/verify/verify-repro/repro4/run.sh` (exit 1). It uses a Lua-only guest `wfi; j -4`, with mtvec, mie, mstatus and mtimecmp programmed from the host.
  ```
  == (a) run(N) on a WFI loop, timer far away
    unreproducible run(1024): break=5 mcycle=1025 ; second run(1024): mcycle is past
    BUG REPRODUCED (a): run() ended past mcycle_end
  == (b) timer deadline on an RTC tick while the hart sleeps in WFI
    iunrep=0: halted=1, timer handler entered at mcycle 245760 (deadline 245760)
    iunrep=1: halted=1, timer handler entered at mcycle 253952 (deadline 245760)
    BUG REPRODUCED (b): unreproducible WFI wake-up delivered the timer 8192 cycles late
  ```
  The hunter's `hunter/r4-wfi-overshoot/run.sh` also reproduces as documented.
  - **Additional finding.** With the ASan/UBSan build (`<SCRATCH>/asan`, where `interpret.cpp` keeps its asserts) the same guest aborts the process:
    ```
    interpret.cpp:6411: ... interpret(...): Assertion `a.read_mcycle() == effective_mcycle_end' failed.   (exit 134)
    ```
    That is exactly the assertion the earlier "fuzzer Bug 5" fix was meant to make unreachable ("WFI clamps mcycle_max to mcycle_end"). The fix is off by one.
    - The regression test does not catch it. It now sets only the shadow `iunrep`, so it never runs the unreproducible path.
    - It uses `run(4)`, where `timeout_us = 0` and nothing is advanced.
    - The reproducer also shows up in (A') of REPRO-2: `a0(mcycle after wfi)=81921` = 10·8192 + 1.

- **Root cause:**
  - `machine::poll_external_interrupts` (`machine.cpp:2257-2261`) returns `mcycle = min(max(next, mcycle), mcycle_max)`, where `mcycle_max = min(rtc_time_to_cycle(mtimecmp), mcycle_end)` (`interpret.cpp:2833`).
  - `interpret_loop` then still executes `++mcycle` for the WFI itself (`interpret.cpp:6321-6338`), so the WFI retires at `mcycle_max + 1`.
  - Consequences:
    - (a) `run(N)` returns `mcycle = N+1` with `reached_target_mcycle`. The `assert` in `interpret()` is compiled out only in the default build.
    - (b) When the deadline is the timer, `mcycle` skips the tick `mtimecmp·8192`. `set_rtc_interrupt` runs only on ticks (`interpret.cpp:5766`), so MTIP is raised one RTC period late. At 128 MHz that is 8192 cycles, about 64 µs.

- **Severity: Low** (agree).
  - It affects unreproducible machines only, where timing is host-driven by design.
  - Effects:
    - a host-loop contract violation: "mcycle is past" on a repeated `run(N)`;
    - about 64 µs of extra timer latency per idle wake-up;
    - an abort in assert-enabled builds (debug/sanitize/fuzz), which are not the packaged build.
  - Reproducible machines never call into this code: `poll_external_interrupts` is gated by `is_unreproducible()`.

- **Fix assessment:** the hunter's fix is correct.
  - Clamp to `mcycle_max - 1`: `mcycle = std::min(std::max(next_mcycle, mcycle), mcycle_max - 1);`. The guard `mcycle_max > mcycle` in `execute_WFI` holds, and the advance only happens when `timeout_us > 0`, i.e. `mcycle_max - mcycle >= 128`, so `mcycle_max - 1 >= mcycle`.
  - The loop's `++mcycle` then lands exactly on `mcycle_max`. That satisfies `mcycle_end` and makes the next outer iteration see the tick.
  - It has no effect on reproducible machines, hashes or the on-chain verifier.
  - Suggestion: also make the Bug 5 regression test use a genuinely unreproducible machine (`iunrep=1` in config) and a target of at least 128 cycles. Otherwise it keeps passing vacuously.
  - **Fix validation:** `fixbuild/src` with the clamp changed to `mcycle_max - 1` (on top of the REPRO-2 guard). Running `CARTESI_SRC=<SCRATCH>/verify/verify-repro/fixbuild/src sh repro4/run.sh` exits 0:
    ```
    unreproducible run(1024): break=5 mcycle=1024 ; second run(1024): ok
    unreproducible run(4096): break=5 mcycle=4096 ; second run(4096): ok
    unreproducible run(128000): break=5 mcycle=128000 ; second run(128000): ok
    iunrep=0: timer handler entered at mcycle 245760 (deadline 245760)
    iunrep=1: timer handler entered at mcycle 245760 (deadline 245760)
    OK
    ```

---

### REPRO-3 (brief, supporting evidence for interp-priv-1)
- **Verdict: CONFIRMED** as stated.
  - `hunter/r3-console-cfg/run.sh` reproduces. All runs start from the same initial root `70fe91da…`. Changing only the runtime config gives:
    - `to_null`: exit 2041 / mcycle 8195;
    - default stdout/every_line and the `to_buffer` modes: exit 1 / mcycle 34;
    - `soft_yield`: mcycle 35.
  - `cm_collect_mcycle_root_hashes` likewise returns different hashes for `to_null` and for the default runtime.
- The precondition is the same as interp-priv-1: partial `mideleg` with an M-destined interrupt left pending. The repo already carries `tests/bugs/interrupt-priority-chunking`.
- The new information is that runtime options which legitimately differ between nodes act as the re-entry trigger, so the earlier "chunking" framing undersells how likely the divergence is.
- No separate severity: it follows interp-priv-1, and the fix is interp-priv-1's.

---

### ROLLUP-FLOW-2: `--revert-mode=none` aborts at the first rejected advance-state input
- **Verdict: REFUTED.** The behaviour is intended, documented and tested.
- Check: `<SCRATCH>/verify/verify-repro/rollupflow2/check.sh` (exit 0 = behaves as documented):
  ```
  == cartesi-machine --help, revert-mode=none:
      none disables snapshots. inspect states are not reverted. a rejected
      advance cannot be reverted and aborts the run.
  == run with input 1 rejected: exit status 1
  lua5.4: .../cartesi-machine.lua:3969: rollback did not restore the input boundary
  ```
  The hunter's `poc-cli-norevert.sh` shows the same abort.
- Why it is not a defect:
  - The CLI help (`src/cartesi-machine.lua:158-162`) says "a rejected advance cannot be reverted and aborts the run. DON'T USE revert-mode=none IN PRODUCTION".
  - The upstream test `tests/lua/spec-cm-cli.lua:3130-3165`, "plain run without reverts aborts at the first rejected input", asserts exactly this error message, with and without a following input. Its rationale: "instead of delivering later inputs to a machine stuck at the rejected yield".
  - The README sentence the hunter cited ("never reverts rejected inputs", `doc/README.md:2482`) is consistent with that, if terse.
  - At most there is a UX point: an assertion traceback instead of a friendly message. That is out of scope.
- Severity: none.
