-- child: mode = phtc_size, concurrency; prints wall ms
local cartesi = require"cartesi"
local phtc, conc, iters = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3])
local function now() local f=io.popen("date +%s%N"); local t=tonumber(f:read("l")); f:close(); return t/1e6 end
local m = cartesi.machine({hash_tree={phtc_size=phtc}, ram={length=0x100000}}, {concurrency={update_hash_tree=conc}})
m:get_root_hash()
local t0 = now()
for i = 1, iters do m:write_memory(0x80001000, string.pack("<I8", i)); m:get_root_hash() end
local t1 = now()
print(string.format("%.1f", t1 - t0))
