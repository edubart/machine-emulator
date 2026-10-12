#!/usr/bin/env lua5.4
-- Regression test: src/cartesi/hash-tree.lua frontier API validation gaps.
-- Run (from repo root, after sourcing bugs/env/env.sh):
--   lua5.4 <path>/test-hash-tree-frontier-validation.lua
-- Each check feeds invalid input and expects an error that leaves the frontier unchanged.
-- Prints "BUG REPRODUCED" and exits 1 if any check fails, "OK" and exits 0 when all pass.
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")

local X = cartesi.keccak256("x")
local A, B = cartesi.keccak256("a"), cartesi.keccak256("b")
local H = 4
local failures = {}

local function snapshot(f)
    local s = { n = #f }
    for l = 1, #f + 4 do
        s[l] = f[l]
    end
    return s
end

local function unchanged(f, s)
    if #f ~= s.n then return false end
    for l = 1, s.n + 4 do
        if f[l] ~= s[l] then return false end
    end
    return true
end

-- Expects fn(f, ...) to raise an error and leave f unchanged.
local function expect_rejected(name, f, fn, ...)
    local s = snapshot(f)
    local ok = pcall(fn, f, ...)
    if ok then
        failures[#failures + 1] = name .. ": accepted (frontier now has " .. #f .. " levels, expected " .. s.n .. ")"
    elseif not unchanged(f, s) then
        failures[#failures + 1] = name .. ": failed but mutated the frontier"
    end
end

-- 1. Subtree / pad height above the frontier height (H).
expect_rejected("frontier_push_back(X, height=H+1)", ht.frontier(H, "keccak256"), ht.frontier_push_back, X, H + 1)
expect_rejected("frontier_append({X}, height=H+1)", ht.frontier(H, "keccak256"), ht.frontier_append, { X }, 1, 2, H + 1)
expect_rejected("frontier_pad_back(X, nil, pad_height=H+1)", ht.frontier(H, "keccak256"), ht.frontier_pad_back, X, nil,
    H + 1)
do
    local ok, root = pcall(ht.frontier_get_root_hash, ht.frontier(H, "keccak256"), X, H + 1)
    if ok then
        failures[#failures + 1] = "frontier_get_root_hash(pad=X, pad_height=H+1): accepted, returned "
            .. (root == X and "the pad itself" or "a root")
    end
end

-- 2a. frontier_append is not atomic: earlier subtrees are folded in before a bad later entry fails.
expect_rejected("frontier_append({A,B,A,B,<table>,<table>})", ht.frontier(3, "keccak256"), ht.frontier_append,
    { A, B, A, B, {}, {} })

-- 2b. Any field of the cartesi module is accepted as a hash type.
if pcall(ht.frontier, 2, "tohex") then failures[#failures + 1] = "frontier(2, \"tohex\"): accepted" end
if pcall(ht.frontier_forest, 2, "tohex") then failures[#failures + 1] = "frontier_forest(2, \"tohex\"): accepted" end

-- 3. frontier_pad_back on frontiers taller than 64 levels with a negative count (>= 2^63 unsigned).
expect_rejected("height-70 empty frontier_pad_back(count=-1)", ht.frontier(70, "keccak256"), ht.frontier_pad_back, X,
    -1)
do
    local f = ht.frontier(70, "keccak256")
    ht.frontier_push_back(f, A, 63)
    expect_rejected("height-70 frontier_pad_back(count=-1) after one 2^63 subtree", f, ht.frontier_pad_back, X, -1)
end

if #failures > 0 then
    print("BUG REPRODUCED")
    for _, msg in ipairs(failures) do
        print("  " .. msg)
    end
    os.exit(1, true)
end
print("OK")
os.exit(0, true)
