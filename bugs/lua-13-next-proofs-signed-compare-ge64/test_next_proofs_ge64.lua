-- frontier_next_proofs signed-comparison bug for trees of height >= 64
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")

local H = 64
local f = ht.frontier(H, "keccak256")
-- leaf count 2^63-1: levels 1..63 hold complete left subtrees (arbitrary distinct hashes)
for level = 1, 63 do f[level] = cartesi.keccak256("level" .. level) end
assert(ht.frontier_get_leaf_count(f) == math.maxinteger)

local leaves = {}
for i = 1, 3 do leaves[i] = cartesi.keccak256("leaf" .. i) end

-- reference root via push_back on a copy
local ref = ht.frontier_copy(f)
for i = 1, #leaves do ht.frontier_push_back(ref, leaves[i]) end
local ref_root = ht.frontier_get_root_hash(ref)

-- control: same thing with a tree that does not cross 2^63 (height 64, smaller count)
local g = ht.frontier(H, "keccak256")
for level = 1, 10 do g[level] = cartesi.keccak256("level" .. level) end
local gref = ht.frontier_copy(g)
for i = 1, #leaves do ht.frontier_push_back(gref, leaves[i]) end
local gproofs = ht.frontier_next_proofs(g, leaves)
for i = 1, #leaves do
    assert(gproofs[i].root_hash == ht.frontier_get_root_hash(gref), "control root mismatch")
    ht.verify_slice(gproofs[i])
end
print("control (leaf count 1023, height 64): OK")

local proofs = ht.frontier_next_proofs(f, leaves)
local bad = 0
for i = 1, #leaves do
    local p = proofs[i]
    local root_ok = p.root_hash == ref_root
    local ok = pcall(ht.verify_slice, p)
    local rolled = ht.roll_hash_up_tree(p, p.target_hash)
    print(string.format("proof %d target_address=%s root_matches_push_back=%s verify_slice=%s rolled_matches_push_back=%s",
        i, math.tointeger(p.target_address) and string.format("0x%016x", p.target_address), tostring(root_ok),
        tostring(ok), tostring(rolled == ref_root)))
    if not (root_ok and ok and rolled == ref_root) then bad = bad + 1 end
end
if bad > 0 then
    print(string.format("BUG: frontier_next_proofs produced %d/%d wrong proofs for height-64 tree when range crosses 2^63", bad, #leaves))
    os.exit(1)
end
print("OK")
