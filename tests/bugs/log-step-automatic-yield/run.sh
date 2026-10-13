#!/bin/sh
# cm_log_step(N)/cm_verify_step(N) stop at an automatic yield inside the step while the log claims N mcycles
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
build_rv prog.bin "$TEST_DIR/prog.S" || { echo "ERROR: build failed"; exit 2; }
build_c autoyield "$TEST_DIR/autoyield.c" || { echo "ERROR: build failed"; exit 2; }

rc=0
timeout 120 "$WORK_DIR/autoyield" "$WORK_DIR/prog.bin" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: a 64-mcycle cm_log_step/cm_verify_step across an automatic yield agrees with cm_run and the uarch"; exit 0;;
    1) echo "BUG REPRODUCED: cm_log_step(64)/cm_verify_step(64) stop at the automatic yield: the verified 64-mcycle transition ends in the state at the yield, not the state after 64 mcycles computed by cm_run and the uarch"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
