-- Test: --dump-memory-ranges=<dir> must create exactly <dir> (no shell word splitting / injection).
-- Usage (from repo root): lua5.4 bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua [workdir]
-- Without a workdir argument, a fresh temporary directory is used.
local base = arg[1]
if not base then
    local p = assert(io.popen("mktemp -d"))
    base = p:read("l")
    p:close()
end
local tmp = base .. "/run"
os.execute("rm -rf '" .. tmp .. "' && mkdir -p '" .. tmp .. "'")
local function exists(p) local f = io.open(p, "rb"); if f then f:close() return true end return false end
local bad = false
-- 1. space in name
local dir = tmp .. "/dm x"
local cmd = string.format("cd '%s' && timeout 60 cartesi-machine.lua --ram-length=32Mi --max-mcycle=0 '--dump-memory-ranges=%s' > out1.txt 2>&1",
    tmp, dir)
local ok = os.execute(cmd)
local out = io.open(tmp .. "/out1.txt"):read("a")
local dumped = exists(dir .. "/0000000000000000--0000000000008000.bin")
local split = exists(tmp .. "/x") or exists(tmp .. "/dm")
if not ok or not dumped or split then
    bad = true
    print(string.format("BUG: --dump-memory-ranges='%s' exit_ok=%s dumped=%s stray_dirs(dm/x)=%s", dir, tostring(ok), tostring(dumped), tostring(split)))
    for l in out:gmatch("[^\n]+") do if l:find("No such") or l:find("error") or l:find("traceback") then print("  " .. l) end end
end
-- 2. shell metacharacter injection
local dir2 = tmp .. "/d2;touch " .. tmp .. "/INJECTED"
cmd = string.format("cd '%s' && timeout 60 cartesi-machine.lua --ram-length=32Mi --max-mcycle=0 '--dump-memory-ranges=%s' > out2.txt 2>&1", tmp, dir2)
os.execute(cmd)
if exists(tmp .. "/INJECTED") then
    bad = true
    print("BUG: shell command injected through --dump-memory-ranges: file INJECTED was created by 'touch'")
end
if bad then os.exit(1) end
print("OK")
