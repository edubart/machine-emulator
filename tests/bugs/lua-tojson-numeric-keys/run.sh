#!/bin/sh
# cartesi.tojson converts numeric table keys in place during lua_next (spurious "invalid key to 'next'", dropped fields or endless loop)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# In src/clua-i-machine.cpp the object branch of the Lua->JSON conversion accepts any key for which lua_isstring is
# true (numbers included) and then calls lua_tostring(L, -2) on the key inside the lua_next loop, converting it in
# place. Both cases of keys.lua fail deterministically. The timeout is only a guard: other key layouts can make the
# traversal loop forever, and a hang also counts as the bug.
cd "$WORK_DIR"
rc=0
timeout 20 "$LUA" "$TEST_DIR/keys.lua" || rc=$?
case $rc in
    0) echo "OK: cartesi.tojson handles numeric keys in non-array tables without corrupting the traversal"; exit 0;;
    1) echo "BUG REPRODUCED: cartesi.tojson corrupts the table traversal on numeric keys (lua_tostring on a lua_next key)"; exit 1;;
    124) echo "BUG REPRODUCED: cartesi.tojson did not terminate"; exit 1;;
    *) echo "keys.lua failed (exit code $rc)"; exit 2;;
esac
