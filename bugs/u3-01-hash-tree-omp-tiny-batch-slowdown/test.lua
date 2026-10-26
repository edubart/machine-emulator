-- Repro: hash_tree::return_updated_dirty_pages opens an OpenMP parallel region (all cores, libgomp
-- spin-wait) for tiny dirty-page batches (> max(ncores, lanes) pages). Under CPU contention each
-- collect_mcycle_root_hashes sample stalls in GOMP_parallel waiting for descheduled workers.
-- Run from repo root: eval $(make -s env); timeout 300 lua5.4 bugs/u3-01-hash-tree-omp-tiny-batch-slowdown/test.lua
-- Env: LOAD=<busy procs to add, default nproc>, SAMPLES=<default 300>, WORKDIR=<scratch dir>, CARTESI_IMAGES_PATH.
-- Exits 1 and prints BUG: when the default runtime is >10x slower than update_hash_tree=1; 0 otherwise.
io.stdout:setvbuf("no")
local cartesi = require"cartesi"
local function now() local f=io.open("/proc/uptime") local s=f:read("n") f:close() return s end
local images = os.getenv("CARTESI_IMAGES_PATH") or "/usr/share/cartesi-machine/images"
-- Scratch directory for the stored machine: $WORKDIR if set, else a fresh mktemp -d (removed on exit)
local own_dir = not os.getenv("WORKDIR")
local dir = os.getenv("WORKDIR") or io.popen("mktemp -d"):read("l")
local stored = dir .. "/m64"
local SAMPLES = tonumber(os.getenv("SAMPLES") or "300")
local LOG2P = 10

-- 1. build a small Linux machine, run it partway through boot, store it
os.execute("rm -rf " .. stored)
local cfg = {
  ram = { length = 64 << 20, backing_store = { data_filename = images .. "/linux.bin" } },
  dtb = { entrypoint = "while true; do echo hi > /dev/null; done" },
  flash_drive = { { backing_store = { data_filename = images .. "/rootfs.ext2" } } },
}
local m0 = cartesi.machine(cfg)
m0:run(10000000)
m0:store(stored)
m0 = nil collectgarbage()

-- 2. CPU load: one busy process per CPU, killed on exit (bounded by timeout anyway)
local ncpu = tonumber(io.popen("nproc"):read("l"))
local pidf = dir .. "/load.pids"
local LOAD = tonumber(os.getenv("LOAD") or ncpu)
os.execute(string.format("rm -f %s; for i in $(seq %d); do timeout 120 sh -c 'while :; do :; done' & echo $! >> %s; done; true", pidf, LOAD, pidf))
local function cleanup() os.execute("[ -f " .. pidf .. " ] && kill $(cat " .. pidf .. ") 2>/dev/null; rm -f " .. pidf) end

local function timed(rt, label)
  local m = cartesi.machine(stored, rt, cartesi.SHARING_NONE)
  m:get_root_hash()
  local mc = m:read_reg("mcycle")
  local t = now()
  local c = m:collect_mcycle_root_hashes(mc + SAMPLES * (1 << LOG2P), LOG2P, 0, 0)
  local dt = now() - t
  print(string.format("%-28s %d samples in %.3fs (%.3f ms/sample)", label, #c.hashes, dt, 1000*dt/#c.hashes))
  return dt, c.hashes
end

local ok, err = pcall(function()
  local t_def, h_def = timed({}, "default runtime (all cores)")
  local t_one, h_one = timed({ concurrency = { update_hash_tree = 1 } }, "update_hash_tree=1")
  assert(#h_def == #h_one)
  for i = 1, #h_def do assert(h_def[i] == h_one[i], "hash mismatch at " .. i) end
  local ratio = t_def / t_one
  print(string.format("ratio default/serial = %.1fx (ncpu=%d)", ratio, ncpu))
  if ratio > 10 then
    print(string.format("BUG: default hash-tree concurrency makes collect_mcycle_root_hashes %.0fx slower than serial under CPU load (OpenMP region for tiny batches)", ratio))
    return false
  end
  return true
end)
cleanup()
os.execute("rm -rf " .. stored)
if own_dir then os.execute("rm -rf " .. dir) end
if not ok then print("ERROR", err) os.exit(2) end
os.exit(err and 0 or 1)
