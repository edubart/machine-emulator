#!/bin/sh
# Run from the repo root after: eval $(make -s env)
# Builds the C reproducer against src/libcartesi and runs both the C and Lua reproducers.
# Exit status is non-zero if either reproducer detects the bug.
here=$(dirname "$0")
root=${REPO_ROOT:-$(pwd)}
out=$(mktemp -d "${TMPDIR:-/tmp}/vmem-wrap.XXXXXX")
trap 'rm -rf "$out"' EXIT
rc=0
g++ -std=c++20 -I"$root/src" "$here/test-vmem-wrap.cpp" -L"$root/src" -lcartesi -o "$out/test-vmem-wrap" || exit 2
echo "== C API =="
LD_LIBRARY_PATH="$root/src${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" timeout 30 "$out/test-vmem-wrap" || rc=1
echo "== Lua binding =="
timeout 30 lua5.4 "$here/test-vmem-wrap.lua" || rc=1
exit $rc
