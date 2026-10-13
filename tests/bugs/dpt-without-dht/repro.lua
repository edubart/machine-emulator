-- A persisted dirty-page tree (dpt) whose pages are marked clean is trusted even when the matching dense hash tree
-- (dht) was never computed (anonymous all-zero memory, or a zero-filled file the emulator recreated). Clean pages are
-- never rehashed, so the drive's node hash is all zeros and the root hash, proofs and node hashes do not depend on
-- the drive contents at all.
--
-- Triggers:
--   A: a shared flash drive configured with dpt_filename but without dht_filename (the CLI help says "when omitted
--      ... the hash tree will be built from scratch"); session 1 hashes the drive (marks the dpt clean), session 2
--      reopens it.
--   B: creating a machine in a directory from a config whose drive brings data_filename + dpt_filename (no dht):
--      the copied dpt is kept, the dht becomes a zero file.
--   C: a stored machine whose flash drive .dht file is lost, then loaded with SHARING_ALL: the .dht is silently
--      recreated zero-filled next to the clean .dpt; every later load (even SHARING_NONE) is wrong too.
--      Refusing such a load (as SHARING_NONE already does) is an acceptable fix.
--
-- Decision: the expected Merkle root of the drive is computed independently, straight from the bytes of its data
-- file, with cartesi.hash-tree get_data_root_hash. It must equal the machine's node hash for the drive, and rolling
-- it up the machine's own proof must give the machine's root hash.
--
-- usage: lua5.4 repro.lua <workdir>     exit 0 = fixed, 1 = bug reproduced, 2 = test error
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")

local W = assert(arg[1], "usage: repro.lua <workdir>")
local LOG2_LEN = 16
local LEN = 1 << LOG2_LEN
local function p(f) return W .. "/" .. f end
local function readfile(f)
    local h <close> = assert(io.open(f, "rb"))
    return h:read("a")
end
local function writefile(f, s)
    local h <close> = assert(io.open(f, "wb"))
    assert(h:write(s))
end
local function hex(h) return h and cartesi.tohex(h):sub(1, 18) or "nil" end

local function config(backing_store)
    return { ram = { length = 0x10000 }, flash_drive = { { length = LEN, backing_store = backing_store } } }
end

-- Does machine m commit to `data` (the bytes of its flash drive 0)?
local function commits(m, data, label)
    local start = m:get_initial_config().flash_drive[1].start
    local expected = ht.get_data_root_hash(data, LOG2_LEN)
    local node = m:get_node_hash(start, LOG2_LEN)
    local root = m:get_root_hash()
    local rolled = ht.roll_hash_up_tree(m:get_proof(start, LOG2_LEN), expected)
    local ok = node == expected and rolled == root
    print(string.format("  %-40s drive node %s expected %s root %s => %s", label, hex(node), hex(expected), hex(root),
        ok and "ok" or "ROOT HASH DOES NOT COMMIT TO DRIVE DATA"))
    return ok
end

-- Session 1: a shared drive whose contents are written through the API, then hashed (this marks the dpt clean)
local function session1(backing_store, seed)
    for _, f in ipairs({ "d.bin", "d.dht", "d.dpt" }) do
        os.remove(p(f))
    end
    writefile(p("d.bin"), string.rep("\0", LEN))
    local m <close> = cartesi.machine(config(backing_store))
    local start = m:get_initial_config().flash_drive[1].start
    local t = {}
    for i = 1, 3 * 4096 do
        t[i] = string.char((i * seed + 5) & 0xff)
    end
    m:write_memory(start + 4096, table.concat(t))
    m:get_root_hash()
end

local bad = 0
local function trigger(ok)
    if not ok then bad = bad + 1 end
end
local function control(ok)
    if not ok then error("control case failed: the test itself is broken") end
end

local function main()
    print("[A] shared drive with dpt_filename and no dht_filename")
    do
        local bs = { shared = true, data_filename = p("d.bin"), dpt_filename = p("d.dpt") }
        session1(bs, 7)
        local m <close> = cartesi.machine(config(bs))
        trigger(commits(m, readfile(p("d.bin")), "session 2, dpt only"))
    end

    print("[A-control] same flow with both dht_filename and dpt_filename")
    do
        local bs = { shared = true, data_filename = p("d.bin"), dht_filename = p("d.dht"), dpt_filename = p("d.dpt") }
        session1(bs, 7)
        local m <close> = cartesi.machine(config(bs))
        control(commits(m, readfile(p("d.bin")), "session 2, dht + dpt"))
    end

    print("[B] create in a directory from a config whose drive brings data + dpt (no dht)")
    do
        session1({ shared = true, data_filename = p("d.bin"), dpt_filename = p("d.dpt") }, 9)
        local m <close> = cartesi.machine(config({ data_filename = p("d.bin"), dpt_filename = p("d.dpt") }), nil, p("B"))
        trigger(commits(m, readfile(p("d.bin")), "machine created in directory B"))
    end

    print("[C] stored machine whose flash drive .dht file was lost")
    do
        do
            local m <close> = cartesi.machine(config({}))
            local start = m:get_initial_config().flash_drive[1].start
            m:write_memory(start + 8192, string.rep("\x5a", 4096))
            m:get_root_hash()
            m:store(p("C"), cartesi.SHARING_ALL)
        end
        local bs = cartesi.fromjson(readfile(p("C/config.json"))).config.flash_drive[1].backing_store
        local data = readfile(p("C/" .. bs.data_filename))
        assert(os.remove(p("C/" .. bs.dht_filename)))
        print("  removed " .. bs.dht_filename)
        -- Each load must either be refused (fail closed) or produce a root hash that commits to the drive data
        local function load(sharing, label)
            local ok, m = pcall(cartesi.machine, p("C"), nil, sharing)
            if not ok then
                print(string.format("  %-40s refused: %s", label, tostring(m)))
                return true
            end
            local machine <close> = m
            return commits(machine, data, label)
        end
        trigger(load(cartesi.SHARING_NONE, "load with SHARING_NONE"))
        trigger(load(cartesi.SHARING_ALL, "load with SHARING_ALL"))
        -- A zeroed .dht now sits on disk next to the clean .dpt: later loads are affected as well
        trigger(load(cartesi.SHARING_NONE, "later load, SHARING_NONE"))
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("ERROR: " .. tostring(err))
    os.exit(2)
end
if bad > 0 then
    print(string.format("BUG REPRODUCED: %d case(s) where the root hash does not commit to the flash drive data", bad))
    os.exit(1)
end
print("OK: the root hash commits to the flash drive data in every case")
os.exit(0)
