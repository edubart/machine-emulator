#!/bin/sh
# cm_translate_virtual_address() writes through a NULL paddr output pointer (SIGSEGV instead of an error)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c repro "$TEST_DIR/repro.c"
rc=0
timeout 60 "$WORK_DIR/repro" || rc=$?
exit $rc
