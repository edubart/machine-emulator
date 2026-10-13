-- Tells which 4 KiB image the "data" flash drive holds at the end of the run, from its --final-proof.
-- Usage: lua5.4 which-data.lua final-proof.lua  (prints "replacement", "original" or "unknown")
local hash_tree = require("cartesi.hash-tree")
local proof = dofile(arg[1])
local function root(c) return hash_tree.get_data_root_hash(string.rep(c, 4096), 12) end
if proof.target_hash == root("B") then
    print("replacement")
elseif proof.target_hash == root("A") then
    print("original")
else
    print("unknown")
end
