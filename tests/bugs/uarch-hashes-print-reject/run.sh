#!/bin/sh
# cartesi-machine --print-uarch-cycle-root-hashes prints a fabricated uarch group (the revert root hash twice) after an rx-rejected manual yield of a loaded mid-input machine
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/cartesi-machine.lua passes fake_revert_uarch_tail = {R, R} to the collection, assuming a rejection "never
# happens outside cmio mode". A loaded mid-input snapshot reaches one without cmio mode, and
# append_revert_uarch_tail_period (src/machine.cpp) then emits the fake 2-entry period, labelled with an mcycle
# that never happens. compare.lua checks every printed hash against collect_uarch_cycle_root_hashes() with the real
# revert uarch tail.
build_rv guest.bin "$TEST_DIR/guest.S"
set +e
export LUA
rc=0
timeout 120 "$LUA" "$TEST_DIR/compare.lua" "$WORK_DIR/guest.bin" "$WORK_DIR" "$SRC_DIR/cartesi-machine.lua" || rc=$?
case $rc in
    0|1) exit $rc;;
    *) echo "ERROR: compare.lua failed (exit $rc)"; exit 2;;
esac
