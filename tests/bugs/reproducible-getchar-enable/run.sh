#!/bin/sh
# The host API (write_reg, the full-shadow write_memory, set_runtime_config) enables HTIF getchar on a reproducible machine; run() then reads host input and diverges from log_step/verify_step and the uarch
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# The invariant "console input => unreproducible machine" is only enforced by machine::init_console (create/load).
# machine::write_reg(htif_iconsole), the full-shadow write_memory path and machine::set_runtime_config accept it at
# run time. device_state_access::do_getchar then serves real console input to the guest in run(), while every
# non-interactive state access (uarch / on-chain step, record/replay, collect) returns "no character".
# getchar.lua compares run() against log_step()+verify_step() and run_uarch() for each way of setting the bit, on a
# hand-encoded guest that does one getchar and halts (no toolchain needed).
set +e
rc=0
timeout 120 "$LUA" "$TEST_DIR/getchar.lua" "$WORK_DIR" || rc=$?
case $rc in
    0|1) exit $rc;;
    *) echo "ERROR: getchar.lua failed (exit $rc)"; exit 2;;
esac
