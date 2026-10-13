#!/bin/sh
# A uarch store to the uarch_x0 shadow word (0x400018) is refused by the host ("register is read-only") but accepted by cm_verify_step_uarch, whose post-state then has x0 != 0
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c x0store "$TEST_DIR/x0store.c" || build_failed x0store
set +e
# x0store.c builds the step log from cm_get_proof of the official pre-state (no modified library), checks the log
# construction against two host-logged controls, then compares host and verifier on the x0 store.
rc=0
timeout 60 "$WORK_DIR/x0store" "$WORK_DIR" || rc=$?
case $rc in
    0|1) exit $rc;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
