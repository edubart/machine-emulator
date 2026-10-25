-- Proof for: a torn hash_tree.phtc, left by a store()/clone_stored() that was killed while writing it,
-- is accepted at load and silently yields wrong root hashes/proofs once cached pages are touched.
--
-- The kill is real: a child lua process runs machine:store() (or cartesi.machine:clone_stored()) with
-- an LD_PRELOAD shim that SIGKILLs it after N pwrite() calls to hash_tree.phtc.
-- Run from the repo root: eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh
-- (run.sh builds killshim.c into a temp dir and sets KILLSHIM_DIR/WORK_DIR). Exit 1 + "BUG:" when the defect is present.
-- Optional env: KILL_AFTER_PHTC=<n> (kill point, default 4000), VERIFY=1 (also call verify_hash_tree, noisy).
local cartesi = require("cartesi")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local shim = (os.getenv("KILLSHIM_DIR") or here) .. "/killshim.so"
local RAM = 0x80000000
local RAM_LEN = 16 << 20
local KILL_AFTER = tonumber(os.getenv("KILL_AFTER_PHTC") or "4000") -- phtc has ~37k non-pristine 4 KiB blocks; die well after header+metadata

local function build_machine()
    local m = cartesi.machine({ ram = { length = RAM_LEN } })
    local page = string.pack("<I8", 0x55) .. string.rep("\0", 4096 - 8)
    m:write_memory(RAM, string.rep(page, RAM_LEN // 4096))
    m:get_root_hash() -- populates the page hash-tree cache with all RAM pages
    return m
end

local function modify(m)
    -- a guest/input touching every RAM page (one word each); the rest of each page stays as before
    for p = 0, RAM_LEN - 4096, 4096 do
        m:write_word(RAM + p, 0x1234)
    end
    return m:get_root_hash()
end

-- child mode ---------------------------------------------------------------------------------------
if arg[1] == "child-store" then
    local m = build_machine()
    m:store(arg[2], cartesi.SHARING_ALL)
    os.exit(0)
elseif arg[1] == "child-clone" then
    cartesi.machine:clone_stored(arg[2], arg[3])
    os.exit(0)
end

-- parent mode --------------------------------------------------------------------------------------
local function sh(cmd)
    local ok, how, code = os.execute(cmd)
    return ok, how, code
end
local work = os.getenv("WORK_DIR")
if not work then
    work = os.tmpname()
    os.remove(work)
end
assert(sh("mkdir -p " .. work))
local function cleanup() sh("rm -rf " .. work) end

local function run_child(args)
    local cmd = string.format("timeout 120 env LD_PRELOAD=%s KILL_AFTER_PHTC_WRITES=%d lua5.4 %s %s",
        shim, KILL_AFTER, arg[0], args)
    local ok, how, code = sh(cmd)
    return ok, how, code
end

local ref = build_machine()
local ref_before = ref:get_root_hash()
local ref_after = modify(ref)
ref:destroy()

local function hex(h) return (h:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local failures = 0
local function check_dir(label, dir)
    local m = cartesi.machine(dir, {}, cartesi.SHARING_NONE) -- accepted without error
    local before = m:get_root_hash()
    local after = modify(m)
    local verified = "skipped (set VERIFY=1)"
    if os.getenv("VERIFY") then verified = m:verify_hash_tree() end -- noisy on stderr
    m:destroy()
    local c = cartesi.machine(dir, { clear_hash_tree = true }, cartesi.SHARING_NONE)
    local rebuilt = modify(c)
    c:destroy()
    print(string.format("[%s] load accepted; root on load matches reference: %s", label, tostring(before == ref_before)))
    print(string.format("[%s] root after touching pages: %s", label, hex(after)))
    print(string.format("[%s] reference root           : %s", label, hex(ref_after)))
    print(string.format("[%s] same dir, clear_hash_tree: %s", label, hex(rebuilt)))
    print(string.format("[%s] verify_hash_tree() after modification: %s", label, tostring(verified)))
    if after ~= ref_after then
        failures = failures + 1
        print(string.format("BUG: [%s] torn hash_tree.phtc accepted at load; machine computes a wrong root hash " ..
            "(clear_hash_tree rebuild %s reference)", label, rebuilt == ref_after and "matches" or "ALSO differs from"))
    end
end

-- 1) store() killed while writing hash_tree.phtc
local d1 = work .. "/stored"
local ok, how, code = run_child("child-store " .. d1)
print(string.format("child store exited: %s %s %s", tostring(ok), tostring(how), tostring(code)))
if ok then
    print("could not interrupt store (shim did not fire?)")
    cleanup()
    os.exit(2)
end
check_dir("store", d1)

-- 2) clone_stored() killed while copying hash_tree.phtc (ext4 etc.: no reflink -> copy_file fallback)
local src = work .. "/src"
local m = build_machine()
m:store(src, cartesi.SHARING_ALL)
m:destroy()
check_dir("intact-source", src) -- control: complete store behaves correctly
local d2 = work .. "/cloned"
ok, how, code = run_child("child-clone " .. src .. " " .. d2)
print(string.format("child clone_stored exited: %s %s %s", tostring(ok), tostring(how), tostring(code)))
if ok then
    print("clone_stored completed (reflink available?); clone scenario not applicable on this filesystem")
else
    check_dir("clone_stored", d2)
end

cleanup()
if failures > 0 then os.exit(1) end
print("OK: no wrong hash")
os.exit(0)
