-- Instrumented launcher for the real cartesi-machine.lua CLI.
-- Usage: lua5.4 wrapper.lua <report-file> <cli-path> <cli args...>
local report_file, cli = arg[1], arg[2]
local cartesi = require("cartesi")
local mt = debug.getmetatable(cartesi.new())
local idx = mt.__index
assert(type(idx) == "table")
local stats = { loads = 0, clearing_loads = 0, creates = 0, clearing_creates = 0, root_hash_calls = 0, page_changes = 0 }
local orig_load, orig_create, orig_grh = idx.load, idx.create, idx.get_root_hash
idx.load = function(self, dir, runtime, ...)
    stats.loads = stats.loads + 1
    if runtime and runtime.clear_hash_tree then stats.clearing_loads = stats.clearing_loads + 1 end
    return orig_load(self, dir, runtime, ...)
end
idx.create = function(self, config, runtime, ...)
    stats.creates = stats.creates + 1
    if runtime and runtime.clear_hash_tree then stats.clearing_creates = stats.clearing_creates + 1 end
    return orig_create(self, config, runtime, ...)
end
idx.get_root_hash = function(self, ...)
    local r = orig_grh(self, ...)
    stats.root_hash_calls = stats.root_hash_calls + 1
    local s = self:get_hash_tree_stats(true)
    stats.page_changes = stats.page_changes + (s.phtc and s.phtc.page_changes or 0)
    return r
end
local function dump()
    local f = assert(io.open(report_file, "w"))
    for k, v in pairs(stats) do f:write(k, "=", tostring(v), "\n") end
    f:close()
end
local real_exit = os.exit
os.exit = function(...) dump() return real_exit(...) end
local newarg = { [0] = cli, [-1] = arg[-1] }
for i = 3, #arg do newarg[#newarg + 1] = arg[i] end
arg = newarg
local ok, err = pcall(dofile, cli)
dump()
if not ok then
    -- os.exit inside the CLI never reaches here; rethrow real errors
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
