# Angle `diff-fuzz2`: differential testing of execution paths (status: INCOMPLETE)

## Summary
- New findings: none.
- Programs compared: 1 (existing `work/uarch/fuzz/p201.bin`). Cycles compared: 3000 mcycles. Paths: R, A, A2, B x5, C, D x3, E x3. Result: no divergence.
- The system-level program generator was not finished. My session was stopped while I was writing it, so no campaign ran.

## Harness status
- `<SCRATCH>/work/diff-fuzz2/dfz.c` is a copy of `work/diff-fuzz/dfz.c`. It now compiles and runs. Fixes so far:
  - `realpath()` needs a PATH_MAX buffer. The old 1024-byte buffer aborted with a fortify "buffer overflow detected" error.
  - Still open: path S calls `cm_store(..., CM_SHARING_NONE)`, which fails with "attempt to rollback unbacked address range". It must use `CM_SHARING_ALL` to store the current state.
- Build: `gcc -O2 -g -I/home/user/machine-emulator/src dfz.c -o dfz -L/home/user/machine-emulator/src -lcartesi -Wl,-rpath,/home/user/machine-emulator/src`. The binary uses RUNPATH, so `LD_LIBRARY_PATH=<SCRATCH>/work/interp-priv/build/src` overrides the library for interp-priv-1 triage.
- `<SCRATCH>/work/diff-fuzz2/gen2.py` is an incomplete partial file. It does not run. Do not use it.

## Performance finding (important for any later campaign)
- On this loaded host (load average 35-65 on 4 cores), the default OpenMP settings make each `cm_get_root_hash` very slow. The gdb backtrace shows the time going to libgomp barriers in `hash_tree::return_updated_dirty_pages`.
- The same 3000-mcycle dfz run was killed after more than 10 min wall time (2m24s CPU). With `OMP_NUM_THREADS=1` it finished in 8 s wall (1.7 s user).
- Always run differential campaigns with `OMP_NUM_THREADS=1`. The concurrency angle already showed that hashes do not depend on the thread count.
