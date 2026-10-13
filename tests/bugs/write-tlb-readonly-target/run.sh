#!/bin/sh
# A shadow WRITE-TLB slot targeting a non-writable range (PMA table, read-only flash) lets cm_run write to it or crash
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
build_c rotlb "$TEST_DIR/rotlb.c" || build_failed rotlb
# shadow_tlb_verify_slot (src/shadow-tlb.hpp) does not check that a WRITE-set slot points at a writable (W=1) range.
# The reference is the guest semantics (the control case: an honest store to the same range faults), not
# cm_run_uarch: its refusal comes from a host-only read-only check in machine::write_word, not from the step semantics.

cd "$WORK_DIR"
rc=0
timeout 60 "$WORK_DIR/rotlb" "$WORK_DIR" || rc=$?
case $rc in
    0) echo "OK: a shadow WRITE-TLB slot that targets a non-writable range is rejected; cm_run does not modify the range"; exit 0;;
    1) echo "BUG REPRODUCED: a committed shadow WRITE-TLB slot that targets a non-writable memory range is accepted by shadow_tlb_verify_slot, so cm_run writes to that range (PMA table, read-only flash drive) or crashes the host process on a read-only host mapping"; exit 1;;
    124) echo "ERROR: reproducer timed out"; exit 2;;
    *) echo "ERROR: reproducer failed (exit $rc)"; exit 2;;
esac
