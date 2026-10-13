#!/bin/sh
# minstret under-counts by one for every interrupt taken (interrupts increment icycleinstret)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv prog.bin "$TEST_DIR/prog.S"
out="$(timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/prog.bin")" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "$out"
lost="$(echo "$out" | sed -n 's/^exit=\([0-9]*\).*/\1/p')"
[ -n "$lost" ] || { echo "ERROR: no exit code"; exit 2; }
echo "minstret delta across 10 retired instructions and 3 interrupts: expected 10, lost $lost"
if [ "$lost" -ne 0 ]; then
    echo "BUG REPRODUCED: minstret lost $lost counts over 3 interrupts (one per interrupt)"
    exit 1
fi
echo "OK: taking interrupts does not change minstret"
exit 0
