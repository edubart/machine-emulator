-- Word-level proof / node hash of an address in the power-of-two padding of a memory range.
--
-- Usage: lua5.4 padding-proof.lua proof|nodehash
--   proof:    cm_get_proof(PAD_WORD, 5) must have the pristine word hash as target and must bubble up to the machine
--             root hash (checked with the same procedure on a real RAM word first).
--   nodehash: cm_get_node_hash(PAD_WORD, 5) must be the pristine word hash.
-- Exit codes: 0 = correct, 1 = wrong hash/proof (or the query raised an error), 2 = setup failure.
-- A process abort is reported by run.sh.
--
-- Machine: 64 KiB RAM and a 3-page flash drive at 0x90000000, so the drive's dense hash tree spans 4 pages and page
-- 0x90003000 is padding. The page hash-tree cache is tiny (phtc_size 4) and is filled with entries of other, non-pristine
-- pages. get_page_proof() (and the sub-page branch of get_dense_node_hash()) borrow a cache entry for the padding page,
-- update_dirty_page() refuses to fill it because the page is outside the range (its "false" return is ignored), and the
-- proof is then built from the stale hashes of whatever page was evicted.
local cartesi = require("cartesi")

local FLASH, PAD_WORD, RAM_WORD = 0x90000000, 0x90003040, 0x80002040

local m, root
local setup_ok, setup_err = pcall(function()
    m = cartesi.machine({
        ram = { length = 0x10000 },
        flash_drive = { { start = FLASH, length = 0x3000 } },
        hash_tree = { phtc_size = 4 },
    })
    -- Dirty every RAM page and the 3 drive pages with distinct data, then update the tree
    for i = 0, 15 do
        m:write_memory(0x80000000 + i * 4096, string.rep(string.char(i + 1), 4096))
    end
    for i = 0, 2 do
        m:write_memory(FLASH + i * 4096, string.rep(string.char(0x80 + i), 4096))
    end
    root = m:get_root_hash()
    -- Word proofs of real pages, so the page cache holds their (non-pristine) entries
    for i = 0, 15 do
        m:get_proof(0x80000000 + i * 4096, 5)
    end
end)
if not setup_ok then
    print("setup failure: " .. tostring(setup_err))
    os.exit(2)
end

local pristine_word = cartesi.keccak256(string.rep("\0", 32))
local function hex(h) return cartesi.tohex(h):sub(1, 18) end

if arg[1] == "nodehash" then
    local h = m:get_node_hash(PAD_WORD, 5)
    print(string.format("get_node_hash(0x%x, 5) = %s, pristine word hash = %s", PAD_WORD, hex(h), hex(pristine_word)))
    os.exit(h == pristine_word and 0 or 1)
end

-- Recomputes the root hash from a word proof (sibling_hashes[1] is the sibling of the target)
local function bubble_up(address, proof)
    local h = proof.target_hash
    for log2 = 5, 63 do
        local sib = proof.sibling_hashes[log2 - 4]
        if ((address >> log2) & 1) == 1 then
            h = cartesi.keccak256(sib, h)
        else
            h = cartesi.keccak256(h, sib)
        end
    end
    return h
end

-- Sanity check of the procedure on a real RAM word
if bubble_up(RAM_WORD, m:get_proof(RAM_WORD, 5)) ~= root then
    print("setup failure: proof check procedure does not reproduce the root hash on a RAM word")
    os.exit(2)
end

local p = m:get_proof(PAD_WORD, 5)
local h = bubble_up(PAD_WORD, p)
print(string.format("get_proof(0x%x, 5): target %s (pristine word %s), recomputed root %s, machine root %s", PAD_WORD,
    hex(p.target_hash), hex(pristine_word), hex(h), hex(root)))
os.exit((p.target_hash == pristine_word and h == root) and 0 or 1)
