-- Proves parse_func_sig cache (weak-keyed by string) never evicts entries.
local evmu = require("cartesi.evmu")
local N = 20000
local zero32 = "0x" .. ("00"):rep(32)
local function full_gc() for _ = 1, 4 do collectgarbage("collect") end end
-- warm up
evmu.encode_calldata("warm(uint256,bytes32)", { 1, zero32 })
full_gc()
local before = collectgarbage("count")
for i = 1, N do
    evmu.encode_calldata("f" .. i .. "(uint256,bytes32)", { 1, zero32 })
end
full_gc()
local after = collectgarbage("count")
local retained = after - before
-- Directly check the cache via the upvalue of parse_func_sig
local cache
local i = 1
while true do
    local name, val = debug.getupvalue(evmu.parse_func_sig, i)
    if not name then break end
    if name == "parsed_func_sig_cache" then cache = val end
    i = i + 1
end
local entries = 0
if cache then for _ in pairs(cache) do entries = entries + 1 end end
print(string.format("signatures=%d retained=%.1f KiB (%.0f bytes/sig) cache_entries=%d", N, retained,
    retained * 1024 / N, entries))
if entries >= N or retained > 16 * 1024 then
    print(string.format("BUG: parse_func_sig cache retained %d entries / %.1f MiB after full GC for %d " ..
        "no-longer-referenced signature strings (weak string keys never evict)", entries, retained / 1024, N))
    os.exit(1)
end
print("OK: cache entries were collected")
os.exit(0)
