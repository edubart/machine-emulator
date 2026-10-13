#!/bin/sh
# Data TLB not flushed when MPRV's effective privilege changes through an M->M trap or an M->M MRET
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv prog.bin "$TEST_DIR/prog.S"
out="$(timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/prog.bin")" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "$out"
code="$(echo "$out" | sed -n 's/^exit=\([0-9]*\).*/\1/p')"
[ -n "$code" ] || { echo "ERROR: no exit code"; exit 2; }
[ $((code & 1)) -ne 0 ] && echo "case 1: M->M trap with MPRV=1 (MPP=M): handler load used the stale S-mode translation instead of physical memory"
[ $((code & 2)) -ne 0 ] && echo "case 2: M->M MRET with MPRV=1 (MPP=U): effective-U load of an S-only page did not fault (stale effective-M TLB entry)"
if [ $((code & ~3)) -ne 0 ]; then echo "ERROR: unexpected exit code $code"; exit 2; fi
if [ "$code" -ne 0 ]; then
    echo "BUG REPRODUCED: data TLB keeps entries of the previous effective privilege after an MPRV privilege change (mask=$code)"
    exit 1
fi
echo "OK: loads use the new effective privilege after M->M trap and M->M MRET with MPRV=1"
exit 0
