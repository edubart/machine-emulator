-- Run under umask 022 (the script re-execs itself via sh to force it).
if os.getenv("FMODE_UMASK_SET") ~= "1" then
    local self = arg[0]
    local ok, _, rc = os.execute("umask 022; FMODE_UMASK_SET=1 timeout 120 lua5.4 '" .. self .. "'")
    os.exit(ok and 0 or (rc or 1))
end
local cartesi = require("cartesi")
local hash_tree = require("cartesi.hash-tree")
local fs = require("cartesi.filesystem")

local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
local function mode(p)
    local h = assert(io.popen("stat -c %a '" .. p .. "'")); local m = h:read("l"); h:close(); return m
end
local bugs = {}
local function check(label, path, expected)
    local m = mode(path)
    print(string.format("%-60s mode %s (expected %s)", label, m, expected))
    if m ~= expected then bugs[#bugs + 1] = label .. ": mode " .. m .. ", expected " .. expected end
end

-- 1. Baseline: ordinary writes (fs.write_file / io.open) follow umask -> 644
fs.write_file("x", dir .. "/plain")
check("fs.write_file (baseline)", dir .. "/plain", "644")

-- 2. hash_tree.frontier_store into a new file
local f = hash_tree.frontier(4, "keccak256")
hash_tree.frontier_push_back(f, cartesi.keccak256("leaf"))
hash_tree.frontier_store(f, dir .. "/new_frontier.json")
check("hash_tree.frontier_store, new file", dir .. "/new_frontier.json", "644")

-- 3. frontier_store over an existing 0644 file (replaces it with whatever mode the temp file had)
fs.write_file("old", dir .. "/existing_frontier.json")
hash_tree.frontier_store(f, dir .. "/existing_frontier.json")
check("hash_tree.frontier_store, overwriting existing 0644 file", dir .. "/existing_frontier.json", "644")

-- 4. frontier_forest_store: tree files and frontier file
local forest = hash_tree.frontier_forest(4, "keccak256")
for i = 1, 3 do hash_tree.frontier_forest_push_back(forest, cartesi.keccak256("leaf" .. i)) end
local fdir = dir .. "/forest"; assert(os.execute("mkdir -p '" .. fdir .. "'"))
hash_tree.frontier_forest_store(forest, fdir, dir .. "/forest_frontier.json")
check("hash_tree.frontier_forest_store, frontier file", dir .. "/forest_frontier.json", "644")
local h = io.popen("ls '" .. fdir .. "'"); for name in h:lines() do
    check("hash_tree.frontier_forest_store, tree file " .. name:sub(1, 12) .. "...", fdir .. "/" .. name, "644")
end; h:close()

-- 5. CLI resumable epoch: state_hash vs outputs_frontier vs computation frontier
local stored = dir .. "/machine"
local machine <close> = cartesi.machine({ ram = { length = 4096 } })
machine:write_reg("htif_iyield", cartesi.HTIF_YIELD_CMD_MANUAL_MASK)
machine:write_reg("iflags_Y", 1)
machine:write_reg("htif_tohost_dev", cartesi.HTIF_DEV_YIELD)
machine:write_reg("htif_tohost_cmd", cartesi.HTIF_YIELD_CMD_MANUAL)
machine:write_reg("htif_tohost_reason", cartesi.HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED)
machine:store(stored)
local ep = dir .. "/ep"; assert(os.execute("mkdir -p '" .. ep .. "'"))
local cmd = string.format("timeout 60 cartesi-machine.lua --load=%s --revert-mode=none --max-mcycle=0 "
    .. "--cmio-advance-state=output_proof:,resumable:true,begin_epoch:true,end_epoch:false,"
    .. "state_hash:%s/sh,outputs_frontier:%s/of,output_hashes:%s/oh,output_input_indices:%s/oi "
    .. "--mcycle-computation-hash=log2_mcycle_period:19,frontier:%s/cf >%s/log 2>&1",
    stored, ep, ep, ep, ep, ep, dir)
local ok = os.execute(cmd)
if not ok then io.stderr:write(fs.read_file(dir .. "/log")); error("CLI run failed") end
check("CLI state_hash file", ep .. "/sh", "644")
check("CLI output_hashes file", ep .. "/oh", "644")
check("CLI outputs_frontier file", ep .. "/of", "644")
check("CLI computation frontier file", ep .. "/cf", "644")

os.execute("rm -rf '" .. dir .. "'")
if #bugs > 0 then
    for _, b in ipairs(bugs) do print("BUG: " .. b) end
    print("BUG: frontier files are created mode 0600 (mkstemp) instead of honoring umask like other output files")
    os.exit(1)
end
print("OK: all files honor umask")
