-- Proof: verify_hash_tree() returns true although stored dense inner nodes / sparse nodes are corrupted,
-- so get_root_hash()/get_node_hash()/get_proof() are wrong while the "integrity check" passes.
local cartesi = require("cartesi")
-- Scratch directory for the stored machines (defaults to a fresh temporary directory)
local dir = os.getenv("WORKDIR")
if not dir then
    local h = assert(io.popen("mktemp -d"))
    dir = h:read("l")
    h:close()
end
local RAM = 0x80000000
local function base(name)
    local d = dir .. "/" .. name
    os.execute("rm -rf " .. d)
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    m:write_memory(RAM, "hello")
    m:write_memory(RAM + (1 << 19), "world")
    m:get_root_hash()
    m:store(d)
    m:destroy()
    return d
end
local function patch(file, off, bytes)
    local f = assert(io.open(file, "r+b"))
    f:seek("set", off)
    f:write(bytes)
    f:close()
end
local function readall(file)
    local f = assert(io.open(file, "rb"))
    local s = f:read("a")
    f:close()
    return s
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local bugs = 0
local function check(label, m, getter)
    local before = getter(m)
    local ok = m:verify_hash_tree()
    m:clear_hash_tree()
    local after = getter(m)
    print(string.format("[%s] verify_hash_tree=%s  value_before=%s  recomputed=%s", label, tostring(ok),
        hex(before):sub(1, 16), hex(after):sub(1, 16)))
    if ok and before ~= after then
        print("BUG: [" .. label .. "] verify_hash_tree() returned true but the hash tree was stale/corrupted")
        bugs = bugs + 1
    end
end
local ramdht = "/0000000080000000-100000.dht"

-- A: corrupt the RAM dense-tree root node (heap index 1 at byte 32)
do
    local d = base("stA")
    patch(d .. ramdht, 32, string.rep("\1", 32))
    local m = cartesi.new():load(d, { sharing = "none" })
    check("A dense root", m, function(mm) return mm:get_root_hash() end)
end

-- B: corrupt a dense inner node (heap index 2 = left half of RAM, byte 64); query that node / a proof through it
do
    local d = base("stB")
    patch(d .. ramdht, 64, string.rep("\2", 32))
    local m = cartesi.new():load(d, { sharing = "none" })
    check("B dense inner node hash", m, function(mm) return mm:get_node_hash(RAM, 19) end)
    m:destroy()
    m = cartesi.new():load(d, { sharing = "none" })
    -- proof of right half: its sibling is the corrupted left-half node
    check("B proof sibling", m, function(mm)
        local p = mm:get_proof(RAM + (1 << 19), 19)
        return p.sibling_hashes[1] .. p.root_hash
    end)
end

-- C: corrupt the sparse-tree root hash inside hash_tree.sht
do
    local d = base("stC")
    local m0 = cartesi.new():load(d, { sharing = "none" })
    local root = m0:get_root_hash()
    m0:destroy()
    local sht = readall(d .. "/hash_tree.sht")
    local pos = sht:find(root, 1, true)
    assert(pos, "root hash not found in .sht")
    patch(d .. "/hash_tree.sht", pos - 1, string.rep("\3", 32))
    local m = cartesi.new():load(d, { sharing = "none" })
    check("C sparse root", m, function(mm) return mm:get_root_hash() end)
end

os.execute("rm -rf " .. dir .. "/stA " .. dir .. "/stB " .. dir .. "/stC")
if not os.getenv("WORKDIR") then os.execute("rmdir " .. dir) end
if bugs > 0 then
    print(string.format("BUG: verify_hash_tree accepted %d corrupted hash trees", bugs))
    os.exit(1)
end
print("OK: verify_hash_tree detected all corruptions")
os.exit(0)
