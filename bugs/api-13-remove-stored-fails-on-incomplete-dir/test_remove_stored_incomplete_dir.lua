-- remove_stored on incomplete stored machine directories
local cartesi = require("cartesi")
local W = arg[1] or os.getenv("W") or os.getenv("TMPDIR") or "/tmp"
local function sh(c) local p = io.popen(c) local o = p:read("a") p:close() return o end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local function ls(d) return (sh("ls -1 " .. d .. " 2>/dev/null"):gsub("\n", " ")) end
local fail = false

local base = W .. "/api-13-remove-stored-tmpdirs"
sh("chmod -R u+w " .. base .. " 2>/dev/null; rm -rf " .. base .. "; mkdir -p " .. base)

local config = {
  ram = { length = 1 << 20 },
  processor = { registers = { iunrep = 0 } },
}
local m = cartesi.machine(config)

-- Case 1: store, then simulate an interrupted store by deleting one data file
local dir = base .. "/m1"
m:store(dir)
local victim = sh("ls -1 " .. dir .. "/*.bin | head -1"):gsub("\n", "")
sh("chmod u+w " .. dir .. "; rm -f '" .. victim .. "'")
print("case1: deleted " .. victim)
for i = 1, 2 do
  local ok, err = pcall(m.remove_stored, m, dir)
  print(string.format("case1: remove_stored #%d ok=%s err=%s", i, tostring(ok), tostring(err)))
  print("case1:   remaining: " .. ls(dir))
end
if exists(dir .. "/config.json") then
  print("BUG: remove_stored cannot remove a stored machine dir with a missing file; config.json remains and the dir is permanently unremovable via API")
  fail = true
  local ok, err = pcall(m.store, m, dir)
  print("case1: store() into same dir ok=" .. tostring(ok) .. " err=" .. tostring(err))
end

sh("chmod -R u+w " .. base .. " 2>/dev/null; rm -rf " .. base)
os.exit(fail and 1 or 0)
