-- Requires gdb. Run from the repo root: eval $(make -s env); lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test-boundary.lua
-- PRT-style recovery check: a machine stored at a committed boundary (root H0) is loaded in place with
-- SHARING_ALL, an "input" is applied (page write + 5000 cycles), and the process is SIGKILLed inside the
-- first hash-tree update. On reopen the root hash still equals H0 although mcycle has advanced.
-- Exits 1 and prints "BUG:" while the defect is present.
local cartesi = require"cartesi"
local here = arg[0]:match("^(.*)/") or "."
local tmp = os.getenv("TMPDIR_POC") or io.popen("mktemp -d"):read("l")
local dir = tmp .. "/st"
local gdblog = tmp .. "/gdb.log"
os.execute("rm -rf '" .. dir .. "'")
local H0
do
  local m = cartesi.machine{ ram = { length = 4 << 20 } }
  H0 = m:get_root_hash()
  m:store(dir); m:destroy()
end
collectgarbage(); collectgarbage()
-- expected after child actions
local expected, exp_mcycle
do
  local m = cartesi.new(); m:load(dir, nil, cartesi.SHARING_NONE)
  m:write_memory(0x80000000 + 5*4096, string.rep("\x13\x00\x00\x00", 1024))
  m:run(m:read_reg("mcycle") + 5000)
  expected = m:get_root_hash(); exp_mcycle = m:read_reg("mcycle"); m:destroy()
end
local gdb = "timeout 120 gdb -q -batch -nx -ex 'set breakpoint pending on' -ex 'break cm_get_root_hash' -ex run -ex continue " ..
  "-ex 'break cartesi::hash_tree::update_dense_trees' -ex continue -ex 'python import os,signal; os.kill(gdb.selected_inferior().pid, signal.SIGKILL)' -ex 'echo KILLED\\n' " ..
  "--args lua5.4 '" .. here .. "/child-boundary.lua' '" .. dir .. "' > '" .. gdblog .. "' 2>&1"
os.execute(gdb)
local log = io.open(gdblog):read("a")
assert(log:find("KILLED",1,true) and not log:find("not killed",1,true), log)
-- "reopen" like prt.lua: load in place and compare with the committed boundary hash
local m = cartesi.new(); m:load(dir, nil, cartesi.SHARING_ALL)
local r = m:get_root_hash()
print("reloaded root == committed boundary H0:", r == H0, " mcycle:", m:read_reg("mcycle"), " expected mcycle:", exp_mcycle)
print("reloaded root == true state root:", r == expected, " verify_hash_tree:", m:verify_hash_tree())
m:destroy()
m = cartesi.new(); m:load(dir, nil, cartesi.SHARING_NONE); m:clear_hash_tree()
local rebuilt = m:get_root_hash()
print("rebuild == true state:", rebuilt == expected)
m:destroy()
if r ~= expected and rebuilt == expected then
  print(string.format("BUG: reloaded machine (mcycle %d) reports %s root hash; verify_hash_tree did not detect it",
    exp_mcycle, r == H0 and "the committed boundary (pre-input)" or "a stale"))
  os.exit(1)
end
print("OK")
os.exit(0)
