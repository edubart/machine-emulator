# gdb script: stop the child inside hash_tree::update_sparse_tree right after the
# root sparse node gets marked=1 in the shared hash_tree.sht mapping, then SIGKILL it.
import gdb
gdb.execute("set pagination off")
gdb.execute("set breakpoint pending on")
gdb.execute("break cartesi::hash_tree::update_sparse_tree")
gdb.execute("run")
maps = gdb.execute("info proc mappings", to_string=True)
base = None
for line in maps.splitlines():
    if line.strip().endswith("hash_tree.sht"):
        base = int(line.split()[0], 16)
        break
assert base is not None, "sht mapping not found"
gdb.execute("delete")
gdb.execute("watch -l *(unsigned int*)(%d)" % (base + 64 + 28))
gdb.execute("continue")
v = int(gdb.parse_and_eval("*(unsigned int*)(%d)" % (base + 64 + 28)))
print("ROOT_MARKED_AT_KILL=%d" % v)
gdb.execute("kill")
