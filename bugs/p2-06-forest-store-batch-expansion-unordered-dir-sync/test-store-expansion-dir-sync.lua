-- Proof: frontier_forest_store writes an in-memory expansion (parent X plus children) in one
-- batch with a single directory sync, unlike store_expansion, which syncs the directory between
-- the children and the parent. X is already reachable by hash from another committed forest A.
local cartesi = require("cartesi")
local fs = require("cartesi.filesystem")
local ht = require("cartesi.hash-tree")
local K = cartesi.keccak256
local HT = "keccak256"

local base = arg[0]:match("^(.*)/[^/]*$") or "."
local D = base .. "/run." .. tostring(os.time()) .. "." .. tostring(math.random(1 << 30))
assert(os.execute("rm -rf '" .. D .. "' && mkdir -p '" .. D .. "/forests'"))
local DIR = D .. "/forests"

-- trace renames and directory syncs
local events = {}
local orig_rename, orig_sync = fs.rename_file, fs.sync_directory
fs.rename_file = function(from, to)
    events[#events + 1] = { "rename", to }
    return orig_rename(from, to)
end
fs.sync_directory = function(d)
    events[#events + 1] = { "sync", d }
    return orig_sync(d)
end

local function leaf(s) return K(s) end
local function h1(a, b) -- full height-1 forest over two leaves -> fixed_point tree with a file
    local f = ht.frontier_forest(1, HT)
    ht.frontier_forest_append(f, { leaf(a), leaf(b) })
    return f
end
local function bundle() -- mixed height-2 forest: two height-1 fixed-point children
    local f = ht.frontier_forest(2, HT)
    ht.frontier_forest_push_back(f, h1("a", "b"))
    ht.frontier_forest_push_back(f, h1("c", "d"))
    return f
end
local X = ht.frontier_forest_get_root_hash(bundle())
local left = ht.frontier_forest_get_root_hash(h1("a", "b"))
local right = ht.frontier_forest_get_root_hash(h1("c", "d"))
local Y = K("other")
local function path(h) return DIR .. "/" .. cartesi.tohex(h) .. ".json" end

local function outer() -- height 3, two opaque height-2 leaves X, Y
    local f = ht.frontier_forest(3, HT)
    ht.frontier_forest_push_back(f, X, 2)
    ht.frontier_forest_push_back(f, Y, 2)
    return f
end

-- A: committed in DIR, holds X as an opaque leaf
local A = outer()
ht.frontier_forest_store(A, DIR, D .. "/A.json")

-- Control: forest C with a directory expanding X uses store_expansion (ordered).
local function check_order(label)
    local last_child, x_rename
    for i, e in ipairs(events) do
        if e[1] == "rename" and (e[2] == path(left) or e[2] == path(right)) then last_child = i end
        if e[1] == "rename" and e[2] == path(X) then x_rename = i end
    end
    assert(last_child and x_rename, label .. ": expected child and parent renames")
    local synced = false
    for i = last_child + 1, x_rename - 1 do
        if events[i][1] == "sync" then synced = true end
    end
    print(string.format("%s: child rename #%d, X rename #%d, dir sync in between: %s", label, last_child, x_rename,
        tostring(synced)))
    return synced
end

-- B: no directory, expands X in memory, then first store into the shared DIR
local B = outer()
ht.frontier_forest_expand_leaf(B, 0, bundle())
events = {}
ht.frontier_forest_store(B, DIR, D .. "/B.json")
local ordered_store = check_order("frontier_forest_store (first store of in-memory expansion)")

-- control run in a second directory: same expansion through store_expansion
local DIR2 = D .. "/forests2"
assert(os.execute("mkdir -p '" .. DIR2 .. "'"))
local C = outer()
ht.frontier_forest_store(C, DIR2, D .. "/C.json")
local saved = DIR
DIR = DIR2
events = {}
ht.frontier_forest_expand_leaf(C, 0, bundle())
local ordered_expand = check_order("frontier_forest_expand_leaf on stored forest (store_expansion)")
DIR = saved

-- Consequence: emulate the crash where X's directory entry survived but the right child's did not.
fs.rename_file, fs.sync_directory = orig_rename, orig_sync
assert(fs.exists(path(X)) and fs.exists(path(right)))
os.remove(path(right))
local A2 = ht.frontier_forest_load(DIR, D .. "/A.json")
local h, err = ht.frontier_forest_get_node_hash(A2, 2, 0)
print("get_node_hash(A, 2, 0) after simulated crash:", h and cartesi.tohex(h) or "nil", err)
local ok, eerr = pcall(ht.frontier_forest_expand_leaf, A2, 0, bundle())
print("expand_leaf(A, 0, X-bundle) after simulated crash:", ok, eerr)
local unopenable = (h == nil) and not ok and tostring(eerr):find("leaf height mismatch")

os.execute("rm -rf '" .. D .. "'")
if not ordered_store and ordered_expand then
    print("BUG: frontier_forest_store renames expansion top file X (already referenced by committed forest A)"
        .. " in the same batch as its child files with no directory sync in between; store_expansion does sync."
        .. (unopenable and " If a child entry is lost, A can no longer query or re-expand X with its bundle."
            or ""))
    os.exit(1)
end
print("OK: parent written after children are durable")
os.exit(0)
