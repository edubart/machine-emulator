-- Proof: cartesi.keccak256/sha256(left, "") and (left, nil) silently fall back to single-input hash,
-- and frontier functions in cartesi.hash-tree accept non-32-byte entries without error.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local bugs = 0
local function bug(msg) bugs = bugs + 1; print("BUG: " .. msg) end
local function ok(msg) print("ok: " .. msg) end

local a = ("a"):rep(32)
local b = ("b"):rep(32)

for _, hn in ipairs({ "keccak256", "sha256" }) do
    local h = cartesi[hn]
    -- 1. explicit empty second argument
    local s, r = pcall(h, a, "")
    if s and r == h(a) then
        bug(hn .. '(a, "") returned ' .. hn .. "(a) instead of raising an error")
    else
        ok(hn .. '(a, "") -> ' .. tostring(s) .. " " .. (s and cartesi.tohex(r) or tostring(r)))
    end
    -- 2. explicit nil second argument
    s, r = pcall(h, a, nil)
    if s and r == h(a) then
        bug(hn .. "(a, nil) returned " .. hn .. "(a) instead of raising an error")
    else
        ok(hn .. "(a, nil) -> " .. tostring(s))
    end
    -- control: empty FIRST argument with 32-byte second raises
    s, r = pcall(h, "", a)
    ok(hn .. '("", a) raises: ' .. tostring(not s) .. " (" .. tostring(r) .. ")")
end

-- 3. frontier_push_back accepts "" entry; parent becomes keccak256(a), not concat hash
do
    local f = ht.frontier(4, "keccak256")
    ht.frontier_push_back(f, a)
    local s, e = pcall(ht.frontier_push_back, f, "")
    if s then
        if f[2] == cartesi.keccak256(a) then
            bug('frontier_push_back(f, "") accepted; f[2] == keccak256(a) (single-input hash of left sibling)')
        else
            bug('frontier_push_back(f, "") accepted a non-hash entry')
        end
    else
        ok('frontier_push_back(f, "") rejected: ' .. tostring(e))
    end
end

-- 4. frontier_push_back accepts a 31-byte (truncated) entry at an even position, stores it silently
do
    local f = ht.frontier(4, "keccak256")
    local s, e = pcall(ht.frontier_push_back, f, ("x"):rep(31))
    if s then
        local r2, root = pcall(ht.frontier_get_root_hash, f)
        bug("frontier_push_back(f, 31-byte entry) accepted; later root computation " ..
            (r2 and "succeeded" or ("fails late with: " .. tostring(root))))
    else
        ok("frontier_push_back rejected 31-byte entry: " .. tostring(e))
    end
end

-- 5. frontier_get_root_hash with pad "" : silently returns a root built from single-input hashes
do
    local f = ht.frontier(4, "keccak256")
    ht.frontier_push_back(f, a)
    local s, root = pcall(ht.frontier_get_root_hash, f, "")
    if s then
        bug('frontier_get_root_hash(f, "") accepted empty pad, returned ' .. cartesi.tohex(root))
    else
        ok('frontier_get_root_hash(f, "") rejected: ' .. tostring(root))
    end
end

-- 6. frontier_next_proofs with an empty output hash entry at an odd position
do
    local f = ht.frontier(4, "keccak256")
    local s, proofs = pcall(ht.frontier_next_proofs, f, { a, "" })
    if s then
        bug('frontier_next_proofs(f, {a, ""}) accepted; root ' .. cartesi.tohex(proofs[1].root_hash) ..
            ", target_hash[2] length " .. #proofs[2].target_hash)
        -- and the bad proof verifies
        local vs = pcall(ht.verify_slice, proofs[1], "keccak256")
        print("   proof[1] verifies against that root: " .. tostring(vs))
    else
        ok("frontier_next_proofs rejected: " .. tostring(proofs))
    end
end

-- 7. frontier(proof) with "" sibling
do
    local f = ht.frontier(4, "keccak256")
    local proofs = ht.frontier_next_proofs(f, { a, b })
    local p = proofs[2]
    p.sibling_hashes[1] = ""   -- sibling of leaf 1 (a) replaced by empty string: hash_function("", b) raises
    local s, e = pcall(ht.frontier, p, "keccak256")
    ok("frontier(proof with first sibling \"\") -> " .. tostring(s) .. " " .. tostring(e))
end

-- 8. verify_slice with "" sibling where current hash is left child: computed root is keccak(h), not error
do
    local proof = { target_address = 0, log2_target_size = 0, log2_root_size = 1,
        target_hash = a, sibling_hashes = { "" }, root_hash = cartesi.keccak256(a) }
    local s = pcall(ht.verify_slice, proof, "keccak256")
    if s then
        bug('verify_slice accepted a proof with an empty sibling hash (root = keccak256(target))')
    else
        ok("verify_slice rejected empty sibling")
    end
end

if bugs > 0 then
    print(("%d defect(s) observed"):format(bugs))
    os.exit(1)
end
print("no defect")
os.exit(0)
