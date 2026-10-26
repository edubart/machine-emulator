--[[
Test suite for machine API surface.
Specifically, it provides test coverage for:
    machine.cpp (get_address_name, get_reg_address, read_reg, write_reg, write_word)
    shadow-registers.hpp (shadow_registers_get_what, shadow_registers_get_what_name)
    shadow-tlb.hpp (shadow_tlb_get_what, shadow_tlb_get_what_name)
    shadow-uarch-state.hpp (shadow_uarch_state_get_what, shadow_uarch_state_get_what_name)
    pmas.hpp (pmas_get_what, pmas_get_what_name)
]]

local lester = require("cartesi.third-party.lester")
lester.parse_args()
local cartesi = require("cartesi")
local filesystem = require("cartesi.filesystem")
local tests_util = require("cartesi.tests.util")
local describe, it, expect = lester.describe, lester.it, lester.expect

describe("uarch constants", function()
    it("should expose the full uarch state range", function()
        expect.equal(cartesi.UARCH_STATE_START_ADDRESS, 0x400000)
        expect.equal(cartesi.UARCH_STATE_LOG2_SIZE, 22)
        expect.equal(cartesi.UARCH_STATE_LENGTH, 1 << cartesi.UARCH_STATE_LOG2_SIZE)
    end)
end)

describe("get_uarch_pristine_hash static method", function()
    it("should return the embedded hash without a machine instance", function()
        local hash = cartesi.machine:get_uarch_pristine_hash()
        expect.equal(#hash, cartesi.HASH_SIZE)
        expect.equal(hash, cartesi.UARCH_PRISTINE_STATE_HASH)
    end)
end)

local variants = {
    {
        name = "local",
        new = cartesi.new,
        create = function(config, runtime)
            return cartesi.machine(config, runtime)
        end,
    },
    {
        name = "remote",
        new = function()
            local jsonrpc = require("cartesi.jsonrpc")
            return jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
        end,
        create = function(config, runtime)
            local jsonrpc = require("cartesi.jsonrpc")
            return jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN):create(config, runtime)
        end,
    },
}

