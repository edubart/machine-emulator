-- Proof: store() of a SHARING_ALL-loaded machine persists shared:true flags into config.json,
-- so a later SHARING_CONFIG load modifies the stored snapshot in place.
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/p1-02-store-persists-load-time-sharing-all-as-config-shared-/test.lua
-- Exits 1 and prints BUG lines while the bug is present; exits 0 once fixed.
local cartesi = require("cartesi")
local images = os.getenv("CARTESI_IMAGES_PATH") or "/usr/share/cartesi-machine/images"
local base = os.tmpname(); os.remove(base)
assert(os.execute("mkdir -p " .. base))
local A, S = base .. "/A", base .. "/S"
local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function readfile(p) local f = assert(io.open(p, "rb")); local d = f:read("a"); f:close(); return d end
local bug = {}

-- 1. Create a machine with default (non-shared) backing stores and store it in A.
local m = cartesi.new():create({
    ram = { length = 32 << 20, backing_store = { data_filename = images .. "/linux.bin" } },
    dtb = { entrypoint = "echo hi" },
    flash_drive = { { backing_store = { data_filename = images .. "/rootfs.ext2" } } },
})
local cfg0 = m:get_initial_config()
print("original ram.shared=", cfg0.ram.backing_store.shared, " hash_tree.shared=", cfg0.hash_tree.shared)
m:store(A)
m:destroy()
local cA = readfile(A .. "/config.json")

-- 2. Load A with SHARING_ALL, run, store to S (like PRT store_checkpoint).
local M = cartesi.new():load(A, nil, cartesi.SHARING_ALL)
M:run(2000000)
local h = M:get_root_hash()
local mc = M:read_reg("mcycle")
local ic = M:get_initial_config()
print("get_initial_config of SHARING_ALL-loaded: ram.shared=", ic.ram.backing_store.shared,
    " ram.data_filename=", ic.ram.backing_store.data_filename, " hash_tree.shared=", ic.hash_tree.shared)
M:store(S)
M:destroy()

local cS = readfile(S .. "/config.json")
local ramA = cA:match('"ram":%b{}'); local ramS = cS:match('"ram":%b{}')
print("A config ram:", ramA)
print("S config ram:", ramS)
print("A hash_tree:", cA:match('"hash_tree":%b{}'))
print("S hash_tree:", cS:match('"hash_tree":%b{}'))
if (ramS or ""):find('"shared":true') and not (ramA or ""):find('"shared":true') then
    bug[#bug + 1] = "S/config.json persists ram shared:true from the load-time SHARING_ALL override (original config has shared:false)"
end

-- 3. Load S with SHARING_CONFIG and run further; this should not touch S on disk.
local B = cartesi.new():load(S, nil, cartesi.SHARING_CONFIG)
B:run(4000000)
B:destroy()

-- 4. Reload S read-only and compare with what was stored.
local R = cartesi.new():load(S)
local h2 = R:get_root_hash()
local mc2 = R:read_reg("mcycle")
R:destroy()
print("stored: mcycle=", mc, " hash=", hex(h))
print("reload: mcycle=", mc2, " hash=", hex(h2))
if h2 ~= h or mc2 ~= mc then
    bug[#bug + 1] = string.format("SHARING_CONFIG load + run modified the stored snapshot S in place (mcycle %d -> %d, root hash changed=%s)",
        mc, mc2, tostring(h2 ~= h))
end

os.execute("rm -rf " .. base)
if #bug > 0 then
    for _, b in ipairs(bug) do print("BUG: " .. b) end
    os.exit(1)
end
print("OK: stored snapshot not modified")
os.exit(0)
