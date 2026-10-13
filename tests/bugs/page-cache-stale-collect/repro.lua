-- The page hash-tree cache keeps word-level hashes of pages, keyed only by physical address, and trusts a cache hit
-- for a page that is not marked dirty without checking it against the page's hash in the dense tree.
-- cm_replace_memory_range() with the range's own hash-tree files (data + dht + dpt, clean dirty-page tree) does not
-- invalidate the cache, so the entries computed for the OLD contents of the range keep being used:
--   - cm_get_node_hash / cm_get_proof at word level return hashes of the old contents (wrong proofs);
--   - cm_collect_uarch_cycle_root_hashes() re-hashes only the words written during each uarch cycle on top of the
--     stale entry and copies its root into the dense tree, so the collected uarch-cycle root hashes (the commitment
--     used in fraud-proof disputes) are wrong.
-- Reference: a fresh machine created directly with the replacement data file (no hash-tree files, no cache).
-- Usage: lua5.4 repro.lua <work-dir> [control]
--   control: replace with the data file only (no dht/dpt); must not reproduce (validates the test)
local cartesi = require("cartesi")
local dir = assert(arg[1], "usage: repro.lua <work-dir> [control]")
local control = arg[2] == "control"

local RAM_START, RAM_LENGTH = 0x80000000, 1 << 20
local DRIVE_START, DRIVE_LENGTH = 0x80100000, 64 << 10 -- data flash drive right after RAM
local WORD = DRIVE_START + 0x100 -- a word of the drive's first page, checked at word level
local MCYCLE_END = 4 -- the guest stores into the drive's first page at mcycle 2

local function le32(...)
    local t = {}
    for _, v in ipairs({ ... }) do
        t[#t + 1] = string.pack("<I4", v)
    end
    return table.concat(t)
end

-- Guest (rv64g, runs from 0x80000000):
--   auipc t0, 0x100      # t0 = 0x80100000 (drive)
--   addi  t1, zero, 123
--   sd    t1, 8(t0)      # write one word of the drive's first page
--   addi  a1, zero, 1
--   lui   t0, 0x40008    # HTIF tohost
--   sd    a1, 0(t0)      # halt
--   j     .
local PROGRAM = le32(0x00100297, 0x07b00313, 0x0062b423, 0x00100593, 0x400082b7, 0x00b2b023, 0x0000006f)

local function config(drive_backing_store)
    return {
        ram = { length = RAM_LENGTH },
        flash_drive = { { start = DRIVE_START, length = DRIVE_LENGTH, backing_store = drive_backing_store } },
    }
end

local function hex(h)
    return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 16) .. "..."
end

-- Stored machine "e" whose drive holds 0x22 bytes; stored after a hash, so its drive's dirty-page tree is clean.
local e_dir = dir .. (control and "/e-control" or "/e")
do
    local e <close> = cartesi.machine(config())
    e:write_memory(RAM_START, PROGRAM)
    e:write_memory(DRIVE_START, string.rep("\x22", DRIVE_LENGTH))
    e:get_root_hash()
    e:store(e_dir)
end
local base = string.format("%s/%016x-%x", e_dir, DRIVE_START, DRIVE_LENGTH)
local replacement = { data_filename = base .. ".bin" }
if not control then
    replacement.dht_filename, replacement.dpt_filename = base .. ".dht", base .. ".dpt"
end
for _, f in pairs(replacement) do
    assert(io.open(f, "rb"), "test error: missing stored drive file " .. f):close()
end

-- Machine under test: drive initially holds 0x11 bytes; hashing it fills the page hash-tree cache with those
-- contents; then the drive is replaced with e's drive.
local function machine_under_test()
    local m = cartesi.machine(config())
    m:write_memory(RAM_START, PROGRAM)
    m:write_memory(DRIVE_START, string.rep("\x11", DRIVE_LENGTH))
    m:get_root_hash()
    m:get_proof(WORD, 5)
    m:replace_memory_range({ start = DRIVE_START, length = DRIVE_LENGTH, backing_store = replacement })
    return m
end

-- Fresh machine: created directly with e's drive data file (private copy, no hash-tree files, empty cache)
local function fresh_machine()
    local m = cartesi.machine(config({ data_filename = base .. ".bin" }))
    m:write_memory(RAM_START, PROGRAM)
    return m
end

local failures = 0
local function check(ok, what, detail)
    print(string.format("%-58s %s%s", what, ok and "ok" or "WRONG", detail and (" " .. detail) or ""))
    if not ok then failures = failures + 1 end
end

print(control and "== control: replace the drive with its data file only" or
    "== replace the drive with its data + dht + dpt files")

-- 1. Root hash and word-level node hash / proof
do
    local m <close> = machine_under_test()
    local f <close> = fresh_machine()
    assert(m:read_memory(WORD, 32) == f:read_memory(WORD, 32), "test error: drive contents differ")
    check(m:get_root_hash() == f:get_root_hash(), "root hash")
    local mn, fn = m:get_node_hash(WORD, 5), f:get_node_hash(WORD, 5)
    check(mn == fn, "word node hash (cm_get_node_hash, log2_size 5)", mn ~= fn and (hex(mn) .. " vs fresh " .. hex(fn)))
    local mp, fp = m:get_proof(WORD, 5), f:get_proof(WORD, 5)
    local same = mp.target_hash == fp.target_hash and mp.root_hash == fp.root_hash and
        #mp.sibling_hashes == #fp.sibling_hashes
    for i = 1, #fp.sibling_hashes do
        same = same and mp.sibling_hashes[i] == fp.sibling_hashes[i]
    end
    check(same, "word proof (cm_get_proof, log2_size 5)")
end

-- 2. Uarch-cycle root hashes collected while the guest writes the drive's first page
do
    local m <close> = machine_under_test()
    local f <close> = fresh_machine()
    local function collect(x)
        local tail = { x:read_revert_root_hash(), x:read_revert_root_hash() } -- required by the API, unused here
        return x:collect_uarch_cycle_root_hashes(MCYCLE_END, 0, tail)
    end
    local rm, rf = collect(m), collect(f)
    local n, nbad, first = math.max(#rm.hashes, #rf.hashes), 0, nil
    for i = 1, n do
        if rm.hashes[i] ~= rf.hashes[i] then
            nbad = nbad + 1
            first = first or i
        end
    end
    check(nbad == 0 and #rm.hashes == #rf.hashes and #rf.hashes > 0,
        string.format("collect_uarch_cycle_root_hashes to mcycle %d", MCYCLE_END),
        string.format("(%d hashes, %d differ from the fresh machine%s)", n, nbad,
            first and string.format(", first at index %d", first) or ""))
    check(m:get_root_hash() == f:get_root_hash(), "root hash after collection")
end

if failures > 0 then
    print("BUG REPRODUCED: after cm_replace_memory_range with the range's own hash-tree files, stale page hash-tree "
        .. "cache entries give wrong word-level hashes/proofs and wrong collected uarch-cycle root hashes")
    os.exit(1)
end
print("OK: word-level hashes, proofs and collected uarch-cycle root hashes match the fresh machine")
os.exit(0)
