local cartesi = require"cartesi"
local dir = arg[1]
do
  local m <close> = cartesi.machine({ram={length=256<<20}})
  m:store(dir)
end
local m <close> = cartesi.new():load(dir, nil, cartesi.SHARING_ALL)
local chunk = string.rep("\9\2\3\4\5\6\7\8", (1<<20)/8)
for i=0,255 do m:write_memory(cartesi.AR_RAM_START + i*(1<<20), chunk) end
