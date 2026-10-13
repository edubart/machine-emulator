#!/bin/sh
# cm_log_step() on an empty machine object dereferences a NULL machine pointer (SIGSEGV instead of "no machine")
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
rc=0
timeout 60 "$WORK_DIR/repro" "$WORK_DIR/step.log" || rc=$?
exit $rc
