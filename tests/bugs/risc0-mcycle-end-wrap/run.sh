#!/bin/sh
# RISC Zero step replay wraps mcycle_end on overflow while the host verify_step saturates
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/libcartesi.a" ] || skip "missing $SRC_DIR/libcartesi.a"
REPLAY_SRC="$REPO_DIR/risc0/cpp/risc0-replay-steps.cpp"
[ -f "$REPLAY_SRC" ] || skip "missing $REPLAY_SRC"

# Compile the unmodified guest entry point for the host. It is copied next to a host stand-in for zk-runtime.hpp,
# because its #include "zk-runtime.hpp" is resolved relative to its own directory first.
cp "$REPLAY_SRC" "$TEST_DIR/zk-runtime.hpp" "$WORK_DIR/"
build_cxx_static risc0-wrap "$TEST_DIR/risc0-wrap.cpp" "$WORK_DIR/risc0-replay-steps.cpp" "$TEST_DIR/interpret-ref.cpp"

rc=0
timeout 120 "$WORK_DIR/risc0-wrap" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: risc0_replay_steps agrees with cm_verify_step when mcycle + mcycle_count exceeds 2^64-1"; exit 0;;
    1) echo "BUG REPRODUCED: risc0_replay_steps wraps mcycle_end (mcycle + mcycle_count > 2^64-1): it rejects honest step logs and accepts forged ones that cm_verify_step rejects"; exit 1;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
