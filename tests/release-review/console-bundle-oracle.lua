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

-- Independent executable release review: buffered console/automatic-yield boundaries.
local c = require('cartesi')
local RAM = 0x80000000
local cases = 0
local function eq(a,b,label) assert(a==b,label) end
local function uless(a,b) return (a ~ math.mininteger) < (b ~ math.mininteger) end
local function satadd(a,b)
    local n=a+b
    return uless(n,a) and -1 or n
end
local function make(start,budget,mode)
    local m=c.machine({ram={length=4096},processor={pc=RAM},hash_tree={phtc_size=16}},
        {console={output_destination='to_buffer',output_buffer_size=2,output_flush_mode=mode},
            concurrency={update_hash_tree=1}})
    -- console store; addi x1,x1,1; automatic yield; addi x2,x2,3; jal -16.
    m:write_memory(RAM,string.pack('<I4I4I4I4I4',0x00b53023,0x00108093,0x00c53023,0x00310113,0xff1ff06f))
    m:write_reg('x10',0x40008000)
    m:write_reg('x11',(1<<56)|(1<<48)|65)
    m:write_reg('x12',(2<<56)|(2<<32))
    m:write_reg('htif_iconsole',2)
    m:write_reg('htif_iyield',3)
    m:write_reg('mcycle',start)
    m:write_reg('imcyclemax',budget)
    return m
end
local function fixed(m)
    return m:read_reg('iflags_H')~=0 or m:read_reg('iflags_Y')~=0
        or not uless(m:read_reg('mcycle'),m:read_reg('imcyclemax'))
end
local function runto(m,target)
    for _=1,10000 do
        local br=m:run(target)
        -- Consumers resume ordinary run after taking buffered console output.
        m:read_console_output()
        if fixed(m) or br==c.BREAK_REASON_REACHED_TARGET_MCYCLE then return end
    end
    error('reference execution did not terminate')
end
for _,mode in ipairs({'when_full','every_char','every_line'}) do
    for _,point in ipairs({{0,1},{0,5},{0,13},{0,130},{-3,-1},{-1,-1}}) do
        for _,offset in ipairs({0,3}) do
            for _,shape in ipairs({{0,3},{5,1}}) do
                local lp,lb=shape[1],shape[2]
                    local actual <close> = make(point[1],point[2],mode)
                    local oracle <close> = make(point[1],point[2],mode)
                    local got=actual:collect_mcycle_bundle(offset,lp,lb)
                    local begin=satadd(point[1],offset*(1<<(lp+lb)))
                    runto(oracle,begin)
                    local target=begin
                    eq(#got,1<<lb,'bundle length')
                    for i=1,1<<lb do
                        target=satadd(target,1<<lp)
                        runto(oracle,target)
                        eq(got[i],oracle:get_root_hash(),'state sample '..i)
                    end
                    eq(actual:read_reg('mcycle'),oracle:read_reg('mcycle'),'final mcycle')
                    eq(actual:get_root_hash(),oracle:get_root_hash(),'final state')
                    cases=cases+1
            end
        end
    end
    print(('Completed mode %s: %d cases'):format(mode,cases))
    io.stdout:flush()
end
print(('PASS: %d buffered-console bundles match independently stepped state roots'):format(cases))