for _, variant in ipairs(variants) do
    describe("machine API (" .. variant.name .. ")", function()
        local machine <close> = variant.create({ ram = { length = 0x1000 } })

        describe("clear_hash_tree", function()
            for _, hash_function in ipairs({ "keccak256", "sha256" }) do
                local function create_source(phtc_size)
                    return variant.create({
                        ram = { length = 0x3000 },
                        flash_drive = { { start = 0x90000000, length = 0x3000 } },
                        hash_tree = { hash_function = hash_function, phtc_size = phtc_size or 32 },
                    })
                end

                it("should rebuild all cached hashes lazily (" .. hash_function .. ")", function()
                    -- Keep every page cached so stale cache entries cannot hide behind eviction.
                    local source <close> = create_source(2048)
                    source:write_reg("x1", 42)
                    source:write_memory(cartesi.AR_RAM_START, string.rep("A", 0x1000))
                    source:write_memory(0x90002000, string.rep("B", 0x1000))
                    local root = source:get_root_hash()
                    local cold_stats = source:get_hash_tree_stats(true)
                    expect.truthy(cold_stats.phtc.page_misses <= 2048)
                    local proof = source:get_proof(cartesi.AR_RAM_START, 5)
                    local state = source:read_memory(cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH)
                    local stats = source:get_hash_tree_stats()
                    source:clear_hash_tree()
                    source:clear_hash_tree()
                    expect.equal(source:get_hash_tree_stats(), stats)
                    expect.equal(
                        source:read_memory(cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH),
                        state
                    )
                    expect.equal(source:read_memory(cartesi.AR_RAM_START, 0x1000), string.rep("A", 0x1000))
                    source:get_hash_tree_stats(true)
                    expect.equal(source:get_root_hash(), root)
                    local rebuilt_stats = source:get_hash_tree_stats()
                    expect.equal(rebuilt_stats.phtc.page_hits, 0)
                    expect.equal(rebuilt_stats.phtc.page_misses, cold_stats.phtc.page_misses)
                    expect.equal(rebuilt_stats.phtc.page_changes, cold_stats.phtc.page_changes)
                    expect.equal(rebuilt_stats.dense_node_hashes, cold_stats.dense_node_hashes)
                    expect.equal(rebuilt_stats.sparse_node_hashes, cold_stats.sparse_node_hashes)
                    expect.equal(source:get_proof(cartesi.AR_RAM_START, 5), proof)
                    expect.truthy(source:verify_hash_tree())
                    source:clear_hash_tree()
                    expect.equal(source:get_proof(cartesi.AR_RAM_START, 5), proof)

                    -- Clearing must also preserve writes that have not yet been hashed.
                    source:write_memory(0x90000000, string.rep("C", 0x1000))
                    source:write_reg("x1", 43)
                    source:clear_hash_tree()
                    expect.equal(source:get_root_hash(), tests_util.calculate_emulator_hash(source))
                    expect.not_equal(source:get_root_hash(), root)
                end)

                for _, sharing in ipairs({ cartesi.SHARING_NONE, cartesi.SHARING_ALL }) do
                    for _, runtime_clear in ipairs({ false, true }) do
                        it(
                            "should clear stored caches ("
                                .. hash_function
                                .. ", sharing="
                                .. sharing
                                .. ", runtime="
                                .. tostring(runtime_clear)
                                .. ")",
                            function()
                                local source <close> = create_source()
                                local fresh_dirname = filesystem.temp_pathname()
                                local _ <close> = tests_util.scope_exit(function()
                                    cartesi.machine:remove_stored(fresh_dirname)
                                end)
                                source:store(fresh_dirname)
                                local tree_filenames = { "hash_tree.sht", "hash_tree.phtc" }
                                for _, ar in ipairs(source:get_address_ranges()) do
                                    if ar.is_memory then
                                        local prefix = string.format("%016x-%x", ar.start, ar.length)
                                        tree_filenames[#tree_filenames + 1] = prefix .. ".dht"
                                        tree_filenames[#tree_filenames + 1] = prefix .. ".dpt"
                                    end
                                end
                                source:write_memory(cartesi.AR_RAM_START, string.rep("A", 0x1000))
                                source:write_memory(0x90002000, string.rep("B", 0x1000))
                                local root = source:get_root_hash()
                                local proof = source:get_proof(0x90002000, 5)
                                local dirname = filesystem.temp_pathname()
                                local _ <close> = tests_util.scope_exit(function()
                                    cartesi.machine:remove_stored(dirname)
                                end)
                                source:store(dirname)
                                local warm_files = {}
                                for _, filename in ipairs(tree_filenames) do
                                    warm_files[filename] = filesystem.read_file(dirname .. "/" .. filename)
                                end
                                local loaded <close> = variant.new()
                                loaded:load(dirname, { clear_hash_tree = runtime_clear }, sharing)
                                expect.equal(loaded:get_runtime_config().clear_hash_tree, runtime_clear)
                                if not runtime_clear then
                                    expect.equal(loaded:get_root_hash(), root)
                                    loaded:clear_hash_tree()
                                end
                                -- Persist the cleared trees before any hash request rebuilds them.
                                local cleared_dirname = filesystem.temp_pathname()
                                local _ <close> = tests_util.scope_exit(function()
                                    cartesi.machine:remove_stored(cleared_dirname)
                                end)
                                loaded:store(cleared_dirname)
                                for _, filename in ipairs(tree_filenames) do
                                    local fresh_data = filesystem.read_file(fresh_dirname .. "/" .. filename)
                                    local cleared_data = filesystem.read_file(cleared_dirname .. "/" .. filename)
                                    assert(cleared_data == fresh_data, filename .. " differs from fresh tree storage")
                                    local backing_data = filesystem.read_file(dirname .. "/" .. filename)
                                    local expected = sharing == cartesi.SHARING_ALL and fresh_data
                                        or warm_files[filename]
                                    assert(backing_data == expected, filename .. " has incorrect backing storage")
                                end
                                local restored <close> = variant.new():load(cleared_dirname)
                                expect.equal(restored:get_root_hash(), root)
                                expect.truthy(restored:verify_hash_tree())
                                if sharing == cartesi.SHARING_ALL then
                                    loaded:destroy()
                                    loaded:load(dirname)
                                end
                                local before = loaded:get_hash_tree_stats(true)
                                expect.equal(loaded:get_root_hash(), root)
                                local after = loaded:get_hash_tree_stats()
                                expect.truthy(after.phtc.page_misses > 0)
                                expect.equal(after.phtc.page_hits, 0)
                                expect.truthy(after.sparse_node_hashes > 0)
                                if runtime_clear then
                                    expect.equal(before.phtc.page_misses, 0)
                                end
                                expect.equal(loaded:get_proof(0x90002000, 5), proof)
                                expect.truthy(loaded:verify_hash_tree())
                            end
                        )
                    end
                end
            end

            it("should default to false and validate the runtime flag", function()
                expect.equal(machine:get_runtime_config().clear_hash_tree, false)
                expect.fail(function()
                    local _ <close> = variant.create({ ram = { length = 0x1000 } }, { clear_hash_tree = "true" })
                end, "clear_hash_tree")
                local source <close> = variant.create({ ram = { length = 0x1000 } }, { clear_hash_tree = true })
                expect.equal(source:get_runtime_config().clear_hash_tree, true)
                expect.equal(source:get_hash_tree_stats().phtc.page_misses, 0)
                expect.equal(source:get_root_hash(), tests_util.calculate_emulator_hash(source))
            end)

            it("should reject an empty machine", function()
                local source <close> = variant.new()
                expect.fail(function()
                    source:clear_hash_tree()
                end, "no machine")
            end)
        end)

        describe("verify_hash_tree", function()
            it("should detect corrupted inner nodes in stored hash trees", function()
                local source <close> = variant.create({ ram = { length = 0x2000 } })
                local root = source:get_root_hash()
                local dirname = filesystem.temp_pathname()
                local _ <close> = tests_util.scope_exit(function()
                    cartesi.machine:remove_stored(dirname)
                end)
                source:store(dirname)
                local function verify()
                    local loaded <close> = variant.new():load(dirname, {}, cartesi.SHARING_NONE)
                    return loaded:verify_hash_tree()
                end
                expect.truthy(verify())
                local dht_filename = string.format("%s/%016x-%x.dht", dirname, cartesi.AR_RAM_START, 0x2000)
                local sht_filename = dirname .. "/hash_tree.sht"
                -- Overwrite the RAM dense tree root and the sparse tree root
                -- (loading rehashes sparse inner nodes, so only the dense tree stays corrupted)
                for _, filename in ipairs({ dht_filename, sht_filename }) do
                    local data = filesystem.read_file(filename)
                    local offset = filename == dht_filename and cartesi.HASH_SIZE
                        or assert(data:find(root, 1, true)) - 1
                    local corrupted = string.rep("\1", cartesi.HASH_SIZE)
                    filesystem.write_file(
                        data:sub(1, offset) .. corrupted .. data:sub(offset + #corrupted + 1),
                        filename
                    )
                    expect.equal(verify(), filename == sht_filename)
                    filesystem.write_file(data, filename)
                end
            end)
        end)

        describe("concurrency runtime config", function()
            it("should clamp out-of-range update_hash_tree values", function()
                for _, update_hash_tree in ipairs({ -1, 0xffffffff, 0x100000001 }) do
                    local runtime = { concurrency = { update_hash_tree = update_hash_tree } }
                    local source <close> = variant.create({ ram = { length = 0x1000 } }, runtime)
                    expect.equal(source:get_root_hash(), machine:get_root_hash())
                end
            end)
        end)

        describe("mark_pages_dirty backing-store config", function()
            it("should default to false and preserve an explicit true", function()
                expect.equal(machine:get_initial_config().ram.backing_store.mark_pages_dirty, false)
                local source <close> = variant.create({
                    ram = { length = 0x1000, backing_store = { mark_pages_dirty = true } },
                })
                expect.equal(source:get_initial_config().ram.backing_store.mark_pages_dirty, true)
                expect.equal(source:get_root_hash(), tests_util.calculate_emulator_hash(source))
            end)

            it("should reject a value that is not a boolean", function()
                expect.fail(function()
                    local _ <close> = variant.create({
                        ram = { length = 0x1000, backing_store = { mark_pages_dirty = "true" } },
                    })
                end, "mark_pages_dirty")
            end)
        end)

        describe("memory range replacement", function()
            for _, access in ipairs({ "code", "read", "write" }) do
                it("should refresh the hot TLB after memory replacement (" .. access .. ")", function()
                    local drive_start = 0x90000000
                    local old_value = 0x0102030405060708
                    local new_value = 0x0807060504030201
                    -- addi a2,zero,1; ld a2,0(a0); sd a1,0(a0)
                    local instruction = access == "code" and 0x00100613 or access == "read" and 0x00053603 or 0x00b53023
                    local program = string.pack("<I4I4", instruction, instruction)
                    -- Replacement code: addi a2,zero,2.
                    local replacement_data = access == "code" and string.pack("<I4I4", 0x00200613, 0x00200613)
                        or string.pack("<I8", new_value)
                    replacement_data = replacement_data .. string.rep("\0", 0x1000 - #replacement_data)
                    local _ <close>, replacement_filename = filesystem.write_scope_temp_file(replacement_data)
                    local source <close> = variant.create({
                        ram = { length = 0x1000 },
                        flash_drive = { { start = drive_start, length = 0x1000 } },
                    })
                    source:write_memory(cartesi.AR_RAM_START, program)
                    source:write_memory(drive_start, string.pack("<I8", old_value))
                    source:write_reg("x10", drive_start)
                    source:write_reg("x11", old_value)
                    source:run(1) -- Populate the hot code, read, or write entry before replacing its mapping.
                    expect.equal(source:read_reg("mcycle"), 1)
                    if access == "code" then
                        expect.equal(source:read_reg("x12"), 1)
                    elseif access == "read" then
                        expect.equal(source:read_reg("x12"), old_value)
                    else
                        source:write_reg("x11", old_value + 1)
                    end

                    local shadow_tlb = source:read_memory(cartesi.AR_SHADOW_TLB_START, cartesi.AR_SHADOW_TLB_LENGTH)
                    local range_start = access == "code" and cartesi.AR_RAM_START or drive_start
                    source:replace_memory_range({
                        start = range_start,
                        length = 0x1000,
                        backing_store = { data_filename = replacement_filename },
                    })
                    expect.equal(source:read_memory(range_start, 0x1000), replacement_data)
                    expect.equal(
                        source:read_memory(cartesi.AR_SHADOW_TLB_START, cartesi.AR_SHADOW_TLB_LENGTH),
                        shadow_tlb
                    )

                    source:run(2) -- Use the cached guest translation with the new host mapping.
                    expect.equal(source:read_reg("mcycle"), 2)
                    if access == "code" then
                        expect.equal(source:read_reg("x12"), 2)
                    elseif access == "read" then
                        expect.equal(source:read_reg("x12"), new_value)
                    else
                        expect.equal(source:read_memory(drive_start, 8), string.pack("<I8", old_value + 1))
                    end
                    expect.equal(source:get_root_hash(), tests_util.calculate_emulator_hash(source))
                end)
            end
        end)

        describe("get_uarch_pristine_hash", function()
            it("should accept the pristine hash in a reset log and reject a changed hash", function()
                local source <close> = variant.create({ ram = { length = 0x1000 } })
                source:write_reg("uarch_x1", 123)
                local hash = source:get_uarch_pristine_hash()
                local before = source:get_root_hash()
                local log = source:log_reset_uarch()
                expect.equal(log.accesses[1].written_hash, hash)
                expect.equal(source:verify_reset_uarch(before, log), source:get_root_hash())
                log.accesses[1].written_hash = string.char(hash:byte(1) ~ 1) .. hash:sub(2)
                expect.fail(function()
                    source:verify_reset_uarch(before, log)
                end, "written hash for uarch.state does not match expected hash")
            end)

            it("should match the full uarch subtree after reset", function()
                local hash = machine:get_uarch_pristine_hash()
                machine:write_reg("uarch_x1", 123)
                expect.equal(machine:get_uarch_pristine_hash(), hash)
                machine:reset_uarch()
                expect.equal(
                    machine:get_node_hash(cartesi.UARCH_STATE_START_ADDRESS, cartesi.UARCH_STATE_LOG2_SIZE),
                    hash
                )
            end)

            it("should work on an empty handle", function()
                local source <close> = variant.create({ ram = { length = 0x1000 } })
                source:destroy()
                expect.truthy(source:is_empty())
                expect.equal(source:get_uarch_pristine_hash(), cartesi.machine:get_uarch_pristine_hash())
                expect.truthy(source:is_empty())
            end)
        end)

        describe("log_step", function()
            it("should reject an empty machine", function()
                local log_filename = filesystem.temp_pathname()
                local source <close> = variant.new()
                expect.fail(function()
                    source:log_step(1, log_filename)
                end, "no machine")
                source:create({ ram = { length = 0x1000 } })
                source:destroy()
                expect.fail(function()
                    source:log_step(1, log_filename)
                end, "no machine")
            end)
        end)

        describe("create and load", function()
            it("should reject a non-empty machine", function()
                local source <close> = variant.create({ ram = { length = 0x1000 } })
                local root = source:get_root_hash()
                local dirname = filesystem.temp_pathname()
                local _ <close> = tests_util.scope_exit(function()
                    cartesi.machine:remove_stored(dirname)
                end)
                source:store(dirname)
                expect.fail(function()
                    source:create({ ram = { length = 0x2000 } })
                end, "machine exists")
                expect.fail(function()
                    source:load(dirname)
                end, "machine exists")
                expect.equal(source:get_root_hash(), root)
            end)
        end)

        describe("move", function()
            it("should return a machine from a closing scope", function()
                local function create_moved()
                    local source <close> = variant.create({ ram = { length = 0x1000 } })
                    source:write_reg("x1", 42)
                    local root_hash = source:get_root_hash()
                    return source:move(), root_hash
                end

                local moved <close>, root_hash = create_moved()
                collectgarbage("collect")
                expect.equal(moved:get_root_hash(), root_hash)
                expect.equal(moved:read_reg("x1"), 42)
                moved:write_reg("x1", 43)
                expect.equal(moved:read_reg("x1"), 43)
            end)

            it("should leave the source empty and reusable", function()
                local source <close> = variant.create({ ram = { length = 0x1000 } })
                source:write_reg("x1", 42)
                local moved <close> = source:move()
                expect.truthy(source ~= moved)
                expect.truthy(source:is_empty())
                source:create({ ram = { length = 0x1000 } })
                source:write_reg("x1", 43)
                expect.equal(moved:read_reg("x1"), 42)
                expect.equal(source:read_reg("x1"), 43)
            end)

            it("should move an empty handle", function()
                local source <close> = variant.create({ ram = { length = 0x1000 } })
                source:destroy()
                local moved <close> = source:move()
                expect.truthy(source:is_empty())
                expect.truthy(moved:is_empty())
                moved:create({ ram = { length = 0x1000 } })
                moved:write_reg("x1", 42)
                expect.equal(moved:read_reg("x1"), 42)
            end)
        end)

        describe("get_address_name", function()
            -- Build table of reg name -> expected get_address_name output.
            -- Names follow shadow_registers_get_what_name / shadow_uarch_state_get_what_name strings.
            local reg_address_names = {}
            for i = 0, 31 do
                reg_address_names["x" .. i] = "x" .. i
                reg_address_names["f" .. i] = "f" .. i
                reg_address_names["uarch_x" .. i] = "uarch.x" .. i
            end
            local identity_regs = {
                "pc",
                "fcsr",
                "mvendorid",
                "marchid",
                "mimpid",
                "mcycle",
                "icycleinstret",
                "mstatus",
                "mtvec",
                "mscratch",
                "mepc",
                "mcause",
                "mtval",
                "misa",
                "mie",
                "mip",
                "medeleg",
                "mideleg",
                "mcounteren",
                "menvcfg",
                "stvec",
                "sscratch",
                "sepc",
                "scause",
                "stval",
                "satp",
                "scounteren",
                "senvcfg",
                "ilrsc",
                "iprv",
                "iunrep",
                "imcyclemax",
            }
            for _, name in ipairs(identity_regs) do
                reg_address_names[name] = name
            end
            local namespaced_regs = {
                iflags_X = "iflags.X",
                iflags_Y = "iflags.Y",
                iflags_H = "iflags.H",
                clint_mtimecmp = "clint.mtimecmp",
                plic_girqpend = "plic.girqpend",
                plic_girqsrvd = "plic.girqsrvd",
                htif_tohost = "htif.tohost",
                htif_fromhost = "htif.fromhost",
                htif_ihalt = "htif.ihalt",
                htif_iconsole = "htif.iconsole",
                htif_iyield = "htif.iyield",
                uarch_halt = "uarch.halt",
                uarch_cycle = "uarch.cycle",
                uarch_pc = "uarch.pc",
            }
            for reg_name, addr_name in pairs(namespaced_regs) do
                reg_address_names[reg_name] = addr_name
            end

            it("should roundtrip get_reg_address through get_address_name", function()
                for reg_name, expected in pairs(reg_address_names) do
                    local paddr = machine:get_reg_address(reg_name)
                    expect.equal(machine:get_address_name(paddr), expected)
                end
            end)

            it("should return correct names for TLB slot fields", function()
                -- shadow_tlb_slot layout (32 bytes): vaddr_page@0, vp_offset@8, pma_index@16, zero_padding_@24
                local tlb_slot_size = 32 -- sizeof(shadow_tlb_slot)
                local tlb_set_bytes = 256 * tlb_slot_size -- TLB_SET_SIZE * sizeof(shadow_tlb_slot)
                local tlb_fields = {
                    [0] = "tlb.slot.vaddr_page",
                    [8] = "tlb.slot.vp_offset",
                    [16] = "tlb.slot.pma_index",
                    [24] = "tlb.slot.zero_padding_",
                }
                for set_index = 0, 2 do
                    for _, slot_index in ipairs({ 0, 17 }) do
                        for field_offset, expected in pairs(tlb_fields) do
                            local paddr = cartesi.AR_SHADOW_TLB_START
                                + set_index * tlb_set_bytes
                                + slot_index * tlb_slot_size
                                + field_offset
                            expect.equal(machine:get_address_name(paddr), expected)
                        end
                    end
                end
            end)

            it("should return correct names for PMA entry fields", function()
                -- pmas_entry layout (16 bytes): istart@0, ilength@8
                expect.equal(machine:get_address_name(cartesi.AR_PMAS_START + 0), "pma.istart")
                expect.equal(machine:get_address_name(cartesi.AR_PMAS_START + 8), "pma.ilength")
            end)

            it("should return uarch.ram for uarch RAM address", function()
                expect.equal(machine:get_address_name(cartesi.UARCH_RAM_START_ADDRESS), "uarch.ram")
            end)

            it("should return memory for unmapped address", function()
                expect.equal(machine:get_address_name(cartesi.AR_RAM_START), "memory")
            end)

            it("should return unknown_ for misaligned addresses in each shadow region", function()
                expect.equal(machine:get_address_name(cartesi.AR_SHADOW_STATE_START + 1), "state.unknown_")
                expect.equal(machine:get_address_name(cartesi.AR_SHADOW_TLB_START + 1), "tlb.unknown_")
                expect.equal(machine:get_address_name(cartesi.AR_PMAS_START + 1), "pma.unknown_")
                expect.equal(machine:get_address_name(cartesi.UARCH_SHADOW_START_ADDRESS + 1), "uarch.unknown_")
            end)

            it("should return correct names for peripheral regions", function()
                expect.equal(machine:get_address_name(cartesi.AR_DTB_START), "dtb")
                expect.equal(machine:get_address_name(cartesi.AR_DTB_START + cartesi.AR_DTB_LENGTH - 1), "dtb")
                expect.equal(machine:get_address_name(cartesi.AR_CLINT_START), "clint")
                expect.equal(machine:get_address_name(cartesi.AR_CLINT_START + cartesi.AR_CLINT_LENGTH - 1), "clint")
                expect.equal(machine:get_address_name(cartesi.AR_HTIF_START), "htif")
                expect.equal(machine:get_address_name(cartesi.AR_HTIF_START + cartesi.AR_HTIF_LENGTH - 1), "htif")
                expect.equal(machine:get_address_name(cartesi.AR_PLIC_START), "plic")
                expect.equal(machine:get_address_name(cartesi.AR_PLIC_START + cartesi.AR_PLIC_LENGTH - 1), "plic")
                expect.equal(machine:get_address_name(cartesi.AR_CMIO_RX_BUFFER_START), "cmio.rx_buffer")
                expect.equal(machine:get_address_name(cartesi.AR_CMIO_TX_BUFFER_START), "cmio.tx_buffer")
                expect.equal(machine:get_address_name(cartesi.AR_FIRST_VIRTIO_START), "virtio")
                expect.equal(machine:get_address_name(cartesi.AR_LAST_VIRTIO_END - 1), "virtio")
            end)
        end)

        describe("read_reg and write_reg", function()
            -- Registers whose write must be rejected.
            local read_only = { x0 = true, mvendorid = true, marchid = true, mimpid = true }

            it("should round-trip every shadow register through read_reg/write_reg", function()
                -- Walk the shadow register page (it ends where the shadow TLB
                -- begins) and name each slot through get_address_name. Its dotted
                -- names map to read_reg/write_reg names by turning each "." into
                -- "_" (e.g. "iflags.X" -> "iflags_X").
                local value = 0xfedcba9876543210
                for addr = cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_TLB_START - 8, 8 do
                    local addr_name = machine:get_address_name(addr)
                    if addr_name ~= "state.unknown_" then
                        local name = addr_name:gsub("%.", "_")
                        if read_only[name] then
                            expect.fail(function()
                                machine:write_reg(name, 1)
                            end, "register is read-only")
                            machine:read_reg(name)
                        else
                            machine:write_reg(name, value)
                            expect.equal(machine:read_reg(name), value)
                        end
                    end
                end
            end)

            it("should round-trip a value through each htif field alias", function()
                -- These aliases share the htif.tohost/htif.fromhost words, so they
                -- have no address of their own and only preserve their sub-field.
                -- A value that fits the narrowest (8-bit) field round-trips.
                local field_aliases = {
                    "htif_tohost_dev",
                    "htif_tohost_cmd",
                    "htif_tohost_reason",
                    "htif_tohost_data",
                    "htif_fromhost_dev",
                    "htif_fromhost_cmd",
                    "htif_fromhost_reason",
                    "htif_fromhost_data",
                }
                for _, name in ipairs(field_aliases) do
                    machine:write_reg(name, 0x5)
                    expect.equal(machine:read_reg(name), 0x5)
                end
            end)
        end)

        describe("write_word", function()
            it("should reject unmapped shadow state addresses", function()
                -- Aligned address inside the shadow register page but past the
                -- register layout, so it forwards to no register.
                expect.fail(function()
                    machine:write_word(cartesi.AR_SHADOW_STATE_START + 0xff8, 0)
                end, "unhandled write to shadow state")
            end)

            it("should reject writes to protected memory ranges", function()
                -- The shadow TLB is in the protected shadow state range, outside
                -- the register page that write_word forwards to write_reg.
                expect.fail(function()
                    machine:write_word(cartesi.AR_SHADOW_TLB_START, 0)
                end, "protected memory range")
            end)

            it("should reject writes to read-only memory ranges", function()
                local ro <close> = variant.create({
                    ram = { length = 0x1000 },
                    nvram = { { start = 0x70000000, length = 0x1000, read_only = true } },
                })
                expect.fail(function()
                    ro:write_word(0x70000000, 0x1234)
                end, "read-only")
            end)
        end)

        describe("write_memory over shadow state", function()
            -- Regression: overwriting the whole shadow state (its special case in
            -- machine::write_memory) resets the hot TLB. Pages written by the guest
            -- through the write TLB but not yet flushed into the dirty-page tree
            -- would lose their pending dirty mark, so a later incremental hash would
            -- not reflect them. write_memory must flush the write TLB dirty pages
            -- before replacing the shadow.
            it("should keep the root hash consistent with memory", function()
                -- auipc t0, 0x2 ; addi t1, x0, 0x42 ; sd t1, 0(t0) ; jal x0, 0
                -- The store dirties page RAM_START+0x2000 through the write TLB.
                local program = string.char(
                    0x97,
                    0x22,
                    0x00,
                    0x00,
                    0x13,
                    0x03,
                    0x20,
                    0x04,
                    0x23,
                    0xb0,
                    0x62,
                    0x00,
                    0x6f,
                    0x00,
                    0x00,
                    0x00
                )
                local m <close> = variant.create({ ram = { length = 1 << 20 } })
                m:write_memory(cartesi.AR_RAM_START, program)
                -- Snapshot the shadow while its TLB references no written page.
                local shadow = m:read_memory(cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH)
                -- Establish a baseline so the later hash update is incremental.
                m:get_root_hash()
                -- Execute the store, leaving the page dirty in host memory but only
                -- tracked by the write TLB, not yet by the dirty-page tree.
                m:run(100)
                -- Overwrite the shadow with the snapshot, whose TLB no longer
                -- references the written page.
                m:write_memory(cartesi.AR_SHADOW_STATE_START, shadow)
                expect.equal(m:get_root_hash(), tests_util.calculate_emulator_hash(m))
            end)

            it("should reject an inconsistent shadow and keep the machine unchanged", function()
                local m <close> = variant.create({ ram = { length = 1 << 20 } })
                local shadow = m:read_memory(cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH)
                local root = m:get_root_hash()
                -- Non-zero byte in the TLB padding page, which is not always dirty
                local padding = shadow:sub(1, 0x7000) .. "X" .. shadow:sub(0x7002)
                expect.fail(function()
                    m:write_memory(cartesi.AR_SHADOW_STATE_START, padding)
                end, "shadow padding bytes are corrupt")
                local x0 = m:get_reg_address("x0") - cartesi.AR_SHADOW_STATE_START
                local nonzero_x0 = shadow:sub(1, x0) .. string.pack("<I8", 1) .. shadow:sub(x0 + 9)
                expect.fail(function()
                    m:write_memory(cartesi.AR_SHADOW_STATE_START, nonzero_x0)
                end, "x0 register is corrupt")
                expect.equal(m:read_memory(cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH), shadow)
                expect.equal(m:get_root_hash(), root)
                expect.truthy(m:verify_hash_tree())
            end)
        end)
    end)
end

describe("JSON-RPC fork", function()
    local jsonrpc = require("cartesi.jsonrpc")

    local function request_batch(server, requests)
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local body = cartesi.tojson(requests)
        local response = {}
        local _, status = assert(http.request({
            url = "http://" .. server:get_server_address() .. "/",
            method = "POST",
            headers = { ["content-type"] = "application/json", ["content-length"] = tostring(#body) },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(response),
        }))
        expect.equal(status, 200)
        return cartesi.fromjson(table.concat(response))
    end

    for _, hash_function in ipairs({ "keccak256", "sha256" }) do
        for _, notification in ipairs({ false, true }) do
            it(
                "should preserve the fork snapshot in a batch ("
                    .. hash_function
                    .. ", notification="
                    .. tostring(notification)
                    .. ")",
                function()
                    local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN):create({
                        ram = { length = 0x1000 },
                        hash_tree = { hash_function = hash_function, phtc_size = 32 },
                    })
                    -- addi a2,zero,42; jal zero,0
                    server:write_memory(cartesi.AR_RAM_START, string.pack("<I4I4", 0x02a00613, 0x0000006f))
                    server:write_reg("x12", 0)
                    local responses = request_batch(server, {
                        { jsonrpc = "2.0", id = 1, method = "machine.write_reg", params = { "x1", 10 } },
                        { jsonrpc = "2.0", id = 2, method = "fork" },
                        {
                            jsonrpc = "2.0",
                            id = not notification and 3 or nil,
                            method = "machine.write_reg",
                            params = { "x1", 20 },
                        },
                        { jsonrpc = "2.0", id = 4, method = "machine.run", params = { 2 } },
                        { jsonrpc = "2.0", id = 5, method = "machine.read_reg", params = { "x1" } },
                    })
                    local by_id = {}
                    for _, response in ipairs(responses) do
                        by_id[response.id] = response
                    end
                    local child <close> =
                        jsonrpc.connect_server(by_id[2].result.address):set_cleanup_call(jsonrpc.SHUTDOWN)
                    expect.equal(#responses, notification and 4 or 5)
                    for _, response in ipairs(responses) do
                        expect.equal(response.error, nil)
                    end
                    expect.truthy(by_id[2].result.pid > 0)
                    expect.equal(by_id[5].result, 20)
                    expect.equal(server:read_reg("x1"), 20)
                    expect.equal(server:read_reg("x12"), 42)
                    expect.equal(server:read_reg("mcycle"), 2)
                    expect.equal(child:read_reg("x1"), 10)
                    expect.equal(child:read_reg("x12"), 0)
                    expect.equal(child:read_reg("mcycle"), 0)
                    expect.equal(server:get_root_hash(), tests_util.calculate_emulator_hash(server))
                    expect.equal(child:get_root_hash(), tests_util.calculate_emulator_hash(child))

                    child:write_reg("x1", 30)
                    child:run(1)
                    expect.equal(child:read_reg("mcycle"), 1)
                    expect.equal(child:read_reg("x12"), 42)
                    expect.equal(server:read_reg("x1"), 20)
                    expect.equal(server:read_reg("mcycle"), 2)
                end
            )
        end
    end

    it("should fork an empty server", function()
        local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
        local child <close>, address, pid = server:fork_server()
        child:set_cleanup_call(jsonrpc.SHUTDOWN)
        expect.truthy(server:is_empty())
        expect.truthy(child:is_empty())
        expect.truthy(pid > 0)
        expect.not_equal(address, server:get_server_address())
    end)

    -- Keeps the server busy with a request that timed out, so the next connections wait in its backlog
    local function make_busy(server)
        server:delay_next_request(1000)
        server:set_timeout(100)
        expect.fail(function()
            server:is_empty()
        end, "timeout")
    end

    it("should stop a server forked for a request that timed out", function()
        local server <close>, _, pid = jsonrpc.spawn_server()
        server:set_cleanup_call(jsonrpc.SHUTDOWN)
        make_busy(server)
        expect.fail(function()
            server:fork_server()
        end, "timeout")
        server:set_timeout(-1)
        expect.truthy(server:is_empty())
        local children <close> = assert(io.open(string.format("/proc/%d/task/%d/children", pid, pid)))
        expect.equal(children:read("a"), "")
    end)

    it("should not serve a connection accepted before a fork in the forked server", function()
        local socket = require("socket")
        local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
        make_busy(server)
        local host, port = server:get_server_address():match("^(.*):(%d+)$")
        local body = '{"jsonrpc":"2.0","id":1,"method":"fork"}'
        local request = "POST / HTTP/1.1\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
        local forker = assert(socket.connect(host, port))
        assert(forker:send(request))
        -- Accepted by the server right before it handles the fork request
        local idle = assert(socket.connect(host, port))
        local response = assert(forker:receive("*a"))
        local result = cartesi.fromjson(response:match("\r\n\r\n(.*)$")).result
        forker:close()
        local child <close> = jsonrpc.connect_server(result.address):set_cleanup_call(jsonrpc.SHUTDOWN)
        -- Shutting down the server closes its connections, and the forked server must not hold the idle one open
        server:set_timeout(-1)
        server:shutdown_server()
        server:set_cleanup_call(jsonrpc.NOTHING)
        idle:settimeout(1)
        expect.equal(select(2, idle:receive(1)), "closed")
        idle:close()
    end)

    it("should reject a shared memory range", function()
        local _ <close>, filename = filesystem.write_scope_temp_file(string.rep("\0", 0x1000))
        local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN):create({
            ram = { length = 0x1000, backing_store = { data_filename = filename, shared = true } },
        })
        local root_hash = server:get_root_hash()
        expect.fail(function()
            local child <close> = server:fork_server()
            child:set_cleanup_call(jsonrpc.SHUTDOWN)
        end, "cannot fork machines with shared backing stores")
        expect.equal(server:get_root_hash(), root_hash)
    end)

    for _, hash_function in ipairs({ "keccak256", "sha256" }) do
        for _, shared in ipairs({ false, true }) do
            it(
                "should handle a disk-backed hash tree (" .. hash_function .. ", shared=" .. tostring(shared) .. ")",
                function()
                    local prefix = filesystem.temp_pathname()
                    local config = {
                        ram = { length = 0x1000 },
                        hash_tree = {
                            hash_function = hash_function,
                            phtc_size = 32,
                            shared = true,
                            create = true,
                            sht_filename = prefix .. ".sht",
                            phtc_filename = prefix .. ".phtc",
                        },
                    }
                    do
                        local _ <close> = cartesi.machine(config)
                    end
                    local _ <close> = tests_util.scope_exit(function()
                        filesystem.remove_file(config.hash_tree.sht_filename)
                        filesystem.remove_file(config.hash_tree.phtc_filename)
                    end)
                    config.hash_tree.shared = shared
                    config.hash_tree.create = false
                    local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN):create(config)
                    server:write_reg("x1", 10)
                    local root_hash = server:get_root_hash()
                    if shared then
                        expect.fail(function()
                            local child <close> = server:fork_server()
                            child:set_cleanup_call(jsonrpc.SHUTDOWN)
                        end, "cannot fork machines with shared backing stores")
                        expect.equal(server:read_reg("x1"), 10)
                        expect.equal(server:get_root_hash(), root_hash)
                    else
                        do
                            local child <close> = server:fork_server()
                            child:set_cleanup_call(jsonrpc.SHUTDOWN)
                            expect.equal(child:get_root_hash(), root_hash)
                            server:write_reg("x1", 20)
                            child:write_reg("x1", 30)
                            server:write_memory(cartesi.AR_RAM_START, string.rep("A", 0x1000))
                            child:write_memory(cartesi.AR_RAM_START, string.rep("B", 0x1000))
                            expect.equal(server:read_reg("x1"), 20)
                            expect.equal(child:read_reg("x1"), 30)
                            expect.equal(server:read_memory(cartesi.AR_RAM_START, 0x1000), string.rep("A", 0x1000))
                            expect.equal(child:read_memory(cartesi.AR_RAM_START, 0x1000), string.rep("B", 0x1000))
                            expect.equal(server:get_root_hash(), tests_util.calculate_emulator_hash(server))
                            expect.equal(child:get_root_hash(), tests_util.calculate_emulator_hash(child))
                            expect.not_equal(server:get_root_hash(), child:get_root_hash())
                        end
                        expect.equal(server:read_reg("x1"), 20)
                        expect.equal(server:get_root_hash(), tests_util.calculate_emulator_hash(server))
                    end
                end
            )
        end
    end
end)

describe("remote error messages", function()
    it("should survive an error message with invalid UTF-8", function()
        local jsonrpc = require("cartesi.jsonrpc")
        local dirname = filesystem.temp_pathname()
        filesystem.create_directory(dirname)
        local _ <close> = tests_util.scope_exit(function()
            filesystem.remove_file(dirname .. "/config.json")
            filesystem.remove_directory(dirname)
        end)
        filesystem.write_file('{"a":\xff}', dirname .. "/config.json")
        local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
        expect.fail(function()
            server:load(dirname)
        end, "parse error")
        expect.truthy(server:is_empty())
    end)

    it("should not execute a request with an invalid id", function()
        local jsonrpc = require("cartesi.jsonrpc")
        local http = require("socket.http")
        local server <close> =
            jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN):create({ ram = { length = 0x1000 } })
        local body = '[{"jsonrpc":"2.0","id":true,"method":"machine.write_reg","params":["x1",77]}]'
        local response = assert(http.request("http://" .. server:get_server_address() .. "/", body))
        local responses = cartesi.fromjson(response)
        expect.equal(#responses, 1)
        expect.equal(responses[1].error.code, -32600)
        expect.equal(server:read_reg("x1"), 0)
    end)
end)

describe("remote clone cleanup", function()
    local jsonrpc = require("cartesi.jsonrpc")
    for _, policy in ipairs({ jsonrpc.NOTHING, jsonrpc.DESTROY, jsonrpc.SHUTDOWN }) do
        for _, operation in ipairs({ "create", "load" }) do
            it("should own a " .. operation .. " clone (source cleanup=" .. tostring(policy) .. ")", function()
                local config = { ram = { length = 0x1000 }, hash_tree = { phtc_size = 32 } }
                local server <close> = jsonrpc.spawn_server():create(config)
                server:write_reg("x1", 42)
                local source <close> =
                    jsonrpc.connect_server(server:get_server_address()):set_cleanup_call(policy):set_timeout(1234)
                local dirname = filesystem.temp_pathname()
                local _ <close> = tests_util.scope_exit(function()
                    if operation == "load" then
                        cartesi.machine:remove_stored(dirname)
                    end
                end)
                local input = config
                if operation == "load" then
                    local machine <close> = cartesi.machine(config)
                    machine:write_reg("x1", 7)
                    machine:store(dirname)
                    input = dirname
                end

                local clone = source(input)
                -- The observer also cleans up if a regression leaves the clone's server running.
                local observer <close> = jsonrpc
                    .connect_server(clone:get_server_address())
                    :set_cleanup_call(jsonrpc.SHUTDOWN)
                    :set_timeout(1234)
                do
                    local scoped_clone <close> = clone
                    expect.equal(scoped_clone:get_timeout(), 1234)
                    expect.equal(scoped_clone:get_cleanup_call(), jsonrpc.SHUTDOWN)
                    expect.not_equal(scoped_clone:get_server_address(), source:get_server_address())
                    expect.falsy(scoped_clone:is_empty())
                    if operation == "load" then
                        expect.equal(scoped_clone:read_reg("x1"), 7)
                    end
                    expect.equal(scoped_clone:get_root_hash(), tests_util.calculate_emulator_hash(scoped_clone))
                    scoped_clone:write_reg("x1", 99)
                end
                expect.fail(function()
                    observer:get_server_version()
                end)
                expect.equal(server:read_reg("x1"), 42)
            end)
        end
    end
end)

describe("move remote cleanup", function()
    it("should transfer the connection and cleanup policy to the returned handle", function()
        local jsonrpc = require("cartesi.jsonrpc")
        local server <close> = jsonrpc.spawn_server():set_cleanup_call(jsonrpc.SHUTDOWN)
        server:create({ ram = { length = 0x1000 } })
        local address = server:get_server_address()
        local function connect_moved()
            local source <close> = jsonrpc.connect_server(address):set_cleanup_call(jsonrpc.DESTROY):set_timeout(1234)
            return source:move()
        end

        do
            local moved <close> = connect_moved()
            expect.equal(moved:get_server_address(), address)
            expect.equal(moved:get_timeout(), 1234)
            expect.equal(moved:get_cleanup_call(), jsonrpc.DESTROY)
            expect.falsy(server:is_empty())
            moved:write_reg("x1", 42)
            expect.equal(server:read_reg("x1"), 42)
        end
        expect.truthy(server:is_empty())
    end)
end)

describe("remote hash-tree concurrency", function()
    local jsonrpc = require("cartesi.jsonrpc")

    -- OpenMP spawns worker threads only when a hash-tree update uses a concurrency above 1
    local function count_threads_after_update(create_runtime, set_runtime)
        local server <close>, _, pid = jsonrpc.spawn_server()
        server:set_cleanup_call(jsonrpc.SHUTDOWN):create({ ram = { length = 0x100000 } }, create_runtime)
        if set_runtime then
            server:set_runtime_config(set_runtime)
        end
        server:write_memory(cartesi.AR_RAM_START, string.rep("\1", 0x100000))
        server:get_root_hash()
        local tasks <close> = assert(io.popen("ls /proc/" .. pid .. "/task"))
        local _, count = tasks:read("a"):gsub("\n", "")
        return count
    end

    it("should apply update_hash_tree changed by set_runtime_config", function()
        local one = { concurrency = { update_hash_tree = 1 } }
        local two = { concurrency = { update_hash_tree = 2 } }
        expect.equal(count_threads_after_update(one, two), count_threads_after_update(two))
    end)
end)

lester.report()
lester.exit()
