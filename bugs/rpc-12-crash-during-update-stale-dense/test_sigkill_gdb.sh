#!/bin/bash
# Real-crash reproduction: SIGKILL the process (via gdb) at entry of hash_tree::update_dense_trees
# while cm_get_root_hash updates a stored machine loaded with SHARING_ALL. Reload and compare.
# Requires gdb. Run with env.sh sourced.
set -u
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
lua5.4 "$D/kill_prep.lua" "$T/base" || { echo "prep failed"; exit 2; }
cp -a "$T/base" "$T/ref"
REF=$(timeout 120 lua5.4 "$D/kill_victim.lua" "$T/ref" 2>/dev/null)
cp -a "$T/base" "$T/crash"
timeout 120 gdb -q -batch -ex "set breakpoint pending on" -ex "break cartesi::hash_tree::update_dense_trees" \
    -ex run -ex kill --args lua5.4 "$D/kill_victim.lua" "$T/crash" >"$T/gdb.log" 2>&1
grep -q "Breakpoint 1, cartesi::hash_tree::update_dense_trees" "$T/gdb.log" || { echo "breakpoint not hit"; cat "$T/gdb.log"; exit 2; }
GOT=$(timeout 120 lua5.4 "$D/kill_check.lua" "$T/crash" 2>&1)
GOT2=$(timeout 120 lua5.4 "$D/kill_check.lua" "$T/crash" 2>&1)
echo "correct root hash (uninterrupted update): $REF"
echo "root hash after reload of crashed dir   : $GOT"
echo "root hash after second reload           : $GOT2"
if [ "$GOT" != "$REF" ]; then
    case "$GOT" in 0x*) echo "BUG: process killed during hash-tree update of a SHARING_ALL stored machine; reload silently returns a wrong root hash"; exit 1;; esac
    echo "reload failed loudly (acceptable): $GOT"; exit 0
fi
echo "OK"; exit 0
