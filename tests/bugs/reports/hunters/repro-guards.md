# Angle `repro-guards`: reproducibility guards and runtime-config independence

Scope:
- the `iunrep` (unreproducible) flag: where it lives and who checks it;
- the guards on proof-related entry points;
- runtime options (console in/out, soft_yield, concurrency, skip_version_check, buffers) versus the hashed state transition;
- the host-time polling in `machine::poll_external_interrupts`;
- HTIF/VirtIO console paths.

Sources read: `machine.cpp`, `machine.hpp`, `interpret.cpp`, `cm.cpp`, `machine-console.cpp`, `machine-runtime-config.hpp`, `machine-address-ranges.cpp`, `device-state-access.hpp`, `record/replay-step-state-access.hpp`, `mock-address-range.hpp`, `virtio-address-range.cpp`, `htif-address-range.cpp`, `cartesi-machine.lua`.

Work dir: `<SCRATCH>/work/repro-guards/`, where `<SCRATCH>` = `<SCRATCH>`. Every PoC is a `run.sh` that prints `BUG REPRODUCED` and exits 1 while the defect is present.

## Summary

| ID | Title | Status | Severity |
|---|---|---|---|
| REPRO-1 | Two sources of truth for `iunrep`. Guards and the interpreter use the config value (`m_c`). The root hash commits to the shadow register, which `cm_write_reg(IUNREP)` changes freely. Effects: an unreproducible machine hashes as reproducible, and `cm_store` writes a snapshot that `cm_load` rejects | PROVEN | Low (Medium if host tooling copies register sets) |
| REPRO-2 | `cm_log_step` (and CLI `--log-step`) has no reproducibility guard, unlike `log_step_uarch`, `run_uarch` and `collect_*`. On unreproducible machines it (A) produces logs that `cm_verify_step` accepts for transitions `cm_run` does not perform; (B) with VirtIO, runs the whole step on the real machine and then fails; (C) **aborts the host process** (library user, JSON-RPC server, CLI) as soon as the step contains a VirtIO queue notify | PROVEN | Medium |
| REPRO-3 | New evidence for interp-priv-1: runtime config alone changes the state that `cm_run` reaches and the hashes `cm_collect_mcycle_root_hashes` returns. This covers console output destination/flush mode, soft_yield, and the default runtime vs `to_null` | PROVEN (dup of interp-priv-1, new evidence) | per interp-priv-1 |
| REPRO-4 | Unreproducible WFI fast-forward overshoots `mcycle_end` by 1 (`cm_run(N)` returns mcycle N+1, a follow-up `cm_run(N)` throws "mcycle is past"), and it skips the RTC tick, so the timer IRQ arrives 8192 cycles late | PROVEN | Low |

Already reported by others, not repeated: DEVICES2-1 (`cm_write_reg(htif_iconsole)` / `cm_set_runtime_config(input_source)` enable getchar on a reproducible machine), cli-lua-2 (`--load-config` drops `iunrep`), the rollup-flow note on `--assert-rolling-template` not checking `iunrep`, and STEP-PROOF-1 (log_step aborts on the tail of a non-pow2 flash; I hit it when logging a Linux window at 30M).

### Guard table (measured, `work/repro-guards/guard-table.lua`, machine with `iunrep=1`)
```
run                                ACCEPTED
log_step                           ACCEPTED              <-- REPRO-2
log_step_uarch                     refused: microarchitecture cannot be used with unreproducible machines
run_uarch                          refused: microarchitecture cannot be used with unreproducible machines
log_reset_uarch                    ACCEPTED
reset_uarch                        ACCEPTED
collect_mcycle_root_hashes         refused: cannot collect hashes from unreproducible machines
collect_uarch_cycle_root_hashes    refused: cannot collect hashes from unreproducible machines
log_send_cmio_response             ACCEPTED
send_cmio_response                 ACCEPTED
get_proof                          ACCEPTED
get_root_hash                      ACCEPTED
store                              refused: cannot store unreproducible machines
```
`collect_mcycle_bundle` and `collect_uarch_cycle_bundle` also refuse, through the same checks (`machine.cpp:2489`, `2635`). `verify_step`, `verify_step_uarch`, `verify_reset_uarch` and `verify_send_cmio_response` are static, so a guard is impossible there. All guards read `machine::is_unreproducible()` = `m_c.processor.registers.iunrep != 0` (`machine.hpp:818`), never the hashed shadow register. In the CLI, `--log-step` is the only proof/hash option without an `iunrep == 0` assert. `--log-step-uarch`, `--final-hash`, the proofs and the hash collection all assert.

