#!/bin/sh
# Build and run the proof that cm_jsonrpc_spawn_server hangs on its error path when the caller has SIGTERM blocked.
# Run from the repo root after `eval $(make -s env)` (needs src/libcartesi*.so and cartesi-jsonrpc-machine in PATH).
# Exit 1 + "BUG:" line when the defect is present; exit 0 when fixed.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${REPO_ROOT:-$(pwd)}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
g++ -std=c++20 -Wall -I"$ROOT/src" "$HERE/test_spawn_sigterm_blocked.cpp" \
    -L"$ROOT/src" -lcartesi_jsonrpc -lcartesi -o "$OUT/test_spawn_sigterm_blocked"
timeout -s KILL 60 "$OUT/test_spawn_sigterm_blocked"
