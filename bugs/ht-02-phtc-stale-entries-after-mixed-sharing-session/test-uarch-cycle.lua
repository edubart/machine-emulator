-- Stale persisted page hash-tree cache (phtc) entries corrupt collect_uarch_cycle_root_hashes.
-- Session 1 creates a machine in a directory with ram.backing_store.shared=true (hash tree keeps its
-- default shared=false). Session 2 loads it with SHARING_CONFIG (CLI --load default) and writes a data
-- page: the RAM file and its .dht/.dpt get the new content, the phtc on disk keeps the old page hashes.
-- Session 3 loads with SHARING_NONE or SHARING_ALL (matching flags: nothing evicted) and runs a program
-- whose `sd` writes into that page. The update_words cache-hit path rehashes only the written word over
-- the stale cached page, so uarch-cycle root hashes differ from a clear_hash_tree reference, while the
-- initial root hash matches and verify_hash_tree returns true.
local cartesi = require("cartesi")
local RAM = cartesi.AR_RAM_START

local W = os.tmpname()
os.remove(W)
W = W .. "-ht02u"
assert(os.execute("rm -rf " .. W .. " && mkdir -p " .. W))

-- session 1: fully on-disk machine; stored config keeps ram shared=true, hash tree shared=false (default)
local cfg = { ram = { length = 0x10000, backing_store = { shared = true } } }
local m = cartesi.machine(cfg, {}, W .. "/S")
-- auipc t0,1 ; sd zero,0(t0) ; j .
m:write_memory(RAM, string.pack("<I4I4I4", 0x00001297, 0x0002b023, 0x0000006f))
m:write_memory(RAM + 0x1000, string.rep("A", 0x1000))
m:get_root_hash()
m:destroy()

-- session 2: SHARING_CONFIG load: RAM shared, hash tree private; host writes the data page
local m2 = cartesi.machine(W .. "/S", nil, cartesi.SHARING_CONFIG)
m2:write_memory(RAM + 0x1000, string.rep("B", 0x1000))
m2:get_root_hash()
m2:destroy()

local bugs = 0
for _, sh in ipairs({ { cartesi.SHARING_NONE, "SHARING_NONE" }, { cartesi.SHARING_ALL, "SHARING_ALL" } }) do
    -- copy so SHARING_ALL does not mutate the directory for the next iteration
    assert(os.execute("rm -rf " .. W .. "/C && cp -a " .. W .. "/S " .. W .. "/C"))
    local a = cartesi.machine(W .. "/C", nil, sh[1])
    local r = cartesi.machine(W .. "/S", { clear_hash_tree = true }, cartesi.SHARING_NONE)
    local root_ok = a:get_root_hash() == r:get_root_hash()
    local verify_before = a:verify_hash_tree()
    local tail = { string.rep("\0", cartesi.HASH_SIZE), string.rep("\0", cartesi.HASH_SIZE) }
    local ha = a:collect_uarch_cycle_root_hashes(3, 0, tail)
    local hr = r:collect_uarch_cycle_root_hashes(3, 0, tail)
    local first, ndiff = nil, 0
    for i = 1, #hr.hashes do
        if ha.hashes[i] ~= hr.hashes[i] then
            first = first or i
            ndiff = ndiff + 1
        end
    end
    local final_ok = a:get_root_hash() == r:get_root_hash()
    local verify_after = a:verify_hash_tree()
    print(string.format(
        "[%s] initial_root_ok=%s verify_before=%s uarch_hashes=%d/%d differing=%d first_differing=%s "
            .. "final_root_ok=%s verify_after=%s",
        sh[2], tostring(root_ok), tostring(verify_before), #ha.hashes, #hr.hashes, ndiff, tostring(first),
        tostring(final_ok), tostring(verify_after)))
    if ndiff > 0 or #ha.hashes ~= #hr.hashes then
        print(string.format("BUG: [%s] collect_uarch_cycle_root_hashes uses stale cached page hashes", sh[2]))
        bugs = bugs + 1
    end
    a:destroy()
    r:destroy()
end
assert(os.execute("rm -rf " .. W))
if bugs > 0 then os.exit(1) end
print("OK: uarch-cycle root hashes match the reference")
os.exit(0)
