#!/bin/sh
# cm_read/write_virtual_memory() silently do nothing for ranges ending in the top page of the address space
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
rc=0
timeout 60 "$WORK_DIR/repro" || rc=$?
exit $rc
