-- Child: load stored machine with SHARING_ALL, dirty all RAM, signal readiness, then hash.
local cartesi = require"cartesi"
local dir, ready, done = arg[1], arg[2], arg[3]
local m = cartesi.machine(dir, {concurrency={update_hash_tree=1}}, cartesi.SHARING_ALL)
m:write_memory(cartesi.AR_RAM_START, string.rep("\7", 64<<20))
io.open(ready, "w"):close()
m:get_root_hash()          -- parent SIGKILLs us somewhere in here
io.open(done, "w"):close()
