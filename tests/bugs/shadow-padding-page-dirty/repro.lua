-- cm_write_memory(0, data, 0x8000) has a special case that copies the whole shadow (processor state, 0x0-0x7fff) with
-- one memcpy and relies on the "always dirty" shadow pages to get it re-hashed. Those cover 0x0-0x6fff only, so the
-- TLB padding page 0x7000-0x7fff is written without being marked dirty and its hash in the tree goes stale: the root
-- hash no longer commits to the machine's memory contents.
-- Fixed behavior: either the write is applied and the page is re-hashed, or it is rejected; in both cases the page's
-- hash in the tree (and the root hash) must match the page's bytes.
-- Usage: lua5.4 repro.lua [control]
--   control: change register x5 (an always-dirty shadow page) through the same full-shadow write; must not reproduce
--            (validates the hash checks of the test)
local cartesi = require("cartesi")
local hash_tree = require("cartesi.hash-tree")
local control = arg[1] == "control"
local SHADOW_LENGTH, PAD_PAGE, PAGE_LOG2 = 0x8000, 0x7000, 12
local X5_VALUE = 0x5a5a5a5a5a5a5a5a

local m <close> = cartesi.machine({ ram = { length = 1 << 20 } })
local shadow = m:read_memory(0, SHADOW_LENGTH)
assert(#shadow == SHADOW_LENGTH, "test error: could not read the shadow")

local patched, page_addr
if control then
    -- locate x5 in the shadow by changing it and diffing, then restore it
    m:write_reg("x5", X5_VALUE)
    local changed = m:read_memory(0, SHADOW_LENGTH)
    m:write_reg("x5", 0)
    local offset
    for i = 1, SHADOW_LENGTH do
        if shadow:byte(i) ~= changed:byte(i) then
            offset = i - 1
            break
        end
    end
    assert(offset and offset < PAD_PAGE, "test error: x5 not found in the shadow")
    patched, page_addr = changed, offset & ~0xfff
else
    -- the same shadow, with one non-zero byte in the padding page
    patched, page_addr = shadow:sub(1, PAD_PAGE) .. "\1" .. shadow:sub(PAD_PAGE + 2), PAD_PAGE
end
m:get_root_hash() -- start from a clean hash tree
local accepted, err = pcall(m.write_memory, m, 0, patched)
print(string.format("full-shadow cm_write_memory changing page 0x%x: %s", page_addr,
    accepted and "accepted" or ("rejected (" .. tostring(err) .. ")")))
if control then
    assert(accepted and m:read_reg("x5") == X5_VALUE, "test error: control write did not change x5")
end

local page = m:read_memory(page_addr, 1 << PAGE_LOG2)
local page_hash = hash_tree.get_data_root_hash(page, PAGE_LOG2)
local node_hash = m:get_node_hash(page_addr, PAGE_LOG2)
local root_hash = m:get_root_hash()
-- root hash obtained by rolling the hash of the page's actual bytes up the tree
local rolled = hash_tree.roll_hash_up_tree(m:get_proof(page_addr, PAGE_LOG2), page_hash)
print("page hash in the tree      : " .. cartesi.tohex(node_hash))
print("hash of the page bytes     : " .. cartesi.tohex(page_hash))
print("root hash                  : " .. cartesi.tohex(root_hash))
print("root from the page bytes   : " .. cartesi.tohex(rolled))
if node_hash ~= page_hash or rolled ~= root_hash then
    print("BUG REPRODUCED: full-shadow cm_write_memory changed the padding page without re-hashing it "
        .. "(stale page hash, root hash does not commit to memory)")
    os.exit(1)
end
print("OK: the page hash and the root hash match the memory contents")
os.exit(0)
