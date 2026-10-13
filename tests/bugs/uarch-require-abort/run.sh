#!/bin/sh
# A misaligned uarch fetch aborts the process (uarch require() is assert()) instead of returning an error
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c misaligned "$TEST_DIR/misaligned.c" || { echo "ERROR: build failed"; exit 2; }

rc=0
timeout 120 "$WORK_DIR/misaligned" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: cm_run_uarch, cm_log_step_uarch and cm_verify_step_uarch reject a misaligned uarch fetch with an error"; exit 0;;
    1) echo "BUG REPRODUCED: a misaligned uarch instruction fetch (reached by a custom uarch RAM image, or by a step log checked with static cm_verify_step_uarch) aborts the process (or is accepted) instead of returning an error"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
