-- Proves: a page-hash-tree cache entry left with borrowed=1 on disk (as happens when a process is
-- killed during update_dirty_pages on a SHARING_ALL machine) makes the stored machine unloadable
-- in every sharing mode, even with runtime {clear_hash_tree=true}.
local cartesi = require"cartesi"
local here = arg[0]:match("(.*/)") or "./"
local work = os.getenv("WORK") or (here .. "tmp")
os.execute("rm -rf " .. work .. " && mkdir -p " .. work)
local orig = work .. "/orig"
local bad = work .. "/bad"

local function u64(s, off) return (string.unpack("<I8", s, off + 1)) end

-- 1. create and store a small machine
do
    local m <close> = cartesi.new():create({ ram = { length = 1 << 20 } })
    m:write_memory(0x80000000, string.rep("x", 4096 * 8))
    m:get_root_hash()
    m:store(orig)
end
local function readall(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local phtc = readall(orig .. "/hash_tree.phtc")
-- layout: tag(8) | lru(24) | entries[40 bytes: hook(16) paddr(8) borrowed(8) payload_index(8)]
assert(u64(phtc, 0) ~= 0, "phtc not initialized")
for i = 0, 3 do
    assert(u64(phtc, 32 + 40 * i + 32) == i, "unexpected phtc layout (payload index)")
    assert(u64(phtc, 32 + 40 * i + 24) == 0, "unexpected phtc layout (borrowed)")
end
local active = u64(phtc, 24) -- lru size
print("lru size", active, "entry0 paddr", string.format("0x%x", u64(phtc, 48)))

-- sanity: original loads
do local m <close> = cartesi.new():load(orig); print("orig root", (m:get_root_hash():gsub(".", function(c) return string.format("%02x", c:byte()) end))) end

-- 2. simulate crash in the borrow window: set entry 0 borrowed = 1
os.execute("cp -a " .. orig .. " " .. bad)
local patched = phtc:sub(1, 56) .. string.pack("<I8", 1) .. phtc:sub(65)
local f = assert(io.open(bad .. "/hash_tree.phtc", "wb")); f:write(patched); f:close()

local failures = 0
local modes = { NONE = cartesi.SHARING_NONE, CONFIG = cartesi.SHARING_CONFIG, ALL = cartesi.SHARING_ALL }
for _, rt in ipairs({ { name = "{}", cfg = {} }, { name = "{clear_hash_tree=true}", cfg = { clear_hash_tree = true } } }) do
    for _, mname in ipairs({ "NONE", "CONFIG", "ALL" }) do
        local d = bad
        if mname == "ALL" then d = work .. "/bad_all_" .. (rt.cfg.clear_hash_tree and "c" or "n"); os.execute("cp -a " .. bad .. " " .. d) end
        local ok, err = pcall(function()
            local m <close> = cartesi.new():load(d, rt.cfg, modes[mname])
            m:get_root_hash()
        end)
        print(string.format("load(runtime=%s, SHARING_%s): %s", rt.name, mname, ok and "ok" or tostring(err)))
        if not ok then failures = failures + 1 end
    end
end
os.execute("rm -rf " .. work)
if failures > 0 then
    print(string.format("BUG: stored machine with a borrowed phtc entry cannot be loaded (%d/6 attempts failed, including clear_hash_tree=true)", failures))
    os.exit(1)
end
print("OK")
