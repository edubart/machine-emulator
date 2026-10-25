-- Repro: write_memory full-shadow snapshot does not mark the TLB padding page dirty,
-- and does not validate the content (x0, iunrep, padding).
local cartesi = require("cartesi")
local D = arg[0]:match("(.*/)") or "./"
local bugs = 0
local function bug(msg) print("BUG: " .. msg); bugs = bugs + 1 end
local function hex(h) return cartesi.tohex(h) end

local S, L = cartesi.AR_SHADOW_STATE_START, cartesi.AR_SHADOW_STATE_LENGTH
local function new_machine()
    return cartesi.machine({ ram = { length = 1 << 20 } })
end

local function setbyte(s, off, b) return s:sub(1, off) .. string.char(b) .. s:sub(off + 2) end
local function set_u64(s, off, v) return s:sub(1, off) .. string.pack("<I8", v) .. s:sub(off + 9) end

-- Case 1: non-zero byte in TLB padding page (offset 0x7000)
do
    local m = new_machine()
    local h0 = m:get_root_hash()
    local s = m:read_memory(S, L)
    assert(#s == L)
    local s2 = setbyte(s, 0x7000, string.byte("X"))
    local ok, err = pcall(m.write_memory, m, S, s2)
    if not ok then
        print("write_memory rejected padding write (fixed?): " .. tostring(err))
    else
        local back = m:read_memory(S, L)
        assert(back:byte(0x7001) == string.byte("X"), "write not applied")
        local h1 = m:get_root_hash()
        local vok = m:verify_hash_tree()
        print("root before: " .. hex(h0))
        print("root after : " .. hex(h1))
        print("verify_hash_tree: " .. tostring(vok))
        if h1 == h0 then bug("root hash unchanged after writing 'X' at shadow offset 0x7000 (page not marked dirty)") end
        if not vok then bug("verify_hash_tree returns false after shadow snapshot write") end
        m:clear_hash_tree()
        local h2 = m:get_root_hash()
        print("root after clear_hash_tree: " .. hex(h2))
        if h2 ~= h1 then bug("root hash changes after clear_hash_tree (stale hash tree)") end
        local dir = D .. "stored-padding"
        os.execute("rm -rf '" .. dir .. "'")
        local sok, serr = pcall(m.store, m, dir)
        if not sok then
            print("store failed: " .. tostring(serr))
        else
            local lok, lerr = pcall(cartesi.machine, dir)
            print("load stored: " .. tostring(lok) .. " " .. (lok and "" or tostring(lerr)))
            if not lok then bug("stored machine cannot be loaded: " .. tostring(lerr)) end
        end
        os.execute("rm -rf '" .. dir .. "'")
    end
end

-- Case 2: non-zero x0 / mismatching iunrep accepted
local function check_reg_case(name, mutate)
    local m = new_machine()
    local s = m:read_memory(S, L)
    local s2 = mutate(m, s)
    local ok, err = pcall(m.write_memory, m, S, s2)
    if not ok then
        print(name .. ": write_memory rejected (fixed?): " .. tostring(err))
        return
    end
    local dir = D .. "stored-" .. name
    os.execute("rm -rf '" .. dir .. "'")
    local sok, serr = pcall(m.store, m, dir)
    if not sok then print(name .. ": store failed: " .. tostring(serr)); return end
    local lok, lerr = pcall(cartesi.machine, dir)
    print(name .. ": load stored: " .. tostring(lok) .. " " .. (lok and "" or tostring(lerr)))
    if not lok then bug(name .. " accepted by write_memory, stored machine unloadable: " .. tostring(lerr)) end
    os.execute("rm -rf '" .. dir .. "'")
end
check_reg_case("x0", function(m, s)
    local off = m:get_reg_address("x0") - S
    return set_u64(s, off, 0x1234)
end)
check_reg_case("iunrep", function(m, s)
    local off = m:get_reg_address("iunrep") - S
    local cur = string.unpack("<I8", s, off + 1)
    return set_u64(s, off, cur ~ 1)
end)

if bugs > 0 then os.exit(1) end
print("OK: no defect")
os.exit(0)