---

### REPRO-1: `iunrep` has two sources of truth; `cm_write_reg(CM_REG_IUNREP)` desynchronizes the hashed flag from the one every guard uses
- Status: PROVEN
- Area: C API / store-load / hash-tree semantics
- Category: proof-soundness (state misrepresents reproducibility), data-loss (unloadable snapshot)
- Where:
  - `src/machine.hpp:818-820` `is_unreproducible()` reads `m_c` (config).
  - `src/machine.cpp:1332-1334` `write_reg(reg::iunrep)` writes only the shadow. It is not read-only, unlike `mvendorid`/`marchid`/`mimpid` (`machine.cpp:1242-1247`).
  - `src/machine.cpp:1734-1745`: the full-shadow `write_memory` "manual snapshot" path overwrites `iunrep` (and `iconsole`) without any validation.
  - `src/machine.cpp:213-216` `validate_processor_shadow` enforces shadow==config, but only in the constructor/loader.
  - `src/machine.cpp:395-401` `store()` checks only `m_c`. The interpreter never reads the shadow `iunrep` (no `read_iunrep` use in `interpret.cpp`).
- Problem:
  - The root hash commits to `shadow.registers.iunrep`. The behaviour (WFI host-time fast-forward, console polling) and all guards (store, uarch, collect) use the config copy.
  - `cm_write_reg(CM_REG_IUNREP, v)`, a JSON-RPC `write_reg`, or a full-shadow `cm_write_memory(0, …, 0x8000)` changes only the shadow:
    - Reproducible machine with shadow `iunrep` set to 1: collect is still allowed, and so is `cm_store`. The stored directory has config `iunrep=0` and shadow `iunrep=1`, so every later `cm_load` fails with "iunrep mismatch between shadow state and config".
    - Unreproducible machine with shadow `iunrep` set to 0: its root hash becomes byte-identical to the reproducible machine with the same content, yet `cm_run` still fast-forwards WFIs with host time. Two machines with the same root hash then perform different transitions under the same call, and `cm_log_step` proves a third behaviour.
- Scenario:
  - Host tooling or a JSON-RPC client copies a register set or a shadow snapshot between machines, since `iunrep` is listed among the ordinary writable registers.
  - It ends up either with a snapshot that `cm_store` accepted but nobody can load, or with an unreproducible machine whose root hash claims reproducibility. Hashes computed from it with `cm_run` + `cm_get_root_hash` are host-time dependent.
  - Guest code cannot reach this.
- Evidence: `sh <SCRATCH>/work/repro-guards/r1-iunrep/run.sh` (exit 1):
  ```
  == Part A: reproducible machine, cm_write_reg(IUNREP, 1)
  cm_write_reg(IUNREP,1): accepted; read back iunrep=1
  root hash before=a1ef021681299ab8 after=0297193fb70abe49 ; cm_get_initial_config: "iunrep":0,"
  cm_collect_mcycle_root_hashes on state with iunrep=1: ACCEPTED (guard reads config, not state)
  cm_store: ok
  cm_load of the stored directory: iunrep mismatch between shadow state and config
  BUG REPRODUCED (A): cm_store accepted a machine whose snapshot cm_load can never load
  == Part B: unreproducible machine, cm_write_reg(IUNREP, 0)
  root(reproducible)   = a1ef021681299ab8783dd184e8c936882275eac0054a98c762ee322b220756d8
  root(unreproducible) = 0297193fb70abe49accb5d32afde9c1f5a731c22616f22b941c1e543a95dae5d
  after cm_write_reg(IUNREP,0) on the unreproducible machine:
  root(unreproducible) = a1ef021681299ab8783dd184e8c936882275eac0054a98c762ee322b220756d8  (IDENTICAL to reproducible)
  cm_collect_mcycle_root_hashes: cannot collect hashes from unreproducible machines
  cm_store: cannot store unreproducible machines
  cm_run(2000000) reproducible  : break=1 mcycle=24       root=215d48eaf836a6ae
  cm_run(2000000) iunrep cleared: break=1 mcycle=819220   root=934f53c803be5080
  cm_log_step(2000000) on iunrep-cleared unreproducible machine: accepted break=1 mcycle=24 root=215d48eaf836a6ae
  cm_verify_step: OK, proven final root=215d48eaf836a6ae
  BUG REPRODUCED (B): two machines with the SAME root hash perform DIFFERENT transitions under cm_run; ...
  ```
  The guest arms `mtimecmp=100` and executes WFI 4 times. Under unreproducible semantics the first WFI jumps to mcycle 819200.
