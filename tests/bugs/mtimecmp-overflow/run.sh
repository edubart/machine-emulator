#!/bin/sh
# mtimecmp is compared as mtimecmp*8192 with 64-bit wrap-around, so a far-future mtimecmp raises a timer interrupt
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv prog.bin "$TEST_DIR/prog.S"
out="$(timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/prog.bin")" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "$out"
echo "(a0 = mcause, a1 = mtime when the interrupt was taken or at the end of the loop)"
code="$(echo "$out" | sed -n 's/^exit=\([0-9]*\).*/\1/p')"
case "$code" in
1)
    echo "BUG REPRODUCED: machine timer interrupt taken although mtimecmp=2^61+3 is far in the future"
    exit 1
    ;;
0)
    echo "OK: no timer interrupt before mtime reaches mtimecmp"
    exit 0
    ;;
*)
    echo "ERROR: unexpected exit code '$code'"
    exit 2
    ;;
esac
