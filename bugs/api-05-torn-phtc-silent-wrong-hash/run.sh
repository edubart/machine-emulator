#!/bin/sh
# Build the LD_PRELOAD kill shim into a temporary directory and run the proof.
# Exit 1 + "BUG:" lines when the defect is present; exit 0 when fixed.
# Run from the repo root: eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh
# The clone_stored case needs a filesystem without reflink (e.g. ext4) for the temp dir; otherwise it is skipped.
set -e
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gcc -shared -fPIC -O2 "$D/killshim.c" -o "$T/killshim.so" -ldl
KILLSHIM_DIR="$T" WORK_DIR="$T/work" timeout 300 lua5.4 "$D/test_torn_phtc.lua"
