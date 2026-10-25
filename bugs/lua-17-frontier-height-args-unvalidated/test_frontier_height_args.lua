-- Proof: frontier functions accept subtree heights beyond the tree height.
-- Run from the repo root: eval $(make -s env); lua5.4 bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua
-- Exits 1 with BUG: lines while the bug is present; prints OK once the frontier functions validate their arguments.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local bugs = 0
local function bug(msg) bugs = bugs + 1; print("BUG: " .. msg) end
local x = cartesi.keccak256("x")
local p = cartesi.keccak256("p")

-- 1. push_back with height 5 on a height-3 tree
local f = ht.frontier(3, "keccak256")
local ok, err = pcall(ht.frontier_push_back, f, x, 5)
print("push_back(f,x,5) ok=", ok, err, "#f=", #f)
if ok then
  if #f ~= 4 then bug("frontier_push_back with height 5 > log2_max_leaves 3 grew frontier from 4 to " .. #f .. " levels") end
  local r = ht.frontier_get_root_hash(f)
  if r == x then bug("after that, frontier_get_root_hash returns the pushed hash x as the root of the height-3 tree") end
  local ok2, n = pcall(ht.frontier_get_leaf_count, f)
  print("leaf count after:", ok2, n)
end

-- 2. append with height 4 on a height-3 tree
local g = ht.frontier(3, "keccak256")
ok, err = pcall(ht.frontier_append, g, { x }, 1, 2, 4)
print("append({x},1,2,4) ok=", ok, err, "#g=", #g)
if ok and #g ~= 4 then bug("frontier_append with height 4 > log2_max_leaves 3 grew frontier to " .. #g .. " levels") end

-- 3. get_root_hash with pad_height 6 on empty height-3 tree
local e = ht.frontier(3, "keccak256")
ok, err = pcall(ht.frontier_get_root_hash, e, p, 6)
print("get_root_hash(empty L=3, p, 6) ok=", ok, ok and cartesi.tohex(err) or err)
if ok and err == p then bug("frontier_get_root_hash with pad_height 6 > 3 returns the pad itself as the height-3 root") end

-- 4. frontier with a non-hash cartesi field as hash_type
ok, err = pcall(ht.frontier, 3, "tohex")
print("frontier(3,'tohex') ok=", ok)
if ok then
  local h = ok and err
  local ok3, e3 = pcall(ht.frontier_push_back, h, x)
  local ok4, e4 = pcall(ht.frontier_push_back, h, x)
  print("push twice with tohex hash fn:", ok3, ok4, e4)
  bug("frontier accepts hash_type 'tohex' (not a hash function)")
end

-- 5. corrupted frontier from (1) cannot round-trip through store/load

local path = os.tmpname()
local f2 = ht.frontier(3, "keccak256")
pcall(ht.frontier_push_back, f2, x, 5)
local oks, es = pcall(ht.frontier_store, f2, path)
print("store corrupted:", oks, es)
if oks then
  local okl, el = pcall(ht.frontier_load, path, 3, "keccak256")
  print("load corrupted with L=3:", okl, el)
  if not okl then bug("stored frontier cannot be reloaded with its original height (" .. tostring(el) .. ")") end
end
os.remove(path)

if bugs > 0 then os.exit(1) end
print("OK: frontier rejects out-of-range heights and hash types")
