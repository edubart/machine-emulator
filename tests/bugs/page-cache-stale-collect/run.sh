#!/bin/sh
# Stale page hash-tree cache entries survive cm_replace_memory_range with the range's own dht/dpt files: wrong word-level hashes/proofs and wrong cm_collect_uarch_cycle_root_hashes results
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
# Control (replacement without hash-tree files) validates the test itself and must pass
rc=0
out="$(timeout 120 "$LUA" "$TEST_DIR/repro.lua" "$WORK_DIR" control 2>&1)" || rc=$?
if [ $rc -ne 0 ]; then
    echo "$out"; echo "test error: control run failed (exit $rc)"; exit 2
fi
rc=0
out="$(timeout 120 "$LUA" "$TEST_DIR/repro.lua" "$WORK_DIR" 2>&1)" || rc=$?
echo "$out"
case $rc in
    0) exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "test error (exit $rc)"
exit 2
