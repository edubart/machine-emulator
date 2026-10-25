-- Proof: persisted page hash-tree cache (hash_tree.phtc) entries are reused at load time even when
-- they no longer match the backing data of their range.
--
-- Scenario (case a): load a stored machine with SHARING_ALL, replace_memory_range() a flash drive with a
-- different image, compute the root hash (fills the shared phtc with entries for the NEW image), close.
-- The stored directory still holds the OLD flash image, dht and dpt (all pages clean). Reloading the
-- directory keeps the stale phtc entries, so:
--   * get_proof() for sub-page targets returns hashes of the new image (wrong target / siblings)
--   * collect_uarch_cycle_root_hashes() (update_words hit path) computes wrong root hashes when the guest
--     writes to such a page.
-- A reference copy of the stored directory, taken before the replacement, is used as ground truth.
--
-- Run from repo root: eval $(make -s env); lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-replace-memory-range.lua
--   (add argument `control` to skip replace_memory_range; expected PASS). Exit 0 = fixed, exit 1 = BUG present.

local cartesi = require("cartesi")

local here = arg[0]:match("(.*/)") or "./"
local work = here .. "run"
os.execute("rm -rf '" .. work .. "' && mkdir -p '" .. work .. "'")

local START = 0x80000000000000 -- flash drive start
local FLEN = 65536
local TARGET = START + 3 * 4096 + 64 -- word the guest program will write

local function writefile(name, data)
    local f = assert(io.open(name, "wb"))
    f:write(data)
    f:close()
end

local function rnd(seed, n)
    math.randomseed(seed)
    local t = {}
    for i = 1, n do
        t[i] = string.char(math.random(0, 255))
    end
    return table.concat(t)
end

writefile(work .. "/imgA", rnd(1, FLEN))
writefile(work .. "/imgB", rnd(2, FLEN))

-- tiny RISC-V program: store 0x55 to TARGET, then spin
local insns = {
    0x00100293, -- addi t0, x0, 1
    (55 << 20) | (5 << 15) | (1 << 12) | (5 << 7) | 0x13, -- slli t0, t0, 55   => 0x80000000000000
    (3 << 12) | (6 << 7) | 0x37, -- lui  t1, 3        => 0x3000
    (6 << 20) | (5 << 15) | (5 << 7) | 0x33, -- add  t0, t0, t1
    (64 << 20) | (5 << 15) | (5 << 7) | 0x13, -- addi t0, t0, 64
    (0x55 << 20) | (6 << 7) | 0x13, -- addi t1, x0, 0x55
    (6 << 20) | (5 << 15) | (3 << 12) | 0x23, -- sd   t1, 0(t0)
    0x0000006f, -- j .
}
local prog = {}
for i, w in ipairs(insns) do
    prog[i] = string.pack("<I4", w)
end
writefile(work .. "/prog", table.concat(prog))

local rep = work .. "/rep"
local ref = work .. "/ref"

do
    local m = cartesi.machine({
        ram = { length = 1 << 20, backing_store = { data_filename = work .. "/prog" } },
        flash_drive = { { start = START, length = FLEN, backing_store = { data_filename = work .. "/imgA" } } },
    })
    m:get_root_hash()
    m:store(rep, cartesi.SHARING_ALL)
    m:destroy()
end
-- ground-truth copy of the stored machine, taken before anything touches it
assert(os.execute("cp -a '" .. rep .. "' '" .. ref .. "'"))

local control = arg[1] == "control" -- control run: skip replace_memory_range, everything must match
if not control then -- honest operator: load shared, swap the flash drive, hash, close
    local m = cartesi.machine(rep, {}, cartesi.SHARING_ALL)
    m:replace_memory_range({ start = START, length = FLEN, backing_store = { data_filename = work .. "/imgB" } })
    m:get_root_hash()
    m:destroy()
end

local bug = false
local function check(cond, msg)
    if not cond then
        print("BUG: " .. msg)
        bug = true
    else
        print("ok: " .. msg)
    end
end

local m = cartesi.machine(rep, {}, cartesi.SHARING_ALL)
local r = cartesi.machine(ref, {}, cartesi.SHARING_NONE)

local root = m:get_root_hash()
check(root == r:get_root_hash(), "reloaded root hash equals reference root hash")
check(m:read_memory(START, FLEN) == r:read_memory(START, FLEN), "reloaded flash content equals reference (imgA)")

-- 1) sub-page proof must match memory and rebuild the root
local p = m:get_proof(TARGET, 5)
local leaf_hash = cartesi.keccak256(m:read_memory(TARGET, 32))
check(p.target_hash == leaf_hash, "get_proof target_hash == keccak256(memory word)")
local cur = p.target_hash
for i, sib in ipairs(p.sibling_hashes) do
    local log2 = 5 + i - 1
    if (TARGET >> log2) & 1 == 0 then
        cur = cartesi.keccak256(cur, sib)
    else
        cur = cartesi.keccak256(sib, cur)
    end
end
check(cur == root, "proof siblings rebuild the machine root hash")
local rp = r:get_proof(TARGET, 5)
check(p.target_hash == rp.target_hash, "get_proof target_hash equals reference")

-- 2) node hash for a sub-page node
check(m:get_node_hash(TARGET, 5) == r:get_node_hash(TARGET, 5), "get_node_hash(word) equals reference")

-- 3) uarch-cycle root hashes when guest writes a word in a stale-cached clean page (update_words hit path)
local tail = { string.rep("\0", cartesi.HASH_SIZE), string.rep("\0", cartesi.HASH_SIZE) }
local NM = 8
local hm = m:collect_uarch_cycle_root_hashes(NM, 0, tail)
local hr = r:collect_uarch_cycle_root_hashes(NM, 0, tail)
local first_diff
for i = 1, math.max(#hm.hashes, #hr.hashes) do
    if hm.hashes[i] ~= hr.hashes[i] then
        first_diff = i
        break
    end
end
check(first_diff == nil, "collect_uarch_cycle_root_hashes equals reference ("
    .. #hm.hashes .. " hashes" .. (first_diff and (", first mismatch at #" .. first_diff) or "") .. ")")
check(m:read_memory(TARGET, 8) == string.pack("<I8", 0x55), "guest store reached the flash drive")
local final_m = m:get_root_hash()
local final_r = r:get_root_hash()
check(final_m == final_r, "root hash after uarch run equals reference")
check(hm.hashes[#hm.hashes] == final_r, "last collected uarch hash equals reference final root")

m:destroy()
r:destroy()

os.execute("rm -rf '" .. work .. "'")
if bug then
    print("BUG: persisted phtc entries not validated against backing data at load (stale page cache reused)")
    os.exit(1)
end
print("PASS")
os.exit(0)
