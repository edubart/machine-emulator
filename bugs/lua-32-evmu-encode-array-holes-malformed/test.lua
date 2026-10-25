-- Repro: evmu ABI encoder with arrays containing nil holes
local evmu = require("cartesi.evmu")
local bugs = 0
local function report(fmt, ...) bugs = bugs + 1; print("BUG: " .. string.format(fmt, ...)) end

local function try(spec, args)
    local ok, res = pcall(evmu.encode_abi, spec, args)
    return ok, res
end

-- Case 1: dynamic array of static elements
do
    local vals = { 1, nil, 3 }
    print("#vals =", #vals)
    local ok, res = try("(uint8[])", { vals })
    if ok then
        print("uint8[] {1,nil,3} ->", evmu.encode_hex(res), "(" .. #res .. " bytes)")
        local count = #vals
        local expected_len = 32 + 32 + count * 32 -- offset + length + elements
        if #res ~= expected_len then
            report("uint8[] {1,nil,3}: encoded length word says %d elements but only %d element words emitted (%d bytes, expected %d)",
                count, (#res - 64) // 32, #res, expected_len)
        end
        -- decode back
        local dok, derr = pcall(evmu.decode_abi, "(uint8[])", res)
        print("decode_abi of produced data:", dok, dok and "" or derr)
        if not dok then report("encode_abi output for uint8[] cannot be decoded by decode_abi: %s", tostring(derr)) end
    else
        print("uint8[] {1,nil,3} rejected:", res)
    end
end

-- Case 2: static array T[3] of static elements -> fewer than k words, subsequent fields shift
do
    local vals = { 1, nil, 3 }
    local ok, res = try("(uint8[3],uint256)", { vals, 0x42 })
    if ok then
        print("(uint8[3],uint256) ->", evmu.encode_hex(res), "(" .. #res .. " bytes)")
        if #res ~= 4 * 32 then
            report("(uint8[3],uint256) with {1,nil,3}: static head is %d bytes, expected 128; following field shifted", #res)
        end
        local dok, d = pcall(evmu.decode_abi, "(uint8[3],uint256)", res)
        if dok then
            print("decoded:", d[1][1], d[1][2], d[1][3], tostring(d[2]))
        else
            print("decode error:", d)
        end
    else
        print("(uint8[3],uint256) rejected:", res)
    end
end

-- Case 3: dynamic array of dynamic elements: offsets table
do
    local vals = { "a", nil, "c" }
    local ok, res = try("(string[])", { vals })
    if ok then
        print("string[] {'a',nil,'c'} ->", evmu.encode_hex(res), "(" .. #res .. " bytes)")
        local dok, derr = pcall(evmu.decode_abi, "(string[])", res)
        print("decode_abi:", dok, dok and "" or derr)
        if not dok then report("string[] with hole: encoded data is malformed (decode_abi fails: %s)", tostring(derr)) end
    else
        print("string[] rejected:", res)
    end
end

-- Case 4: bytes32[] proof array like a sibling list, accidental nil at a level
do
    local h = "0x" .. string.rep("11", 32)
    local vals = { h, h, nil, h }
    local ok, res = try("(bytes32[],uint256)", { vals, 7 })
    if ok then
        print("(bytes32[],uint256) hole ->", #res, "bytes")
        local dok, d = pcall(evmu.decode_abi, "(bytes32[],uint256)", res)
        print("decode_abi:", dok, dok and ("n=" .. #d[1] .. " u=" .. tostring(d[2])) or d)
        if not dok then report("bytes32[] with hole silently encoded into malformed data (decode fails: %s)", tostring(d)) end
    else
        print("bytes32[] rejected:", res)
    end
end

if bugs > 0 then os.exit(1) end
print("OK: arrays with holes are rejected or correctly encoded")
