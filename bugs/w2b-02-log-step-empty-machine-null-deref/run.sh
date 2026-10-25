#!/bin/sh
# Reproduces: cm_log_step / machine:log_step on an empty or destroyed local machine segfaults.
# Run from the repo root after `eval $(make -s env)` (libcartesi built in src/).
# Exit status is non-zero while the bug is present.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$HERE/../.." && pwd)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0
echo "== C API =="
g++ -std=c++20 -I"$REPO/src" "$HERE/test_log_step_empty.cpp" -L"$REPO/src" -lcartesi -o "$TMP/test_log_step_empty" || exit 2
LD_LIBRARY_PATH="$REPO/src:${LD_LIBRARY_PATH}" "$TMP/test_log_step_empty" "$TMP" || rc=1
echo "== Lua =="
lua5.4 "$HERE/test_log_step_empty.lua" "$TMP" || rc=1
exit $rc
