#!/bin/sh
# S-mode can set sip.STIP and clear sip.SEIP, which the spec makes read-only in sip
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
need_riscv
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua module cartesi.so"
build_rv control.bin -DCONTROL "$TEST_DIR/sip.S"
build_rv prog.bin "$TEST_DIR/sip.S"
# run <bin>: runs the program and prints its exit code (a0) and a1..a3 (mcause, interrupts taken, sip)
run() {
    timeout 60 "$LUA" "$TEST_DIR/run.lua" "$WORK_DIR/$1"
}
exit_code() { echo "$1" | sed -n 's/^exit=\([0-9]*\).*/\1/p'; }

# Control: without the sip writes, the SEI set by M-mode must be taken and nothing else.
out="$(run control.bin)" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "control: $out"
[ "$(exit_code "$out")" = "0" ] || { echo "ERROR: control run did not take exactly SEI"; exit 2; }

out="$(run prog.bin)" || { echo "$out"; echo "ERROR: runner failed"; exit 2; }
echo "test:    $out"
echo "(a2 = S interrupts taken: 0x20=STI 0x200=SEI, spec expects 0x200; a3 = sip read by S after the writes, spec expects 0x200)"
code="$(exit_code "$out")"
[ -n "$code" ] || { echo "ERROR: no exit code"; exit 2; }
if [ $((code & ~3)) -ne 0 ]; then echo "ERROR: unexpected exit code $code"; exit 2; fi
[ $((code & 1)) -ne 0 ] && echo "S-mode 'csrs sip, STIP' set STIP (an STI was taken)"
[ $((code & 2)) -ne 0 ] && echo "S-mode 'csrc sip, SEIP' cleared the SEIP set by M-mode (the SEI was lost)"
if [ "$code" -ne 0 ]; then
    echo "BUG REPRODUCED: S-mode modified read-only sip bits (mask=$code)"
    exit 1
fi
echo "OK: sip.STIP and sip.SEIP are read-only from S-mode"
exit 0
