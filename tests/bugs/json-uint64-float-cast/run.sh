#!/bin/sh
# JSON uint64 fields equal to 2^64 pass the range check and reach an out-of-range double-to-uint64 cast (accepted as 0 on x86-64)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
# src/json-util.cpp ju_get_opt_field(..., uint64_t &) checks `f > static_cast<double>(UINT64_MAX)`, and that bound
# is exactly 2^64, so a config value of 2^64 (or 18446744073709552000, which is how JavaScript writes 2^64-1) is
# accepted and converted with undefined behaviour. The int64 overload has the same flaw at 2^63.
# uint64-range.c creates a machine through cm_create_new with mcycle set to such values; they must be rejected.
build_c uint64-range "$TEST_DIR/uint64-range.c"
rc=0
"$WORK_DIR/uint64-range" || rc=$?
case $rc in
    0) echo "OK: cm_create_new rejects out-of-range uint64 values"; exit 0;;
    1) echo "BUG REPRODUCED: cm_create_new accepts a uint64 config value of 2^64"; exit 1;;
    *) echo "uint64-range failed (exit code $rc)"; exit 2;;
esac
