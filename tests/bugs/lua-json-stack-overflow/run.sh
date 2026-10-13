#!/bin/sh
# Lua<->JSON conversion in the Lua bindings (clua_tojson/clua_fromjson) never reserves Lua stack space: deep nesting overflows the Lua stack (heap corruption)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
set +e
# clua_push_managed_toclose_json_ref/clua_push_json_value (src/clua-i-machine.cpp) push several Lua values per
# nesting level and never call lua_checkstack, so past ~8-30 levels they write beyond the end of the Lua stack.
# Each conversion runs in a child process. A correct implementation either converts the value correctly or raises
# a clean Lua error (e.g. "JSON nesting too deep"); a crash, abort, hang or wrong result means the bug is present.
bad=0
check() { # description rc output-file
    if [ "$2" -ne 0 ] || ! grep -q '^DONE' "$3"; then
        case $2 in
            124) what="hang (timeout)";;
            134) what="abort (SIGABRT)";;
            139) what="crash (SIGSEGV)";;
            3) what="wrong result";;
            *) what="exit code $2";;
        esac
        echo "  $1: $what: $(grep -v '^DONE' "$3" | tail -1 | cut -c1-160)"
        bad=$((bad + 1))
    else
        echo "  $1: $(grep '^RESULT' "$3" | cut -c1-160)"
    fi
}
for c in tojson-array:16 tojson-object:16 fromjson:50 tojson-array:100 tojson-object:100 fromjson:100; do
    mode=${c%%:*}; depth=${c##*:}
    rc=$( { timeout 10 "$LUA" "$TEST_DIR/deep.lua" "$mode" "$depth" >"$WORK_DIR/out.txt" 2>&1; echo $?; } 2>/dev/null)
    check "cartesi.$mode depth $depth" "$rc" "$WORK_DIR/out.txt"
done
# The CLI: --load-config with a JSON config file holding a deeply nested (otherwise ignored) field.
"$LUA" -e 'local n = 1000
io.write([[{"ram":{"length":65536},"x":]], string.rep("[", n), string.rep("]", n), "}")' >"$WORK_DIR/deep-config.json"
rc=$( { cd "$WORK_DIR" && timeout 30 "$LUA" "$SRC_DIR/cartesi-machine.lua" --no-ram-image --no-root-flash-drive \
    --load-config=deep-config.json --max-mcycle=0 >cli.txt 2>&1; echo $?; } 2>/dev/null)
case $rc in
    0|1) echo "  cartesi-machine --load-config=<1000-level JSON>: exit code $rc (clean)";;
    *) echo "  cartesi-machine --load-config=<1000-level JSON>: exit code $rc (killed by signal or hang): $(tail -1 "$WORK_DIR/cli.txt" | cut -c1-160)"
       bad=$((bad + 1));;
esac
if [ $bad -ne 0 ]; then
    echo "BUG REPRODUCED: $bad deeply nested Lua<->JSON conversion(s) crashed, hung or corrupted the Lua stack instead of failing cleanly"
    exit 1
fi
echo "OK: deeply nested Lua<->JSON conversions either succeed or fail with a clean Lua error"
exit 0
