# Angle `diff-fuzz`: large-scale differential testing of execution paths

Status: INCOMPLETE. No fuzzing campaign was executed.

## What happened
- Early in the session, every Bash call started being refused by the session's permission layer ("auto mode could not evaluate this action"). This happened even for trivial commands such as `uptime`, and the refusal said it would persist for the rest of the conversation. Read, Write, Edit and Grep still worked.
- So nothing could be compiled or run. There are no measured results and no PROVEN or UNPROVEN findings from this angle.
- One measurement was taken before the block. The existing harness `work/uarch/difftest` (`BIG=1`, full per-cycle memory compare) took 7m48s wall time and 91 s CPU for 2000 mcycles on `work/uarch/fuzz/p201`, at load average about 50. The result was `OK mcycle=2000 max_uarch_cycles=3395`. Any long campaign needs a much cheaper per-cycle check: hash-only comparison against a reference trace, as `dfz.c` below does.

## Deliverable prepared (not compiled, not run)
`<SCRATCH>/work/diff-fuzz/dfz.c` is a single-program differential harness built on the C API. It runs one bare-metal RAM image through these paths and compares each against a per-mcycle reference hash trace:
- **R** (reference): `cm_run(mcycle+1)` per cycle, root hash recorded at every mcycle.
- **A**: one `cm_run(F)`, resumed only across automatic yields, soft yields and console breaks.
- **A2**: the same as A, with `soft_yield=true` and console `to_buffer` (more breaks).
- **B**: random chunking in five distributions: tiny, small, medium with bursts, RTC-tick-aligned ±2, and large.
- **C**: uarch big-steps (`cm_run_uarch(UINT64_MAX)` + `cm_reset_uarch`). Every `UALOG` mcycles it also runs `cm_log_step_uarch`/`cm_verify_step_uarch` and `cm_log_reset_uarch`/`cm_verify_reset_uarch`.
- **D**: chained `cm_log_step(k)` + `cm_verify_step` for random k. When a step stops early at an automatic yield, the check uses the mcycle actually reached, so it does not re-report the known ROLLUP-FLOW-1.
- **E**: `cm_collect_mcycle_root_hashes` with random period and phase, split into random calls. The rx-rejected fixed point is handled.
- **S**: `cm_store`/`cm_load_new` at a random mcycle, then the run continues.

On a mismatch it prints the first diverging mcycle, a register diff and a RAM diff against a freshly built reference.
- Build: `gcc -O2 -g -I/home/user/machine-emulator/src dfz.c -o dfz -L/home/user/machine-emulator/src -lcartesi -Wl,-rpath,/home/user/machine-emulator/src`
- Run: `./dfz prog.bin N [seed]`

Suggested triage for the known interrupt-priority class (interp-priv-1): re-run any divergence with `LD_LIBRARY_PATH=<SCRATCH>/work/interp-priv/build/src`. That library contains the fast-path fix but its uarch image is unchanged. A divergence that disappears with it is interp-priv-1.

The system-level program generator (M-mode trap handlers, random legal delegation, timers, paging, FP, AMO, HTIF) and the Linux-window driver were designed but not written, because they could not be tested.

## Source review notes (no new defect identified)
These checks were done while preparing the harness. They are not proofs.
- Every CSR write that can enable or raise an interrupt returns `success_and_serve_interrupts`. So do CLINT msip writes and PLIC complete-with-pending. Store, AMO, SC and FP-store paths propagate device status. This agrees with interp-priv and step-proof R-5.
- Device reads of mtime use the interpreter-local mcycle. Interpreter code does not read `pc` or `mcycle` from state inside the loop.
- The fetch cache is invalidated on every status above `success`. This covers the satp mode/ASID changes and SFENCE.VMA that return `success_and_flush_fetch`.
- In `collect_mcycle_hashes_state_access`, dirty tracking covers memory-word writes (including PTE A/D updates), TLB slot writes and all shadow register/TLB pages (marked on every `write_mcycle`). Write-TLB evictions are marked by the machine itself.

## Negative results
- Programs and cycles compared by this angle: **0**. The campaign was not run.

## Recommendation to the coordinator
Re-launch this angle in a session where Bash works. `dfz.c` is ready to compile.
