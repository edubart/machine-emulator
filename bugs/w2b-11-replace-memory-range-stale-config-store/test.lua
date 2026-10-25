-- Repro: replace_memory_range does not update machine config; store(SHARING_CONFIG/NONE)
-- then persists the ORIGINAL backing store instead of the current memory contents.
local cartesi = require("cartesi")

-- Scratch directory: $WORKDIR if set, otherwise a fresh directory under the system temp dir.
local work = os.getenv("WORKDIR")
if not work then
    work = os.tmpname()
    os.remove(work)
    work = work .. "-w2b-11"
end
os.execute("rm -rf '" .. work .. "' && mkdir -p '" .. work .. "'")
local function wfile(name, data)
    local f = assert(io.open(work .. "/" .. name, "wb")); f:write(data); f:close()
    return work .. "/" .. name
end
local FLASH = 0x0080000000000000
local LEN = 0x2000
local a_file = wfile("A.bin", string.rep("A", LEN))

local base_dir = work .. "/base"
do
    local m <close> = cartesi.machine({
        ram = { length = 0x100000 },
        flash_drive = { { start = FLASH, length = LEN, label = "drv", backing_store = { data_filename = a_file } } },
    })
    m:store(base_dir)
end

local failed = false
-- expected: what the reloaded flash must contain.
--  shared replacement + SHARING_CONFIG: the range is shared, so store must write CURRENT memory ("B...Z").
--  unshared replacement + SHARING_CONFIG/NONE: the range is rolled back to ITS backing store, i.e. "B..." (not "A...").
local function scenario(name, shared, sharing)
    local b_file = wfile("B-" .. name .. ".bin", string.rep("B", LEN))
    local out_dir = work .. "/out-" .. name
    local hash_before_store, mem_before_store, cfg_bs
    do
        local m <close> = cartesi.machine(base_dir, {}, cartesi.SHARING_NONE)
        m:replace_memory_range({ start = FLASH, length = LEN, backing_store = { data_filename = b_file, shared = shared } })
        m:write_memory(FLASH + 0x1000, "Z") -- also modify current memory
        hash_before_store = m:get_root_hash()
        mem_before_store = m:read_memory(FLASH, 8)
        cfg_bs = m:get_initial_config().flash_drive[1].backing_store
        m:store(out_dir, sharing)
    end
    local m2 <close> = cartesi.machine(out_dir, {}, cartesi.SHARING_NONE)
    local hash_after = m2:get_root_hash()
    local mem_after = m2:read_memory(FLASH, 8)
    local z_after = m2:read_memory(FLASH + 0x1000, 1)
    local expected_z = shared and "Z" or "B"
    print(string.format("[%s] get_initial_config flash backing_store: data_filename=%s shared=%s",
        name, tostring(cfg_bs.data_filename), tostring(cfg_bs.shared)))
    print(string.format("[%s] memory before store=%q after reload=%q", name, mem_before_store, mem_after))
    print(string.format("[%s] root hash equal after store/reload: %s", name, tostring(hash_before_store == hash_after)))
    print(string.format("[%s] byte at +0x1000 after reload=%q expected=%q", name, z_after, expected_z))
    if mem_after ~= "BBBBBBBB" or z_after ~= expected_z then
        print(string.format("BUG: [%s] store after replace_memory_range persisted the PRE-replacement flash image " ..
            "(%q, byte@+0x1000=%q) instead of the replacement (%q, byte@+0x1000=%q)", name, mem_after, z_after,
            "BBBBBBBB", expected_z))
        failed = true
    end
    if cfg_bs.data_filename ~= b_file or cfg_bs.shared ~= shared then
        print(string.format("BUG: [%s] get_initial_config still reports the pre-replacement backing store (%s, shared=%s)",
            name, tostring(cfg_bs.data_filename), tostring(cfg_bs.shared)))
        failed = true
    end
end

scenario("shared-B_SHARING_CONFIG", true, cartesi.SHARING_CONFIG)
scenario("unshared-B_SHARING_CONFIG", false, cartesi.SHARING_CONFIG)
scenario("unshared-B_SHARING_NONE", false, cartesi.SHARING_NONE)

os.execute("rm -rf '" .. work .. "'")
if failed then os.exit(1) end
print("OK")
