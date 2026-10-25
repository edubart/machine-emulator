#!/bin/sh
# Reproduces: cm_translate_virtual_address(m, vaddr, NULL) segfaults instead of returning an error.
# Run from the repo root after `eval $(make -s env)` (libcartesi and libcartesi_jsonrpc built in src/,
# cartesi-jsonrpc-machine in PATH for the JSON-RPC cases).
# Exit status is non-zero while the bug is present.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$HERE/../.." && pwd)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g++ -std=c++20 -I"$REPO/src" "$HERE/test_null_output.cpp" -L"$REPO/src" -lcartesi -lcartesi_jsonrpc -o "$TMP/test_null_output" || exit 2
LD_LIBRARY_PATH="$REPO/src:${LD_LIBRARY_PATH}" timeout 120 "$TMP/test_null_output"
