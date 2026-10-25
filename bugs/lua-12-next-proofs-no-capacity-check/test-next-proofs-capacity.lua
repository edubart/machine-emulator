-- frontier_next_proofs must reject outputs that exceed the tree capacity (like push_back/append do).
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local hf = cartesi.keccak256
local bugs = 0
local function bug(fmt, ...) bugs = bugs + 1; print("BUG: " .. fmt:format(...)) end

-- Case 1: height-2 tree (4 leaves), 3 already present, ask proofs for 3 more (only 1 fits)
local f = ht.frontier(2, "keccak256")
for i = 1, 3 do ht.frontier_push_back(f, hf("l" .. i)) end
local fc = ht.frontier_copy(f)
assert(not pcall(ht.frontier_append, fc, { hf("a"), hf("b"), hf("c") }), "append should reject overflow")
local ok, ps = pcall(ht.frontier_next_proofs, f, { hf("a"), hf("b"), hf("c") })
if ok then
    local addrs, verified = {}, 0
    for i, p in ipairs(ps) do
        addrs[#addrs + 1] = tostring(p.target_address)
        if pcall(ht.verify_slice, p) then verified = verified + 1 end
    end
    bug("overflow: next_proofs accepted 3 outputs into a 4-leaf tree holding 3 leaves (frontier_append rejects); "
        .. "target addresses {%s} (tree has 4 leaves), %d of %d proofs pass verify_slice", table.concat(addrs, ","), verified, #ps)
end

-- Case 2: full 4-leaf frontier, ask proof for 1 more
local g = ht.frontier(2, "keccak256")
for i = 1, 4 do ht.frontier_push_back(g, hf("l" .. i)) end
local real_root = ht.frontier_get_root_hash(g)
local ok2, ps2 = pcall(ht.frontier_next_proofs, g, { hf("a") })
if ok2 then
    local p = ps2[1]
    local v = pcall(ht.verify_slice, p)
    bug("full: next_proofs on a full frontier returned target_address=%d (out of tree), root %s the real root, verify_slice=%s",
        p.target_address, p.root_hash == real_root and "equals" or "differs from", tostring(v))
    -- show the proof root ignores existing leaves: equals root of tree {a, pristine, pristine, pristine}
    local e = ht.frontier(2, "keccak256"); ht.frontier_push_back(e, hf("a"))
    if p.root_hash == ht.frontier_get_root_hash(e) then
        print("     (proof root == root of a tree holding only the new leaf; existing 4 leaves ignored)")
    end
end

if bugs > 0 then os.exit(1) end
print("OK: next_proofs rejects overflow")
