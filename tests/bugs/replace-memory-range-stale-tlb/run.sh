#!/bin/sh
# cm_replace_memory_range() after cm_run() leaves stale host pointers in the hot TLB (silent divergence or crash)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
result=0
for mode in divergence crash; do
    rc=0
    timeout 60 "$WORK_DIR/repro" "$mode" "$WORK_DIR" || rc=$?
    case $rc in
        0) ;;
        1) result=1 ;;
        *) echo "test error in mode $mode (exit $rc)"; exit "$rc" ;;
    esac
done
exit $result
