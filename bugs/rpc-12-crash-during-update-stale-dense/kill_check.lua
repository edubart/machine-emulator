local cartesi = require"cartesi"
local m <close> = cartesi.new():load(arg[1], nil, cartesi.SHARING_NONE)
print(cartesi.tohex(m:get_root_hash()))
