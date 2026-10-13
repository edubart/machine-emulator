#!/bin/sh
# Every input rejected by a Lua conversion helper (cartesi.fromjson/tojson/frombase64/fromhex...) leaks its C++ exception object, because luaL_error is called inside the catch block
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/clua-cartesi.cpp (tobase64, frombase64, tohex, fromhex, tojson, fromjson) and src/clua-i-machine.cpp
# (clua_tojson, clua_fromjson) do `try { ... } catch (std::exception &e) { luaL_error(L, ...); }`. With Lua built as
# C, lua_error longjmps out of the handler, so __cxa_end_catch never runs and the exception object (about 400 bytes
# with its message) stays on the thread's caught-exceptions chain forever: a long-lived Lua service that validates
# untrusted input with these helpers grows without bound.
# excount.so counts exception objects allocated vs released while cases.lua rejects N inputs through one helper.
# Property checked (what a fix restores): every exception object allocated is released.
"$CC" -O1 -shared -fPIC "$TEST_DIR/excount.c" -o "$WORK_DIR/excount.so" -ldl -Wl,--no-as-needed -lstdc++ ||
    build_failed excount.so
set +e
N=1000
bug=0
for c in capi_error fromjson tojson frombase64 fromhex; do
    rm -f "$WORK_DIR/count.txt"
    # (the interposer is preloaded into the Lua process only, not into timeout, which would overwrite the counts)
    rejected=$(timeout 60 env EXCOUNT_OUT="$WORK_DIR/count.txt" LD_PRELOAD="$WORK_DIR/excount.so" "$LUA" \
        "$TEST_DIR/cases.lua" "$c" "$N")
    rc=$?
    case "$rejected" in ''|*[!0-9]*) rc=2;; esac
    [ "$rc" -eq 0 ] || { echo "ERROR: cases.lua $c failed (exit $rc)"; exit 2; }
    read -r allocated released <"$WORK_DIR/count.txt" || { echo "ERROR: no counts for $c"; exit 2; }
    leaked=$((allocated - released))
    printf "  %-11s rejected=%d  exceptions allocated=%5d released=%5d never released=%5d\n" "$c" "$rejected" \
        "$allocated" "$released" "$leaked"
    if [ "$c" = capi_error ]; then
        # control: the C API's own catch releases its exceptions; it also shows that the interposer sees them
        [ "$rejected" -eq "$N" ] || { echo "ERROR: the control input was not rejected"; exit 2; }
        [ "$allocated" -gt 0 ] || skip "the interposer saw no C++ exception (libstdc++ not interposable here)"
        [ "$leaked" -eq 0 ] || { echo "ERROR: control leaked exceptions"; exit 2; }
    elif [ "$leaked" -gt 0 ]; then
        bug=1
    fi
done
# Informational: resident memory growth over 20000 rejected fromjson inputs
timeout 60 "$LUA" -e '
local cartesi = require("cartesi")
local function rss()
    for l in io.lines("/proc/self/status") do
        local v = l:match("^VmRSS:%s+(%d+)")
        if v then return tonumber(v) end
    end
end
for _ = 1, 1000 do pcall(cartesi.fromjson, "{") end
collectgarbage() collectgarbage()
local before = rss()
for _ = 1, 20000 do pcall(cartesi.fromjson, "{") end
collectgarbage() collectgarbage()
local kb = rss() - before
print(string.format("  RSS growth over 20000 rejected fromjson inputs: %d kB (%.0f bytes each)", kb, kb * 1024 / 20000))' 2>/dev/null
if [ "$bug" -eq 1 ]; then
    echo "BUG REPRODUCED: each input rejected by a Lua conversion helper leaks its C++ exception object"
    exit 1
fi
echo "OK: every exception object raised by a rejected input is released"
exit 0
