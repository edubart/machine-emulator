local cartesi = require"cartesi"
local dir = arg[1]
local m = cartesi.new()
m:load(dir, nil, cartesi.SHARING_ALL)
io.stderr:write("child: boundary root ", cartesi.tohex(m:get_root_hash()), "\n")
-- simulate an input: write a page and run some cycles
m:write_memory(0x80000000 + 5*4096, string.rep("\x13\x00\x00\x00", 1024)) -- nops
m:run(m:read_reg("mcycle") + 5000)
io.stderr:write("child: mcycle ", m:read_reg("mcycle"), " calling get_root_hash\n")
m:get_root_hash()
io.stderr:write("child: not killed?\n")
