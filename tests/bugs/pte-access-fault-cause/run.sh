#!/bin/sh
# PTE accesses that violate a PMA raise page faults instead of access faults; A/D write-back to a read-only PTE is silently skipped
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv prog.bin "$TEST_DIR/pte_fault.S"
out="$(timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/prog.bin" "$WORK_DIR/flash.bin")" ||
    { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "$out"
echo "(spec-expected mcauses: load 5, store 7, fetch 1 via the CLINT PTE; load 5, store 7 via the read-only PTE with A=D=0)"
code="$(echo "$out" | sed -n 's/^exit=\([0-9]*\).*/\1/p')"
[ -n "$code" ] || { echo "ERROR: no exit code"; exit 2; }
if [ $((code & ~31)) -ne 0 ]; then echo "ERROR: unexpected exit code $code"; exit 2; fi
# Half 1: page-table walk reads a PTE from device memory (PMA violation)
[ $((code & 7)) -ne 0 ] &&
    echo "half 1: PTE read from device memory (CLINT) raised a page fault instead of an access fault (mask=$((code & 7)): 1 load, 2 store, 4 fetch)"
# Half 2: A/D update needs a store to a PTE in read-only memory
[ $((code & 24)) -ne 0 ] &&
    echo "half 2: access needing an A/D update of a PTE in read-only flash did not raise an access fault (mask=$((code & 24)): 8 load, 16 store)"
if [ "$code" -ne 0 ]; then
    echo "BUG REPRODUCED: wrong exception for page-table accesses that violate a PMA (mask=$code)"
    exit 1
fi
echo "OK: PMA violations during page-table walks and A/D updates raise access faults"
exit 0
