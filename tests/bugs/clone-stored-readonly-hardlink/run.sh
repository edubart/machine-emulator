#!/bin/sh
# cm_clone_stored hard-links the writable-range files of a read-only stored machine, so running the clone (SHARING_ALL) modifies the source
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c" || build_failed repro
rc=0
timeout 60 "$WORK_DIR/repro" "$WORK_DIR" || rc=$?
exit $rc