- Possible solution: keep one source of truth.
  1. Make `reg::iunrep` read-only on the public path. Throw in `machine::write_reg` like `marchid`, and have `init_processor` assign `m_s->shadow.registers.iunrep` directly.
  2. In the full-shadow `write_memory` special case, reject a buffer whose `iunrep` differs from the config, or whose `htif.iconsole` has the getchar bit on a reproducible machine. The simplest way is to run the `validate_processor_shadow` checks on the new buffer before the `memcpy`.
  3. Make `store()` call `validate_processor_shadow(false)` (and the `init_console` checks) before writing anything, so it can never produce an unloadable directory.
  4. Optionally define `is_unreproducible()` as `m_c.iunrep != 0 || m_s->shadow.registers.iunrep != 0` (fail closed).
- Severity: Low. It needs host-API misuse, and the guest cannot trigger it. It would be Medium if register-copy or snapshot tooling exists, since a store then succeeds silently but the snapshot is unloadable, and the root hash misstates reproducibility. This is the same class as DEVICES2-1, which was rated Low.
- Risks: unfixed, the root hash's `iunrep` bit is not a trustworthy marker. The fix changes no hash of any legitimately created machine. Clients that wrote `iunrep` themselves would get an error.

---

### REPRO-2: `cm_log_step` / `--log-step` accept unreproducible machines; the produced proofs disagree with `cm_run`, VirtIO steps run and then fail, and a VirtIO queue notify aborts the process
- Status: PROVEN
- Area: step-log / C API / JSON-RPC / CLI / devices
- Category: proof-soundness (proofs from unreproducible machines), DoS (process abort), API atomicity
- Where:
  - `src/machine.cpp:2171-2190` `machine::log_step`: no `is_unreproducible()` check. Compare `log_step_uarch` `:2079`, `run_uarch` `:2124`, `collect_*` `:2325/2489/2635`.
  - `src/record-step-state-access.hpp:250-263`: `do_read_memory`/`do_write_memory` throw.
  - `src/virtio-address-range.cpp:836` `do_write_device(...) noexcept` → `mmio_write` → `QUEUE_NOTIFY` → `on_device_queue_notify` → `virtq_get_avail_header` → `a->read_memory`, which throws through a `noexcept` frame, so `std::terminate`.
  - `src/mock-address-range.hpp:64-74`: the replay has no VirtIO mock, so it throws "unhandled mock address range". `find_pma` mocks every PMA up to the match, so any access to a VirtIO window or to an unmapped address reaches it.
  - `src/cartesi-machine.lua:4644-4649`: `--log-step` has no `iunrep == 0` assert, unlike `--log-step-uarch` (`:4675`).
  - The record accessor is non-interactive, so it never calls `poll_external_interrupts` and `getchar` returns -1.
- Problem: `cm_log_step` is the only interpreter-driven proof producer without the reproducibility guard. It has three outcomes on an unreproducible machine:
  - **(A) HTIF getchar.** The record accessor returns "no character", while `cm_run` returns the host byte (or EOT with input closed). The log is self-consistent, so `cm_verify_step` accepts a transition that differs from `cm_run`'s from the same root hash. WFI behaves the same way: the logged step is a NOP, while `cm_run` fast-forwards with host time.
  - **(B) VirtIO read.** The step executes on the real machine through all its instructions, including any device side effects. Only the post-hoc replay fails, with "unhandled mock address range". The call reports failure, but the machine has already advanced and the log file was written.
  - **(C) VirtIO write that makes the device touch guest memory** (`QUEUE_NOTIFY` on a ready queue, which every Linux VirtIO driver does). `record_step_state_access::read_memory` throws inside the `noexcept` `virtio_address_range::do_write_device`, so `std::terminate()` kills the process. That process is the embedding program, the JSON-RPC server (the client loses the machine), or `cartesi-machine`.
