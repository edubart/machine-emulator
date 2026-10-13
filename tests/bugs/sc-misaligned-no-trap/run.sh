#!/bin/sh
# Misaligned SC.W/SC.D does not raise an address-misaligned (or access-fault) exception and returns rd=1
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv prog.bin "$TEST_DIR/prog.S"
out="$(timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/prog.bin")" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "$out"
echo "(a1 = traps taken, expected 4; a2 = last mcause)"
code="$(echo "$out" | sed -n 's/^exit=\([0-9]*\).*/\1/p')"
[ -n "$code" ] || { echo "ERROR: no exit code"; exit 2; }
if [ $((code & ~7)) -ne 0 ]; then echo "ERROR: control (misaligned lr.w traps) failed or unexpected exit code $code"; exit 2; fi
[ $((code & 1)) -ne 0 ] && echo "sc.w at buf+1 without reservation did not trap"
[ $((code & 2)) -ne 0 ] && echo "sc.d at buf+4 after lr.d on buf did not trap"
[ $((code & 4)) -ne 0 ] && echo "sc.d at buf+6 without reservation did not trap"
if [ "$code" -ne 0 ]; then
    echo "BUG REPRODUCED: misaligned SC did not raise an exception (mask=$code)"
    exit 1
fi
echo "OK: every misaligned SC traps"
exit 0
