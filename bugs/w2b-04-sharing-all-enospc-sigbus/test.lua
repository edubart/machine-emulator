-- Driver: runs child.lua in a private mount namespace with a 60 MiB tmpfs.
-- Needs root (unshare -m, mount). Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/w2b-04-sharing-all-enospc-sigbus/test.lua
-- Exit 1 = bug reproduced (child killed by SIGBUS), 0 = fixed, 2 = could not run.
local here = arg[0]:match("^(.*)/") or "."
local mnt = os.getenv("TMPDIR_MNT") or (here .. "/mnt")
os.execute("mkdir -p " .. mnt)
local cmd = string.format(
  "timeout 120 unshare -m sh -c 'mount -t tmpfs -o size=60m tmpfs %s && lua5.4 %s/child.lua %s; echo EXIT=$?' 2>&1",
  mnt, here, mnt)
local p = io.popen(cmd)
local out = p:read("a"); p:close()
os.execute("rmdir " .. mnt .. " 2>/dev/null")
io.write(out)
local code = tonumber(out:match("EXIT=(%d+)"))
if code == nil then print("could not run test (unshare/mount unavailable?)"); os.exit(2) end
if code == 135 or code == 128 + 7 then
  print("BUG: process killed by SIGBUS (exit " .. code .. ") on write_memory to SHARING_ALL machine when disk fills; no error returned")
  os.exit(1)
elseif code == 3 then
  print("OK: write_memory reported an error instead of crashing")
  os.exit(0)
elseif code == 0 then
  print("OK: all pages written (space preallocated)")
  os.exit(0)
else
  print("unexpected exit code " .. code); os.exit(4)
end
