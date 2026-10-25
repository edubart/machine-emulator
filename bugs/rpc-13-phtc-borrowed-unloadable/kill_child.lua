local cartesi = require"cartesi"
local m <close> = cartesi.new():load(arg[1], {}, cartesi.SHARING_ALL)
local chunk = string.rep("\1\2\3\4\5\6\7\8", 1 << 17) -- 1 MiB
for i = 0, tonumber(arg[2]) - 1 do m:write_memory(0x80000000 + i * (1 << 20), chunk) end
io.stderr:write("hashing\n"); io.stderr:flush()
m:get_root_hash()
io.stderr:write("done\n")
