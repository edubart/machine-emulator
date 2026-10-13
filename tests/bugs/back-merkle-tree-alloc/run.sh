#!/bin/sh
# back_merkle_tree allocates (log2_max_leaves+1) hashes before validating log2_max_leaves, so a previous_partial_bundle input triggers an attacker-sized allocation before being rejected
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -r /proc/self/status ] || skip "needs /proc/self/status (Linux)"
build_c repro "$TEST_DIR/repro.c" || build_failed repro
# repro measures its own peak RSS around the call; the requested allocation is bounded to 64 MiB
rc=0
timeout 60 "$WORK_DIR/repro" || rc=$?
case $rc in
    0 | 1) exit $rc ;;
    124) echo "test error: timed out" ;;
    *) echo "test error (exit $rc)" ;;
esac
exit 2
