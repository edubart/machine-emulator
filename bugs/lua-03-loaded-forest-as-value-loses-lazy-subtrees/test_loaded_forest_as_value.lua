-- Repro: a lazily loaded forest used as a value (pad_back/push_back/expand_leaf) loses its
-- unloaded descendants in the destination forest, and storing the destination does not copy them.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local K = cartesi.keccak256
-- Scratch directory: first argument, $WORKDIR, or $TMPDIR (default /tmp), plus a unique suffix.
local base = (arg[1] or os.getenv("WORKDIR") or os.getenv("TMPDIR") or "/tmp") .. "/lua03-" .. tostring(os.time()) .. "-" .. math.random(1 << 30)
assert(os.execute("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "/A' '" .. base .. "/B' '" .. base .. "/C'"))

local function new_inner()
    local sub = ht.frontier_forest(1, "keccak256") -- leaves a, b
    ht.frontier_forest_append(sub, { K("a"), K("b") })
    local inner = ht.frontier_forest(3, "keccak256") -- sub repeated 4 times: a b a b a b a b
    ht.frontier_forest_pad_back(inner, sub, 4)
    return inner
end
ht.frontier_forest_store(new_inner(), base .. "/A", base .. "/inner.json")
local function load_inner() return ht.frontier_forest_load(base .. "/A", base .. "/inner.json") end

local failures = 0
local function check(label, got, want)
    if got == want then
        print("ok:   " .. label)
    else
        failures = failures + 1
        print(string.format("BUG: %s: expected %s, got %s", label, want and cartesi.tohex(want) or "nil",
            type(got) == "string" and #got == 32 and cartesi.tohex(got) or tostring(got)))
    end
end
local function q(f, pos, h) local v, err = ht.frontier_forest_get_node_hash(f, pos, h or 0); return v or ("nil (" .. tostring(err) .. ")") end

-- Controls
check("loaded inner answers leaf 1 itself", q(load_inner(), 1), K("b"))
local ctrl = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_pad_back(ctrl, new_inner(), 2)
check("outer with in-memory inner, leaf 1", q(ctrl, 1), K("b"))

-- 1. pad_back of a loaded forest into an in-memory forest
local outer = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_pad_back(outer, load_inner(), 2)
check("pad_back(loaded inner) into in-memory outer: leaf 1", q(outer, 1), K("b"))
check("root hash still matches", ht.frontier_forest_get_root_hash(outer), ht.frontier_forest_get_root_hash(ctrl))

-- 2. store outer into a different directory B, reload: data never copied
ht.frontier_forest_store(outer, base .. "/B", base .. "/outer.json")
local o2 = ht.frontier_forest_load(base .. "/B", base .. "/outer.json")
check("outer stored in B and reloaded: leaf 9", q(o2, 9), K("b"))

-- 3. push_back of a loaded forest into a forest that already has its own directory C
local outer3 = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_push_back(outer3, load_inner())
ht.frontier_forest_push_back(outer3, K("z"), 3)
ht.frontier_forest_store(outer3, base .. "/C", base .. "/outer3.json")
check("push_back(loaded inner) into outer with directory C: leaf 3", q(outer3, 3), K("b"))

-- 4. expand_leaf with a loaded subtree forest
local outer4 = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_push_back(outer4, ht.frontier_forest_get_root_hash(load_inner()), 3)
ht.frontier_forest_push_back(outer4, K("z"), 3)
check("leaf 0 opaque before expansion", select(1, ht.frontier_forest_get_node_hash(outer4, 0, 0)), nil)
ht.frontier_forest_expand_leaf(outer4, 0, load_inner())
check("expand_leaf(loaded inner): leaf 1", q(outer4, 1), K("b"))

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all ok")
