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

local cartesi=require('cartesi')
local ht=require('cartesi.hash-tree')
math.randomseed(120260)
local checks=0
for _,hash_type in ipairs({'keccak256','sha256'}) do
    local hash=cartesi[hash_type]
    for trial=1,120 do
        local height=math.random(59,62)
        local capacity=1<<height
        local prefix={}
        for i=1,math.random(0,48) do prefix[i]=hash(string.pack('<I8I8',trial,i)) end
        local pad=hash('padding-'..trial)
        local repeated={[0]=pad}
        for h=1,height do repeated[h]=hash(repeated[h-1],repeated[h-1]) end
        local cache={}
        local function reference(position,h)
            if position>=#prefix then return repeated[h] end
            local key=position..'/'..h
            if cache[key] then return cache[key] end
            local answer
            if h==0 then answer=prefix[position+1]
            else answer=hash(reference(position,h-1),reference(position+(1<<(h-1)),h-1)) end
            cache[key]=answer
            return answer
        end
        local forest=ht.frontier_forest(height,hash_type)
        local i=1
        while i<=#prefix do
            local next_i=math.min(i+math.random(1,9),#prefix+1)
            ht.frontier_forest_append(forest,prefix,i,next_i)
            i=next_i
        end
        ht.frontier_forest_pad_back(forest,pad)
        assert(ht.frontier_forest_get_leaf_count(forest)==capacity)
        local root=reference(0,height)
        assert(ht.frontier_forest_get_root_hash(forest)==root)
        local positions={0,1,#prefix, math.max(0,#prefix-1), (1<<(height-1))-1, 1<<(height-1),capacity-2,capacity-1}
        for _,position in ipairs(positions) do
            for h=0,height do
                local node_position=position & ~((1<<h)-1)
                assert(ht.frontier_forest_get_node_hash(forest,node_position,h)==reference(node_position,h))
                local siblings=assert(ht.frontier_forest_get_siblings(forest,node_position,h))
                assert(#siblings==height-h)
                local rolling=reference(node_position,h)
                local index=node_position>>h
                for k,sibling in ipairs(siblings) do
                    assert(sibling==reference((index~1)<<(h+k-1),h+k-1))
                    rolling=(index&1)==0 and hash(rolling,sibling) or hash(sibling,rolling)
                    index=index>>1
                    checks=checks+1
                end
                assert(rolling==root)
                checks=checks+2
            end
        end
    end
end
print('PASS high forest boundary: '..checks..' assertions')
