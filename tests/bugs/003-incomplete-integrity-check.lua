-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Model one local storage bit fault; exit successfully when the checker misses it.
local c = require('cartesi')
local fs = require('cartesi.filesystem')
local ht = require('cartesi.hash-tree')
local dir = fs.temp_pathname()
local original_root
local ram = c.AR_RAM_START
local function proof_ok(m)
    return pcall(ht.verify_slice, m:get_proof(ram + 0x2000, 12))
end
do
    local m <close> = c.machine({ ram = { length = 0x4000 }, hash_tree = { phtc_size = 32 } })
    m:write_memory(ram, string.rep('A', 4096))
    m:write_memory(ram + 0x2000, string.rep('B', 4096))
    original_root = m:get_root_hash()
    assert(m:verify_hash_tree())
    assert(proof_ok(m))
    m:store(dir)
end
local cleanup <close> = setmetatable({}, { __close = function() c.machine:remove_stored(dir) end })
-- Internal dense node 2 covers the left half of RAM. No guest memory is changed.
do
    local f <close> = assert(io.open(dir .. '/0000000080000000-4000.dht', 'r+b'))
    assert(f:seek('set', 64))
    local byte = assert(f:read(1)):byte()
    assert(f:seek('set', 64))
    assert(f:write(string.char(byte ~ 1)))
    assert(f:flush())
end
do
    local m <close> = c.new():load(dir)
    assert(m:verify_hash_tree())
    print('integrity check accepted inconsistent metadata:', true)
    local ok, err = proof_ok(m)
    print('full proof valid:', ok, err)
    assert(not ok and tostring(err):find('target node not in tree', 1, true))
    assert(m:get_root_hash() == original_root)
    assert(m:verify_hash_tree())
    m:clear_hash_tree()
    assert(proof_ok(m))
    assert(m:get_root_hash() == original_root)
    print('rebuilding metadata restored a valid proof with the original root')
end
print('BUG 003 reproduced: successful integrity check did not ensure valid proofs')
