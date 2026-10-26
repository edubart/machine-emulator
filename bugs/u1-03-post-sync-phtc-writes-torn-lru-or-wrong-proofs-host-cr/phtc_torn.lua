-- Proof: after sync_stored, read-only hash-tree queries (get_root_hash / get_proof) on a
-- SHARING_ALL machine rewrite hash_tree.phtc in place (LRU links, paddr_page, payloads).
-- A host crash during the unordered writeback of those dirty pages leaves a .phtc that is a
-- mixture of the synced image (S) and the post-query image (U). We simulate such mixtures
-- page-by-page and show that:
--   (a) some mixtures make the stored machine unloadable, and
--   (b) the mixture "metadata pages written back, payload pages not" loads, has the correct
--       root hash and passes verify_hash_tree(), but returns WRONG word proofs.
-- Usage: source env.sh; lua5.4 phtc_torn.lua
local cartesi = require("cartesi")

local self_path = arg[0]
local W = self_path:match("^(.*)/[^/]*$") or "."
local D = os.getenv("PHTC_TORN_DIR") or assert(io.popen("mktemp -d"):read("l"))
local PHTC_SIZE = 256
local RAM_LEN = 4 << 20
local NPAGES = RAM_LEN // 4096
local PAGE = 4096

local function sh(cmd)
    local ok = os.execute(cmd)
    assert(ok, "command failed: " .. cmd)
end

local function config()
    return {
        ram = { length = RAM_LEN, backing_store = { data_filename = D .. "/ram.bin" } },
        hash_tree = { phtc_size = PHTC_SIZE },
    }
end

