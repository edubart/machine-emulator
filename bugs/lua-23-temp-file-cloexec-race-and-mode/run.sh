#!/bin/sh
# Runs both proofs; exits non-zero if either defect is present.
# Run from the repo root after: eval $(make -s env)
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
rc=0
(umask 022; timeout 30 lua5.4 "$D/test_mode.lua") || rc=1
g++ -std=c++20 -O2 -I/usr/include/lua5.4 "$D/test_cloexec_race.cpp" -llua5.4 -pthread -o "$T/test_cloexec_race" || exit 2
mkdir -p "$T/probe"
timeout 60 "$T/test_cloexec_race" "$T/probe" || rc=1
exit $rc
