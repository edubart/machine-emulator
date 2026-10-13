#!/bin/sh
# cartesi-machine --load-config silently ignores command-line options for fields omitted from the config file (documented fallback not implemented)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# The --load-config help says: "If a field is omitted on the config table, it will fall back into the respective
# command-line argument or into the default value." The CLI wraps the loaded table in a metatable whose __index is
# the command-line config, but machine:create() serializes it with a raw lua_next walk (clua_tojson), so every
# omitted top-level field silently gets the C++ default instead of the command-line value.
# partial.json only sets "ram"; hash_tree, processor (HTIF yield flags) and dtb must come from the command line.
cd "$WORK_DIR"
cp "$TEST_DIR/partial.json" .
OPTS="--no-ram-image --no-root-flash-drive --hash-tree=hash_function:sha256 --no-htif-yield-automatic --max-mcycle=0"
# shellcheck disable=SC2086
"$LUA" "$SRC_DIR/cartesi-machine.lua" $OPTS --load-config=partial.json --store-config=got.lua --initial-hash \
    >got.txt 2>&1 || { cat got.txt; echo "cartesi-machine --load-config failed"; exit 2; }
# Reference: the same options without --load-config (64 KiB RAM given on the command line instead)
# shellcheck disable=SC2086
"$LUA" "$SRC_DIR/cartesi-machine.lua" $OPTS --ram-length=64Ki --store-config=ref.lua --initial-hash \
    >ref.txt 2>&1 || { cat ref.txt; echo "reference cartesi-machine run failed"; exit 2; }
got_hash=$(grep -E '^0: 0x' got.txt | head -1 | cut -d' ' -f2)
ref_hash=$(grep -E '^0: 0x' ref.txt | head -1 | cut -d' ' -f2)
[ -n "$got_hash" ] && [ -n "$ref_hash" ] || { echo "could not read initial hashes"; exit 2; }
rc=0
"$LUA" "$TEST_DIR/compare.lua" got.lua ref.lua "$got_hash" "$ref_hash" || rc=$?
case $rc in
    0) echo "OK: fields omitted from the --load-config file fall back to the command-line options"; exit 0;;
    1) echo "BUG REPRODUCED: command-line options silently ignored for fields omitted from the --load-config file (different machine and root hash)"; exit 1;;
    *) echo "compare.lua failed"; exit 2;;
esac
