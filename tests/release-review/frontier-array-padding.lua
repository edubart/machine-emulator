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

local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
math.randomseed(1222026)
local cases = 0
for _, hash_type in ipairs({"keccak256", "sha256"}) do
    local hash = cartesi[hash_type]
    for _, height in ipairs({0, 1, 2, 3, 4, 5, 6, 7, 8, 62, 63, 64, 72}) do
        local base_height = math.max(0, height - 8)
        local relative_height = height - base_height
        local capacity = 1 << relative_height
        for trial = 1, 60 do
            local frontier = ht.frontier(height, hash_type)
            local reference = {}
            while #reference < capacity and math.random(1, 4) ~= 1 do
                local count = math.random(1, math.min(capacity - #reference, 16))
                if math.random(1, 2) == 1 then
                    local values = { hash("ignored-before") }
                    for i = 1, count do
                        values[i + 1] = hash(string.pack("<I8I8I8", height, trial, #reference + i))
                    end
                    values[count + 2] = hash("ignored-after")
                    ht.frontier_append(frontier, values, 2, count + 2, base_height)
                    table.move(values, 2, count + 1, #reference + 1, reference)
                else
                    local pad = hash(string.pack("<I8I8I8", height, trial, #reference))
                    ht.frontier_pad_back(frontier, pad, count, base_height)
                    for _ = 1, count do reference[#reference + 1] = pad end
                end
                assert(ht.frontier_get_leaf_count(frontier, base_height) == #reference)
            end
            local pad = hash("implicit-fill")
            ht.frontier_pad_back(frontier, pad, nil, base_height)
            while #reference < capacity do reference[#reference + 1] = pad end
            while #reference > 1 do
                local parents = {}
                for i = 1, #reference, 2 do parents[#parents + 1] = hash(reference[i], reference[i + 1]) end
                reference = parents
            end
            assert(ht.frontier_get_leaf_count(frontier, base_height) == capacity)
            assert(ht.frontier_get_root_hash(frontier) == reference[1])
            -- Filling a full frontier again must preserve the cached root.
            ht.frontier_pad_back(frontier, pad, nil, base_height)
            assert(ht.frontier_get_root_hash(frontier) == reference[1])
            cases = cases + 1
        end
    end
end
print("PASS plain frontier mixed array/explicit/implicit padding: " .. cases .. " reference-root cases")
