import gdb, os
gdb.execute("set pagination off")
gdb.execute("set breakpoint pending on")
state = {"armed": False}
class BP(gdb.Breakpoint):
    def stop(self):
        if state["armed"]: return False
        pid = gdb.selected_inferior().pid
        base = None
        for line in open(f"/proc/{pid}/maps"):
            if line.rstrip().endswith("hash_tree.sht"):
                base = int(line.split("-")[0], 16); break
        if base is None: return False
        state["armed"] = True
        addr = base + 64 + 28  # sparse node 1 (root): offsetof(node_type, marked) == 28, sizeof == 64
        gdb.write(f"watching root marked flag at {addr:#x}\n")
        gdb.execute(f"watch -l *(unsigned int*){addr:#x} if *(unsigned int*){addr:#x} == 1")
        return False
BP("cartesi::hash_tree::update_sparse_tree")
def on_stop(ev):
    if isinstance(ev, gdb.BreakpointEvent) and state["armed"]:
        gdb.write("root marked=1 inside update_sparse_tree: SIGKILL\n")
        gdb.execute("bt 3")
        gdb.execute("signal SIGKILL")
gdb.events.stop.connect(on_stop)
gdb.execute("run")
