-- Child: open the stored machine fully shared, then call clear_hash_tree (crash shim kills us mid-clear).
local cartesi = require"cartesi"
local dir, armed = arg[1], arg[2]
local m <close> = cartesi.new():load(dir, nil, cartesi.SHARING_ALL)
m:get_root_hash()
assert(io.open(armed, "w")):close() -- arm the crash injector
m:clear_hash_tree()
os.remove(armed)
io.stderr:write("child: clear_hash_tree completed without crash\n")
