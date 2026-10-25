-- Reproduces: hash_tree.frontier(last_proof) hangs on target_address = 2^64-1 and
-- silently accepts out-of-range / inconsistent proofs.
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua
-- (writes hang-proof.json, ok-proof.json, child_hang.lua, cli*.log next to this script)
-- Exits non-zero printing "BUG:" lines while the defect is present.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local hf = cartesi.keccak256

local dir = arg[0]:match("^(.*)/[^/]*$") or "."
local bugs = 0
local function bug(msg)
    bugs = bugs + 1
    print("BUG: " .. msg)
end

local function mk(L, addr)
    local s = {}
    for i = 1, L do
        s[i] = hf("s" .. i)
    end
    return {
        target_address = addr,
        log2_target_size = 0,
        log2_root_size = L,
        target_hash = hf("t"),
        root_hash = hf("r"),
        sibling_hashes = s,
    }
end

-- 1) A Proof JSON with target_address 18446744073709551615 parses fine (it becomes Lua -1)
local proof_hang = mk(63, -1)
local json = cartesi.tojson(proof_hang, -1, "Proof")
json = json:gsub('"target_address":[^,}]*', '"target_address":18446744073709551615')
local parsed = cartesi.fromjson(json, "Proof")
assert(parsed.target_address == -1, "unexpected parse")
local proof_file = dir .. "/hang-proof.json"
local f = assert(io.open(proof_file, "w"))
f:write(json)
f:close()

-- 1a) Library: hash_tree.frontier(proof) in a child process, 5s timeout
local child = dir .. "/child_hang.lua"
f = assert(io.open(child, "w"))
f:write([[
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fs = io.open(arg[1]):read("a")
local proof = cartesi.fromjson(fs, "Proof")
local ok, err = pcall(ht.frontier, proof, "keccak256")
print("returned", ok, err)
]])
f:close()
local t0 = os.time()
local ok, how, code = os.execute(string.format("timeout 5 lua5.4 %q %q >/dev/null 2>&1", child, proof_file))
if how == "exit" and code == 124 then
    bug("hash_tree.frontier(proof) with target_address=2^64-1 (log2_root_size 63) did not return within 5s (infinite loop)")
else
    print("ok: library frontier(proof) returned (exit " .. tostring(code) .. ")")
end

-- 1b) CLI: cartesi-machine --cmio-advance-state last_output_proof:<file> with that proof.
-- The hang happens in initialize_cmio_outputs (hash_tree.frontier(proof)) before any input is
-- processed. A control run with a genuine last-output proof finishes in ~1-2s.
local good = ht.frontier_next_proofs(ht.frontier(63, "keccak256"), { hf("x") })[1]
local good_file = dir .. "/ok-proof.json"
f = assert(io.open(good_file, "w"))
f:write(cartesi.tojson(good, -1, "Proof"))
f:close()
local function run_cli(pfile, log)
    local cli = string.format(
        "cd %q && timeout 20 cartesi-machine.lua --ram-length=32Mi --revert-mode=none "
            .. "--cmio-advance-state=input:none-%%i.bin,input_file_index_begin:0,input_file_index_end:0,"
            .. "last_output_proof:%s,format:json "
            .. "-- true >%s 2>&1",
        dir,
        pfile,
        log
    )
    local _, h, c = os.execute(cli)
    return h, c
end
local h, c = run_cli(good_file, "cli-control.log")
assert(h == "exit" and c == 0, "control CLI run with genuine proof failed (exit " .. tostring(c) .. "), see cli-control.log")
print("ok: control CLI run with genuine last_output_proof exited 0")
h, c = run_cli(proof_file, "cli.log")
if h == "exit" and c == 124 then
    bug("cartesi-machine --cmio-advance-state last_output_proof:<target_address 18446744073709551615> hung (killed by 20s timeout)")
else
    print("ok: CLI terminated (exit " .. tostring(c) .. ")")
end

-- 2) Out-of-range target_address silently produces a frontier for a different leaf count.
-- Height-4 tree has 16 leaves: addresses 0..15. Address 16 must be rejected.
local ok2, f2 = pcall(ht.frontier, mk(4, 16), "keccak256")
if ok2 then
    bug(
        string.format(
            "frontier(proof) accepted target_address=16 in a 2^4-leaf tree; frontier leaf_count=%d (expected error; true count would be 17)",
            ht.frontier_get_leaf_count(f2)
        )
    )
else
    print("ok: out-of-range address 16 rejected: " .. tostring(f2))
end

-- 3) Proof whose root_hash does not match target/siblings is accepted without verification.
local junk = mk(4, 5) -- root_hash "r" unrelated to target_hash/siblings
local ok3, f3 = pcall(ht.frontier, junk, "keccak256")
if ok3 then
    local root = ht.frontier_get_root_hash(f3)
    if root ~= junk.root_hash then
        bug("frontier(proof) accepted a proof whose root_hash does not match its target/siblings (frontier root differs from proof.root_hash)")
    end
else
    print("ok: inconsistent proof rejected: " .. tostring(f3))
end

-- Sanity: a genuine proof round-trips (so the checks above are not caused by a broken test).
local g = ht.frontier(4, "keccak256")
local leaves = {}
for i = 1, 6 do
    leaves[i] = hf("leaf" .. i)
end
local proofs = ht.frontier_next_proofs(g, leaves)
local rebuilt = ht.frontier(proofs[6], "keccak256")
assert(ht.frontier_get_leaf_count(rebuilt) == 6, "sanity: leaf count")
assert(ht.frontier_get_root_hash(rebuilt) == proofs[6].root_hash, "sanity: root")
print("ok: sanity genuine proof rebuilds frontier with leaf_count 6 and matching root")

if bugs > 0 then
    os.exit(1)
end
print("PASS")
