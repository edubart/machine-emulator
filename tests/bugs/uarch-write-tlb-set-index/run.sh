#!/bin/sh
# uarch WRITE_TLB ecall does not bounds-check the TLB set index (out-of-bounds host write)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c write-tlb "$TEST_DIR/write-tlb.c"

# Each case runs in its own process, because the out-of-range index can corrupt or crash the host process.
# Sets $rc to the exit status of the child (0 = step rejected, 1 = step accepted, 2 = setup error, >128 = signal).
run_case() { # mode set_index
    rc=0
    timeout 60 "$WORK_DIR/write-tlb" "$1" "$2" >"$WORK_DIR/out" 2>&1 || rc=$?
    sed 's/^/    /' "$WORK_DIR/out" | tail -n 4
}

# Control: a valid set index must be accepted, otherwise this test cannot reach the WRITE_TLB ecall at all
for mode in run log; do
    run_case $mode 2
    if [ "$rc" -ne 1 ]; then
        echo "ERROR: control case ($mode, valid set_index=2) did not succeed (exit $rc)"
        exit 2
    fi
done

# Out-of-range set indices (3 is one past the end of the 3-entry TLB arrays)
bad=""
for mode in run log; do
    for idx in 3 65536; do
        run_case $mode $idx
        case $rc in
            0) ;;
            1) bad="$bad [$mode set_index=$idx: accepted]";;
            2) echo "ERROR: setup failed"; exit 2;;
            124) bad="$bad [$mode set_index=$idx: hang]";;
            *) bad="$bad [$mode set_index=$idx: process died, exit $rc]";;
        esac
    done
done

if [ -n "$bad" ]; then
    echo "BUG REPRODUCED: uarch WRITE_TLB ecall with an out-of-range TLB set index is not rejected and is used as a host array index:$bad"
    exit 1
fi
echo "OK: uarch WRITE_TLB ecall rejects out-of-range TLB set indices"
exit 0
