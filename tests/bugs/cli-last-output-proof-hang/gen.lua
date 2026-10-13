-- Writes the inputs of the test into the current directory:
--   valid.json: a correct outputs-tree proof (JSON, as the CLI stores them between epochs) for output index 0
--   bad.json:   the same proof with target_address = 2^64-1, outside the 2^63-leaf outputs tree
--   yield.bin:  a tiny RAM image that performs a manual rx-accepted yield, so --cmio-advance-state can start an epoch
local cartesi = require("cartesi")
local hash_tree = require("cartesi.hash-tree")

local log2_max = cartesi.ROLLUP_LOG2_MAX_OUTPUT_COUNT
local output_hash = string.rep("\x11", cartesi.HASH_SIZE)
local proof = hash_tree.frontier_next_proofs(hash_tree.frontier(log2_max, "keccak256"), { output_hash })[1]
assert(proof.target_address == 0, "unexpected target address")
hash_tree.verify_slice(proof, "keccak256") -- raises if the siblings do not roll up to root_hash

local valid = cartesi.tojson(proof, -1, "Proof")
local bad, n = valid:gsub('"target_address":%s*0([,}])', '"target_address":18446744073709551615%1')
assert(n == 1, "could not rewrite target_address")

local function write(name, data)
    local f = assert(io.open(name, "wb"))
    assert(f:write(data))
    assert(f:close())
end
write("valid.json", valid .. "\n")
write("bad.json", bad .. "\n")

-- RV64 machine code, loaded at the start of RAM (0x80000000):
--   lui  t0, 0x40008        # t0 = HTIF tohost (0x40008000)
--   lui  t1, 0x2010         # t1 = 0x02010000: dev 2 (yield), cmd 1 (manual)
--   addi t1, t1, 1          #      reason 1 (rx-accepted)
--   slli t1, t1, 32         # t1 = 0x0201000100000000
--   sd   t1, 0(t0)          # yield
--   j    .
write("yield.bin", string.pack("<I4I4I4I4I4I4", 0x400082b7, 0x02010337, 0x00130313, 0x02031313, 0x0062b023, 0x0000006f))
