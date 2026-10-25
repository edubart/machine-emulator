-- Test: cartesi-machine --remote-address=X --no-remote-create --clear-hash-tree must clear
-- the hash tree of the existing remote machine (or reject the combination).
local jsonrpc = require("cartesi.jsonrpc")

local server <close>, address = jsonrpc.spawn_server("127.0.0.1:0")
server:set_cleanup_call(jsonrpc.SHUTDOWN)
local m = server:create({ ram = { length = 1 << 20 } }, {})
m:get_root_hash() -- populate cached hash tree
m:get_hash_tree_stats(true) -- reset stats

-- measurement sanity: a fully cached tree needs no page rehash
m:get_root_hash()
local s0 = m:get_hash_tree_stats(true)
print("baseline (cached) page_misses:", s0.phtc.page_misses, "sparse_node_hashes:", s0.sparse_node_hashes)

local cmd = string.format(
    "timeout 60 cartesi-machine.lua --remote-address=%s --no-remote-create --no-remote-destroy "
        .. "--clear-hash-tree --max-mcycle=0 --final-hash 2>&1",
    address
)
print("running: " .. cmd)
local p = assert(io.popen(cmd))
local out = p:read("a")
local ok, how, code = p:close()
io.write(out)
print("CLI exit:", ok, how, code)

local s1 = m:get_hash_tree_stats(true)
print("page_misses during CLI run:", s1.phtc.page_misses, "sparse_node_hashes:", s1.sparse_node_hashes)
m:get_root_hash()
local s2 = m:get_hash_tree_stats(true)
print("page_misses on next root hash:", s2.phtc.page_misses)

-- reference: what an actual clear_hash_tree() costs
m:clear_hash_tree()
m:get_root_hash()
local s3 = m:get_hash_tree_stats(true)
print("reference page_misses after explicit clear_hash_tree():", s3.phtc.page_misses)

if not ok then
    print("CLI rejected the combination (acceptable fix)")
    os.exit(0, true)
end
if s1.phtc.page_misses + s2.phtc.page_misses == 0 then
    print("BUG: CLI accepted --clear-hash-tree with --no-remote-create and exited successfully, "
        .. "but the remote machine's hash tree was never cleared (0 page rehashes vs "
        .. s3.phtc.page_misses .. " after a real clear)")
    os.exit(1, true)
end
print("OK: hash tree was cleared")
os.exit(0, true)
