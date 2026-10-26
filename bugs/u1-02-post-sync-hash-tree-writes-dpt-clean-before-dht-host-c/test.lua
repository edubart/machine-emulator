-- Simulates a host crash with arbitrary page-cache writeback order after
-- sync_stored + get_root_hash on a SHARING_ALL machine.
-- S = directory content right after sync_stored (what is durable)
-- U = directory content after the subsequent get_root_hash (dirty page cache)
-- A crash can leave any per-file mix of S and U on disk. Each mix represents the
-- same machine state, so every mix must reload with the root hash R.
local cartesi = require("cartesi")
local W = arg[1] or ((os.getenv("TMPDIR") or "/tmp") .. "/cm-bug-u1-02-test")
local function sh(c) assert(os.execute(c), c) end
local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
sh("rm -rf " .. W .. " && mkdir -p " .. W)

-- tiny RV64 program: store to N consecutive pages starting at 0x80100000, then halt via HTIF
local function addi(rd, rs1, imm) return ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13 end
local function slli(rd, rs1, sh_) return (sh_ << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13 end
local function lui(rd, imm) return ((imm & 0xfffff) << 12) | (rd << 7) | 0x37 end
local function add(rd, rs1, rs2) return (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33 end
local function sd(rs2, off, rs1) return ((off >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((off & 31) << 7) | 0x23 end
local function blt(rs1, rs2, off) local imm = off & 0x1fff
  return (((imm>>12)&1)<<31)|(((imm>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|(4<<12)|(((imm>>1)&0xf)<<8)|(((imm>>11)&1)<<7)|0x63 end
local N = 1500 -- more pages than the TLB holds, so evictions mark pages dirty in the .dpt during the run
local P = {
  addi(29, 0, 1), slli(29, 29, 31),        -- t4 = 0x80000000
  lui(28, 0x100), add(28, 28, 29),         -- t3 = 0x80100000
  lui(30, 1),                              -- t5 = 4096
  addi(7, 0, 0), addi(6, 0, N),            -- t2 = 0, t1 = N
  addi(7, 7, 1), sd(7, 0, 28), add(28, 28, 30), blt(7, 6, -12), -- loop
  addi(5, 0, 1),                           -- t0 = 1 (htif halt: dev 0, cmd 0, data 1)
  lui(31, 0x40008), sd(5, 0, 31),          -- tohost = 1
  0x0000006f,                              -- j .
}
local prog = {}
for _, i in ipairs(P) do prog[#prog + 1] = string.pack("<I4", i) end
local pf = assert(io.open(W .. "/p.bin", "wb")); pf:write(table.concat(prog)); pf:close()

local base = cartesi.machine({ ram = { length = 8 << 20, backing_store = { data_filename = W .. "/p.bin" } } })
base:store(W .. "/base")
base:destroy()

cartesi.machine:clone_stored(W .. "/base", W .. "/w")
local m = cartesi.machine(W .. "/w", nil, cartesi.SHARING_ALL)
m:get_root_hash()              -- hash tree up to date at load
m:run(1 << 20)
assert(m:read_reg("iflags_H") ~= 0, "machine did not halt")
m:sync_stored(W .. "/w")       -- node commits the directory
sh("cp -a " .. W .. "/w " .. W .. "/S")
local R = m:get_root_hash()    -- node then queries the root hash of the committed state
sh("cp -a " .. W .. "/w " .. W .. "/U")
print("R (root hash of the committed state) = " .. hex(R))

local diffs = {}
local p = io.popen("cd " .. W .. "/S && for f in *; do cmp -s \"$f\" \"../U/$f\" || echo \"$f\"; done")
for l in p:lines() do diffs[#diffs + 1] = l end
p:close()
print("files rewritten by get_root_hash after sync_stored: " .. table.concat(diffs, " "))

local bad = 0
for mask = 0, (1 << #diffs) - 1 do
  local d = W .. "/mix" .. mask
  sh("rm -rf " .. d .. " && cp -a " .. W .. "/S " .. d)
  local names = {}
  for i = 1, #diffs do
    if mask & (1 << (i - 1)) ~= 0 then
      sh("cp " .. W .. "/U/" .. diffs[i] .. " " .. d .. "/")
      names[#names + 1] = diffs[i]
    end
  end
  local ok, mm = pcall(cartesi.machine, d)
  local res, good
  if not ok then
    res, good = "LOAD FAILED: " .. tostring(mm), false
  else
    local h = mm:get_root_hash()
    local v = mm:verify_hash_tree()
    good = (h == R) and v
    res = hex(h) .. " verify_hash_tree=" .. tostring(v)
    mm:destroy()
  end
  print(string.format("%s from U={%s}: %s", good and "ok " or "BAD", table.concat(names, ","), res))
  if not good then bad = bad + 1 end
  sh("rm -rf " .. d)
end
m:destroy()
if bad > 0 then
  print(string.format("BUG: %d of %d possible post-crash file mixes of a synced SHARING_ALL directory reload with a wrong root hash; get_root_hash after sync_stored marked .dpt pages clean while their new .dht hashes were not yet durable", bad, 1 << #diffs))
  os.exit(1)
end
print("OK: every post-crash mix reloads with root hash R")
os.exit(0)
