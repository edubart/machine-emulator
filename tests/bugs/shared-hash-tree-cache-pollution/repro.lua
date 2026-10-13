-- A stored machine whose config has hash_tree.shared=true while RAM is private (the RAM default).
-- A session loaded with SHARING_CONFIG writes RAM (discarded, by design), but the page hash-tree cache
-- entries created by hashing those writes are persisted into the snapshot's hash_tree.phtc. Every later
-- load of the snapshot (even with SHARING_NONE) maps the clean page to a cache entry holding the discarded
-- contents, and cache hits are trusted without validation. Word-level hashes/proofs of that page are then
-- wrong (the root hash is not), so an honest uarch step log for an instruction that reads the page cannot be
-- produced.
-- Usage: lua5.4 repro.lua <work-dir> [control]
--   control: same flow without a shared hash tree (must not reproduce; used to validate the test)
local cartesi = require("cartesi")
local dir = assert(arg[1], "usage: repro.lua <work-dir> [control]")
local control = arg[2] == "control"
local snap = dir .. (control and "/snapshot-control" or "/snapshot")
local RAM, P = 0x80000000, 0x80010000

local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local function le32(...)
    local t = {}
    for _, v in ipairs({ ... }) do
        t[#t + 1] = string.pack("<I4", v)
    end
    return table.concat(t)
end

local function main()
    -- program: auipc t0, 0x10 (t0 = 0x80010000); ld t1, 0(t0); j .
    local prog = le32(0x00010297, 0x0002b303, 0x0000006f)
    do
        local m <close> = cartesi.machine({
            ram = { length = 1 << 20 },
            hash_tree = control and { phtc_size = 1024 } or {
                phtc_size = 1024,
                shared = true,
                create = true,
                sht_filename = snap .. ".sht",
                phtc_filename = snap .. ".phtc",
            },
        })
        m:write_memory(RAM, prog)
        m:write_memory(P, string.rep("\x11", 4096))
        m:get_root_hash()
        -- default sharing (all): writes the RAM image; config.json keeps hash_tree.shared=true and RAM private
        m:store(snap)
    end
    local snapshot_root
    do
        local m <close> = cartesi.machine(snap, nil, cartesi.SHARING_NONE)
        snapshot_root = m:get_root_hash()
    end
    -- one ordinary "what-if" session over the snapshot, as its config asks (SHARING_CONFIG)
    do
        local m <close> = cartesi.machine(snap, nil, cartesi.SHARING_CONFIG)
        m:write_memory(P, string.rep("\x22", 4096))
        m:get_root_hash()
    end -- the RAM changes are discarded, but the snapshot's hash_tree.phtc was updated in place

    local m <close> = cartesi.machine(snap, nil, cartesi.SHARING_NONE)
    local root = m:get_root_hash()
    local word = m:read_memory(P, 32)
    print("snapshot root          ", hex(snapshot_root))
    print("reloaded root          ", hex(root))
    print(string.format("reloaded memory at P    0x%02x...", word:byte(1)))
    local nh = m:get_node_hash(P, 5)
    print("get_node_hash(P, 5)    ", hex(nh))
    print("keccak256(actual word) ", hex(cartesi.keccak256(word)))
    local bad = false
    if root ~= snapshot_root then
        print("=> reloaded root hash differs from the snapshot root hash")
        bad = true
    end
    if nh ~= cartesi.keccak256(word) then
        print("=> word hash does not match the memory contents")
        bad = true
    end
    -- consequence: uarch step log of the `ld` that reads page P
    m:run(1) -- execute auipc
    local steps, err = 0, nil
    while steps < 100000 do
        local ok, log = pcall(m.log_step_uarch, m)
        if not ok then
            err = log
            break
        end
        steps = steps + 1
        if m:read_reg("uarch_halt") ~= 0 then break end
    end
    if err then
        print(string.format("log_step_uarch failed at uarch step %d: %s", steps, err))
        bad = true
    else
        print(string.format("log_step_uarch ok for %d steps", steps))
    end
    return bad
end

local ok, bad = pcall(main)
if not ok then
    io.stderr:write("test error: ", tostring(bad), "\n")
    os.exit(2)
end
if bad then
    print("BUG REPRODUCED: a session over a snapshot with a shared hash tree pollutes the snapshot's page "
        .. "hash-tree cache; later loads return wrong word hashes and cannot produce an honest uarch step log")
    os.exit(1)
end
print("OK: word hashes and uarch step logs of the reloaded snapshot are correct")
os.exit(0)
