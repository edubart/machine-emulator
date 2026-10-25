# gdb script: SIGKILL the inferior on the HIT-th hit of FUNC after the READY file exists
import gdb, os
FUNC = os.environ["KILL_FUNC"]; READY = os.environ["KILL_READY"]; HIT = int(os.environ.get("KILL_HIT", "1"))
gdb.execute("set breakpoint pending on"); gdb.execute("set pagination off"); gdb.execute("set confirm off")
class B(gdb.Breakpoint):
    hits = 0
    def stop(self):
        if os.path.exists(READY):
            B.hits += 1
            return B.hits >= HIT
        return False
B(FUNC)
gdb.execute("run")
if gdb.selected_inferior().pid:
    print("gdb: sending SIGKILL inside %s (hit %d)" % (FUNC, HIT))
    gdb.execute("signal SIGKILL")
