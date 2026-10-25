#!/usr/bin/env python3
# Repro: machine:run aborts with "console output flush failed: Resource temporarily
# unavailable" when the emulator's stdout is a non-blocking pipe that is momentarily full.
#
# Run from the repo root:  eval $(make -s env); python3 -I bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py
# Control (blocking fd, expected to pass): CONTROL_BLOCKING=1 python3 -I bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py
# Exits 1 and prints "BUG:" when the defect is present; exits 0 when the run completes.
import fcntl, os, subprocess, sys, tempfile, threading, time

NBYTES = 300000            # > 64 KiB pipe capacity
READER_DELAY = 4.0         # seconds the "host" does not drain stdout (transient backpressure)
TIMEOUT = 240

guest_cmd = "head -c %d /dev/zero | tr '\\0' x; echo; echo GUEST-DONE" % NBYTES

r, w = os.pipe()
# Make the write end non-blocking, as a libuv/Node.js parent would do on its pipes.
fl = fcntl.fcntl(w, fcntl.F_GETFL)
if os.environ.get("CONTROL_BLOCKING"): fl &= ~os.O_NONBLOCK; NB = 0
else: NB = os.O_NONBLOCK
fcntl.fcntl(w, fcntl.F_SETFL, fl | NB)

errf = tempfile.TemporaryFile()
proc = subprocess.Popen(["cartesi-machine.lua", "--ram-length=64Mi", "--", guest_cmd],
                        stdin=subprocess.DEVNULL, stdout=w, stderr=errf, close_fds=True)
os.close(w)

chunks = []
def reader():
    time.sleep(READER_DELAY)
    while True:
        b = os.read(r, 65536)
        if not b:
            break
        chunks.append(b)
t = threading.Thread(target=reader, daemon=True)
t.start()

try:
    rc = proc.wait(timeout=TIMEOUT)
except subprocess.TimeoutExpired:
    proc.kill()
    print("TIMEOUT: emulator did not finish")
    sys.exit(2)
t.join(timeout=10)
errf.seek(0)
err = errf.read().decode(errors="replace")
out = b"".join(chunks)
nx = out.count(b"x")
print("exit code:", rc, "| bytes of guest 'x' received:", nx, "| GUEST-DONE seen:", b"GUEST-DONE" in out)
tail = "\n".join(err.strip().splitlines()[-8:])
print("stderr tail:\n" + tail)

if "Resource temporarily unavailable" in err or "console output flush failed" in err:
    print("BUG: machine:run aborted with a console flush EAGAIN error on a non-blocking stdout "
          "(transient host backpressure killed the emulation run)")
    sys.exit(1)
if rc != 0 or nx < NBYTES or b"GUEST-DONE" not in out:
    print("BUG: emulator run did not complete correctly with non-blocking stdout")
    sys.exit(1)
print("OK: run completed and all console output was delivered")
sys.exit(0)