- Scenario:
  - A developer debugging an app runs `cartesi-machine --volume=…` (or `--network`, `-it`, `--virtio-console`) `--log-step=file,count:N`. The CLI aborts with SIGABRT, losing the session.
  - A service that exposes `log_step` over JSON-RPC for arbitrary machine configs can be crashed by a client config with any VirtIO device plus a guest that notifies a queue.
  - Separately, (A) lets tooling emit step proofs, which `cm_verify_step` and the on-chain/risc0 verifiers accept, for unreproducible machines whose real (`cm_run`) execution differs. Every other proof path refuses such machines.
- Evidence: `sh <SCRATCH>/work/repro-guards/r2-logstep/run.sh` (exit 1). The CLI variant is `sh <SCRATCH>/work/repro-guards/r2-logstep/cli/cli.sh` (~30 s).
  ```
  == getchar
  initial root: run-machine=3bde232ca1e98764 step-machine=3bde232ca1e98764 (equal)
  cm_run          : break=1 mcycle=12 exit(fromhost data)=66 root=9c4580d71c04e9f6
  cm_log_step_uarch on the same machine: microarchitecture cannot be used with unreproducible machines
  cm_log_step     : break=1 mcycle=12 exit(fromhost data)=0 root=b04ac0c17ae319d2
  cm_verify_step  : ACCEPTED, proven root after=b04ac0c17ae319d2
  BUG REPRODUCED (A): ...
  == vmagic
  cm_log_step on VirtIO machine: returned -6 (unhandled mock address range)
    before: mcycle=0 s1=0 root=617e4616238130aa
    after : mcycle=10 s1=3 iflags_H=1 root=1b509b33b688e31b
  BUG REPRODUCED (B): ...
  == vnotify
  [control] cm_run: break=1 mcycle=15 exit=3
  terminate called after throwing an instance of 'std::runtime_error'
    what():  unexpected call to record_step_state_access::read_memory
  cm_log_step process killed by signal 6 (Aborted)
  BUG REPRODUCED (C): ...
  == vnotify over JSON-RPC
  terminate called after throwing an instance of 'std::runtime_error'
    what():  unexpected call to record_step_state_access::read_memory
  log_step:  false  jsonrpc error: post error contacting 127.0.0.1:43653 (end of stream ...)
  follow-up get_root_hash: false ... (Connection refused ...)
  BUG REPRODUCED (C/jsonrpc): log_step on an unreproducible VirtIO machine killed the JSON-RPC server
  ```
  CLI (Linux, 9p volume, `--max-mcycle=40000000 --log-step=…,count:30000000`):
  ```
  40000000: 0xd970013afab7fa6271dd2c67e8871b67d6187b09403287990fa52e371be521d1
  terminate called after throwing an instance of 'std::runtime_error'
    what():  unexpected call to record_step_state_access::read_memory
  cartesi-machine exit status: 134
  BUG REPRODUCED: cartesi-machine --log-step on an unreproducible (VirtIO) machine aborted (SIGABRT)
  ```
  The printed root hash at mcycle 40000000 differs between runs: it was `0x761532…` in an earlier run. That is expected for an unreproducible machine, but the CLI prints it under `--log-step` without any warning beyond "Running in unreproducible mode!".
- Possible solution:
  - At the top of `machine::log_step`, before `get_root_hash`/`init_hot_tlb_contents`, add `if (is_unreproducible()) throw std::runtime_error{"cannot log steps of unreproducible machines"};`. Optionally add the same to `log_send_cmio_response` and `log_reset_uarch` for a uniform "no proofs from unreproducible machines" policy.
  - Add `assert(initial_config.processor.registers.iunrep == 0, ...)` for `--log-step` in `cartesi-machine.lua`.
  - Defence in depth: never let accessor exceptions cross `noexcept` device callbacks. Either make `record_step_state_access`/`collect_mcycle_hashes_state_access` `do_read_memory`/`do_write_memory` return `false` (the device then flags NEEDS_RESET deterministically), or catch in `device_state_access`.
