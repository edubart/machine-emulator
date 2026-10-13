#!/bin/sh
# cartesi-machine --gdb: a stepc that ends exactly on an automatic-yield mcycle never gets a stop reply; the CLI exits 0 with the final hash of an unfinished run, or (with any breakpoint) re-services the same yield forever
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
"$LUA" -e 'require("socket")' >/dev/null 2>&1 || skip "missing LuaSocket (needed by cartesi.gdbstub)"
command -v python3 >/dev/null 2>&1 || skip "missing python3"
# src/cartesi/gdbstub.lua _handle_continue: when the step target (mcycle_limit) lands on an automatic yield, the outer
# call is suspended so the CLI can service the yield. On resume (_pump_session) _handle_continue runs again with
# mcycle == mcycle_limit: nothing executes and iflags_X is still set. Without breakpoints _advance returns a
# zero-length REACHED_TARGET_MCYCLE that run_to_stop takes as the CLI's own target (prints the final hash, exits 0);
# with breakpoints the stale YIELDED_AUTOMATICALLY is returned and run_to_stop re-services the same yield forever.
# driver.py passes the CLI an inherited listening socket on 127.0.0.1 (kernel-chosen port, --gdb-fd), plays gdb,
# never stores the CLI output, and SIGKILLs the CLI's own session at the end of each case.
build_rv guest.bin "$TEST_DIR/guest.S"
set +e
# mcycle of the automatic yield and of the halt, measured on the same guest
marks=$(GUEST="$WORK_DIR/guest.bin" timeout 30 "$LUA" -e '
local cartesi = require("cartesi")
local m = cartesi.machine({ ram = { length = 0x10000, backing_store = { data_filename = os.getenv("GUEST") } } })
assert(m:run(-1) == cartesi.BREAK_REASON_YIELDED_AUTOMATICALLY)
local y = m:read_reg("mcycle")
assert(m:run(-1) == cartesi.BREAK_REASON_HALTED)
print(y, m:read_reg("mcycle"))') || { echo "ERROR: could not measure the guest"; exit 2; }
set -- $marks
rc=0
timeout 150 python3 -I -u "$TEST_DIR/driver.py" "$LUA" "$SRC_DIR/cartesi-machine.lua" "$WORK_DIR/guest.bin" "$1" "$2" || rc=$?
case $rc in
    0|1) exit $rc;;
    124) echo "ERROR: driver timed out"; exit 2;;
    *) echo "ERROR: driver failed (exit $rc)"; exit 2;;
esac
