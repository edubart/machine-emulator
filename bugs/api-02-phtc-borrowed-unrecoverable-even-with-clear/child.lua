local cartesi = require("cartesi")
local dir, seed = arg[1], tonumber(arg[2])
local m = cartesi.machine(dir, {}, cartesi.SHARING_ALL)
math.randomseed(seed)
local chunk = {}
for i = 1, 4096 do chunk[i] = string.char(math.random(0, 255)) end
local big = string.rep(table.concat(chunk), 256) -- 1 MiB
local n = 0
io.stderr:write("R\n")
while true do
    n = n + 1
    for off = 0, (64 << 20) - 1, 1 << 20 do
        m:write_memory(0x80000000 + off, string.char((off >> 20) + n & 255) .. big:sub(2))
    end
    m:get_root_hash()
end
