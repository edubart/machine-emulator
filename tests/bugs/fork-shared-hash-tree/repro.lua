-- JSON-RPC fork_server() is allowed for a machine whose hash tree is shared (hash_tree.shared=true) while all
-- address ranges are private. jsonrpc_fork_handler only refuses machines with shared address ranges, but the
-- hash tree's own backing stores (sparse tree and page hash-tree cache) are mapped MAP_SHARED, so after the
-- fork parent and child operate on the same page hash-tree cache with private indexes into it. When the child
-- hashes its own pages it recycles cache entries the parent still maps to its pages:
--   - the parent's word-level hashes/proofs for pages it hashed before the fork become wrong;
--   - after the parent writes to such a page, its ROOT HASH becomes wrong and stays wrong.
-- A local machine with no shared state performs the same operations and serves as the reference.
-- Usage: lua5.4 repro.lua <work-dir>   (spawned server pids are appended to <work-dir>/pids)
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")
local dir = assert(arg[1], "usage: repro.lua <work-dir>")

local RAM = 0x80000000
local TIMEOUT_MS = 30000

local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local function page(seed) -- deterministic non-pristine page contents
    local t = {}
    for i = 0, 4095 do
        t[#t + 1] = string.char((seed * 31 + i * 7 + 1) % 256)
    end
    return table.concat(t)
end

local function record_pid(pid)
    local f = assert(io.open(dir .. "/pids", "a"))
    f:write(pid, "\n")
    f:close()
end

local function spawn()
    local server, _, pid = jsonrpc.spawn_server("127.0.0.1:0", TIMEOUT_MS)
    record_pid(pid)
    server:set_timeout(TIMEOUT_MS)
    server:set_cleanup_call(jsonrpc.SHUTDOWN)
    return server
end

local function fork(server)
    local child, _, pid = server:fork_server()
    record_pid(pid)
    child:set_timeout(TIMEOUT_MS)
    child:set_cleanup_call(jsonrpc.SHUTDOWN)
    return child
end

local function main()
    local base_cfg = { ram = { length = 1 << 20 }, hash_tree = { phtc_size = 32 } }
    local shared_cfg = {
        ram = { length = 1 << 20 },
        hash_tree = {
            phtc_size = 32,
            shared = true,
            create = true,
            sht_filename = dir .. "/ht.sht",
            phtc_filename = dir .. "/ht.phtc",
        },
    }
    local rt = { concurrency = { update_hash_tree = 1 } }

    -- control: forking a server whose machine shares nothing must work
    do
        local s <close> = spawn()
        s:create(base_cfg, rt)
        local c <close> = fork(s)
        assert(c:get_root_hash() == s:get_root_hash(), "control fork is inconsistent")
    end

    -- local reference performing the same operations, nothing shared, no fork
    local ref <close> = cartesi.machine(base_cfg, rt)
    local parent <close> = spawn()
    parent:create(shared_cfg, rt)

    local function both(f)
        f(parent)
        f(ref)
    end
    both(function(m) m:get_root_hash() end)
    -- pages 8..13 become the most recently used cache entries
    both(function(m)
        for p = 8, 13 do
            m:write_memory(RAM + p * 4096, page(p))
        end
        m:get_root_hash()
    end)
    assert(parent:get_root_hash() == ref:get_root_hash(), "precondition: parent == reference before fork")

    local ok, child = pcall(fork, parent)
    if not ok then
        print("fork of a machine with a shared hash tree refused: " .. tostring(child))
        return false
    end
    print("fork of a machine with a shared hash tree was accepted")

    -- child: write 22 other pages and hash them (recycles the cache entries of the parent's pages)
    for p = 100, 121 do
        child:write_memory(RAM + p * 4096, page(p))
    end
    child:get_root_hash()

    local bad = false
    -- (1) parent changed nothing: word proof inside a page it hashed before the fork
    local pa = RAM + 9 * 4096 + 64
    local pp, rp = parent:get_proof(pa, 5), ref:get_proof(pa, 5)
    print("parent word hash              ", hex(pp.target_hash))
    print("reference word hash           ", hex(rp.target_hash))
    if pp.target_hash ~= rp.target_hash or pp.root_hash ~= rp.root_hash then
        print("=> parent word proof is wrong")
        bad = true
    end
    -- (2) parent writes 8 bytes into page 10 and one byte into a fresh page; same on the reference
    both(function(m)
        m:write_memory(RAM + 10 * 4096 + 128, "\x11\x22\x33\x44\x55\x66\x77\x88")
        m:write_memory(RAM + 200 * 4096, "\x01")
    end)
    local okp, hp = pcall(parent.get_root_hash, parent)
    local hr = ref:get_root_hash()
    print("parent root after write       ", okp and hex(hp) or ("ERROR " .. tostring(hp)))
    print("reference root after write    ", hex(hr))
    if not okp or hp ~= hr then
        print("=> parent root hash is wrong after a post-fork write")
        bad = true
    end
    -- (3) the error persists: a further write elsewhere does not repair it
    both(function(m) m:write_memory(RAM + 201 * 4096, "\x02") end)
    local okp2, hp2 = pcall(parent.get_root_hash, parent)
    local hr2 = ref:get_root_hash()
    print("parent root after 2nd write   ", okp2 and hex(hp2) or ("ERROR " .. tostring(hp2)))
    print("reference root after 2nd write", hex(hr2))
    if not okp2 or hp2 ~= hr2 then bad = true end
    child:shutdown_server()
    return bad
end

local ok, bad = pcall(main)
if not ok then
    io.stderr:write("test error: ", tostring(bad), "\n")
    os.exit(2, true)
end
if bad then
    print("BUG REPRODUCED: fork_server of a machine with a shared hash tree is accepted and the servers then "
        .. "return wrong hashes/proofs (shared page hash-tree cache)")
    os.exit(1, true)
end
print("OK: forked servers do not corrupt each other's hashes (or the fork is refused)")
os.exit(0, true)
