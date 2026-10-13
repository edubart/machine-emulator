#!/bin/sh
# A clean persisted dirty-page tree without its dense hash tree (dpt_filename without dht_filename, create-in-directory, or a lost .dht loaded with SHARING_ALL) makes the root hash ignore the drive contents
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
[ -f "$SRC_DIR/cartesi/hash-tree.lua" ] || skip "missing $SRC_DIR/cartesi/hash-tree.lua"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/memory-address-range.cpp backs m_dpt with dpt_filename but m_dht with anonymous (zero) memory when dht_filename
# is empty; src/machine-address-ranges.cpp recreates a missing .dht as a zero file (shared load, create-in-directory)
# while keeping the .dpt. src/dirty-page-tree.hpp keeps the persisted clean marks, so src/hash-tree.cpp never rehashes
# those pages and copies the zero dht root into the sparse tree. repro.lua checks each trigger against a drive hash
# computed independently from the data file bytes (cartesi.hash-tree get_data_root_hash).
rc=0
out="$(cd "$WORK_DIR" && timeout 60 "$LUA" "$TEST_DIR/repro.lua" "$WORK_DIR" 2>"$WORK_DIR/stderr.txt")" || rc=$?
echo "$out"
case $rc in
    0) echo "$out" | grep -q "^OK:" && exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "ERROR: repro.lua failed (exit $rc):"; tail -5 "$WORK_DIR/stderr.txt"
exit 2
