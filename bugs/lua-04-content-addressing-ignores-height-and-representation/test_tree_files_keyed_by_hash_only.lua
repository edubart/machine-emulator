-- Repro: frontier forest tree files are keyed only by hash (src/cartesi/hash-tree.lua).
-- (a)  the same hash stored at another height by another forest makes a load raise;
-- (a') same, reverse store order;
-- (b)  a coarser representation stored first hides a finer forest's leaves after reload;
-- (c)  case (a) inside a single forest stored alone (no shared directory);
-- (d)  case (b) inside a single forest stored alone.
-- Usage (from the repo root): eval $(make -s env); lua5.4 bugs/<this dir>/test_tree_files_keyed_by_hash_only.lua [workdir]
-- Exits 1 and prints "BUG" lines while the bug is present; prints "PASS" once fixed.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local K = cartesi.keccak256
math.randomseed(os.time())
local root = arg[1] or os.getenv("WORKDIR") or os.getenv("TMPDIR") or "/tmp"
local dir = root .. "/lua04-" .. tostring(os.time()) .. "-" .. tostring(math.random(1 << 30))
local function sh(c) assert(os.execute(c)) end
local failures = 0
local function fresh() sh("rm -rf '" .. dir .. "'; mkdir -p '" .. dir .. "/forests'") end
local function bug(msg)
    print("BUG " .. msg)
    failures = failures + 1
end

-- Pristine chain: z[0] is the hash of a zero word, z[i+1] = H(z[i], z[i]).
local z = { [0] = K(string.rep("\0", 32)) }
for i = 1, 8 do
    z[i] = K(z[i - 1], z[i - 1])
end

---------------------------------------------------------------------------
-- (a) Forest X (height 2) has leaves z1 (roots of 2-word pristine chunks), so its root
-- z3 sits at height 2. Forest Y (height 4) has word leaves z0: its left half [0,8) is a
-- stored tree with hash z3 at height 3. Both share one forests directory.
fresh()
local x = ht.frontier_forest(2, "keccak256")
ht.frontier_forest_pad_back(x, z[1], 4, 0)
assert(ht.frontier_forest_get_root_hash(x) == z[3])
ht.frontier_forest_store(x, dir .. "/forests", dir .. "/x.json")

local others = {}
for i = 1, 8 do
    others[i] = K("leaf" .. i)
end
local y = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_pad_back(y, z[0], 8, 0)
ht.frontier_forest_append(y, others)
assert(ht.frontier_forest_get_node_hash(y, 0, 3) == z[3])
assert(ht.frontier_forest_get_node_hash(y, 0, 0) == z[0])
ht.frontier_forest_store(y, dir .. "/forests", dir .. "/y.json")
local ok, res = pcall(ht.frontier_forest_load, dir .. "/forests", dir .. "/y.json")
if not ok then
    bug("(a): reloading forest Y raises because forest X stored the same hash at another height: " .. tostring(res))
elseif ht.frontier_forest_get_node_hash(res, 0, 0) ~= z[0] then
    bug("(a): reloaded forest Y cannot answer leaf 0")
else
    print("ok (a): Y reloads and answers leaf 0")
end

-- (a') the reverse store order: Y first, then X fails to reload
fresh()
local y2 = ht.frontier_forest(4, "keccak256")
ht.frontier_forest_pad_back(y2, z[0], 8, 0)
ht.frontier_forest_append(y2, others)
ht.frontier_forest_store(y2, dir .. "/forests", dir .. "/y.json")
local x2 = ht.frontier_forest(2, "keccak256")
ht.frontier_forest_pad_back(x2, z[1], 4, 0)
ht.frontier_forest_store(x2, dir .. "/forests", dir .. "/x.json")
ok, res = pcall(ht.frontier_forest_load, dir .. "/forests", dir .. "/x.json")
if not ok then
    bug("(a'): reloading forest X raises because forest Y stored the same hash at another height: " .. tostring(res))
else
    print("ok (a'): X reloads")
end

---------------------------------------------------------------------------
-- (b) Same hash and height, different representation. Coarse forest C has two opaque
-- height-1 leaves R = H(a,b). Fine forest F has the four leaves a,b,a,b. Coarse is
-- stored first; the fine store skips the existing file and loses its leaves on reload.
fresh()
local a, b = K("a"), K("b")
local R = K(a, b)
local c = ht.frontier_forest(2, "keccak256")
ht.frontier_forest_pad_back(c, R, 2, 1)
ht.frontier_forest_store(c, dir .. "/forests", dir .. "/c.json")
local f = ht.frontier_forest(2, "keccak256")
ht.frontier_forest_append(f, { a, b, a, b })
assert(ht.frontier_forest_get_root_hash(f) == ht.frontier_forest_get_root_hash(c))
assert(ht.frontier_forest_get_node_hash(f, 0, 0) == a)
assert(ht.frontier_forest_get_siblings(f, 1, 0))
ht.frontier_forest_store(f, dir .. "/forests", dir .. "/f.json")
local f2 = ht.frontier_forest_load(dir .. "/forests", dir .. "/f.json")
local leaf, lerr = ht.frontier_forest_get_node_hash(f2, 0, 0)
local sibs, serr = ht.frontier_forest_get_siblings(f2, 1, 0)
if leaf ~= a or not sibs then
    bug(
        string.format(
            "(b): reloaded fine forest lost its leaves: get_node_hash(0,0) -> %s (%s); get_siblings(1,0) -> %s (%s)",
            tostring(leaf and cartesi.tohex(leaf)),
            tostring(lerr),
            tostring(sibs),
            tostring(serr)
        )
    )
else
    print("ok (b): fine forest keeps its leaves")
end

---------------------------------------------------------------------------
-- (c) Single forest, stored alone: leaves z1 x4 make a height-2 node with hash z3 at (0,2),
-- and later leaves z0 x8 make a height-3 node with the same hash z3 at (8,3).
fresh()
local s = ht.frontier_forest(5, "keccak256")
ht.frontier_forest_pad_back(s, z[1], 4, 0)
local o = {}
for i = 1, 4 do
    o[i] = K("o" .. i)
end
ht.frontier_forest_append(s, o)
ht.frontier_forest_pad_back(s, z[0], 8, 0)
local p = {}
for i = 1, 16 do
    p[i] = K("p" .. i)
end
ht.frontier_forest_append(s, p)
assert(ht.frontier_forest_get_node_hash(s, 0, 2) == z[3])
assert(ht.frontier_forest_get_node_hash(s, 8, 3) == z[3])
assert(ht.frontier_forest_get_node_hash(s, 8, 0) == z[0])
ht.frontier_forest_store(s, dir .. "/forests", dir .. "/s.json")
ok, res = pcall(ht.frontier_forest_load, dir .. "/forests", dir .. "/s.json")
if not ok then
    bug("(c): a single forest stored alone cannot be reloaded: " .. tostring(res))
elseif ht.frontier_forest_get_node_hash(res, 8, 0) ~= z[0] then
    bug("(c): reloaded single forest cannot answer leaf 8")
else
    print("ok (c): single forest reloads")
end

-- (d) Single forest, stored alone: opaque R x2 at height 1, then leaves a,b,a,b.
fresh()
local h = ht.frontier_forest(3, "keccak256")
ht.frontier_forest_pad_back(h, R, 2, 1)
ht.frontier_forest_append(h, { a, b, a, b })
assert(ht.frontier_forest_get_node_hash(h, 4, 0) == a)
ht.frontier_forest_store(h, dir .. "/forests", dir .. "/h.json")
local h2 = ht.frontier_forest_load(dir .. "/forests", dir .. "/h.json")
leaf, lerr = ht.frontier_forest_get_node_hash(h2, 4, 0)
if leaf ~= a then
    bug("(d): single forest stored alone lost leaf 4 after reload: " .. tostring(lerr))
else
    print("ok (d): single forest keeps its leaves")
end

sh("rm -rf '" .. dir .. "'")
if failures > 0 then
    print(failures .. " check(s) failed: tree files are keyed only by hash")
    os.exit(1)
end
print("PASS")
