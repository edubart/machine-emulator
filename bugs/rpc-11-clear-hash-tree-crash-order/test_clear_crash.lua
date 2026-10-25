-- Proof: clear_hash_tree on a SHARING_ALL machine zeroes each dense hash tree (.dht, via punch-hole on
-- the shared file) BEFORE marking that range's pages dirty in the shared .dpt.  A process death between the
-- two leaves the stored directory with a zeroed .dht and a clean .dpt; on reload the hash tree trusts the
-- clean pages and the machine reports a WRONG root hash, silently.
-- Crash injection is deterministic: shim.so (LD_PRELOAD) SIGKILLs the child right after the N-th
-- punch-hole fallocate issued inside clear_hash_tree.
local cartesi = require"cartesi"
local here = arg[0]:match("^(.*)/") or "."
local shim = os.getenv("SHIM_SO") or (here .. "/shim.so")
local base = os.getenv("TMPDIR_TEST") or (here .. "/tmpdirs")
os.execute("rm -rf '" .. base .. "' && mkdir -p '" .. base .. "'")

local function sh(cmd) local ok, how, code = os.execute(cmd); return ok, how, code end
local function hex(h) return cartesi.tohex(h) end

-- 1. Build and store a small machine with non-trivial RAM and flash contents
local golden = base .. "/golden"
do
    local m <close> = cartesi.machine({
        ram = { length = 1 << 20 },
        flash_drive = { { start = 1 << 40, length = 1 << 20 } },
    })
    m:write_memory(cartesi.AR_RAM_START or 0x80000000, string.rep("A", 8192))
    m:write_memory((1 << 40) + 4096, string.rep("Z", 4096))
    m:store(golden)
end
local expected
do
    local m <close> = cartesi.new():load(golden, nil, cartesi.SHARING_NONE)
    expected = m:get_root_hash()
end
print("expected root hash", hex(expected))

local failures = 0
for n = 1, 4 do
    local dir = string.format("%s/run%d", base, n)
    sh(string.format("cp -a '%s' '%s'", golden, dir))
    local armed = dir .. ".armed"
    os.remove(armed)
    local cmd = string.format("timeout 60 env LD_PRELOAD='%s' CRASH_ARM='%s' CRASH_AFTER=%d lua5.4 '%s/child.lua' '%s' '%s'",
        shim, armed, n, here, dir, armed)
    local ok, how, code = sh(cmd)
    print(string.format("crash after punch-hole #%d: child exit %s %s", n, tostring(how), tostring(code)))
    os.remove(armed)
    -- 2. Reload the stored machine as a validator would after a restart
    local m <close> = cartesi.new():load(dir, nil, cartesi.SHARING_NONE)
    local got = m:get_root_hash()
    local consistent = m:verify_hash_tree()
    -- the true state hash of the stored contents, recomputed from scratch
    m:clear_hash_tree()
    local recomputed = m:get_root_hash()
    print(string.format("  reload root %s verify_hash_tree=%s recomputed %s", hex(got), tostring(consistent), hex(recomputed)))
    if recomputed ~= expected then
        print("  note: stored contents changed (unexpected)")
    end
    if got ~= expected then
        failures = failures + 1
        print(string.format("BUG: after a crash inside clear_hash_tree (SHARING_ALL), reloaded machine reports root hash %s instead of %s",
            hex(got), hex(expected)))
    end
end
os.execute("rm -rf '" .. base .. "'")
if failures > 0 then os.exit(1) end
print("OK: no wrong root hash after crash during clear_hash_tree")
