#!/bin/sh
# Persisted hash-tree files miss guest-written pages (pending write-TLB dirty marks are not flushed), so reloaded machines report stale root hashes
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
rc=0
timeout 120 "$WORK_DIR/repro" "$WORK_DIR" || rc=$?
exit $rc
