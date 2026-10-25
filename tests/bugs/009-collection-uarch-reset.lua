-- Run from the repository root with src in LUA_PATH and LUA_CPATH.
-- Compare collection with a canonical verified reset from the same halted root.
local c = require('cartesi')
local fs = require('cartesi.filesystem')
local image, snapshot = fs.temp_pathname(), fs.temp_pathname()
local cleanup <close> = setmetatable({}, { __close = function()
    os.remove(image)
    if fs.exists(snapshot) then c.machine:remove_stored(snapshot) end
end })
local offset = c.UARCH_RAM_LENGTH // 2
local address = c.UARCH_RAM_START_ADDRESS + offset
local zero, marker = string.rep('\0', 32), string.rep('Q', 32)
do
    local pristine <close> = c.machine({ ram = { length = 4096 } })
    local bytes = pristine:read_memory(c.UARCH_RAM_START_ADDRESS, c.UARCH_RAM_LENGTH)
    assert(bytes:sub(offset + 1, offset + 32) == zero)
    local file <close> = assert(io.open(image, 'wb'))
    assert(file:write(bytes:sub(1, offset), marker, bytes:sub(offset + 33)))
    assert(file:flush())
end
local function create(custom, halted)
    local config = { ram = { length = 4096 }, hash_tree = { phtc_size = 3 } }
    if custom then config.uarch = { ram = { backing_store = { data_filename = image } } } end
    if halted then config.processor = { registers = { iflags = { H = 1 } } } end
    local m = c.machine(config)
    m:write_memory(c.AR_RAM_START, string.pack('<I4', 0x00100093)) -- addi x1,x0,1
    return m
end
local function check(label, maker, custom, halted)
    local collected <close> = maker()
    local explicit <close> = maker()
    assert(collected:read_reg('uarch_cycle') == 0)
    assert(collected:get_root_hash() == explicit:get_root_hash())
    local hashes
    if halted then
        hashes = collected:collect_uarch_cycle_root_hashes(1, 0).hashes
    else
        -- Accepted tail for the zero revert leaf; this instruction never rejects.
        hashes = collected:collect_uarch_cycle_root_hashes(1, 0, { zero, zero }).hashes
    end
    assert(explicit:run_uarch(10000) == c.UARCH_BREAK_REASON_UARCH_HALTED)
    local halt_root = explicit:get_root_hash()
    assert(hashes[#hashes - 1] == halt_root)
    local log = explicit:log_reset_uarch()
    local verified_root = explicit:verify_reset_uarch(halt_root, log)
    assert(verified_root == explicit:get_root_hash())
    assert(explicit:get_node_hash(c.UARCH_STATE_START_ADDRESS, c.UARCH_STATE_LOG2_SIZE)
        == explicit:get_uarch_pristine_hash())
    assert(explicit:read_memory(address, 32) == zero)
    assert(collected:read_memory(address, 32) == (custom and marker or zero))
    assert((hashes[#hashes] == verified_root) == not custom)
    collected:clear_hash_tree()
    assert(collected:get_root_hash() == hashes[#hashes])
    print(label, 'hashes=' .. #hashes, 'halt roots match; reset proof verifies',
        'collected reset matches=' .. tostring(hashes[#hashes] == verified_root))
end
check('pristine configuration', function() return create(false, false) end, false, false)
check('custom configuration', function() return create(true, false) end, true, false)
do
    local source <close> = create(true, false)
    source:get_root_hash()
    source:store(snapshot)
end
check('stored/reloaded custom', function() return c.machine(snapshot) end, true, false)
check('halted pristine, no tail', function() return create(false, true) end, false, true)
check('halted custom, no tail', function() return create(true, true) end, true, true)
print('BUG 009 reproduced: collected reset differs from a verified reset for custom initial RAM')
