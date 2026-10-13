#!/bin/sh
# Interrupt selection ignores mideleg, so a leftover M-destined interrupt makes cm_run results depend on chunking and diverge from uarch
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
build_rv prog.bin "$TEST_DIR/prog.S"
build_c repro "$TEST_DIR/repro.c"
# Same target mcycle through: one cm_run(N), N x cm_run(mcycle+1), N x uarch big-step, cm_run in chunks of 7.
rc=0
timeout 150 "$WORK_DIR/repro" "$WORK_DIR/prog.bin" 1024 || rc=$?
case $rc in
0 | 1) exit $rc ;;
*) echo "ERROR: reproducer failed (rc=$rc)"; exit 2 ;;
esac
