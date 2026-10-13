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

-- Directed/randomized release review probes: no production source changes.
local c = require('cartesi')
io.stdout:setvbuf('no')
local count = 0
math.randomseed(220022)
local RAM = 0x80000000
local function fail(msg) error(msg, 0) end
local function eq(a,b,msg) if a~=b then fail(msg) end end
local function uless(a,b) return (a ~ math.mininteger) < (b ~ math.mininteger) end
local function satadd(a,b)
    local n=a+b
    return uless(n,a) and -1 or n
end
local function satmul(a,b)
    local product=0
    while b~=0 do
        if b&1~=0 then product=satadd(product,a) end
        b=b>>1
        if b~=0 then a=satadd(a,a) end
    end
    return product
end
local function addi(rd,rs,imm) return ((imm&4095)<<20)|(rs<<15)|(rd<<7)|0x13 end
local function ld(rd,rs,imm) return ((imm&4095)<<20)|(rs<<15)|(3<<12)|(rd<<7)|0x03 end
local function sd(rs,base,imm)
    return (((imm>>5)&127)<<25)|(rs<<20)|(base<<15)|(3<<12)|((imm&31)<<7)|0x23
end
local function jal(imm)
    return (((imm>>20)&1)<<31)|(((imm>>1)&1023)<<21)|(((imm>>11)&1)<<20)|(((imm>>12)&255)<<12)|0x6f
end
local function make(spec)
    local m = c.machine({ram={length=4096},processor={pc=RAM},hash_tree={hash_function=spec.hash_function or 'keccak256',phtc_size=32}}, {concurrency={update_hash_tree=1}})
    local p={}
    for i=1,12 do
        if i==3 then p[i]=sd(1,12,0)
        elseif i==7 then p[i]=ld(2,12,0)
        elseif i==(spec.stop_at or 5) and spec.mode and spec.mode~='none' then p[i]=sd(11,10,0)
        else p[i]=addi((i%8)+1,(i%8)+1,(spec.seed or 1)+i) end
    end
    p[13]=jal(-48)
    local raw={}
    for _,v in ipairs(p) do raw[#raw+1]=string.pack('<I4',v) end
    m:write_memory(RAM,table.concat(raw))
    m:write_reg('x10',0x40008000)
    m:write_reg('x12',RAM+0x800)
    m:write_reg('htif_iyield',3)
    local mode=spec.mode
    local htif=0
    if mode=='halt' then htif=1
    elseif mode=='auto' then htif=(2<<56)|(2<<32)
    elseif mode=='manual' then htif=(2<<56)|(1<<48)|(1<<32)
    elseif mode=='reject' then htif=(2<<56)|(1<<48)|(2<<32) end
    m:write_reg('x11',htif)
    if spec.start then m:write_reg('mcycle',spec.start) end
    if spec.budget then m:write_reg('imcyclemax',spec.budget) end
    if spec.fixed then
        if spec.fixed=='halt' then m:write_reg('iflags_H',1)
        elseif spec.fixed=='manual' or spec.fixed=='reject' then
            m:write_reg('iflags_Y',1)
            m:write_reg('htif_tohost_dev',2)
            m:write_reg('htif_tohost_cmd',1)
            m:write_reg('htif_tohost_reason',spec.fixed=='reject' and 2 or 1)
        end
    end
    if spec.warmup then m:run((spec.start or 0)+spec.warmup) end
    return m
end
local function fixed(m)
    return m:read_reg('iflags_H')~=0 or m:read_reg('iflags_Y')~=0 or not uless(m:read_reg('mcycle'),m:read_reg('imcyclemax'))
end
local function canonical(m)
    if m:read_reg('iflags_Y')~=0 and m:read_reg('htif_tohost_dev')==2 and m:read_reg('htif_tohost_cmd')==1 and m:read_reg('htif_tohost_reason')==2 then return m:read_revert_root_hash() end
    return m:get_root_hash()
end
local function runto(m,target)
    for _=1,10000 do
        local br=m:run(target)
        if fixed(m) or br==c.BREAK_REASON_REACHED_TARGET_MCYCLE then return end
    end
    fail('oracle exceeded run retries')
end
local function mcycle_case(spec,offset,lp,lb,label)
    local actual <close> = make(spec)
    local oracle <close> = make(spec)
    local got=actual:collect_mcycle_bundle(offset,lp,lb)
    local period,capacity=1<<lp,1<<lb
    local begin=satadd(oracle:read_reg('mcycle'),satmul(offset,1<<(lp+lb)))
    runto(oracle,begin)
    local want={}
    local target=begin
    for i=1,capacity do
        target=satadd(target,period)
        runto(oracle,target)
        want[i]=canonical(oracle)
    end
    eq(#got,#want,label..': length')
    for i=1,#got do eq(got[i],want[i],label..': hash '..i) end
    eq(actual:read_reg('mcycle'),oracle:read_reg('mcycle'),label..': mcycle')
    eq(actual:get_root_hash(),oracle:get_root_hash(),label..': final state')
    count=count+1
    if count%25==0 then print('Passed '..count..': '..label) end
end
local tail={string.rep('\0',32),string.rep('\0',32)}
-- Check the independently stepped uarch timeline rather than only comparing two
-- wrappers around the existing optimized collector.
for _,mode in ipairs({'none','auto','halt','manual','reject'}) do
    local spec={mode=mode,warmup=4}
    local actual <close> = make(spec)
    local oracle <close> = make(spec)
    local got=actual:collect_uarch_cycle_bundle(0,4,tail)
    local transient={}
    local halted=false
    for cycle=1,c.UARCH_CYCLE_MAX do
        if oracle:run_uarch(cycle)==c.UARCH_BREAK_REASON_UARCH_HALTED then halted=true; break end
        transient[#transient+1]=oracle:get_root_hash()
    end
    assert(halted,'direct uarch did not halt')
    local halt_hash=oracle:get_root_hash()
    for i=1,16 do eq(got[i],transient[i] or halt_hash,'direct uarch '..mode..' hash '..i) end
    oracle:reset_uarch()
    eq(actual:get_root_hash(),oracle:get_root_hash(),'direct uarch '..mode..' final state')
    count=count+1
end
print('Independent direct uarch cases passed: 5')
print('TOTAL passed: '..count)
