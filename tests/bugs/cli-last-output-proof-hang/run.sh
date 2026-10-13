#!/bin/sh
# cartesi-machine does not validate last_output_proof: target_address = 2^64-1 makes hash_tree.frontier() loop forever
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# --cmio-advance-state=last_output_proof:<file> seeds the outputs frontier from the previous epoch's proof.
# src/cartesi-machine.lua initialize_cmio_outputs() only checks log2_root_size and log2_target_size, then calls
# hash_tree.frontier(proof). There, leaf_count = target_address + 1 wraps to 0 for target_address = 2^64-1, and
# `while (leaf_count & (1 << (level - 1))) == 0` never ends. The proof is neither range-checked nor verified.
# The control run uses a valid proof and must succeed; the same proof with target_address = 2^64-1 must be rejected
# promptly instead of hanging (or being accepted).
cd "$WORK_DIR"
"$LUA" "$TEST_DIR/gen.lua"
CM_OPTS="--no-root-flash-drive --ram-image=yield.bin --ram-length=64Ki --revert-mode=none"
rc=0
# shellcheck disable=SC2086
timeout 60 "$LUA" "$SRC_DIR/cartesi-machine.lua" $CM_OPTS \
    --cmio-advance-state=last_output_proof:valid.json,input_file_index_end:0 >valid.txt 2>&1 || rc=$?
if [ $rc -ne 0 ]; then
    cat valid.txt
    echo "control run with a valid last_output_proof failed (exit code $rc)"
    exit 2
fi
echo "valid last_output_proof (target_address 0): accepted, exit code 0"
rc=0
# shellcheck disable=SC2086
timeout 10 "$LUA" "$SRC_DIR/cartesi-machine.lua" $CM_OPTS \
    --cmio-advance-state=last_output_proof:bad.json,input_file_index_end:0 >bad.txt 2>&1 || rc=$?
echo "last_output_proof with target_address 2^64-1: exit code $rc"
case $rc in
    124) echo "BUG REPRODUCED: cartesi-machine hangs in hash_tree.frontier() on last_output_proof target_address 2^64-1 (killed after 10 s)"; exit 1;;
    0) echo "BUG REPRODUCED: cartesi-machine accepted a last_output_proof with target_address 2^64-1"; exit 1;;
    1) head -1 bad.txt; echo "OK: cartesi-machine rejects an out-of-range last_output_proof"; exit 0;;
    *) tail -5 bad.txt; echo "unexpected exit code $rc"; exit 2;;
esac
