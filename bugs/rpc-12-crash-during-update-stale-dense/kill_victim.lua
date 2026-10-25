local cartesi = require"cartesi"
local m <close> = cartesi.new():load(arg[1], nil, cartesi.SHARING_ALL)
io.stderr:write("loaded\n"); io.stderr:flush()
local t=os.clock()
local h = m:get_root_hash()
io.stderr:write("done\n")
print(cartesi.tohex(h))
