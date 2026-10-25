local cartesi = require"cartesi"
local m = cartesi.new():load(arg[1], {}, cartesi.SHARING_ALL)
m:write_memory(cartesi.AR_RAM_START, "hello")
m:get_root_hash()
print("child finished without being killed")
