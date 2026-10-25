-- Proves that cartesi.hash-tree verify_slice/verify_splice accept non-canonical proofs.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local hf = cartesi.keccak256

local function deepcopy(p)
    local c = {}
    for k, v in pairs(p) do c[k] = v end
    c.sibling_hashes = { table.unpack(p.sibling_hashes) }
    return c
end
local function accepts(p) return (pcall(ht.verify_slice, p)) end

local bugs = 0
local function check(desc, accepted)
    if accepted then
        bugs = bugs + 1
        print("BUG: verify_slice accepted " .. desc)
    else
        print("ok: rejected " .. desc)
    end
end

-- 1. Outputs tree of height 63 (PRT outputs geometry style); 5 outputs, proofs from frontier_next_proofs.
local f = ht.frontier(63, "keccak256")
local outs = {}
for i = 1, 5 do outs[i] = hf("output" .. i) end
local proofs = ht.frontier_next_proofs(f, outs)
local p = proofs[3] -- index 2
assert(accepts(p), "baseline valid proof must verify")
print("baseline: index", p.target_address, "verifies")

local q = deepcopy(p); q.target_address = p.target_address + (1 << 63)
check(("target_address beyond tree (0x%x >= 2^63)"):format(q.target_address), accepts(q))

q = deepcopy(p); q.sibling_hashes[#q.sibling_hashes + 1] = hf("junk")
q.sibling_hashes[#q.sibling_hashes + 1] = hf("junk2")
check("proof with 2 extra trailing siblings (" .. #q.sibling_hashes .. " vs 63)", accepts(q))

q = deepcopy(p); q.log2_target_size = q.log2_root_size + 5; q.target_hash = q.root_hash
check("log2_target_size > log2_root_size with target_hash == root_hash (arbitrary address 12345)",
    (function() q.target_address = 12345; return accepts(q) end)())

-- 2. Memory proof from a real machine: unaligned target address with low bits set.
local m = cartesi.machine({ ram = { length = 1 << 20 }, processor = {} } , {})
local ram_start = 0x80000000
local mp = m:get_proof(ram_start, 5) -- 32-byte word proof
assert(accepts(mp), "baseline memory proof must verify")
q = deepcopy(mp); q.target_address = mp.target_address + 0x7 -- not aligned to 2^5
check(("unaligned memory proof target_address 0x%x (log2_target_size 5)"):format(q.target_address), accepts(q))
q = deepcopy(mp); q.target_address = mp.target_address | (1 << 63)
check(("memory proof target_address 0x%x beyond 2^64 address space root (log2_root_size %d)"):format(
    q.target_address, q.log2_root_size), q.log2_root_size < 64 and accepts(q))

-- verify_splice inherits the same: same unaligned proof also "proves" a splice
q = deepcopy(mp); q.target_address = mp.target_address + 0x1f
local newh = hf("new") ; local newroot = ht.roll_hash_up_tree(mp, newh)
check("verify_splice with unaligned target_address", (pcall(ht.verify_splice, q, newh, newroot)))

-- 3. frontier_next_proofs on a full 4-leaf frontier yields a proof at nonexistent index 4 that verifies.
local g = ht.frontier(2, "keccak256")
for i = 1, 4 do ht.frontier_push_back(g, hf("l" .. i)) end
local ok, ps = pcall(ht.frontier_next_proofs, g, { hf("a") })
if ok then
    check(("frontier_next_proofs(full height-2 frontier) proof at target_address %d (tree has 4 leaves)"):format(
        ps[1].target_address), accepts(ps[1]))
else
    print("ok: frontier_next_proofs rejected full frontier: " .. tostring(ps))
end

if bugs > 0 then
    print(("BUG: %d non-canonical proofs accepted"):format(bugs))
    os.exit(1)
end
print("all non-canonical proofs rejected")
os.exit(0)