- Severity: Medium. It is a process abort reachable from guest behaviour (any VirtIO driver) plus a supported API/CLI call. It is limited to unreproducible (dev) machines and does not affect reproducible rollup machines.
- Risks: the guard changes no hash. Users who log steps of unreproducible machines on purpose get an explicit error instead of a meaningless or crashing log.

---

### REPRO-3 (new evidence for interp-priv-1): runtime configuration changes `cm_run` results and collected hashes
- Status: PROVEN. Duplicate root cause of interp-priv-1; this adds a trigger that is not about chunking.
- Area: interpreter / runtime config / hash collection
- Category: nondeterminism (runtime options change the hashed transition)
- Where:
  - `src/interpret.cpp` interpret_loop: interrupts are re-sampled only at RTC ticks or at re-entry.
  - `src/machine.cpp:2132-2155` `interpret_with_console`: every console flush or input break re-enters `interpret()`.
  - `src/interpret.cpp:3284-3291`: the soft-yield hint breaks the loop when `runtime.soft_yield`.
  - `src/collect-mcycle-hashes-state-access.hpp:507`: `putchar` reaches the console, so collection breaks too.
- Problem: under the interp-priv-1 precondition (an enabled M-destined interrupt left pending after taking a delegated one), the state reached depends on where the host breaks the inner loop. Two things decide that:
  - `console.output_destination`/`output_flush_mode`: `to_null` never breaks, while `every_line`/`every_char`/`to_buffer` break after the putchar. This includes the **default runtime config** (`to_stdout`, `every_line`).
  - `soft_yield`.

  So two honest nodes with the same template and inputs but different console settings compute different `cm_run` states and different `cm_collect_mcycle_root_hashes` results.
- Evidence: `sh <SCRATCH>/work/repro-guards/r3-console-cfg/run.sh` (exit 1). The guest uses mideleg=SEIP with STIP pending; the S handler loops {putchar '\n'; soft-yield hint}.
  ```
  cm_run, resumed after every break until halt:
    console to_null                 initial=70fe91da6ea563bc breaks=0  exit=2041 mcycle=8195 final=0228f9b57700f972
    default runtime (stdout,line)   initial=70fe91da6ea563bc breaks=0  exit=1    mcycle=34   final=4f71f7778f3f3208
    console to_buffer every_line    initial=70fe91da6ea563bc breaks=1  exit=1    mcycle=34   final=4f71f7778f3f3208
    console to_buffer every_char    initial=70fe91da6ea563bc breaks=1  exit=1    mcycle=34   final=4f71f7778f3f3208
    console to_null + soft_yield    initial=70fe91da6ea563bc breaks=1  exit=1    mcycle=35   final=0fc30f03887358bf
  cm_collect_mcycle_root_hashes (period 2^10), resumed until halt:
    console to_null                 hashes=2  last=kVx9erHcUzXp0V8OdjqDENTF5dD+iH61VGGqdM5/FU0=
    default runtime (stdout,line)   hashes=1  last=T3H3d48/Mghhq5IVcoBWQP8PotsuY6ltf/M+pvUJ32w=
    console to_buffer every_line    hashes=1  last=T3H3d48/Mghhq5IVcoBWQP8PotsuY6ltf/M+pvUJ32w=
    console to_buffer every_char    hashes=1  last=T3H3d48/Mghhq5IVcoBWQP8PotsuY6ltf/M+pvUJ32w=
    console to_null + soft_yield    refused: cannot collect hashes when soft yield is enabled
  BUG REPRODUCED: same initial root hash, different final state/collected hashes depending only on the runtime configuration
  ```
- Possible solution: the interp-priv-1 fix (re-sample after one instruction while an enabled interrupt is pending, or priority by destination). With it, re-entry and continuation become equivalent and every runtime option is hash-neutral. My negative results below show that, without the precondition, they already are.
- Severity: as interp-priv-1 (Critical, conditional on partial interrupt delegation). It raises the practical likelihood, because console settings legitimately differ between nodes.
- Risks: see interp-priv-1.

---

