-- Proof: a borrowed flag persisted in hash_tree.phtc (as left by a SIGKILL during hashing on a
-- SHARING_ALL machine) makes the stored machine unloadable, even with runtime option clear_hash_tree=true.
-- Part A (deterministic): reproduce the exact on-disk state a kill leaves (m_borrowed=1 in one entry).
-- Part B (realistic, best effort): SIGKILL a child while it hashes a SHARING_ALL machine, retrying.
local cartesi = require("cartesi")
local here = arg[0]:match("(.*/)") or "./"
local base = here .. "tmp"
os.execute("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "'")
local bug = false

local function sh(cmd) return os.execute(cmd) end

-- Part A ----------------------------------------------------------------------
local dir = base .. "/stored"
local m = cartesi.machine({
    ram = { length = 1 << 20 },
    hash_tree = { phtc_size = 64 },
})
m:write_memory(0x80000000, string.rep("\x5a", 4096 * 8))
local h0 = m:get_root_hash()
m:store(dir, cartesi.SHARING_ALL)
m = nil
collectgarbage()

-- Layout (src/page-hash-tree-cache.hpp), as observed: u64 initialized_tag | lru (24 bytes: u64 size, node{next,prev})
-- | entry_metadata[n]{hook{next,prev}, u64 paddr, u64 borrowed, u64 payload_index} ...
local f = assert(io.open(dir .. "/hash_tree.phtc", "r+b"))
local hdr = f:read(32)
local tag = string.unpack("<I8", hdr, 1)
assert(tag == 0x0250485443, string.format("unexpected phtc tag %x", tag))
local lru_size = string.unpack("<I8", hdr, 9)
local ENTRY0, ESZ = 32, 40
f:seek("set", ENTRY0)
local e0 = f:read(ESZ)
local borrowed, pidx = string.unpack("<I8I8", e0, 25)
assert(lru_size > 0 and lru_size <= 64 and borrowed == 0 and pidx < 64, "layout sanity check failed")
print(string.format("phtc lru size=%d, entry0 borrowed=%d payload_index=%d", lru_size, borrowed, pidx))
-- simulate kill while entry 0 is borrowed (update_dirty_pages / update_page borrow then return)
f:seek("set", ENTRY0 + 24)
f:write(string.pack("<I8", 1))
f:close()

for _, mode in ipairs({ "SHARING_NONE", "SHARING_ALL" }) do
    -- copy so SHARING_ALL load does not change the input for the next case
    local d = base .. "/copy-" .. mode
    sh("rm -rf '" .. d .. "' && cp -a '" .. dir .. "' '" .. d .. "'")
    local ok, mm = pcall(cartesi.machine, d, { clear_hash_tree = true }, cartesi[mode])
    if not ok then
        print(string.format("BUG: load(%s, {clear_hash_tree=true}) failed on cache-only corruption: %s", mode, mm))
        bug = true
    else
        local h = mm:get_root_hash()
        if h ~= h0 then
            print("BUG: root hash mismatch after clear_hash_tree load in " .. mode)
            bug = true
        else
            print("ok: " .. mode .. " recovered with clear_hash_tree, root hash matches")
        end
    end
end

-- Part B (optional, real SIGKILL) -------------------------------------------
if os.getenv("REAL_KILL") then
    local child = here .. "child.lua"
    local tries = tonumber(os.getenv("REAL_KILL")) or 20
    for t = 1, tries do
        local w = base .. "/kill"
        sh("rm -rf '" .. w .. "'")
        local mk = cartesi.machine({ ram = { length = 64 << 20 } })
        mk:store(w, cartesi.SHARING_ALL)
        mk = nil
        collectgarbage()
        local delay = 0.005 + (t % 10) * 0.01
        sh(string.format("lua5.4 '%s' '%s' %d 2>'%s/err' & pid=$!; " ..
            "for i in $(seq 1 2000); do grep -q R '%s/err' 2>/dev/null && break; sleep 0.005; done; " ..
            "sleep %f; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null", child, w, t, base, base, delay))
        local ok, err = pcall(cartesi.machine, w, { clear_hash_tree = true }, cartesi.SHARING_NONE)
        print(string.format("real kill try %d delay %.3f: %s", t, delay, ok and "loaded" or err))
        if not ok and tostring(err):find("page hash%-tree cache") then
            print("BUG: real SIGKILL left phtc unloadable even with clear_hash_tree: " .. err)
            bug = true
            break
        end
    end
end

os.execute("rm -rf '" .. base .. "'")
os.exit(bug and 1 or 0)
