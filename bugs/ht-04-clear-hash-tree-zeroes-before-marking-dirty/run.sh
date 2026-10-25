#!/bin/sh
# Build the LD_PRELOAD kill shim into a temporary directory and run the proof.
# Exit 1 + "BUG:" lines when the defect is present; exit 0 when fixed.
# Run from the repo root: eval $(make -s env); sh bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh
set -e
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gcc -shared -fPIC -O2 "$D/killshim.c" -o "$T/killshim.so" -ldl
KILLSHIM_DIR="$T" WORK_DIR="$T/work" timeout 120 lua5.4 "$D/test.lua"
