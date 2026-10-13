#!/bin/sh
# cm_create()/cm_load() on a non-empty machine object leak the previous machine instance (fds, mappings, file locks)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
rc=0
timeout 60 "$WORK_DIR/repro" "$WORK_DIR" || rc=$?
exit $rc
