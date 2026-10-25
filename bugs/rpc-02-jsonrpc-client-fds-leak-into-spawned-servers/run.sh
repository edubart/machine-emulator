#!/bin/sh
# Build and run the fd-leak / concurrent-spawn proof of concept.
# Run from the repo root after `eval $(make -s env)` (needs src/libcartesi*.so and cartesi-jsonrpc-machine in PATH).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${REPO_ROOT:-$(pwd)}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
g++ -std=c++20 -O1 -pthread -I"$ROOT/src" "$HERE/test_spawn_fd_leak.cpp" \
    -L"$ROOT/src" -lcartesi_jsonrpc -lcartesi -o "$OUT/test_spawn_fd_leak"
timeout 120 "$OUT/test_spawn_fd_leak"
