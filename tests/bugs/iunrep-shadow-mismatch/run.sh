#!/bin/sh
# The hashed shadow iunrep can diverge from the configured iunrep the machine obeys (unloadable stores, same root hash with different transitions)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# machine::is_unreproducible() uses the config; write_reg("iunrep") and the full-shadow write_memory change only the
# shadow register (which the root hash commits to), and store() does not re-check shadow == config. See iunrep.lua.

cd "$WORK_DIR"
rc=0
timeout 60 "$LUA" "$TEST_DIR/iunrep.lua" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: the committed iunrep cannot diverge from the configured one (stores load back, equal roots run alike)"; exit 0;;
    10) echo "BUG REPRODUCED: the shadow iunrep (hashed) diverges from the configured iunrep (obeyed) through write_reg or a full-shadow write_memory: store() accepts machines that can never be loaded, and an unreproducible machine shares the root hash of a reproducible one while run() performs a different transition"; exit 1;;
    124) echo "ERROR: reproducer timed out"; exit 2;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
