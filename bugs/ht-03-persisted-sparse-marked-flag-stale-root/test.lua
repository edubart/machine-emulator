-- ht-03: transient sparse-node "marked" flag persisted in shared hash_tree.sht and accepted on load.
-- Part A (needs gdb): SIGKILL a SHARING_ALL process inside update_sparse_tree right after it set the root's
--   marked flag (hardware watchpoint), then reload and compare root hash with a freshly built machine.
-- Part B (always): same state reached by patching the root node's marked field (offset 64+28) to 1.
local cartesi = require"cartesi"
local here = (arg[0]:match("^(.*)/") or ".")
local work = os.getenv("WORK") or (here .. "/tmp-run")
os.execute("rm -rf '" .. work .. "' && mkdir -p '" .. work .. "'")
local function sh(c) return os.execute(c) end

local base = work .. "/base"
do
  local m = cartesi.machine({ram={length=1<<20}})
  m:get_root_hash(); m:store(base, cartesi.SHARING_ALL); m:destroy()
end

local function root_marked(dir)
  local f = assert(io.open(dir .. "/hash_tree.sht", "rb")); f:seek("set", 64 + 28)
  local v = string.unpack("<I4", f:read(4)); f:close(); return v
end

local function check(dir, label)
  local l = cartesi.new():load(dir, {}, cartesi.SHARING_ALL)
  local ref = cartesi.machine({ram={length=1<<20}})
  ref:write_memory(cartesi.AR_RAM_START, "hello")
  local bad = false
  local function cmp(stage)
    local a, b = l:get_root_hash(), ref:get_root_hash()
    local ok = a == b
    print(string.format("[%s] %-22s root_ok=%s verify_hash_tree=%s", label, stage, tostring(ok), tostring(l:verify_hash_tree())))
    if not ok then bad = true end
  end
  cmp("after reload")
  for i, s in ipairs{"world", "again"} do
    l:write_memory(cartesi.AR_RAM_START + 8192, s); ref:write_memory(cartesi.AR_RAM_START + 8192, s)
    cmp("after write " .. i)
  end
  local ok_final = l:get_root_hash() == ref:get_root_hash()
  l:destroy(); ref:destroy()
  return bad, ok_final
end

local failed = false

-- Part A
if sh("command -v gdb >/dev/null 2>&1") then
  local run = work .. "/killed"
  sh("cp -a '" .. base .. "' '" .. run .. "'")
  sh(string.format("timeout 120 gdb -q -batch -x '%s/kill.py' --args lua5.4 '%s/child2.lua' '%s' >'%s/gdb.log' 2>&1",
    here, here, run, work))
  local mk = root_marked(run)
  print("[A] root marked flag on disk after SIGKILL inside update_sparse_tree: " .. mk)
  if mk == 1 then
    local bad, ok_final = check(run, "A")
    if bad then
      failed = true
      print("BUG: after a real SIGKILL inside update_sparse_tree, the reloaded SHARING_ALL machine reports a wrong root hash"
        .. (ok_final and "" or " that stays wrong after further writes") .. ", while verify_hash_tree still says true")
    end
  else
    print("[A] could not reproduce kill point (see " .. work .. "/gdb.log); skipping part A")
  end
else
  print("[A] gdb not found, skipping part A")
end

-- Part B
do
  local run = work .. "/patched"
  sh("cp -a '" .. base .. "' '" .. run .. "'")
  -- reproduce on-disk contents of the killed run: RAM has "hello", root marked=1
  do
    local m = cartesi.new():load(run, {}, cartesi.SHARING_ALL)
    m:write_memory(cartesi.AR_RAM_START, "hello"); m:get_root_hash(); m:destroy()
  end
  local f = assert(io.open(run .. "/hash_tree.sht", "r+b")); f:seek("set", 64 + 28); f:write(string.pack("<I4", 1)); f:close()
  -- note: here the root hash was correct before patching; only the stale flag is injected
  local l = cartesi.new():load(run, {}, cartesi.SHARING_ALL)
  local ref = cartesi.machine({ram={length=1<<20}}); ref:write_memory(cartesi.AR_RAM_START, "hello")
  print("[B] after reload        root_ok=" .. tostring(l:get_root_hash() == ref:get_root_hash()))
  l:write_memory(cartesi.AR_RAM_START + 8192, "world"); ref:write_memory(cartesi.AR_RAM_START + 8192, "world")
  local ok = l:get_root_hash() == ref:get_root_hash()
  print("[B] after write         root_ok=" .. tostring(ok) .. " verify_hash_tree=" .. tostring(l:verify_hash_tree()))
  if not ok then
    failed = true
    print("BUG: a persisted marked=1 on the root sparse node is accepted on load and freezes the root hash (write ignored)")
  end
end

os.execute("rm -rf '" .. work .. "'")
os.exit(failed and 1 or 0)
