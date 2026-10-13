#!/bin/sh
# cm_log_step (and cartesi-machine --log-step) accept unreproducible machines: wrong-semantics logs, non-atomic failure, process abort
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module $SRC_DIR/cartesi.so"
[ -f "$SRC_DIR/cartesi-machine.lua" ] || skip "missing $SRC_DIR/cartesi-machine.lua"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# machine::log_step (src/machine.cpp) has no is_unreproducible() check, unlike log_step_uarch, run_uarch,
# collect_mcycle_root_hashes and store. The library cases are in logstep.lua; each runs in its own process so that
# the std::terminate abort of the VirtIO queue-notify case is observed instead of killing the test.

cd "$WORK_DIR"
ulimit -c 0 2>/dev/null || true # the abort must not leave a core file behind
mkdir hostdir                   # 9P host directory (empty)
bugs=0

lua_case() { # case
    echo "== $1"
    rc=0
    out="$( { timeout 60 "$LUA" "$TEST_DIR/logstep.lua" "$1" "$WORK_DIR"; } 2>&1)" || rc=$?
    echo "$out" | sed 's/^/  | /'
    case $rc in
        0) ;;
        10) bugs=$((bugs + 1));;
        *)
            if [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ] && echo "$out" | grep -q "calling machine:log_step"; then
                echo "  log_step killed the process (exit $rc)"
                bugs=$((bugs + 1))
            else
                echo "ERROR: case $1 failed (exit $rc)"
                exit 2
            fi
            ;;
    esac
}

lua_case control
lua_case wfi
lua_case virtio-write
lua_case virtio-notify

# CLI: a 9P --volume makes the machine unreproducible; --log-step then runs the queue-notify guest under the step
# recorder. Control: the same command line without --log-step runs the guest to its halt (exit 0).
echo "== cli: cartesi-machine --volume=... --log-step=... with the queue-notify guest"
"$LUA" "$TEST_DIR/logstep.lua" gen-notify "$WORK_DIR/notify.bin" || { echo "ERROR: cannot write notify.bin"; exit 2; }
cli() {
    timeout 60 "$LUA" "$SRC_DIR/cartesi-machine.lua" --ram-image="$WORK_DIR/notify.bin" --ram-length=1Mi \
        --no-root-flash-drive --no-bootargs --volume=host_directory:"$WORK_DIR/hostdir",guest_directory:/mnt "$@"
}
rc=0
cli --max-mcycle=100 >cli-control.out 2>&1 || rc=$?
if [ $rc -ne 0 ]; then
    tail -5 cli-control.out | sed 's/^/  | /'
    echo "ERROR: control run of the CLI failed (exit $rc)"
    exit 2
fi
echo "  (control) cartesi-machine --max-mcycle=100: exit 0"
rc=0
cli --max-mcycle=0 --log-step="$WORK_DIR/cli-step.log",count:100 >cli.out 2>&1 || rc=$?
grep -E "unreproducible|terminate|what\(\)|Aborted|rror" cli.out | tail -4 | sed 's/^/  | /'
echo "  cartesi-machine --log-step: exit $rc"
if [ $rc -eq 0 ]; then
    echo "  --log-step logged a step of an unreproducible machine"
    bugs=$((bugs + 1))
elif [ $rc -ge 128 ] && [ $rc -ne 124 ]; then
    echo "  --log-step killed the CLI process"
    bugs=$((bugs + 1))
elif [ $rc -eq 124 ]; then
    echo "ERROR: CLI timed out"
    exit 2
fi

echo "== $bugs of 4 case(s) reproduced"
if [ $bugs -gt 0 ]; then
    echo "BUG REPRODUCED: cm_log_step / --log-step accept unreproducible machines (iunrep=1) instead of refusing them up front: the logged WFI step differs from cm_run, a VirtIO access fails only after the machine changed, and a VirtIO queue notify aborts the process (std::terminate)"
    exit 1
fi
echo "OK: cm_log_step and --log-step refuse unreproducible machines up front"
exit 0
