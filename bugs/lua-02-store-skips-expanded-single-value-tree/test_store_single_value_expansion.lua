-- store_tree skips single-value fixed-point trees (base_height == height), dropping expansions under them.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fs = require("cartesi.filesystem")
local K = cartesi.keccak256
local work = (arg[1] or os.getenv("WORKDIR") or os.getenv("TMPDIR") or "/tmp") .. "/lua02-" .. tostring(os.time()) .. "-" .. math.random(1 << 30)

local function fresh(name)
    local d = work .. "/" .. name
    assert(os.execute("rm -rf '" .. d .. "' && mkdir -p '" .. d .. "/forests'"))
    return d
end
local function bundle(tag)
    local b = ht.frontier_forest(2, "keccak256")
    ht.frontier_forest_append(b, { K(tag .. "0"), K(tag .. "1"), K(tag .. "2"), K(tag .. "3") })
    return b
end

local failures = 0
local function check(label, before, after)
    local ok = (after == before)
    print(string.format("%-60s before=%s after_reload=%s", label, tostring(before ~= nil), tostring(after ~= nil)))
    if not ok then
        failures = failures + 1
        print("BUG: " .. label .. ": node answerable before store is opaque after frontier_forest_load")
    end
end

-- Control: two bundles flushed together -> fixed-point tree base_height 2 < height 3: expansion persists.
do
    local d = fresh("control")
    local R = ht.frontier_forest_get_root_hash(bundle("s"))
    local f = ht.frontier_forest(3, "keccak256")
    ht.frontier_forest_pad_back(f, R, 2, 2)
    ht.frontier_forest_expand_leaf(f, 0, bundle("s"))
    local before = ht.frontier_forest_get_node_hash(f, 1, 0)
    assert(before == K("s1"))
    ht.frontier_forest_store(f, d .. "/forests", d .. "/claim.json")
    local g = ht.frontier_forest_load(d .. "/forests", d .. "/claim.json")
    local after = ht.frontier_forest_get_node_hash(g, 1, 0)
    print("control (2-value tree) after reload ok:", after == before)
    assert(after == before, "control failed; test setup is wrong")
end

-- Case A: bundle root flushed alone (single-value tree), expanded before the first store.
do
    local d = fresh("caseA")
    local R = ht.frontier_forest_get_root_hash(bundle("s"))
    local f = ht.frontier_forest(3, "keccak256")
    ht.frontier_forest_push_back(f, R, 2)
    ht.frontier_forest_pad_back(f, K("other"), 2, 1) -- different height flushes R alone
    ht.frontier_forest_expand_leaf(f, 0, bundle("s"))
    local before = ht.frontier_forest_get_node_hash(f, 1, 0)
    assert(before == K("s1"))
    local sib_before = ht.frontier_forest_get_siblings(f, 1, 0)
    ht.frontier_forest_store(f, d .. "/forests", d .. "/claim.json")
    assert(ht.frontier_forest_get_node_hash(f, 1, 0) == before)
    local g = ht.frontier_forest_load(d .. "/forests", d .. "/claim.json")
    local after, err = ht.frontier_forest_get_node_hash(g, 1, 0)
    if err then print("  reload error: " .. err) end
    check("A: expand_leaf then store (no directory at expand time)", before, after)
    local sib_after, err2 = ht.frontier_forest_get_siblings(g, 1, 0)
    if err2 then print("  get_siblings after reload: " .. err2) end
    check("A: get_siblings after reload", sib_before and #sib_before, sib_after and #sib_after)
end

-- Case B: store_expansion (forest already has a directory) with a replacement forest that itself
-- holds an expanded single-value tree.
do
    local d = fresh("caseB")
    -- replacement: height 3, R alone at height 2 then other at height 1, R expanded in memory
    local R = ht.frontier_forest_get_root_hash(bundle("t"))
    local rep = ht.frontier_forest(3, "keccak256")
    ht.frontier_forest_push_back(rep, R, 2)
    ht.frontier_forest_pad_back(rep, K("x"), 2, 1)
    ht.frontier_forest_expand_leaf(rep, 0, bundle("t"))
    local Q = ht.frontier_forest_get_root_hash(rep)
    -- outer forest of height 4 whose leaves at height 3 are Q, Q; stored before the expansion
    local f = ht.frontier_forest(4, "keccak256")
    ht.frontier_forest_pad_back(f, Q, 2, 3)
    ht.frontier_forest_store(f, d .. "/forests", d .. "/claim.json")
    ht.frontier_forest_expand_leaf(f, 0, rep) -- forest has a directory: store_expansion runs
    local before = ht.frontier_forest_get_node_hash(f, 1, 0)
    assert(before == K("t1"))
    ht.frontier_forest_store(f, d .. "/forests", d .. "/claim.json")
    local g = ht.frontier_forest_load(d .. "/forests", d .. "/claim.json")
    local after, err = ht.frontier_forest_get_node_hash(g, 1, 0)
    if err then print("  reload error: " .. err) end
    check("B: nested expansion inside replacement (store_expansion)", before, after)
end

-- Case C: claim-tree-like layout (per-input bundles followed by pad bundles). Flushing 5 values as
-- 4 + 1 leaves a pad bundle alone in a single-value tree; opening it (as open_bundle does) and
-- storing loses the expansion.
do
    local d = fresh("caseC")
    local roots = {}
    for i = 1, 3 do roots[i] = ht.frontier_forest_get_root_hash(bundle("b" .. i)) end
    local pad = ht.frontier_forest_get_root_hash(bundle("pad"))
    local f = ht.frontier_forest(5, "keccak256")
    ht.frontier_forest_append(f, roots, 1, 4, 2) -- 3 bundles (leaves 0..11)
    ht.frontier_forest_pad_back(f, pad, 2, 2) -- 2 pad bundles (leaves 12..19)
    ht.frontier_forest_append(f, roots, 1, 4, 2) -- next input's bundles
    ht.frontier_forest_pad_back(f, pad, nil, 2) -- pad to full
    ht.frontier_forest_expand_leaf(f, 16, bundle("pad"))
    local before = ht.frontier_forest_get_node_hash(f, 17, 0)
    assert(before == K("pad1"))
    ht.frontier_forest_store(f, d .. "/forests", d .. "/claim.json")
    local g = ht.frontier_forest_load(d .. "/forests", d .. "/claim.json")
    local after, err = ht.frontier_forest_get_node_hash(g, 17, 0)
    if err then print("  reload error: " .. err) end
    check("C: claim-like layout, pad bundle opened then stored", before, after)
end

os.execute("rm -rf '" .. work .. "'")
if failures > 0 then
    print(string.format("BUG: %d check(s) failed: store_tree drops expansions under single-value fixed-point trees", failures))
    os.exit(1)
end
print("OK: expansions survive store/load")
os.exit(0)
