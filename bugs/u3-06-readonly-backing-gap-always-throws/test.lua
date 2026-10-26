-- Repro: read-only flash drive longer than its page-aligned backing image always fails.
local cartesi = require("cartesi")
local dir = arg[0]:match("(.*/)") or "./"
local img = dir .. "ro.bin"
-- 8 KiB page-aligned image with deterministic non-zero content
local f = assert(io.open(img, "wb"))
local t = {}
for i = 1, 8192 do t[i] = string.char((i * 7) % 251 + 1) end
f:write(table.concat(t)); f:close()

local function try(len, ro)
  local ok, m = pcall(cartesi.machine, {
    ram = { length = 1 << 20 },
    flash_drive = { { start = 0x80000000000000, length = len, read_only = ro, backing_store = { data_filename = img } } },
  }, {})
  print(string.format("length=%d read_only=%s -> %s %s", len, tostring(ro), ok and "OK" or "FAIL", ok and "" or tostring(m)))
  return ok, m
end

local ok8 = try(8192, true)
local okrw, mrw = try(16384, false)
local okro, mro = try(16384, true)
os.remove(img)
assert(ok8 and okrw, "control cases unexpectedly failed")
if okrw then
  -- sanity: check gap is zero and image content is intact for rw case
  local d = mrw:read_memory(0x80000000000000, 16384)
  assert(d:sub(1, 8192) == table.concat(t) and d:sub(8193) == string.rep("\0", 8192))
end
if not okro then
  print("BUG: read-only flash drive of 16 KiB backed by page-aligned 8 KiB image rejected: " .. tostring(mro))
  os.exit(1)
end
local d = mro:read_memory(0x80000000000000, 16384)
if d:sub(1, 8192) ~= table.concat(t) or d:sub(8193) ~= string.rep("\0", 8192) then
  print("BUG: read-only mapping content wrong"); os.exit(1)
end
print("OK: read-only gap mapping works")
os.exit(0)
