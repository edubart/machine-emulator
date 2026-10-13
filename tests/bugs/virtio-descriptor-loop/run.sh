#!/bin/sh
# VirtIO virtqueue descriptor-chain traversal has no cycle/length bound: a cyclic chain hangs the host emulator (guest-triggerable DoS)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
set +e

# A tiny bare-metal RISC-V guest (crt.S + driver.c) brings up the virtio-console device and programs a
# two-node cyclic virtqueue descriptor chain (desc[0].next=1 -> desc[1].next=0, both read-only), then
# notifies the queue. on_device_queue_notify() calls virtq::get_desc_rw_avail_len(), which follows
# desc.next in a `while (true)` loop with no visited-set, no counter and no cap at vq.num
# (src/virtio-address-range.cpp). A cyclic chain therefore loops forever inside the cm_run thread.
#
# The C harness (harness.c) creates an unreproducible machine with a virtio-console device, loads the
# guest into RAM and runs cm_run() in a forked child under an 8 s watchdog. If the walk is unbounded the
# child never returns and the watchdog kills it (BUG REPRODUCED, exit 1). A bounded/fixed walker returns
# from cm_run and the guest HTIF-halts, so the child exits 0 (OK). The forked child is the only extra
# process and is SIGKILLed by the harness; no server or socket is involved.
build_rv driver.bin "$TEST_DIR/crt.S" "$TEST_DIR/driver.c" || { echo "failed to build guest driver"; exit 2; }
build_c  harness "$TEST_DIR/harness.c"                     || { echo "failed to build harness"; exit 2; }

# Outer timeout is a safety net only; the harness self-limits to 8 s.
timeout 40 "$WORK_DIR/harness" "$WORK_DIR/driver.bin"
rc=$?
if [ "$rc" = 0 ]; then
    echo "OK: virtio queue notify returned (cyclic descriptor chain is bounded)"
fi
exit $rc
