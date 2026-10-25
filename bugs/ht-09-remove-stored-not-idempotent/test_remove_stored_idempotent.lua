-- remove_stored is not idempotent: an interrupted removal leaves a directory that
-- remove_stored can no longer remove, and that blocks clone_stored/rename_stored/store to that name.
local cartesi = require("cartesi")
-- Work in a fresh temporary directory (override with WORKDIR=...).
local base = os.getenv("WORKDIR")
if not base then
  local p = assert(io.popen("mktemp -d"))
  base = assert(p:read("l")); p:close()
end
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end
local function ls(d) local t = {}; local p = io.popen("ls -1 '"..d.."' 2>/dev/null"); for l in p:lines() do t[#t+1]=l end; p:close(); return t end
local src, dst, other = base.."/src_m", base.."/victim", base.."/other"
os.execute("rm -rf '"..src.."' '"..dst.."' '"..other.."'")
local m = cartesi.machine({ ram = { length = 1 << 20 } })
m:store(src); m:destroy()
local bugs = 0

-- Case A: crash after remove_stored unlinked its first file (data file of processor shadow)
cartesi.machine:clone_stored(src, dst)
local files = ls(dst)
print("stored files:", #files)
-- emulate the first unlink remove_stored performs: processor backing store data file
local first
for _, f in ipairs(files) do if f:match("^0000000000000000%-") and f:match("%.bin$") then first = f break end end
assert(first, "processor data file not found")
assert(os.remove(dst.."/"..first))
local ok, err = pcall(cartesi.machine.remove_stored, cartesi.machine, dst)
print("A: retry remove_stored:", ok, err)
print("A: directory still exists:", exists(dst), "files left:", #ls(dst))
if not ok and exists(dst) then
  print("BUG: remove_stored cannot finish a partially removed stored machine (aborts on first missing file: "..tostring(err)..")")
  bugs = bugs + 1
  local ok2, err2 = pcall(cartesi.machine.clone_stored, cartesi.machine, src, dst)
  print("A: clone_stored to same name:", ok2, err2)
  local ok3, err3 = pcall(function() cartesi.machine:clone_stored(src, other); cartesi.machine:rename_stored(other, dst) end)
  print("A: rename_stored to same name:", ok3, err3)
  if not ok2 and not ok3 then print("BUG: name stays blocked for clone_stored and rename_stored") end
end
os.execute("rm -rf '"..dst.."' '"..other.."'")

-- Case B: crash after remove_stored unlinked every file incl. config.json, before rmdir
cartesi.machine:clone_stored(src, dst)
for _, f in ipairs(ls(dst)) do assert(os.remove(dst.."/"..f)) end
local okb, errb = pcall(cartesi.machine.remove_stored, cartesi.machine, dst)
print("B: retry remove_stored on empty leftover dir:", okb, errb, "exists:", exists(dst))
if not okb and exists(dst) then
  print("BUG: remove_stored cannot remove the empty directory left after config.json was unlinked ("..tostring(errb)..")")
  bugs = bugs + 1
end
os.execute("rm -rf '"..src.."' '"..dst.."' '"..other.."'")
if not os.getenv("WORKDIR") then os.execute("rmdir '"..base.."'") end
if bugs > 0 then os.exit(1) end
print("OK: remove_stored is idempotent")
