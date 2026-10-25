-- Repro: evmu type-spec parser strips memory/storage/calldata prefixes from parameter names.
local evmu = require("cartesi.evmu")
local bug = false
local function report(fmt, ...) print(string.format(fmt, ...)); bug = true end

-- 1) parse_type_spec on names starting with a data-location keyword
for _, nm in ipairs({ "storageRoot", "memoryIndex", "calldataHash", "storage_x" }) do
    local ok, p = pcall(evmu.parse_type_spec, "(uint256 " .. nm .. ")")
    if not ok then
        report("BUG: parse_type_spec('(uint256 %s)') failed: %s", nm, tostring(p))
    else
        local c = p.components[1]
        if c.name ~= nm then
            report("BUG: parameter %q parsed as name=%s data_location=%s", nm, tostring(c.name), tostring(c.data_location))
        end
    end
end

-- 2) decode_abi returns the value under a mangled key
local data = evmu.encode_abi("(uint256,uint256)", { 1, 2 })
local ok, v = pcall(evmu.decode_abi, "(uint256 storageRoot, uint256 memoryIndex)", data)
if not ok then
    report("BUG: decode_abi failed: %s", tostring(v))
else
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    if v.storageRoot == nil or v.memoryIndex == nil then
        report("BUG: decode_abi named fields missing: storageRoot=%s memoryIndex=%s; keys present: %s",
            tostring(v.storageRoot), tostring(v.memoryIndex), table.concat(keys, ","))
    end
end

-- 3) named encoding rejects the correct field name
local ok2, err2 = pcall(evmu.encode_abi, "(uint256 storageRoot)", { storageRoot = 7 })
if not ok2 then report("BUG: encode_abi with {storageRoot=7} failed: %s", tostring(err2)) end

-- 4) encode_calldata with such a function signature
local ok3, err3 = pcall(evmu.encode_calldata, "f(bytes32 calldataHash)", { calldataHash = evmu.raw(string.rep("\1", 32)) })
if not ok3 then report("BUG: encode_calldata with {calldataHash=...} failed: %s", tostring(err3)) end

-- sanity: a genuine data location still parses
local p = evmu.parse_type_spec("(bytes memory payload)")
assert(p.components[1].data_location == "memory" and p.components[1].name == "payload", "data location regression")

if bug then os.exit(1) end
print("OK: parameter names starting with data-location keywords are preserved")
