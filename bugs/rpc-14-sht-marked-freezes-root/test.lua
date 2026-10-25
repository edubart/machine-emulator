-- Repro: a sparse-node 'marked' flag persisted in hash_tree.sht is accepted at load
-- (hash-tree.cpp constructor only rejects marked > 1) and since update_sparse_tree only
-- enqueues nodes whose marked == 0, the marked node (here: the root) is never recomputed
-- and the mark is never cleared: get_root_hash() is frozen forever.
-- Run from the repo root: eval $(make -s env); timeout 120 lua5.4 bugs/rpc-14-sht-marked-freezes-root/test.lua
local cartesi = require"cartesi"
local here = arg[0]:match("^(.*)/") or "."
local work = assert(io.popen("mktemp -d"):read("l"), "mktemp failed") -- scratch dir outside the repo
local ROOT_MARKED_OFF = 64 + 28 -- node[1] (root), field 'marked' (node_type is 64 bytes, index_type int64)

local function make_store(dir)
    local m <close> = cartesi.machine({ram = {length = 1 << 20}})
    m:get_root_hash()
    m:store(dir)
end

local function read_mark(dir)
    local f <close> = assert(io.open(dir .. "/hash_tree.sht", "rb"))
    f:seek("set", ROOT_MARKED_OFF)
    return (string.unpack("<I4", f:read(4)))
end

local function reference_hash(dir, writes)
    local ref <close> = cartesi.new():load(dir, {clear_hash_tree = true})
    for _, w in ipairs(writes) do ref:write_memory(w[1], w[2]) end
    return ref:get_root_hash()
end

local failed = false
local function check(label, dir, prior_writes)
    prior_writes = prior_writes or {}
    print(string.format("[%s] root 'marked' flag on disk = %d", label, read_mark(dir)))
    local m <close> = cartesi.new():load(dir)
    local writes = {}
    for _, w in ipairs(prior_writes) do writes[#writes + 1] = w end
    local h0 = m:get_root_hash()
    local w1 = {cartesi.AR_RAM_START, string.rep("X", 4096)}
    m:write_memory(w1[1], w1[2]); writes[#writes + 1] = w1
    local h1 = m:get_root_hash()
    local w2 = {cartesi.AR_RAM_START + 8192, string.rep("Y", 4096)}
    m:write_memory(w2[1], w2[2]); writes[#writes + 1] = w2
    local h2 = m:get_root_hash()
    local want = reference_hash(dir, writes)
    print(string.format("[%s] root after load   %s", label, cartesi.tohex(h0)))
    print(string.format("[%s] root after write1 %s", label, cartesi.tohex(h1)))
    print(string.format("[%s] root after write2 %s", label, cartesi.tohex(h2)))
    print(string.format("[%s] correct root      %s (clear_hash_tree=true)", label, cartesi.tohex(want)))
    if h2 ~= want then
        print(string.format("BUG: [%s] get_root_hash is wrong after loading a store with a persisted sparse 'marked' flag%s",
            label, (h0 == h1 and h1 == h2) and " (root hash frozen across memory writes)" or ""))
        failed = true
    end
end

-- Case 1: deterministic — set root node marked=1 directly in hash_tree.sht (what a crash leaves behind).
local d1 = work .. "/patched"
make_store(d1)
do
    local f <close> = assert(io.open(d1 .. "/hash_tree.sht", "r+b"))
    f:seek("set", ROOT_MARKED_OFF); f:write(string.pack("<I4", 1))
end
check("patched-sht", d1)

-- Case 2: realistic — a process using the store with SHARING_ALL is SIGKILLed while inside
-- hash_tree::update_sparse_tree (stopped by gdb right after the root gets marked).
if os.execute("command -v gdb >/dev/null 2>&1") then
    local d2 = work .. "/crashed"
    make_store(d2)
    local cmd = string.format("timeout 60 gdb -q -batch -x %s/kill_in_update.py --args lua5.4 %s/child.lua %s >%s/gdb.log 2>&1",
        here, here, d2, work)
    os.execute(cmd)
    -- the child applied this write before being killed; include it in the reference
    check("crash-in-update", d2, {{cartesi.AR_RAM_START, string.rep("X", 4096)}})
else
    print("gdb not available: skipping crash simulation")
end

os.execute("rm -rf " .. work)
os.exit(failed and 1 or 0)
