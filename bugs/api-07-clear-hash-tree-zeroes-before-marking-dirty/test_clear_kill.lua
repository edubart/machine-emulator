-- Proof for: hash_tree::clear zeroes shared dense trees before marking their pages dirty.
-- A SIGKILL between dense_hash_tree::clear() (hole punched in the stored .dht file) and
-- dirty_page_tree::mark_dirty_pages_and_up() leaves a stored machine whose RAM dense tree is all
-- zeros while its dirty-page tree says every RAM page is clean. Reloading it later (without
-- clear_hash_tree) yields wrong proofs and wrong root hashes, silently.
-- Run from the repo root: eval $(make -s env); sh bugs/api-07-clear-hash-tree-zeroes-before-marking-dirty/run.sh
local cartesi = require("cartesi")
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local hook = os.getenv("KILL_HOOK") or (here .. "/kill_after_punch.so")
local tmp = os.getenv("TMPDIR_TEST") or (here .. "/tmp")
os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp)
local base = tmp .. "/base"
local victim = tmp .. "/victim"

local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local RAM = 0x80000000
-- 1. Build and store a machine with non-trivial RAM content.
do
    local m <close> = cartesi.machine({ ram = { length = 1 << 20 } })
    for i = 0, 63 do
        m:write_memory(RAM + i * 4096 + 8, string.rep(string.char(i + 1), 64))
    end
    m:store(base)
end
-- Bring the stored hash tree up to date in place (as a node does when it keeps a SHARING_ALL machine):
-- the stored .dht now holds real hashes and the stored .dpt marks every page clean.
do
    local m <close> = cartesi.machine(base, {}, cartesi.SHARING_ALL)
    m:get_root_hash()
end
local function load(dir, runtime, sharing) return cartesi.machine(dir, runtime or {}, sharing or cartesi.SHARING_NONE) end
local H0, P0
do
    local m <close> = load(base)
    H0 = m:get_root_hash()
    P0 = m:get_proof(RAM + 5 * 4096, 12)
end
print("original root hash:        " .. hex(H0))

-- 2. Child loads a copy with SHARING_ALL + clear_hash_tree=true, and is SIGKILLed right after the RAM .dht hole punch.
assert(os.execute("cp -a " .. base .. " " .. victim))
local child = string.format(
    [[timeout 60 env LD_PRELOAD=%s lua5.4 -e 'local c=require"cartesi"; local m=c.machine("%s",{clear_hash_tree=true},c.SHARING_ALL); print("child survived")' ; echo "child exit status: $?"]],
    hook, victim)
local p = io.popen(child .. " 2>&1")
local out = p:read("a")
p:close()
io.write(out)
if not out:find("child exit status: 137") then
    print("SETUP FAILURE: child was not killed inside hash_tree::clear (hook did not fire)")
    os.exit(2)
end

-- 3. Reload the victim normally (no clear_hash_tree), as a restarting node would.
local bad = false
local m <close> = load(victim)
local H1 = m:get_root_hash()
print("reloaded root hash:        " .. hex(H1))
local ok_verify = m:verify_hash_tree()
print("verify_hash_tree():        " .. tostring(ok_verify))
local P1 = m:get_proof(RAM + 5 * 4096, 12)
local proof_ok = (#P1.sibling_hashes == #P0.sibling_hashes)
for i = 1, #P0.sibling_hashes do
    if P0.sibling_hashes[i] ~= P1.sibling_hashes[i] then proof_ok = false end
end
proof_ok = proof_ok and P0.target_hash == P1.target_hash and P0.root_hash == P1.root_hash
print("RAM page proof matches:    " .. tostring(proof_ok))
if not proof_ok then
    print("  target_hash orig=" .. hex(P0.target_hash) .. " reloaded=" .. hex(P1.target_hash))
end

-- 4. Same RAM write on the reloaded machine and on a reference machine; root hashes must agree.
m:write_memory(RAM + 7 * 4096, "x")
local H1w = m:get_root_hash()
local ref <close> = load(base)
ref:write_memory(RAM + 7 * 4096, "x")
local Hrw = ref:get_root_hash()
print("after write, reloaded:     " .. hex(H1w))
print("after write, reference:    " .. hex(Hrw))

if H1 ~= H0 then print("BUG: reloaded machine reports wrong root hash right after reload"); bad = true end
if not proof_ok then print("BUG: reloaded machine produces wrong Merkle proof for a RAM page (zeroed dense tree kept as clean)"); bad = true end
if H1w ~= Hrw then print("BUG: after one RAM write the reloaded machine reports a wrong root hash (no error raised)"); bad = true end
if ok_verify then
    if bad then print("BUG: verify_hash_tree() did not detect the corruption") end
else
    print("note: verify_hash_tree() detects the inconsistency (internal-test API only)")
end
os.execute("rm -rf " .. tmp)
if bad then os.exit(1) end
print("OK: no corruption after a kill during clear_hash_tree")
os.exit(0)
