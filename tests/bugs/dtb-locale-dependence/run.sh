#!/bin/sh
# DTB unit addresses, /aliases targets and stored-machine file names are formatted with the host's C++ global locale: a digit-grouping locale changes the root hash of the same config and makes stored machines unloadable across locales
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
command -v "$CXX" >/dev/null 2>&1 || skip "missing $CXX"
# locale.cpp sets a synthetic digit-grouping numpunct facet as the C++ global locale in-process (no system locale
# data needed) and compares root hash, DTB and stored file names against the classic locale. It links the shared
# libcartesi, as a C++ host would, so both use the same C++ runtime and global locale.
"$CXX" -std=gnu++20 -O1 -I"$SRC_DIR" "$TEST_DIR/locale.cpp" -o "$WORK_DIR/locale" -L"$SRC_DIR" -lcartesi \
    -Wl,-rpath,"$SRC_DIR" || build_failed locale
set +e
rc=0
timeout 60 "$WORK_DIR/locale" "$WORK_DIR" || rc=$?
case $rc in
    0|1) exit $rc;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
