-- hash_tree.get_data_root_hash(data, log2_size) must equal the hash the machine itself reports for a memory range
-- that holds `data` followed by zeros (the header of src/cartesi/hash-tree.lua says the data "need not fill the
-- tree"). For an all-zero range the natural data is "": e.g. string.unpack("z", nvram) returns "" for an empty
-- output in doc/recipes/slice-calculator-output.lua, which then splices get_data_root_hash(result, ...) into a
-- proof with verify_splice. With empty data level 0 is empty, the pairing loop creates no parents and the function
-- returns level[1] == nil, so the recipe raises instead of accepting a valid proof.
-- usage: lua5.4 empty.lua     exit 0 = fixed, 1 = bug reproduced
local cartesi = require("cartesi")
local hash_tree = require("cartesi.hash-tree")

local LOG2 = 12
local m <close> = cartesi.machine({ ram = { length = 0x10000 }, nvram = { { label = "out", length = 1 << LOG2 } } })
local nv = m:get_initial_config().nvram[1]
local proof = m:get_proof(nv.start, LOG2) -- whole-machine proof of the (all-zero) NVRAM
local machine_hash = m:get_root_hash()
local word_proof = m:get_proof(nv.start, cartesi.HASH_TREE_LOG2_WORD_SIZE) -- one all-zero word
local bug = false

local function show(h) return h and cartesi.tohex(h):sub(1, 18) or "nil" end
local function check(name, data, log2, expected)
    local ok, h = pcall(hash_tree.get_data_root_hash, data, log2)
    local good = ok and h == expected
    print(string.format("  get_data_root_hash(%-13s, %2d) = %-20s %s", name, log2, ok and show(h) or ("error: " .. h),
        good and "matches the machine" or "WRONG"))
    if not good then bug = true end
end
-- controls: data that is not empty but all zero gives the machine's hash
check("one zero byte", "\0", LOG2, proof.target_hash)
check("one zero word", string.rep("\0", 8), LOG2, proof.target_hash)
if bug then
    print("ERROR: the controls failed")
    os.exit(2)
end
check("empty string", "", LOG2, proof.target_hash)
check("empty string", "", cartesi.HASH_TREE_LOG2_WORD_SIZE, word_proof.target_hash)

-- the documented recipe flow: read the NVRAM as a C string and splice its hash back into the proof
local result = string.unpack("z", m:read_memory(nv.start, nv.length))
-- (verify_splice returns nothing and raises when the proof does not match)
local ok, err = pcall(hash_tree.verify_splice, proof, hash_tree.get_data_root_hash(result, LOG2), machine_hash)
print(string.format("  recipe flow (result=%q): verify_splice %s", result, ok and "accepted" or ("raised: " .. tostring(err))))
if not ok then bug = true end

if bug then
    print("BUG REPRODUCED: hash_tree.get_data_root_hash returns nil for empty data instead of the pristine root")
    os.exit(1)
end
print("OK: get_data_root_hash of empty data is the pristine root hash")
os.exit(0)
