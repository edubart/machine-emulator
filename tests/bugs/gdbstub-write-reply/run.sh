#!/bin/sh
# gdbstub replies "E01" to successful 'M' (write memory) packets and "OK" to failed ones
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
"$LUA" -e 'require("socket")' >/dev/null 2>&1 || skip "missing LuaSocket (needed by cartesi.gdbstub)"
# src/cartesi/gdbstub.lua GDBStub:_handle_write_mem does
#   local ok = pcall(function() self.runner:write_virtual_memory(address, mem) end)
#   if ok then return self:_send_error() end
# so the condition is inverted: GDB `set var`, `set {int}addr = v` and `load` report "Cannot access memory" although
# the machine was modified, and writes to invalid addresses are reported as successful.
# gdbwrite.lua plays the GDB client over a loopback socket (kernel-chosen port) and checks both replies.
cd "$WORK_DIR"
rc=0
timeout 30 "$LUA" "$TEST_DIR/gdbwrite.lua" || rc=$?
case $rc in
    0) echo "OK: gdbstub replies OK to successful memory writes and an error to failed ones"; exit 0;;
    1) echo "BUG REPRODUCED: gdbstub memory-write replies are inverted (E01 on success, OK on failure)"; exit 1;;
    124) echo "gdb session timed out"; exit 2;;
    *) echo "gdbwrite.lua failed (exit code $rc)"; exit 2;;
esac
