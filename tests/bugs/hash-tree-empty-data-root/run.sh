#!/bin/sh
# cartesi.hash-tree get_data_root_hash("", log2_size) returns nil instead of the pristine root, so verify_splice of an empty (all-zero) output raises
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
[ -f "$SRC_DIR/cartesi/hash-tree.lua" ] || skip "missing $SRC_DIR/cartesi/hash-tree.lua"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/cartesi/hash-tree.lua get_data_root_hash: with empty data there are no leaves, the pairing loop creates no
# parents, and it returns level[1] == nil. empty.lua compares against get_proof() of an all-zero NVRAM and runs the
# doc/recipes/slice-calculator-output.lua flow (string.unpack("z", nvram) -> "" -> verify_splice).
set +e
rc=0
timeout 60 "$LUA" "$TEST_DIR/empty.lua" || rc=$?
case $rc in
    0|1) exit $rc;;
    *) echo "ERROR: empty.lua failed (exit $rc)"; exit 2;;
esac
