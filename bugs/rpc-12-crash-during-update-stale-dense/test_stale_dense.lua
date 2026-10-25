-- Deterministic reproduction: a stored machine directory in the exact on-disk state that
-- hash_tree::update() leaves behind when the process dies after copying new page roots into
-- the dense-tree leaves (return_updated_dirty_pages) but before update_dense_trees() /
-- update_sparse_tree() / dpt.clean() finish.
--
-- State crafted: RAM .dpt = dirty (pre-update), RAM .dht leaves = new page roots (post-update),
-- RAM .dht inner nodes = old (pre-update), hash_tree.sht = old (pre-update).
-- Reloading this directory must either give the correct root hash or fail loudly.
local cartesi = require("cartesi")

local base = arg[1] or (os.getenv("TMPDIR") or "/tmp") .. "/stale-dense-" .. tostring(os.time()) .. "-" .. tostring(math.random(1 << 30))
local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok, "command failed: " .. cmd)
end
sh("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "'")

local RAM_LEN = 4 << 20
local RAM_FILE = string.format("%016x-%x", cartesi.AR_RAM_START, RAM_LEN)
local A = base .. "/A" -- dirty, pre-update state (as left by a run that did not hash yet)
local C = base .. "/C" -- same, after a complete update
local D = base .. "/D" -- crafted "crashed mid-update" state

local function readfile(p)
    local f = assert(io.open(p, "rb"))
    local d = f:read("a")
    f:close()
    return d
end
local function writefile(p, d)
    local f = assert(io.open(p, "wb"))
    f:write(d)
    f:close()
end

-- 1. Create and store a small machine (store leaves the hash tree clean).
do
    local m <close> = cartesi.machine({ ram = { length = RAM_LEN } })
    m:store(A)
end

-- 2. Load SHARING_ALL, modify a few RAM pages, close without hashing: .bin updated, .dpt dirty,
--    .dht and .sht still describe the old contents.
do
    local m <close> = cartesi.new():load(A, nil, cartesi.SHARING_ALL)
    for i = 0, 15 do
        m:write_memory(cartesi.AR_RAM_START + i * 4096 * 7, string.rep(string.char(0x11 + i), 4096))
    end
end

-- 3. C = A after a complete hash-tree update performed in place (SHARING_ALL).
sh("cp -a '" .. A .. "' '" .. C .. "'")
local correct
do
    local m <close> = cartesi.new():load(C, nil, cartesi.SHARING_ALL)
    correct = m:get_root_hash()
end

-- Reference via clear_hash_tree on the dirty directory.
local reference
do
    local m <close> = cartesi.new():load(A, { clear_hash_tree = true }, cartesi.SHARING_NONE)
    reference = m:get_root_hash()
end
assert(correct == reference, "sanity: in-place update and clear_hash_tree disagree")

local old_root
do
    local m <close> = cartesi.new():load(A, { clear_hash_tree = true }, cartesi.SHARING_NONE)
end

-- 4. D = A, but with the RAM dense-tree leaf level (second half of the heap-ordered .dht)
--    taken from C: exactly what is on disk after return_updated_dirty_pages() copied the new
--    page roots into the leaves and the process died before update_dense_trees() ran.
sh("cp -a '" .. A .. "' '" .. D .. "'")
local a_dht = readfile(A .. "/" .. RAM_FILE .. ".dht")
local c_dht = readfile(C .. "/" .. RAM_FILE .. ".dht")
assert(#a_dht == #c_dht and #a_dht % 2 == 0)
local half = #a_dht // 2
assert(a_dht:sub(half + 1) ~= c_dht:sub(half + 1), "sanity: leaves should differ")
assert(a_dht:sub(1, half) ~= c_dht:sub(1, half), "sanity: inner nodes should differ")
writefile(D .. "/" .. RAM_FILE .. ".dht", a_dht:sub(1, half) .. c_dht:sub(half + 1))
-- .dpt stays as in A (dirty), because dpt.clean() runs only after a successful full update.
assert(readfile(D .. "/" .. RAM_FILE .. ".dpt") == readfile(A .. "/" .. RAM_FILE .. ".dpt"))

-- Root hash the pre-update tree claims (stale .sht)
do
    local m <close> = cartesi.new():load(A, nil, cartesi.SHARING_NONE)
end

-- 5. Reload D and hash it.
local got, ok_verify
do
    local m <close> = cartesi.new():load(D, nil, cartesi.SHARING_NONE)
    got = m:get_root_hash()
    ok_verify = m:verify_hash_tree()
end

-- Also reload D in SHARING_ALL (what a validator node restarting on its directory would do),
-- then reload once more to see the corruption persists.
local got_all, got_again
do
    local m <close> = cartesi.new():load(D, nil, cartesi.SHARING_ALL)
    got_all = m:get_root_hash()
end
do
    local m <close> = cartesi.new():load(D, nil, cartesi.SHARING_NONE)
    got_again = m:get_root_hash()
end

print("correct root hash        :", cartesi.tohex(correct))
print("reloaded D root hash     :", cartesi.tohex(got))
print("D verify_hash_tree       :", tostring(ok_verify))
print("D (SHARING_ALL) root hash:", cartesi.tohex(got_all))
print("D reloaded again         :", cartesi.tohex(got_again))

sh("rm -rf '" .. base .. "'")

if got ~= correct or got_all ~= correct or got_again ~= correct then
    print("BUG: stored machine interrupted mid hash-tree update reloads with a wrong root hash "
        .. "(dirty pages whose leaves already hold the new root are marked clean and the stale inner "
        .. "dense nodes / sparse tree are never recomputed)")
    os.exit(1)
end
print("OK: root hash recovered correctly")
os.exit(0)
