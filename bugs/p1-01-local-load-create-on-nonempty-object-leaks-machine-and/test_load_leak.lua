-- Repro: local cm_load / cm_create on a non-empty machine object leaks the old
-- machine (with its backing-file flocks, fds and mappings).
-- Expected (fixed): second load/create on a non-empty object is rejected (as the
-- JSON-RPC server does with "machine exists"), or the old machine is released.
-- Run from the repo root:
--   eval $(make -s env); lua5.4 bugs/p1-01-local-load-create-on-nonempty-object-leaks-machine-and/test_load_leak.lua
-- Exits 1 and prints BUG: lines while the defect is present; exits 0 once fixed.
local cartesi = require("cartesi")

-- Scratch directory for the stored machines (override with WORKDIR); removed at the end.
local base = os.getenv("WORKDIR") or io.popen("mktemp -d"):read("l")
os.execute("rm -rf " .. base .. " && mkdir -p " .. base)
local A, B, C = base .. "/A", base .. "/B", base .. "/C"

local function count_fds()
    -- count fds of this Lua process via /proc/<pid>/fd: get our pid from /proc/self/stat
    local f = io.open("/proc/self/stat"); local pid = f:read("*l"):match("^(%d+)"); f:close()
    local q = io.popen("ls /proc/" .. pid .. "/fd | wc -l")
    local n = tonumber(q:read("*l")); q:close()
    return n
end

local function vmsize_kb()
    local f = io.open("/proc/self/status"); local s = f:read("*a"); f:close()
    return tonumber(s:match("VmSize:%s*(%d+)"))
end

local config = { ram = { length = 1 << 20 }, dtb = {} }
local m0 = cartesi.machine(config)
m0:store(A)
m0:store(B)
m0:destroy()

local bugs = 0

-- Scenario 1: load on a non-empty object
local M = cartesi.new()
M:load(A, nil, cartesi.SHARING_ALL)
local ok2, err2 = pcall(M.load, M, B, nil, cartesi.SHARING_ALL)
print("second load on non-empty object:", ok2, err2)
M:destroy()
print("is_empty after destroy:", M:is_empty())

local okc, errc = pcall(M.clone_stored, M, A, C)
print("clone_stored(A,C) after destroy:", okc, errc)
local N = cartesi.new()
local okl, errl = pcall(N.load, N, A, nil, cartesi.SHARING_ALL)
print("fresh load(A, SHARING_ALL) after destroy:", okl, errl)
if okl then N:destroy() end
if ok2 and (not okc or not okl) then
    print("BUG: second load() on non-empty local machine succeeded and leaked the first machine; " ..
        "stored machine A remains locked after destroy(): " .. tostring(not okc and errc or errl))
    bugs = bugs + 1
end

-- Scenario 2: create on a non-empty object, measure fd growth
local fds0 = count_fds()
local vm0 = vmsize_kb()
local P = cartesi.new()
P:create(config)
local leaked = 0
for i = 1, 5 do
    local ok = pcall(P.create, P, config)
    if ok then leaked = leaked + 1 end
end
P:destroy()
collectgarbage(); collectgarbage()
local fds1 = count_fds()
local vm1 = vmsize_kb()
print(string.format("VmSize before=%d KiB after destroy=%d KiB (leaked %d KiB)", vm0, vm1, vm1 - vm0))
print(string.format("create() repeated on non-empty object succeeded %d times; fds before=%d after destroy=%d",
    leaked, fds0, fds1))
if leaked > 0 and fds1 > fds0 then
    print(string.format("BUG: create() on non-empty local machine leaks the previous machine (%d fds leaked)",
        fds1 - fds0))
    bugs = bugs + 1
elseif leaked > 0 then
    print("BUG: create() on non-empty local machine silently accepted (old machine leaked)")
    bugs = bugs + 1
end

-- Scenario 3: load loop, fd growth
local fdsL0 = count_fds()
local Q = cartesi.new()
Q:load(B)
local nok = 0
for i = 1, 5 do
    if pcall(Q.load, Q, B) then nok = nok + 1 end
end
Q:destroy()
collectgarbage(); collectgarbage()
local fdsL1 = count_fds()
print(string.format("load() repeated %d times; fds before=%d after destroy=%d", nok, fdsL0, fdsL1))
if nok > 0 and fdsL1 > fdsL0 then
    print(string.format("BUG: repeated load() leaks %d fds that destroy() never releases", fdsL1 - fdsL0))
    bugs = bugs + 1
end

os.execute("rm -rf " .. base)
if bugs > 0 then os.exit(1) end
print("OK: no leak")
os.exit(0)
