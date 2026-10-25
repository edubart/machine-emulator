#!/bin/sh
# Build the LD_PRELOAD kill hook into a temporary directory and run the proof.
# Exit 1 + "BUG:" lines when the defect is present; exit 0 when fixed; exit 2 if the hook never fired.
# Run from the repo root: eval $(make -s env); sh bugs/api-07-clear-hash-tree-zeroes-before-marking-dirty/run.sh
set -e
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gcc -shared -fPIC -O2 "$D/kill_after_punch.c" -o "$T/kill_after_punch.so" -ldl
KILL_HOOK="$T/kill_after_punch.so" TMPDIR_TEST="$T/work" timeout 120 lua5.4 "$D/test_clear_kill.lua"
