#!/bin/sh
# Builds the crash-injection shim into a temp dir and runs the proof.
# Usage from the repo root: eval $(make -s env); sh bugs/rpc-11-clear-hash-tree-crash-order/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rpc11.XXXXXX")
trap 'rm -rf "$work"' EXIT
gcc -shared -fPIC -O2 "$here/shim.c" -o "$work/shim.so" -ldl
SHIM_SO="$work/shim.so" TMPDIR_TEST="$work/dirs" timeout 300 lua5.4 "$here/test_clear_crash.lua"
