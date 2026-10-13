# Drives `cartesi-machine --gdb-fd=<fd>` with a minimal GDB remote-serial-protocol client and sends exactly what gdb
# sends for "break *addr" (optional) and for the tools/gdb/gdbinit `stepc N` macro (monitor stepc N; continue).
# usage: python3 -I driver.py <lua> <cartesi-machine.lua> <guest.bin> <yield-mcycle> <halt-mcycle>
# Cases:
#   control: stepc <yield-1> (one cycle before the automatic yield)
#   A:       stepc <yield> (the step ends exactly on the yield), no breakpoints
#   B:       stepc <yield> with a breakpoint inserted at an address that is never executed
# Fixed behaviour (and the control's): gdb gets a stop reply for the step; after stepc_clear + detach the run goes
# on, services the single yield once and halts. Bug: no stop reply; in A the CLI exits 0 at the yield printing the
# "final" hash of an unfinished machine, in B it re-services the same yield forever.
# exit 0 = fixed, 1 = bug reproduced, 2 = harness problem
import os
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time

# a SIGTERM (e.g. from timeout) unwinds through the finally blocks, which SIGKILL the CLI's session
signal.signal(signal.SIGTERM, lambda *_: sys.exit(2))

LUA, CM, BIN = sys.argv[1], sys.argv[2], sys.argv[3]
YIELD, HALT = int(sys.argv[4]), int(sys.argv[5])
REPLY_TIMEOUT = 10.0  # seconds to wait for the stop reply
LOOP_EVIDENCE = 1000  # the guest yields once: this many serviced yields prove the re-servicing loop


class Output:
    """Consumes the CLI output without storing it (case B can print ~10 MB/s): counts progress lines, keeps a tail."""

    def __init__(self, pipe):
        self.progress = 0
        self.tail = b""
        self.thread = threading.Thread(target=self._read, args=(pipe,), daemon=True)
        self.thread.start()

    def _read(self, pipe):
        carry = b""
        while True:
            chunk = pipe.read1(65536)
            if not chunk:
                break
            data = carry + chunk
            self.progress += data.count(b"Progress:") - carry.count(b"Progress:")
            carry = data[-16:]
            self.tail = (self.tail + chunk)[-65536:]

    def summary(self):
        self.thread.join(5)
        text = self.tail.decode(errors="replace").replace("\r", "\n")
        hashes = re.findall(r"^(\d+): 0x[0-9a-f]+$", text, re.M)
        return {"halted": re.search(r"^Halted", text, re.M) is not None,
                "last_hash_mcycle": int(hashes[-1]) if hashes else None, "progress": self.progress}


class Gdb:
    def __init__(self, sock):
        self.s = sock

    def send(self, d):
        self.s.sendall(("$%s#%02x" % (d, sum(d.encode()) % 256)).encode())
        while True:
            c = self.s.recv(1)
            if c == b"+":
                return
            if not c:
                raise EOFError("connection closed")

    def recv(self):
        while True:
            c = self.s.recv(1)
            if not c:
                raise EOFError("connection closed")
            if c == b"$":
                break
        buf = b""
        while True:
            c = self.s.recv(1)
            if not c:
                raise EOFError("connection closed")
            if c == b"#":
                break
            buf += c
        self.s.recv(2)
        self.s.sendall(b"+")
        return buf.decode()


def run_case(label, n, bp=None):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    fd = listener.fileno()
    os.set_inheritable(fd, True)
    cmd = [LUA, CM, "--ram-image=" + BIN, "--ram-length=64Ki", "--no-root-flash-drive", "--final-hash",
           "--gdb-fd=%d" % fd]
    proc = subprocess.Popen(cmd, pass_fds=[fd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    out = Output(proc.stdout)
    res = {"reply": None}
    try:
        sock = socket.create_connection(listener.getsockname(), timeout=30)
        listener.close()
        gdb = Gdb(sock)
        sock.sendall(b"+")
        if bp:
            gdb.send("Z0,%x,4" % bp)
            r = gdb.recv()
            assert r == "OK", r
        gdb.send("qRcmd," + ("stepc %d" % n).encode().hex())
        r = gdb.recv()
        assert r == "OK", r
        gdb.send("c")
        deadline = time.monotonic() + REPLY_TIMEOUT
        while time.monotonic() < deadline and out.progress < LOOP_EVIDENCE:
            if select.select([sock], [], [], 0.1)[0]:
                try:
                    res["reply"] = gdb.recv()
                except (EOFError, OSError):
                    res["reply"] = None  # the CLI closed the connection without a stop reply
                break
        if res["reply"] is not None:
            gdb.send("qRcmd," + b"stepc_clear".hex())
            gdb.recv()
            gdb.send("D")
            try:
                gdb.recv()
            except (EOFError, OSError):
                pass
        sock.close()
        try:
            # after a detach the run must go on to the halt; without a stop reply just see whether the CLI exits
            proc.wait(timeout=20 if res["reply"] is not None else 3)
            res["cli"] = "exit %d" % proc.returncode
        except subprocess.TimeoutExpired:
            res["cli"] = "still running (killed)"
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    res.update(out.summary())
    print("[%s] stepc %d%s" % (label, n, " with a breakpoint at 0x%x" % bp if bp else ", no breakpoints"))
    print("    gdb stop reply: %s; CLI: %s; halted: %s; progress yields serviced: %d; last hash line at mcycle %s" % (
        res["reply"] or "NONE", res["cli"], "yes" if res["halted"] else "no", res["progress"],
        res["last_hash_mcycle"]))
    res["fine"] = (res["reply"] is not None and res["cli"] == "exit 0" and res["halted"] and res["progress"] == 1
                   and res["last_hash_mcycle"] == HALT)
    return res


print("guest: automatic yield (progress) at mcycle %d, halts at mcycle %d" % (YIELD, HALT))
ctl = run_case("control", YIELD - 1)
if not ctl["fine"]:
    print("ERROR: the control step did not behave (harness problem)")
    sys.exit(2)
a = run_case("A", YIELD)
b = run_case("B", YIELD, 0x80000FF0)
bug = False
for label, r in (("A", a), ("B", b)):
    if r["fine"]:
        continue
    bug = True
    if r["reply"] is None and r["cli"] == "exit 0" and r["last_hash_mcycle"] == YIELD:
        print("  -> [%s] no stop reply; the CLI exited 0 at mcycle %d (halt is at %d) printing it as the final hash"
              % (label, YIELD, HALT))
    elif r["reply"] is None and r["progress"] > 1:
        print("  -> [%s] no stop reply; the CLI re-serviced the single yield %d times" % (label, r["progress"]))
    else:
        print("  -> [%s] the step onto the yield did not complete normally" % label)
if bug:
    print("BUG REPRODUCED: under --gdb, stepc onto an automatic-yield mcycle never completes")
    sys.exit(1)
print("OK: stepc onto an automatic-yield mcycle gets a stop reply and the run then halts normally")
sys.exit(0)
