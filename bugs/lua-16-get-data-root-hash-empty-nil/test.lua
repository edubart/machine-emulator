local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end
local zeros = function(n) return string.rep("\0", n) end

-- 1. empty data should give pristine root (same as all-zero data)
for _, l in ipairs({3, 5, 12, 20}) do
  local ok, h = pcall(ht.get_data_root_hash, "", l)
  local ref = ht.get_data_root_hash(zeros(1 << l), l)
  if not ok then bug(("empty data, log2=%d raised %s"):format(l, tostring(h)))
  elseif h ~= ref then bug(("empty data, log2=%d returned %s, expected pristine %s"):format(l, tostring(h and cartesi.tohex(h)), cartesi.tohex(ref))) end
end

-- 2. A machine whose output nvram is all-zero: the machine's hash equals all-zeros root, not nil
local m = cartesi.machine({ ram = { length = 1 << 20 }, flash_drive = { { length = 4096, start = 0x80000000000000 } } })
local p = m:get_proof(0x80000000000000, 12)
local got = ht.get_data_root_hash("", 12)
if got ~= p.target_hash then bug("verifier comparing get_data_root_hash('',12) against machine proof target fails (got " .. tostring(got) .. ")") end
m:destroy()

-- 3. log2_root_size 63/64 with fitting data
for _, l in ipairs({63, 64}) do
  local ok, err = pcall(ht.get_data_root_hash, "a", l)
  if not ok then bug(("1-byte data, log2=%d rejected: %s"):format(l, tostring(err))) end
end

-- 4. log2_root_size < word size: 1 byte data in a 1-byte (log2=0) tree should either be rejected or return a well-defined hash
do
  local ok, h = pcall(ht.get_data_root_hash, "a", 0)
  local full = ht.get_data_root_hash("a", 3)
  if ok and h == full then bug("log2_root_size=0 (< word) silently returns the full-word hash instead of rejecting") end
  local ok2, h2 = pcall(ht.get_data_root_hash, "abcd", 2)
  if ok2 and h2 == ht.get_data_root_hash("abcd", 3) then bug("log2_root_size=2 (< word) silently returns the full-word hash") end
end
print(("%d bug(s)"):format(bugs))
os.exit(bugs == 0 and 0 or 1)
