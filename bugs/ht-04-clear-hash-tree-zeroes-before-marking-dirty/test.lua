-- Proof for: hash_tree::clear zeroes (punches) dense hash trees before marking pages dirty.
-- A process kill between the punch of the RAM .dht and the marking of the RAM .dpt leaves a stored
-- directory whose RAM dense tree is zero while its dirty-page tree says "clean". Reloading it yields
-- wrong root hashes / proofs with no error.
-- Run via run.sh (builds killshim.so into a temp dir and sets KILLSHIM_DIR / WORK_DIR).
local cartesi = require("cartesi")
local here = arg[0]:match("^(.*)/") or "."
local work = os.getenv("WORK_DIR") or (here .. "/tmpdir")
local shimdir = os.getenv("KILLSHIM_DIR") or here
os.execute("rm -rf " .. work .. " && mkdir -p " .. work)
local stored = work .. "/m"

local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local RAM_LEN = 4 << 20
local cfg = { ram = { length = RAM_LEN }, processor = { registers = {} } }

-- 1) Build and store a machine with non-trivial RAM contents.
local m = cartesi.machine(cfg, {})
for i = 0, 15 do
    m:write_memory(cartesi.AR_RAM_START + i * 0x40000, string.rep(string.char(65 + i), 4096))
end
local good = m:get_root_hash()
m:store(stored)
m:destroy()

-- 2) Child process: load SHARING_ALL and call clear_hash_tree(); the shim SIGKILLs it right after
--    the RAM .dht punch, i.e. inside hash_tree::clear() before the RAM dpt marking loop runs.
local child = string.format(
    "LD_PRELOAD=%s/killshim.so KILL_AFTER_PUNCH_OF=%s timeout 60 lua5.4 -e " ..
    "'local c=require\"cartesi\"; local m=c.machine(\"%s\",{},c.SHARING_ALL); m:clear_hash_tree(); " ..
    "io.stderr:write(\"child: clear completed (not killed)\\n\")'",
    shimdir, string.format("%016x-", cartesi.AR_RAM_START), stored)
local ok, how, code = os.execute(child)
print("child:", ok, how, code)
if not (how == "signal" and code == 9) and not (how == "exit" and code == 137) then
    print("NOTE: child was not killed at the punch point; cannot reproduce interrupted clear")
    os.exit(2)
end

-- 3) Restart: load the directory normally (read-only sharing, so nothing on disk changes).
local failures = 0
local l = cartesi.machine(stored, {}, cartesi.SHARING_NONE)
local r = l:get_root_hash()
print("good root    :", hex(good))
print("reloaded root:", hex(r))

-- Proof of a RAM page must verify against the (reported) root and carry the true page hash.
local ref = cartesi.machine(stored, { clear_hash_tree = true }, cartesi.SHARING_NONE) -- full rebuild
print("ref root     :", hex(ref:get_root_hash()))
local p = l:get_proof(cartesi.AR_RAM_START, 12)
local pref = ref:get_proof(cartesi.AR_RAM_START, 12)
if p.target_hash ~= pref.target_hash then
    print("BUG: reloaded machine's proof of RAM page 0 has target_hash " .. hex(p.target_hash) ..
        " but the true page hash is " .. hex(pref.target_hash))
    failures = failures + 1
end

-- Make the same small change in both machines; roots must stay equal.
l:write_memory(cartesi.AR_RAM_START + 0x100000, "z")
ref:write_memory(cartesi.AR_RAM_START + 0x100000, "z")
local r2, rr2 = l:get_root_hash(), ref:get_root_hash()
print("after write  :", hex(r2), "ref:", hex(rr2))
if r ~= good then
    print("BUG: root hash after interrupted clear_hash_tree is wrong on reload")
    failures = failures + 1
end
if r2 ~= rr2 then
    print("BUG: after one RAM write, reloaded machine root differs from correct root (stale zero dense hashes reused)")
    failures = failures + 1
end
os.execute("rm -rf " .. work)
os.exit(failures == 0 and 0 or 1)
