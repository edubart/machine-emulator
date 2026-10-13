#!/bin/sh
# cm_log_step/cm_get_node_hash abort on hash-tree nodes in the power-of-two padding of a non-power-of-two memory range
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c padding "$TEST_DIR/padding.c" || { echo "ERROR: build failed"; exit 2; }

rc=0
timeout 120 "$WORK_DIR/padding" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: cm_log_step over the last page of a 3-page flash drive verifies and matches cm_run, and padding node hashes are pristine"; exit 0;;
    1) echo "BUG REPRODUCED: cm_log_step/cm_get_node_hash fail (abort in assert-enabled builds) on hash-tree nodes in the power-of-two padding of a non-power-of-two flash drive"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
