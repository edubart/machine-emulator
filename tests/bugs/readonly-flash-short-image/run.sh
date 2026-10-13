#!/bin/sh
# A read-only flash drive backed by a page-aligned image shorter than the drive is refused with "possible non zero partial page"
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/os-mapped-memory.cpp: partial_page_remaining = min(page_size - backing_file_length % page_size, ...) is a whole
# page (not 0) when the image length is a multiple of the page size, so the read-only path throws. The same image is
# accepted for a writable drive (control).
rc=0
out="$(cd "$WORK_DIR" && timeout 30 "$LUA" "$TEST_DIR/short-image.lua" "$WORK_DIR" 2>&1)" || rc=$?
echo "$out"
case $rc in
    0) echo "$out" | grep -q "^OK:" && exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "ERROR: short-image.lua failed (exit $rc)"
exit 2
