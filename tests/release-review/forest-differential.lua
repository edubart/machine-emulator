-- Copyright Cartesi and individual authors (see AUTHORS)
-- SPDX-License-Identifier: LGPL-3.0-or-later
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Lesser General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT ANY
-- WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
-- PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public License along
-- with this program (see COPYING). If not, see <https://www.gnu.org/licenses/>.
--

local cartesi = require('cartesi')
local ht = require('cartesi.hash-tree')
local seed = tonumber(arg[1]) or 8675309
local trials = tonumber(arg[2]) or 800
math.randomseed(seed)
local checks = 0
local function eq(a,b,context)
    checks = checks + 1
    assert(a == b, context)
end
local function levels(leaves, hash)
    local result = {leaves}
    while #result[#result] > 1 do
        local children, parents = result[#result], {}
        for i=1,#children,2 do parents[#parents+1] = hash(children[i], children[i+1]) end
        result[#result+1] = parents
    end
    return result
end
local function full_subtree(height, hash_type)
    local hash, leaves = cartesi[hash_type], {}
    for i=1,1<<height do leaves[i] = hash(string.pack('<I8I8', math.random(0,0x7fffffff), i)) end
    local forest=ht.frontier_forest(height,hash_type)
    ht.frontier_forest_append(forest,leaves)
    return forest, leaves, levels(leaves,hash)[height+1][1]
end
for _,hash_type in ipairs({'keccak256','sha256'}) do
    local hash=cartesi[hash_type]
    for trial=1,trials do
        local height=math.random(0,8)
        local capacity=1<<height
        local forest=ht.frontier_forest(height,hash_type)
        local reference, opacity, opaque_blocks = {}, {}, {}
        local count=0
        while count<capacity do
            local max_height=0
            while max_height<height and (count & ((1<<(max_height+1))-1))==0 and (1<<(max_height+1))<=capacity-count do
                max_height=max_height+1
            end
            local h=math.random(0,max_height)
            local max_count=(capacity-count)>>h
            local repetitions=math.random(1,math.min(max_count,9))
            local subtree, leaves, root=full_subtree(h,hash_type)
            local operation=math.random(1,5)
            local opaque=operation<=2
            local value=opaque and root or subtree
            if operation==1 or operation==3 then
                ht.frontier_forest_pad_back(forest,value,repetitions,h)
            elseif operation==2 then
                local roots={}
                for i=1,repetitions do roots[i]=root end
                ht.frontier_forest_append(forest, roots, nil, nil, h)
            elseif operation==4 then
                repetitions=1
                ht.frontier_forest_push_back(forest,value,h)
            else
                repetitions=1
                ht.frontier_forest_pad_back(forest,value,1,h)
            end
            for i=1,repetitions do
                if opaque and h>0 then opaque_blocks[#opaque_blocks+1]={position=count,height=h,subtree=subtree} end
                for _,leaf in ipairs(leaves) do
                    reference[#reference+1]=leaf
                    opacity[#opacity+1]=opaque and h or 0
                end
                count=count+(1<<h)
            end
            eq(ht.frontier_forest_get_leaf_count(forest),count,'leaf count')
        end
        local expected=levels(reference,hash)
        local context=string.format('%s seed=%d trial=%d H=%d',hash_type,seed,trial,height)
        eq(ht.frontier_forest_get_root_hash(forest), expected[height+1][1],context..' root')
        local function verify(require_exposure)
            for h=0,height do
                for position=0,capacity-1,1<<h do
                    local node,err=ht.frontier_forest_get_node_hash(forest,position,h)
                    local siblings,siblingerr=ht.frontier_forest_get_siblings(forest,position,h)
                    if node then
                        eq(node,expected[h+1][(position>>h)+1],context..' node')
                        assert(siblings,siblingerr)
                        eq(#siblings,height-h,context..' sibling count')
                        local rolling,index=node,position>>h
                        for level,sibling in ipairs(siblings) do
                            local expected_sibling=expected[h+level][(index~1)+1]
                            eq(sibling,expected_sibling,context..' sibling')
                            rolling=(index&1)==0 and hash(rolling,sibling) or hash(sibling,rolling)
                            index=index>>1
                        end
                        eq(rolling,expected[height+1][1],context..' proof root')
                    else
                        eq(err,'the node is below an opaque hash',context..' opaque error')
                        eq(siblings,nil,context..' opaque siblings')
                        eq(siblingerr,err,context..' matching opaque error')
                        if require_exposure then assert(h<opacity[position+1],context..' unexpectedly hidden') end
                    end
                    if require_exposure then eq(node~=nil,h>=opacity[position+1],context..' opacity') end
                end
            end
        end
        verify(true)
        -- Expand opaque retained hashes in a random order, including implicit repeated suffixes.
        for i=#opaque_blocks,2,-1 do
            local j=math.random(1,i)
            opaque_blocks[i],opaque_blocks[j]=opaque_blocks[j],opaque_blocks[i]
        end
        for _,block in ipairs(opaque_blocks) do
            if not ht.frontier_forest_get_node_hash(forest,block.position,block.height-1) then
                ht.frontier_forest_expand_leaf(forest,block.position,block.subtree)
                eq(ht.frontier_forest_get_root_hash(forest),expected[height+1][1],context..' expansion root')
                for p=block.position,block.position+(1<<block.height)-1 do
                    eq(ht.frontier_forest_get_node_hash(forest,p,0),reference[p+1],context..' expanded leaf')
                end
            end
        end
        verify(false)
        for p=0,capacity-1 do eq(ht.frontier_forest_get_node_hash(forest,p,0),reference[p+1],context..' final leaf') end
    end
end
print(string.format('PASS seed=%d trials=%d per hash; %d assertions',seed,trials,checks))
