local cartesi = require"cartesi"
local m = cartesi.new():create{ram={length=1<<20}}
local bugs = 0
local ref = m:read_virtual_memory(-8192, 4096)
print("read(-8192,4096) nonzero bytes:", ref:find("[^%z]") and "yes" or "no")
-- Read a big range so heap garbage is likely; also check a write->read roundtrip-free invariant:
for _, len in ipairs{4096, 65536} do
  local r = m:read_virtual_memory(-len, len)
  -- the range [-len, 2^64) is unmapped (same as -8192), so must read zeros (or error)
  local i = r:find("[^%z]")
  print(("read(%d,%d) first nonzero byte at: %s"):format(-len, len, tostring(i)))
  if i then print(("BUG: read_virtual_memory(%d,%d) returned uninitialized host heap bytes"):format(-len, len)); bugs = bugs + 1 end
end
local okref = pcall(m.write_virtual_memory, m, -8192, ("A"):rep(4096))
local ok = pcall(m.write_virtual_memory, m, -4096, ("A"):rep(4096))
print("write(-8192) ok:", okref, "write(-4096) ok:", ok)
if ok and not okref then print("BUG: write_virtual_memory(-4096,4096) reports success but writes nothing"); bugs = bugs + 1 end
os.exit(bugs == 0 and 0 or 1)
