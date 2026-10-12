-- Regression: loading a stored machine whose hash_tree.phtc has an LRU list with a cycle (not passing
-- through the list root) hangs forever in page_hash_tree_cache's constructor (page-hash-tree-cache.hpp:471)
-- instead of being rejected as corrupted.
--
-- Run (from repo root, after sourcing bugs/env/env.sh):
--   lua5.4 phtc-lru-cycle-hang.lua
local cartesi = require("cartesi")

if arg[1] == "child" then -- load the corrupted directory (run under timeout by the parent)
    local ok, err = pcall(cartesi.machine, arg[2], {}, cartesi.SHARING_NONE)
    print(ok and "loaded" or ("rejected: " .. tostring(err)))
    os.exit(0, true)
end

local N = 4 -- phtc entries
local dir = os.tmpname()
os.remove(dir)
do
    local m <close> = cartesi.machine({ ram = { length = 1 << 20 }, hash_tree = { phtc_size = N } })
    for p = 0, N - 1 do -- make sure all N cache entries are in use (in the LRU list)
        m:write_memory(0x80000000 + p * 4096, "page" .. p)
    end
    m:get_root_hash()
    m:store(dir, cartesi.SHARING_ALL)
end

-- File layout: initialized_tag (8) | lru: size (8), root{next,prev} (16) | entries[N]: {next,prev} (16), ...
-- Hook pointers are boost::interprocess::offset_ptr (offset relative to the pointer's own address).
local fn = dir .. "/hash_tree.phtc"
local f = assert(io.open(fn, "r+b"))
local function rd(off) f:seek("set", off) return string.unpack("<i8", f:read(8)) end
local ROOT = 16
assert(rd(8) == N, "expected a full LRU list")
local nodes, node = {}, ROOT + rd(ROOT)
while node ~= ROOT do
    nodes[#nodes + 1] = node
    node = node + rd(node)
    assert(#nodes <= N, "unexpected list layout")
end
-- Make the last entry's 'next' point back to the first entry: a cycle that never returns to the root
local first, last = nodes[1], nodes[#nodes]
f:seek("set", last)
f:write(string.pack("<i8", first - last))
f:close()

local lua = arg[-1] or "lua5.4"
local p = io.popen(string.format("timeout 15 %q %q child %q 2>&1; echo rc=$?", lua, arg[0], dir))
local out = p:read("a")
p:close()
os.execute(string.format("rm -rf %q", dir))
io.write(out)
if out:find("rc=124", 1, true) then
    print("BUG REPRODUCED: loading a page hash-tree cache with a cyclic LRU list hangs")
    os.exit(1, true)
end
if out:find("rejected:", 1, true) then
    print("OK")
    os.exit(0, true)
end
print("unexpected result")
os.exit(2, true)
