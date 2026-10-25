#!/bin/sh
# Reproduces: remote (JSON-RPC) cm_send/log_send/verify_send_cmio_response with data=NULL
# segfault the client process, while a local machine returns success (oversized) or an error.
# Run from the repo root after `eval $(make -s env)` (libcartesi and libcartesi_jsonrpc built in src/,
# cartesi-jsonrpc-machine on PATH). Exit status is non-zero while the bug is present.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$HERE/../.." && pwd)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g++ -std=c++20 -I"$REPO/src" "$HERE/test_cmio_null_data.cpp" -L"$REPO/src" -lcartesi -lcartesi_jsonrpc \
    -o "$TMP/test_cmio_null_data" || exit 2
LD_LIBRARY_PATH="$REPO/src:${LD_LIBRARY_PATH}" timeout 100 "$TMP/test_cmio_null_data"
