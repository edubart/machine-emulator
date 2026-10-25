-- frontier_pad_back with a valid unsigned count >= 2^63 in a tree taller than 64 levels
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local hf = cartesi.keccak256
local pad = hf("pad")
local bug = false

local function same(a, b)
    if #a ~= #b then return false end
    for l = 1, #a do if a[l] ~= b[l] then return false end end
    return true
end

-- Height-66 tree holding one complete height-65 subtree (2^65 leaves).
local f = ht.frontier(66, "keccak256")
ht.frontier_push_back(f, hf("left"), 65)
local before = ht.frontier_copy(f)

-- Reference: pad 2^64-1 leaves as 2^63-1 + 2^63 (both < 2^63 or exactly 2^63 work fine).
local ref = ht.frontier_copy(before)
ht.frontier_pad_back(ref, pad, math.maxinteger) -- 2^63 - 1
ht.frontier_pad_back(ref, pad, math.mininteger) -- 2^63 (unsigned)
local ref_root = ht.frontier_get_root_hash(ref)

-- Same padding in one call: count = -1 means 2^64-1 unsigned; 2^65 + 2^64 - 1 < 2^66 so it fits.
local ok, err = pcall(ht.frontier_pad_back, f, pad, -1)
print("single-call pad_back(2^64-1):", ok, err)
if not ok then
    print("BUG: frontier_pad_back rejected a fitting count 2^64-1 in a height-66 tree: " .. tostring(err))
    bug = true
    if not same(f, before) then
        print("BUG: the failing frontier_pad_back call mutated the frontier")
        bug = true
    end
else
    local root = ht.frontier_get_root_hash(f)
    if root ~= ref_root then
        print("BUG: single-call root differs from split-call root")
        bug = true
    end
end

-- Second shape: count exactly 2^63 (math.mininteger as unsigned) into a height-70 tree holding 2^65
-- leaves. 2^65 + 2^63 < 2^70 fits, and frontier_padding_fits accepts it.
local g = ht.frontier(70, "keccak256")
ht.frontier_push_back(g, hf("a"), 65)
local g_before = ht.frontier_copy(g)
-- Reference: pad 2^63 as two halves of 2^62.
local ref2 = ht.frontier_copy(g)
ht.frontier_pad_back(ref2, pad, 1 << 62)
ht.frontier_pad_back(ref2, pad, 1 << 62)
local ok2, err2 = pcall(ht.frontier_pad_back, g, pad, 1 << 63)
print("height-70 pad_back(2^63):", ok2, err2)
if not ok2 then
    print("BUG: height-70 frontier_pad_back rejected fitting count 2^63: " .. tostring(err2))
    bug = true
    if not same(g, g_before) then print("BUG: the failing call mutated the height-70 frontier") end
elseif ht.frontier_get_root_hash(g) ~= ht.frontier_get_root_hash(ref2) then
    print("BUG: height-70 single-call root differs from split-call root")
    bug = true
end

if bug then os.exit(1) end
print("OK")
