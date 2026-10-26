-- Demonstrates that nearly every hash-tree update spins up an OpenMP team (default concurrency)
-- for a ~9-page batch, which is pathologically slow on a CPU-saturated host.
local dir = arg[0]:match("(.*/)") or "./"
local iters = 200
local nbusy = tonumber(os.getenv("NBUSY") or "4")
-- start busy loops to saturate the host CPUs (self-terminating after 60 s)
local pids = {}
for i = 1, nbusy do
  local f = io.popen("timeout 60 lua5.4 -e 'while true do end' >/dev/null 2>&1 & echo $!")
  pids[#pids+1] = f:read("l"); f:close()
end
local function run(env, phtc, conc)
  local cmd = string.format("%s timeout 120 lua5.4 %schild.lua %d %d %d", env, dir, phtc, conc, iters)
  local f = io.popen(cmd); local out = f:read("a"); f:close()
  return tonumber(out:match("([%d%.]+)")) or math.huge
end
local function median(env, phtc, conc)
  local t = {}
  for i = 1, 3 do t[i] = run(env, phtc, conc) end
  table.sort(t); return t[2]
end
local def = median("", 4096, 0)        -- defaults: phtc_size=4096, concurrency=omp_get_max_threads()
local small = median("", 8, 0)         -- phtc_size=8 caps batch at 8 -> serial update
local serial = median("", 4096, 1)     -- concurrency.update_hash_tree=1
local passive = median("OMP_WAIT_POLICY=passive", 4096, 0)
for _, p in ipairs(pids) do os.execute("kill " .. p .. " 2>/dev/null") end
print(string.format("%d x (write_memory + get_root_hash), %d busy loops, wall ms:", iters, nbusy))
print(string.format("  default (phtc=4096, concurrency=auto) : %8.1f", def))
print(string.format("  phtc_size=8                           : %8.1f", small))
print(string.format("  concurrency.update_hash_tree=1        : %8.1f", serial))
print(string.format("  default + OMP_WAIT_POLICY=passive     : %8.1f", passive))
local ratio = def / math.max(serial, 1)
print(string.format("  slowdown default/serial = %.1fx", ratio))
if ratio > 5 then
  print("BUG: tiny hash-tree update batches (~9 dirty pages) run an OpenMP parallel region; " ..
        "default config is " .. string.format("%.1f", ratio) .. "x slower than serial on a busy host")
  os.exit(1)
end
print("OK")
