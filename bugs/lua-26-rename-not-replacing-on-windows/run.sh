#!/bin/sh
# Runs test.lua natively and under a Windows Lua 5.4 (mingw-w64 cross build) through Wine.
# Exits non-zero (and test.lua prints "BUG:") when the Windows run fails to replace the destination.
# Requirements: lua5.4, wine (or wine64), and either WIN_LUA=<path to a Windows lua.exe> or
# x86_64-w64-mingw32-gcc to cross-build one (from LUA_TARBALL, or downloaded from lua.org).
set -e
W=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$W/../../src" && pwd)
CACHE=${CACHE:-${TMPDIR:-/tmp}/bugs-lua-26-winlua}
if [ -z "$WIN_LUA" ]; then
    WIN_LUA=$CACHE/lua-5.4.6/src/lua.exe
    if [ ! -x "$WIN_LUA" ]; then
        mkdir -p "$CACHE"
        if [ -z "$LUA_TARBALL" ]; then
            LUA_TARBALL=$CACHE/lua-5.4.6.tar.gz
            [ -f "$LUA_TARBALL" ] || curl -sSfL -o "$LUA_TARBALL" https://www.lua.org/ftp/lua-5.4.6.tar.gz
        fi
        tar -C "$CACHE" -xzf "$LUA_TARBALL"
        make -s -C "$CACHE/lua-5.4.6/src" mingw CC=x86_64-w64-mingw32-gcc >/dev/null
    fi
fi
set +e
echo "== native lua5.4 (Linux) =="; lua5.4 "$W/test.lua" "$SRC" "$(mktemp -d)" || exit 2
echo "== Windows lua.exe under wine =="
D=$(mktemp -d)
mkdir -p "$CACHE/wineprefix"
export WINEDEBUG=-all WINEPREFIX="$CACHE/wineprefix"
WINE=$(command -v wine || command -v wine64 || echo /usr/lib/wine/wine64)
timeout 300 "$WINE" "$WIN_LUA" "Z:$W/test.lua" "Z:$SRC" "Z:$D"
