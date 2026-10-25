-- Proves: frontier_forest_store drops an expansion placed inside a single-raw-hash fixed-point
-- wrapper (base_height == height) of a forest that had no directory when it was expanded.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fs_dir = os.tmpname(); os.remove(fs_dir)
assert(os.execute("mkdir -p " .. fs_dir))
local function h(i) return cartesi.keccak256(string.pack("<i8", i)) end
local function inner_forest(a, b)
    local inner = ht.frontier_forest(1, "keccak256")
    ht.frontier_forest_push_back(inner, a); ht.frontier_forest_push_back(inner, b)
    return inner
end
local failed = false

-- Control: the expanded leaf sits in a regular fixed-point tree (two height-1 values flushed together).
do
    local dir = fs_dir .. "/control"; assert(os.execute("mkdir -p " .. dir))
    local inner = inner_forest(h(1), h(2))
    local A = ht.frontier_forest_get_root_hash(inner)
    local f = ht.frontier_forest(2, "keccak256")
    ht.frontier_forest_push_back(f, A, 1)
    ht.frontier_forest_push_back(f, h(9), 1)
    local root = ht.frontier_forest_get_root_hash(f)
    ht.frontier_forest_expand_leaf(f, 0, inner)
    assert(ht.frontier_forest_get_node_hash(f, 0, 0) == h(1))
    ht.frontier_forest_store(f, dir, dir .. "/frontier.json")
    local g = ht.frontier_forest_load(dir, dir .. "/frontier.json")
    assert(ht.frontier_forest_get_root_hash(g) == root)
    local n, err = ht.frontier_forest_get_node_hash(g, 0, 0)
    print("control: after load node(0,0) ok =", n == h(1), err)
end

-- Bug case: A flushed alone at height 1 -> new_fixed_point_tree(1, 0, {A}) wrapper.
do
    local dir = fs_dir .. "/bug"; assert(os.execute("mkdir -p " .. dir))
    local inner = inner_forest(h(1), h(2))
    local A = ht.frontier_forest_get_root_hash(inner)
    local f = ht.frontier_forest(2, "keccak256")
    ht.frontier_forest_push_back(f, A, 1)    -- pending height 1 {A}
    ht.frontier_forest_push_back(f, h(3), 0) -- height change flushes A alone -> raw wrapper
    ht.frontier_forest_push_back(f, h(4), 0)
    local root = ht.frontier_forest_get_root_hash(f)
    ht.frontier_forest_expand_leaf(f, 0, inner)
    local before = ht.frontier_forest_get_node_hash(f, 0, 0)
    local sib_before = ht.frontier_forest_get_siblings(f, 0, 0)
    print("bug case: before store node(0,0) ok =", before == h(1), "siblings =", sib_before and #sib_before)
    ht.frontier_forest_store(f, dir, dir .. "/frontier.json") -- reports success
    local p = io.popen("ls " .. dir); local listing = p:read("a"); p:close()
    print("files stored:\n" .. listing)
    local A_file = io.open(dir .. "/" .. cartesi.tohex(A) .. ".json")
    print("expansion file for A exists =", A_file ~= nil); if A_file then A_file:close() end
    local g = ht.frontier_forest_load(dir, dir .. "/frontier.json")
    print("root equal after load =", ht.frontier_forest_get_root_hash(g) == root)
    local n, err = ht.frontier_forest_get_node_hash(g, 0, 0)
    local s, serr = ht.frontier_forest_get_siblings(g, 0, 0)
    print("after load node(0,0) =", n and cartesi.tohex(n), err, "siblings =", s and #s, serr)
    if n ~= h(1) then
        print("BUG: frontier_forest_store silently dropped the expansion inside a single-raw-hash "
            .. "fixed-point wrapper; after reload node(0,0) is unavailable: " .. tostring(err or serr))
        failed = true
    end
end
os.execute("rm -rf " .. fs_dir)
os.exit(failed and 1 or 0)
