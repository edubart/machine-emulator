-- Child: load stored machine in place (SHARING_ALL), dirty some RAM pages, compute root hash.
local cartesi = require"cartesi"
local dir = arg[1]
local m = cartesi.new()
m:load(dir, nil, cartesi.SHARING_ALL)
local page = string.rep("\xAB", 4096)
for p = 0, 63 do m:write_memory(0x80000000 + p * 4096 * 7, page) end
io.stderr:write("child: calling get_root_hash\n")
m:get_root_hash() -- will be SIGKILLed inside this call by gdb
io.stderr:write("child: not killed?\n")
