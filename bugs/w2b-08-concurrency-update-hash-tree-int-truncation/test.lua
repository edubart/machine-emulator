-- Repro: concurrency.update_hash_tree values truncating to negative int break hashing
local cartesi = require("cartesi")
local bad = false
local function try(v)
    local okc, m = pcall(cartesi.machine, { ram = { length = 1 << 20 } }, { concurrency = { update_hash_tree = v } })
    if not okc then
        print(string.format("update_hash_tree=%s: constructor rejected (%s) -- acceptable", tostring(v), tostring(m)))
        return
    end
    local ok, err = pcall(m.get_root_hash, m)
    if ok then
        print(string.format("update_hash_tree=%s: get_root_hash OK", tostring(v)))
    else
        print(string.format("BUG: update_hash_tree=%s accepted by constructor but get_root_hash fails: %s", tostring(v), tostring(err)))
        bad = true
    end
    local okp, errp = pcall(m.get_proof, m, 0x80000000, 12)
    if not okp then
        print(string.format("BUG: update_hash_tree=%s get_proof fails: %s", tostring(v), tostring(errp)))
        bad = true
    end
end
try(1)
try(0)
try(1000000)
try(-1)
try(4294967295)
try(0x80000000)
os.exit(bad and 1 or 0)
