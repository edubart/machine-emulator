-- Proof: set_runtime_config{concurrency={update_hash_tree=N}} is stored and reported back,
-- but the hash tree keeps the concurrency it was constructed with.
-- Observable: OpenMP worker threads (counted in /proc/self/task) are only spawned if the
-- hash tree actually uses concurrency > 1. Each scenario runs in its own process.
local cartesi = require("cartesi")

local function self_pid()
    -- /proc/self/stat read from inside lua refers to the lua process itself
    return tonumber(io.open("/proc/self/stat"):read("l"):match("^(%d+)"))
end

local function count_threads()
    local p = io.popen("ls /proc/" .. self_pid() .. "/task | wc -l")
    local n = tonumber(p:read("a")); p:close(); return n
end

local RAM = 64 << 20
local function workload(m)
    -- dirty every RAM page with non-zero data, then force a hash tree update
    local page = string.rep("\xa5", 4096)
    local chunk = string.rep(page, 256) -- 1 MiB
    local base = cartesi.AR_RAM_START
    for off = 0, RAM - 1, #chunk do m:write_memory(base + off, chunk) end
    return m:get_root_hash()
end

local mode = arg[1]
if mode then
    local cfg = {
        ram = { length = RAM },
        dtb = { entrypoint = "" },
        processor = { registers = { iflags = { H = 1 } } }, -- halted, no image needed
    }
    local m
    if mode == "created4" then
        m = cartesi.machine(cfg, { concurrency = { update_hash_tree = 4 } })
    else -- "set4": create with 1, then retune to 4
        m = cartesi.machine(cfg, { concurrency = { update_hash_tree = 1 } })
        local rt = m:get_runtime_config()
        rt.concurrency = { update_hash_tree = 4 }
        m:set_runtime_config(rt)
    end
    local before = count_threads()
    workload(m)
    local after = count_threads()
    io.write(string.format("%s reported=%d threads_before=%d threads_after=%d\n",
        mode, m:get_runtime_config().concurrency.update_hash_tree, before, after))
    os.exit(0)
end

local function run(mode)
    local p = io.popen("timeout 120 lua5.4 " .. arg[0] .. " " .. mode)
    local out = p:read("a"); p:close()
    io.write(out)
    local rep, b, a = out:match("reported=(%d+) threads_before=(%d+) threads_after=(%d+)")
    assert(rep, "child failed: " .. out)
    return tonumber(rep), tonumber(b), tonumber(a)
end

local _, cb, ca = run("created4")
if ca <= cb then
    print("SKIP/INCONCLUSIVE: machine created with concurrency 4 did not spawn worker threads (no OpenMP or <2 CPUs?)")
    os.exit(2)
end
local rep, sb, sa = run("set4")
if rep ~= 4 then print("unexpected: get_runtime_config did not report 4"); os.exit(3) end
if sa <= sb then
    print(string.format("BUG: set_runtime_config reports concurrency.update_hash_tree=%d, but the hash tree " ..
        "update ran single-threaded (threads %d -> %d), while a machine created with 4 spawned threads (%d -> %d)",
        rep, sb, sa, cb, ca))
    os.exit(1)
end
print("OK: set_runtime_config concurrency.update_hash_tree took effect")
os.exit(0)
