#!/bin/sh
# cartesi.evmu.decode_calldata rejects valid calldata with an empty dynamic array of dynamic elements (bytes[], string[], tuple[]) as "calldata too long"
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
[ -f "$SRC_DIR/cartesi/evmu.lua" ] || skip "missing $SRC_DIR/cartesi/evmu.lua"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/cartesi/evmu.lua decode_array: in the dynamic-element branch, last_offset is only set inside the element loop,
# so an empty array returns nil as its end offset and decode_calldata's final assert(offset == #calldata_raw) fails.
rc=0
out="$(cd "$WORK_DIR" && timeout 30 "$LUA" "$TEST_DIR/evmu.lua" 2>&1)" || rc=$?
echo "$out"
case $rc in
    0) echo "$out" | grep -q "^OK:" && exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "ERROR: evmu.lua failed (exit $rc)"
exit 2
