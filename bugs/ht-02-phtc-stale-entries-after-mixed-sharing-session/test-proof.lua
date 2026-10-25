-- Stale persisted page hash-tree cache (phtc) entries after a session where the cache and a range's
-- backing store had different persistence. A later load with matching sharing flags evicts nothing,
-- so get_proof uses stale page hashes: wrong target/sibling hashes, while get_root_hash and
-- verify_hash_tree still succeed.
local cartesi = require("cartesi")

-- Scratch directory outside the repo (machine directories and a ~50 MB phtc file are created there).
local W = os.tmpname()
os.remove(W)
W = W .. "-ht02"
local RAM = cartesi.AR_RAM_START
local PAGE = string.rep

local function sh(cmd) assert(os.execute(cmd)) end

-- Roll a proof up to its root (siblings ordered from the target level upwards).
local function rollup(p)
    local h = p.target_hash
    for i, s in ipairs(p.sibling_hashes) do
        local height = p.log2_target_size + i - 1
        if (p.target_address >> height) & 1 == 0 then
            h = cartesi.keccak256(h, s)
        else
            h = cartesi.keccak256(s, h)
        end
    end
    return h
end

local function eq_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local bugs = 0

-- Load dir with the given sharing mode, collect root/proof/verify, and compare against a reference
-- machine loaded from the same directory with clear_hash_tree (recomputes everything from memory).
local function check(route, dir, sharing, sharing_name)
    local m = cartesi.machine(dir, nil, sharing)
    local mem = m:read_memory(RAM, 4)
    local root = m:get_root_hash()
    local p = m:get_proof(RAM, 5)
    local verify = m:verify_hash_tree()
    m:destroy()
    local r = cartesi.machine(dir, { clear_hash_tree = true }, cartesi.SHARING_NONE)
    local rroot = r:get_root_hash()
    local rp = r:get_proof(RAM, 5)
    r:destroy()
    assert(rollup(rp) == rp.root_hash and rp.root_hash == rroot, "reference proof must roll up to its root")
    local target_ok = p.target_hash == rp.target_hash
    local siblings_ok = eq_list(p.sibling_hashes, rp.sibling_hashes)
    local rolls = rollup(p) == p.root_hash and p.root_hash == root
    print(string.format(
        "[%s %s] mem=%s root_ok=%s verify_hash_tree=%s proof_target_ok=%s proof_siblings_ok=%s proof_rolls_to_root=%s",
        route, sharing_name, mem, tostring(root == rroot), tostring(verify), tostring(target_ok),
        tostring(siblings_ok), tostring(rolls)))
    if root == rroot and (not target_ok or not siblings_ok or not rolls) then
        print(string.format("BUG: [%s %s] get_proof(RAM,5) uses stale cached page hashes (root hash correct, "
            .. "verify_hash_tree=%s) -> proof does not match memory / does not roll up to root", route,
            sharing_name, tostring(verify)))
        bugs = bugs + 1
    end
end

-- Route A: RAM shared (persisted), hash tree private. Session 2 writes RAM file + its dht/dpt but not phtc.
local function route_a()
    sh("rm -rf " .. W .. " && mkdir -p " .. W)
    local m = cartesi.machine({
        ram = { length = 0x3000, backing_store = { data_filename = W .. "/ram.bin", shared = true, create = true } },
    })
    m:write_memory(RAM, PAGE("A", 0x1000))
    m:get_root_hash()
    m:get_proof(RAM, 5) -- make sure the page is in the cache
    m:store(W .. "/S", cartesi.SHARING_ALL)
    m:destroy()
    -- session 2: per stored config, RAM shared, hash tree private
    local m2 = cartesi.machine(W .. "/S", nil, cartesi.SHARING_CONFIG)
    m2:write_memory(RAM, PAGE("B", 0x1000))
    m2:get_root_hash()
    m2:get_proof(RAM, 5)
    m2:destroy()
    check("A(ram shared, cache private)", W .. "/S", cartesi.SHARING_NONE, "SHARING_NONE")
end

-- Route B: hash tree shared (persisted), RAM private. Session 2 writes phtc but not RAM.
local function route_b()
    sh("rm -rf " .. W .. " && mkdir -p " .. W)
    local m = cartesi.machine({
        ram = { length = 0x3000 },
        hash_tree = { shared = true, create = true, sht_filename = W .. "/t.sht", phtc_filename = W .. "/t.phtc" },
    })
    m:write_memory(RAM, PAGE("A", 0x1000))
    m:get_root_hash()
    m:store(W .. "/T", cartesi.SHARING_ALL)
    m:destroy()
    -- session 2: per stored config, hash tree shared, RAM private
    local m2 = cartesi.machine(W .. "/T", nil, cartesi.SHARING_CONFIG)
    m2:write_memory(RAM, PAGE("B", 0x1000))
    m2:get_root_hash()
    m2:get_proof(RAM, 5)
    m2:destroy()
    check("B(cache shared, ram private)", W .. "/T", cartesi.SHARING_NONE, "SHARING_NONE")
    check("B(cache shared, ram private)", W .. "/T", cartesi.SHARING_ALL, "SHARING_ALL")
end

route_a()
route_b()
sh("rm -rf " .. W)
if bugs > 0 then
    os.exit(1)
end
print("OK: no stale page hash-tree cache entries observed")
os.exit(0)
