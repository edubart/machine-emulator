#!/bin/sh
# A process killed during the hash-tree update of a sharing:all stored machine leaves the directory with a permanently wrong root hash or an unusable page hash-tree cache ("already borrowed")
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c" || build_failed repro
# repro.c kills a child process at random points of cm_get_root_hash() (bounded: at most 8 kills, ~40 s budget)
# and exits 77 when too few kills landed during the update.
rc=0
timeout 170 "$WORK_DIR/repro" "$WORK_DIR" || rc=$?
case $rc in
    0 | 1 | 77) exit $rc ;;
    124) echo "test error: timed out" ;;
    *) echo "test error (exit $rc)" ;;
esac
exit 2
