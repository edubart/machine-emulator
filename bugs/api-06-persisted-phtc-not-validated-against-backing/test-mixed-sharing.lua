-- Case (b): hash tree shared + RAM unshared (SHARING_CONFIG), then reload with SHARING_ALL.
-- Run from repo root: eval $(make -s env); lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-mixed-sharing.lua
-- Exit 0 = fixed, exit 1 = BUG present.
local cartesi = require("cartesi")
local here = arg[0]:match("(.*/)") or "./"
local work = here .. "run_b"
os.execute("rm -rf '" .. work .. "' && mkdir -p '" .. work .. "'")
local dir = work .. "/m"
local RAM = 0x80000000
local ADDR = RAM + 5 * 4096 + 96
do
    local m = cartesi.machine({ ram = { length = 1 << 20 } })
    m:get_root_hash()
    m:store(dir)
    m:destroy()
end
-- mixed sharing: hash tree shared, ram private (edit stored config)
local f = assert(io.open(dir .. "/config.json")); local s = f:read("a"); f:close()
s = s:gsub('("hash_tree"%s*:%s*{.-"shared"%s*:%s*)false', "%1true", 1)
f = assert(io.open(dir .. "/config.json", "w")); f:write(s); f:close()
do
    local m = cartesi.machine(dir, {}, cartesi.SHARING_CONFIG)
    assert(m:get_initial_config().hash_tree.shared == true, "edit failed")
    assert(m:get_initial_config().ram.backing_store.shared == false)
    m:write_memory(ADDR - 96, string.rep("\xAA", 4096))
    m:get_root_hash()
    m:destroy()
end
local m = cartesi.machine(dir, {}, cartesi.SHARING_ALL)
local root = m:get_root_hash()
local p = m:get_proof(ADDR, 5)
local bug = false
if p.target_hash ~= cartesi.keccak256(m:read_memory(ADDR, 32)) then
    print("BUG: case (b) get_proof target_hash does not match memory word (stale phtc entry)")
    bug = true
end
m:destroy()
os.execute("rm -rf '" .. work .. "'")
if bug then os.exit(1) end
print("PASS case b")
