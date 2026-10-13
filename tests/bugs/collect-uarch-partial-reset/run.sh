#!/bin/sh
# cm_collect_uarch_cycle_root_hashes resets only the uarch RAM words touched during the mcycle, so a non-pristine uarch yields post-reset hashes that differ from the canonical (on-chain) uarch reset
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
# Control (pristine uarch) validates the test itself and must pass
rc=0
out="$(timeout 60 "$LUA" "$TEST_DIR/repro.lua" control 2>&1)" || rc=$?
if [ $rc -ne 0 ]; then
    echo "$out"; echo "test error: control run failed (exit $rc)"; exit 2
fi
rc=0
out="$(timeout 60 "$LUA" "$TEST_DIR/repro.lua" 2>&1)" || rc=$?
echo "$out"
case $rc in
    0) exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "test error (exit $rc)"
exit 2
