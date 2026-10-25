-- Loads a stored machine with shared backing stores and updates its hash tree.
local cartesi = require"cartesi"
local m = cartesi.new():load(arg[1], {}, cartesi.SHARING_ALL)
m:write_memory(cartesi.AR_RAM_START, string.rep("X", 4096))
m:get_root_hash()
print("child finished (should have been killed)")
