#!/bin/sh
# Unreproducible WFI fast-forward lands one mcycle past its deadline (run(N) ends at N+1, timer interrupt one RTC tick late)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# machine::poll_external_interrupts clamps the advanced mcycle to mcycle_max, then the interpreter loop adds 1 for the
# WFI itself. Each case runs in its own process: assert-enabled builds abort in interpret() on the run-target case.

cd "$WORK_DIR"
ulimit -c 0 2>/dev/null || true # an assertion abort must not leave a core file behind
bugs=0
for c in run-target timer; do
    echo "== $c"
    rc=0
    out="$( { timeout 60 "$LUA" "$TEST_DIR/wfi.lua" "$c"; } 2>&1)" || rc=$?
    echo "$out" | sed 's/^/  | /'
    case $rc in
        0) ;;
        10) bugs=$((bugs + 1));;
        *)
            if [ "$c" = run-target ] && [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ] && echo "$out" | grep -q "calling run("; then
                echo "  run() aborted the process (exit $rc): the WFI overshoot trips the mcycle_end assertion"
                bugs=$((bugs + 1))
            else
                echo "ERROR: case $c failed (exit $rc)"
                exit 2
            fi
            ;;
    esac
done

echo "== $bugs of 2 case(s) reproduced"
if [ $bugs -gt 0 ]; then
    echo "BUG REPRODUCED: on unreproducible machines the WFI fast-forward retires at mcycle_max + 1: run(N) ends past mcycle_end and a timer deadline on an RTC tick is delivered one tick (8192 mcycles) late"
    exit 1
fi
echo "OK: the unreproducible WFI fast-forward stops at its deadline (run(N) ends at N, timer taken at the deadline)"
exit 0
