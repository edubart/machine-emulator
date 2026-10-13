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

-- Independent executable release review: cache eviction, persistence and clone.
local c=require('cartesi')
local f=require('cartesi.filesystem')
local tu=require('cartesi.tests.util')
local RAM=0x80000000
local function eq(a,b,label) assert(a==b,label) end
local checks=0
for _,fn in ipairs({'keccak256','sha256'}) do
    for _,capacity in ipairs({1,2,3,16}) do
        local paths={}
        local scope <close> = tu.scope_exit(function()
            for _,path in ipairs(paths) do c.machine:remove_stored(path) end
        end)
        local m <close> = c.machine({ram={length=0x10000},hash_tree={phtc_size=capacity,hash_function=fn}},
            {concurrency={update_hash_tree=1}})
        local oracle <close> = c.machine({ram={length=0x10000},hash_tree={phtc_size=32,hash_function=fn}},
            {concurrency={update_hash_tree=1}})
        for round=1,3 do
            for page=0,15 do
                local bytes=string.rep(string.char((page+round*17)%256),4096)
                m:write_memory(RAM+page*4096,bytes)
                oracle:write_memory(RAM+page*4096,bytes)
                eq(m:get_root_hash(),oracle:get_root_hash(),'cache eviction root')
                checks=checks+1
            end
            local stored=f.temp_pathname()
            m:store(stored)
            paths[#paths+1]=stored
            local loaded <close> = c.machine(stored,{concurrency={update_hash_tree=1}},c.SHARING_NONE)
            eq(loaded:get_root_hash(),oracle:get_root_hash(),'loaded root')
            for page=15,0,-1 do
                eq(loaded:get_node_hash(RAM+page*4096,12),oracle:get_node_hash(RAM+page*4096,12),'loaded page root')
                eq(loaded:get_root_hash(),oracle:get_root_hash(),'loaded eviction root')
                checks=checks+1
            end
            local clone_path=f.temp_pathname()
            c.machine:clone_stored(stored,clone_path)
            paths[#paths+1]=clone_path
            local clone <close> = c.machine(clone_path,{concurrency={update_hash_tree=1}},c.SHARING_NONE)
            eq(clone:get_root_hash(),oracle:get_root_hash(),'cloned root')
            local changed='post reload write '..round
            loaded:write_memory(RAM+4096,changed)
            oracle:write_memory(RAM+4096,changed)
            m:write_memory(RAM+4096,changed)
            eq(loaded:get_root_hash(),oracle:get_root_hash(),'loaded update root')
            eq(m:get_root_hash(),oracle:get_root_hash(),'original update root')
            checks=checks+3
        end
    end
end
print(('PASS: %d cache eviction/persistence checks across two hash functions and capacities 1,2,3,16'):format(checks))