-- Pages the validator queries after the sync (more than the cache capacity, so entries are evicted)
local QUERY, CHECK
local function set_query(n)
    QUERY, CHECK = {}, {}
    for i = 0, n - 1 do QUERY[#QUERY + 1] = i end
    -- Order used when checking a reloaded machine: most recently queried pages first (cache hits), then the rest
    local seen = {}
    for k = #QUERY, 1, -1 do CHECK[#CHECK + 1] = QUERY[k]; seen[QUERY[k]] = true end
    for i = 0, NPAGES - 1 do if not seen[i] then CHECK[#CHECK + 1] = i end end
end
-- Proofs of one word in each page of the given list
local function proofs(m, list)
    local out, raw = {}, {}
    for _, i in ipairs(list or CHECK) do
        local p = m:get_proof(0x80000000 + i * PAGE + 64, 5)
        out[i] = p.target_hash .. table.concat(p.sibling_hashes)
        raw[i] = p
    end
    return out, raw
end

if arg[1] == "child" then
    set_query(tonumber(arg[2]))
    sh("rm -rf " .. D .. "/w " .. D .. "/S " .. D .. "/R " .. D .. "/U")
    -- Validator-like sequence: load SHARING_ALL, hash, sync (durable point), then only *query*.
    cartesi.machine:clone_stored(D .. "/base", D .. "/w")
    local m = cartesi.new()
    m:load(D .. "/w", nil, cartesi.SHARING_ALL)
    m:get_root_hash()
    m:sync_stored(D .. "/w")
    sh("cp -a " .. D .. "/w " .. D .. "/S") -- what is durable on disk
    m:get_root_hash()
    sh("cp -a " .. D .. "/w " .. D .. "/R") -- after one more get_root_hash only
    proofs(m, QUERY) -- read-only proof queries
    sh("cp -a " .. D .. "/w " .. D .. "/U") -- page cache contents right before the crash
    io.stdout:flush()
    -- crash without any orderly shutdown
    local f = io.open("/proc/self/stat")
    local pid = f:read("*l"):match("^(%d+)")
    f:close()
    os.execute("kill -9 " .. pid)
    os.exit(99)
end

-- Parent
sh("rm -rf " .. D .. " && mkdir -p " .. D)
do -- RAM image with distinct content per word, so every page has a distinct page hash tree
    local f = assert(io.open(D .. "/ram.bin", "wb"))
    local parts = {}
    for i = 0, NPAGES - 1 do
        for j = 0, PAGE // 8 - 1 do
            parts[#parts + 1] = string.pack("<I8", (i << 20) | j | 0x5a00000000000000)
        end
        if #parts >= 4096 then
            f:write(table.concat(parts))
            parts = {}
        end
    end
    f:write(table.concat(parts))
    f:close()
end
do
    local m = cartesi.machine(config())
    m:store(D .. "/base")
end

-- Reference: the same stored machine, loaded without sharing, fresh
local ref = cartesi.machine(D .. "/base")
local ref_root = ref:get_root_hash()
set_query(NPAGES)
local REF = proofs(ref)
ref:destroy()

local loadfails, silent_wrong = 0, 0
for _, nquery in ipairs { NPAGES, 300 } do
set_query(nquery)
print(string.format("=== scenario: after sync_stored, get_root_hash + get_proof on %d pages, then SIGKILL/host crash", nquery))
sh(string.format("PHTC_TORN_DIR=%q timeout 120 lua5.4 %q child %d; true", D, self_path, nquery))
for _, s in ipairs { "S", "R", "U" } do
    assert(io.open(D .. "/" .. s .. "/hash_tree.phtc"), "child did not produce snapshot " .. s)
end

local function read_file(p)
    local f = assert(io.open(p, "rb"))
    local d = f:read("a")
    f:close()
    return d
end
local S = read_file(D .. "/S/hash_tree.phtc")
local R = read_file(D .. "/R/hash_tree.phtc")
local U = read_file(D .. "/U/hash_tree.phtc")
assert(#S == #U)
local npg = #S // PAGE
local meta_pages = (8 + 24 + PHTC_SIZE * 40 + PAGE - 1) // PAGE
local function changed_pages(A, B)
    local c = 0
    for k = 0, npg - 1 do
        if A:sub(k * PAGE + 1, (k + 1) * PAGE) ~= B:sub(k * PAGE + 1, (k + 1) * PAGE) then c = c + 1 end
    end
    return c
end
print(string.format(".phtc: %d pages, %d metadata pages", npg, meta_pages))
print(string.format("pages changed by one get_root_hash after sync_stored: %d", changed_pages(S, R)))
print(string.format("pages changed by get_root_hash+get_proof after sync_stored: %d (metadata %d)",
    changed_pages(S, U), changed_pages(S:sub(1, meta_pages * PAGE), U:sub(1, meta_pages * PAGE))))

-- Build a torn .phtc: page k comes from U if pick(k), else from S
local function try_mix(label, pick)
    local d = D .. "/mix"
    sh("rm -rf " .. d .. " && cp -a " .. D .. "/S " .. d)
    local parts = {}
    for k = 0, npg - 1 do
        local src = pick(k) and U or S
        parts[#parts + 1] = src:sub(k * PAGE + 1, (k + 1) * PAGE)
    end
    local f = assert(io.open(d .. "/hash_tree.phtc", "wb"))
    f:write(table.concat(parts))
    f:close()
    local ok, m = pcall(cartesi.machine, d)
    local res
    if not ok then
        res = { loadfail = tostring(m) }
        print(string.format("%-44s LOAD FAILED: %s", label, tostring(m)))
    else
        local root_ok = m:get_root_hash() == ref_root
        local verify = m:verify_hash_tree()
        local okp, G, RAW = pcall(proofs, m)
        local bad, first = 0, nil
        if okp then
            for i = 0, NPAGES - 1 do
                if G[i] ~= REF[i] then
                    bad = bad + 1
                    first = first or i
                end
            end
        end
        local pv = "n/a"
        if first then -- check the wrong proof against the (correct) root hash
            local p = RAW[first] -- the proof exactly as returned during the pass
            local word = m:read_memory(p.target_address, 32)
            pv = tostring(p.root_hash == ref_root) .. ", target_hash==keccak(actual word): " ..
                tostring(p.target_hash == cartesi.keccak256(word))
            local okv = pcall(function()
                local h = p.target_hash
                -- recompute root from siblings with the machine's hash function
                for l = 5, 63 do
                    local sib = p.sibling_hashes[l - 5 + 1]
                    if ((p.target_address >> l) & 1) == 0 then
                        h = cartesi.keccak256(h, sib)
                    else
                        h = cartesi.keccak256(sib, h)
                    end
                end
                pv = pv .. ", proof recomputes to root: " .. tostring(h == ref_root)
            end)
            if not okv then pv = pv .. " (could not recompute)" end
        end
        res = { root_ok = root_ok, verify = verify, bad = bad, okp = okp }
        print(string.format("%-44s loads; root ok=%s verify_hash_tree=%s proofs-call=%s bad proofs=%d/%d first=%s proof.root_hash ok=%s",
            label, tostring(root_ok), tostring(verify), tostring(okp), bad, NPAGES, tostring(first), pv))
        m:destroy()
    end
    sh("rm -rf " .. d)
    return res
end

local base_ok = try_mix("all pages from S (synced image)", function() return false end)
assert(base_ok.root_ok and base_ok.bad == 0, "synced image itself is bad; test setup broken")
local full = try_mix("all pages from U (fully written back)", function() return true end)
assert(full.root_ok and full.bad == 0, "post-query image itself is bad; test setup broken")
for K = 1, meta_pages - 1 do
    local r = try_mix(string.format("first %d metadata page(s) from U", K), function(k) return k < K end)
    if r.loadfail then loadfails = loadfails + 1 end
end
for K = 1, meta_pages - 1 do
    local r = try_mix(string.format("metadata page %d only from U", K), function(k) return k == K end)
    if r.loadfail then loadfails = loadfails + 1 end
end
local r = try_mix("all metadata from U, payloads from S", function(k) return k < meta_pages end)
if r.root_ok and r.verify and r.okp and r.bad > 0 then silent_wrong = silent_wrong + 1 end
end -- scenario

sh("rm -rf " .. D)
if loadfails > 0 then
    print(string.format("BUG: %d torn .phtc mixtures (from writes made by read-only queries after sync_stored) make the stored machine unloadable", loadfails))
end
if silent_wrong > 0 then
    print("BUG: torn .phtc loads with correct root hash and verify_hash_tree()==true but yields wrong word proofs")
end
if loadfails > 0 or silent_wrong > 0 then os.exit(1) end
print("OK: no torn mixture caused a failure")
os.exit(0)
