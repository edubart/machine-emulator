local cartesi = require("cartesi")
local dir = assert(arg[1])
local m = cartesi.machine({ ram = { length = 64 << 20 } })
m:store(dir .. "/m")
m = nil
collectgarbage()
io.stdout:write("stored; df:\n"); io.stdout:flush()
os.execute("df -k " .. dir .. " | tail -1; du -sk " .. dir .. "/m")
local sharing = cartesi.SHARING_ALL
local m2 = cartesi.machine(dir .. "/m", {}, sharing)
local ram = cartesi.AR_RAM_START or 0x80000000
local page = string.rep("\xAA", 4096)
local n = 0
for addr = ram, ram + (64 << 20) - 4096, 4096 do
  local ok2, err = pcall(m2.write_memory, m2, addr, page)
  if not ok2 then
    print("CHILD_ERROR after " .. n .. " pages: " .. tostring(err))
    os.exit(3)
  end
  n = n + 1
  if n % 2048 == 0 then io.stdout:write("pages written: " .. n .. "\n"); io.stdout:flush() end
end
print("CHILD_OK wrote " .. n .. " pages")
os.exit(0)