### REPRO-4: unreproducible WFI fast-forward overshoots `mcycle_end` and skips the RTC tick
- Status: PROVEN
- Area: interpreter (unreproducible mode only)
- Category: API contract violation, timing
- Where: `src/machine.cpp:2261` sets `mcycle = min(max(next, mcycle), mcycle_max)`. Afterwards the interpret loop still does `++mcycle` for the WFI itself. `mcycle_max` = `min(mtimecmp*8192, mcycle_end)`, set in `execute_WFI` (`interpret.cpp:2833`).
- Problem:
  - When the sleep reaches `mcycle_max`, the WFI commits `mcycle_max + 1`. So `cm_run(N)` can return `mcycle = N+1` with break reason `reached_target_mcycle`, and the next `cm_run(N)` throws "mcycle is past". The interpret.cpp assertion `read_mcycle()==effective_mcycle_end` is compiled out.
  - When the deadline is the timer, mcycle lands on tick+1. The tick is never observed, so MTIP is raised one full RTC period (8192 cycles) late, on every idle wake-up.
- Evidence: `sh <SCRATCH>/work/repro-guards/r4-wfi-overshoot/run.sh` (exit 1):
  ```
  (a) unreproducible cm_run(1000): break=5 mcycle=1001
      follow-up cm_run(1000): mcycle is past
  BUG REPRODUCED (a): cm_run overshot mcycle_end by 1
  (b) reproducible  : timer taken at mcycle 819200 (deadline 819200)
      unreproducible: timer taken at mcycle 827392 (deadline 819200)
  BUG REPRODUCED (b): WFI fast-forward skipped the RTC tick; timer interrupt delivered 8192 cycles late
  ```
- Possible solution: clamp to `mcycle_max - 1`, i.e. `mcycle = std::min(std::max(next_mcycle, mcycle), mcycle_max - 1);`. The caller guarantees `mcycle_max > mcycle`. The loop's `++mcycle` then lands exactly on `mcycle_max`, so `mcycle_end` is respected and the tick is processed.
- Severity: Low. It affects unreproducible machines only, which have no proofs or hashes; the impact is host-loop contract and latency.
- Risks: none for reproducible machines; that code path is not executed for them.

---

## Negative results (no defect)
- **Runtime-config differential on a reproducible Linux workload** (`work/repro-guards/neg-runtime/neg.c`). Workload: 64 MiB RAM, rootfs, an echo loop, then `ls`, halting at mcycle 58914688. Six runtime configs:
  - `to_null`;
  - `to_file every_char`;
  - `to_buffer(16) every_char` (238 breaks);
  - `to_buffer(1) when_full`;
  - `to_null+soft_yield`;
  - `to_null+update_hash_tree=4`.

  Results:
  - Identical `cm_run` final root `27f0bf6d…` and mcycle in all six.
  - Identical `cm_collect_mcycle_root_hashes` (period 2^22, 15 hashes, resumed across console breaks). soft_yield is refused, as designed.
  - Byte-identical `cm_log_step` file at mcycle 5M (389536 B) and identical root afterwards.

  Without the interp-priv-1 precondition, runtime options are hash-neutral.
- **soft_yield** only affects `state_access` (interactive). Record/replay/collect/uarch ignore the hint, and every collect entry point refuses `soft_yield=true`.
- **HTIF getchar determinism.**
  - Non-interactive accessors always return -1 (fromhost 0).
  - `cm_run` returns EOT (4, fromhost 5) with input `from_null`, the next byte with `from_buffer`, and host data with stdin/fd/file.
  - That is nondeterministic by design, so it is safe only because reproducible machines cannot enable getchar at create/load (`init_console`). The runtime holes in that check are DEVICES2-1.
- **Store/load:**
  - `cm_load` validates shadow `iunrep` == config, `push_back_virtio` requires config `iunrep != 0`, and `init_console` re-checks on load.
  - `cm_create` with `dir` refuses unreproducible machines.
  - A stored machine can therefore only become inconsistent through REPRO-1 or DEVICES2-1 (both host API).
- **`verify_step` on logs that reference VirtIO PMAs** fails cleanly ("unhandled mock address range"), with no crash and no acceptance.
- **`poll_external_interrupts`** is gated by `is_unreproducible()`. For reproducible machines `cm_run` never consults host time. The RTC-tick call in `interpret_loop` ignores its return status, but that only matters in unreproducible mode.
- **`skip_version_check` / `no_reserve` / concurrency** do not affect the interpreter. `skip_version_check` is an explicit opt-in to load other-version shadows.
