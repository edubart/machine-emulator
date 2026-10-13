#!/bin/sh
# cm_send_cmio_response/cm_log_send_cmio_response with data == NULL fail but leave the machine partially modified
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c null-data "$TEST_DIR/null-data.c" || { echo "ERROR: build failed"; exit 2; }

rc=0
timeout 60 "$WORK_DIR/null-data" || rc=$?
case $rc in
    0) echo "OK: failed cmio response calls leave the machine unchanged"; exit 0;;
    1) echo "BUG REPRODUCED: a cmio response call with data == NULL and length > 0 failed but modified the machine (imcyclemax and the revert root hash were written before the error)"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
