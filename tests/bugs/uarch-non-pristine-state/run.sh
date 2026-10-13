#!/bin/sh
# Machines with non-pristine uarch state (registers or RAM) are accepted and cm_run diverges from the uarch big step
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c non-pristine "$TEST_DIR/non-pristine.c"

rc=0
timeout 120 "$WORK_DIR/non-pristine" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: machines with non-pristine uarch state are rejected or execute consistently on all paths"; exit 0;;
    1) echo "BUG REPRODUCED: machines with non-pristine uarch state (uarch_cycle == 0) are accepted, and cm_run/cm_log_step/cm_collect_mcycle_root_hashes disagree with the uarch big step"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
