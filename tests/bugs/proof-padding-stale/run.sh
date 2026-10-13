#!/bin/sh
# cm_get_proof/cm_get_node_hash return stale (wrong) word hashes for addresses in the power-of-two padding of a range
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so (make)"

# Each query runs in its own process: in assert-enabled builds get_node_hash on a padding word aborts
# (the assert of the related step-log-padding-assert bug), which must not hide the result of the other query.
proof_rc=0
timeout 60 "$LUA" "$TEST_DIR/padding-proof.lua" proof >"$WORK_DIR/proof.out" 2>&1 || proof_rc=$?
cut -c1-200 "$WORK_DIR/proof.out"
node_rc=0
timeout 60 "$LUA" "$TEST_DIR/padding-proof.lua" nodehash >"$WORK_DIR/node.out" 2>&1 || node_rc=$?
cut -c1-200 "$WORK_DIR/node.out"

if [ $proof_rc -eq 2 ] || [ $node_rc -eq 2 ]; then
    echo "ERROR: reproducer setup failed (proof exit $proof_rc, nodehash exit $node_rc)"; exit 2
fi
msg=""
[ $proof_rc -ne 0 ] && msg="$msg [cm_get_proof on a padding word: wrong proof (exit $proof_rc)]"
if [ $node_rc -ge 124 ]; then
    msg="$msg [cm_get_node_hash on a padding word: process aborted or hung (exit $node_rc)]"
elif [ $node_rc -ne 0 ]; then
    msg="$msg [cm_get_node_hash on a padding word: wrong hash (exit $node_rc)]"
fi
if [ -n "$msg" ]; then
    echo "BUG REPRODUCED: word-level queries in the power-of-two padding of a memory range use a stale page-cache entry:$msg"
    exit 1
fi
echo "OK: word proofs and node hashes in the padding of a memory range are pristine and verify against the root hash"
exit 0
