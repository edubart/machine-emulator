-- Proof for: a process killed (SIGKILL/OOM/container stop) during a hash-tree update of a
-- SHARING_ALL machine corrupts the stored machine directory.
--   Case 1 (kill while a page batch is borrowed): hash_tree.phtc keeps borrowed=1 entries and the
--           directory can no longer be loaded at all, with any sharing mode, even with clear_hash_tree=true.
--   Case 2 (kill while dense-tree inner nodes are being updated): the directory loads fine but
--           get_root_hash() is silently WRONG (page leaves already updated in the .dht, the DPT bits
--           still dirty, and on reload the page-hash "unchanged" shortcut marks the pages clean
--           without bubbling the change up). Only clear_hash_tree=true gives the right hash.
--   Case 3 (no gdb needed): a single persisted borrowed flag blocks loading even with clear_hash_tree=true.
-- Kill points are hit deterministically with gdb breakpoints (falls back to a timed SIGKILL without gdb).
local cartesi = require"cartesi"
local here = arg[0]:match("^(.*)/") or "."
-- scratch directory for stored machines and marker files (system temp dir, removed at exit)
local W = assert(io.popen("mktemp -d"):read("l"))
local RAM = 64 << 20
local bug = false
local function sh(cmd) return os.execute(cmd) end
local function exists(p) local f = io.open(p, "r") if f then f:close() return true end return false end
local have_gdb = os.execute("command -v gdb >/dev/null 2>&1")

local ref = cartesi.machine({ ram = { length = RAM } })
ref:write_memory(cartesi.AR_RAM_START, string.rep("\7", RAM))
local expected = ref:get_root_hash()
ref:destroy()

local function prepare(dir)
    sh("rm -rf " .. dir .. " " .. W .. "/ready " .. W .. "/done")
    local m = cartesi.machine({ ram = { length = RAM } })
    m:store(dir, cartesi.SHARING_ALL)
    m:destroy()
end

-- runs child.lua on dir (SHARING_ALL load, write all RAM, get_root_hash) and SIGKILLs it at func/hit
local function run_and_kill(dir, func, hit, fallback_delay)
    if have_gdb then
        sh(string.format("KILL_FUNC='%s' KILL_HIT=%d KILL_READY=%s/ready timeout -s KILL 120 " ..
            "gdb -q -batch -x %s/killat.py --args lua5.4 %s/child.lua %s %s/ready %s/done 2>&1 | grep '^gdb:'",
            func, hit, W, here, here, dir, W, W))
    else
        sh(string.format("lua5.4 %s/child.lua %s %s/ready %s/done & pid=$!; " ..
            "for i in $(seq 1 600); do [ -e %s/ready ] && break; sleep 0.02; done; " ..
            "sleep %.2f; kill -9 $pid; wait $pid 2>/dev/null; true", here, dir, W, W, W, fallback_delay))
    end
    return not exists(W .. "/done")
end

local function count_borrowed(dir)
    local f = assert(io.open(dir .. "/hash_tree.phtc", "rb"))
    f:seek("set", 8 + 24) -- tag + lru header; each entry_metadata is 40 bytes (next,prev,paddr,borrowed,payload_index)
    local nb = 0
    for _ = 1, 2048 do
        local _, _, _, b = string.unpack("<I8I8I8I8I8", f:read(40))
        if b ~= 0 then nb = nb + 1 end
    end
    f:close()
    return nb
end

local function try_loads(dir)
    local failed = 0
    for _, c in ipairs({
        { "SHARING_ALL", {}, cartesi.SHARING_ALL },
        { "SHARING_NONE", {}, cartesi.SHARING_NONE },
        { "SHARING_NONE + clear_hash_tree=true", { clear_hash_tree = true }, cartesi.SHARING_NONE },
        { "SHARING_ALL + clear_hash_tree=true", { clear_hash_tree = true }, cartesi.SHARING_ALL },
    }) do
        local ok, m = pcall(cartesi.machine, dir, c[2], c[3])
        if ok then
            print(string.format("  load %-36s -> ok, root %s expected", c[1],
                m:get_root_hash() == expected and "==" or "~="))
            m:destroy()
        else
            failed = failed + 1
            print(string.format("  load %-36s -> FAILED: %s", c[1], tostring(m)))
        end
    end
    return failed
end

-- Case 1: kill while the 2nd batch of 2048 pages is borrowed
do
    local dir = W .. "/case1"
    prepare(dir)
    print("case 1: SIGKILL inside hash_tree::return_updated_dirty_pages (3rd batch borrowed, 2 batches returned)")
    if run_and_kill(dir, "cartesi::hash_tree::return_updated_dirty_pages", 3, 0.08) then
        print("  borrowed entries persisted in hash_tree.phtc: " .. count_borrowed(dir))
        if try_loads(dir) == 4 then
            print("BUG: SIGKILL during hash-tree update left borrowed entries in hash_tree.phtc; the stored " ..
                  "machine cannot be loaded with any sharing mode, even with clear_hash_tree=true")
            bug = true
        end
        -- manual repair: replace phtc by an all-zero file (uninitialized cache); without clear_hash_tree
        -- the root is still wrong (see case 2), with clear_hash_tree it is right
        sh("cd " .. dir .. " && sz=$(stat -c %s hash_tree.phtc) && rm -f hash_tree.phtc && truncate -s $sz hash_tree.phtc")
        print("  after zeroing hash_tree.phtc by hand:")
        try_loads(dir)
    else
        print("  child finished before kill; inconclusive")
    end
    sh("rm -rf " .. dir)
end

-- Case 2: kill while the dense hash trees are being updated (no borrowed entries left)
if have_gdb then
    local dir = W .. "/case2"
    prepare(dir)
    print("case 2: SIGKILL inside hash_tree::update_dense_trees (all page entries returned)")
    if run_and_kill(dir, "cartesi::hash_tree::update_dense_trees", 1, 0) then
        print("  borrowed entries persisted in hash_tree.phtc: " .. count_borrowed(dir))
        local ok, m = pcall(cartesi.machine, dir, {}, cartesi.SHARING_NONE)
        if ok then
            local root = m:get_root_hash()
            local okv, verified = pcall(m.verify_hash_tree, m)
            print(string.format("  load SHARING_NONE -> ok; root %s expected; verify_hash_tree() = %s",
                root == expected and "==" or "~=", tostring(okv and verified or verified)))
            if root ~= expected then
                print("BUG: after a SIGKILL during update_dense_trees the stored machine loads but " ..
                      "get_root_hash() silently returns a wrong root hash")
                bug = true
            end
            m:destroy()
        else
            print("  load failed: " .. tostring(m))
        end
        local m2 = cartesi.machine(dir, { clear_hash_tree = true }, cartesi.SHARING_NONE)
        print("  with clear_hash_tree=true root " .. (m2:get_root_hash() == expected and "==" or "~=") .. " expected")
        m2:destroy()
    else
        print("  child finished before kill; inconclusive")
    end
    sh("rm -rf " .. dir)
else
    print("case 2: skipped (gdb not available)")
end

-- Case 3: deterministic, no kill: a single persisted borrowed flag
do
    local dir = W .. "/case3"
    sh("rm -rf " .. dir)
    local m = cartesi.machine({ ram = { length = 0x3000 } })
    m:write_memory(cartesi.AR_RAM_START, string.rep("A", 0x1000))
    m:get_root_hash()
    m:store(dir, cartesi.SHARING_ALL)
    m:destroy()
    local f = assert(io.open(dir .. "/hash_tree.phtc", "r+b"))
    f:seek("set", 8 + 24 + 16 + 8); f:write(string.pack("<I8", 1)); f:close() -- entry 0 borrowed flag
    local ok, err = pcall(cartesi.machine, dir, { clear_hash_tree = true }, cartesi.SHARING_NONE)
    print("case 3: load with clear_hash_tree=true after persisting one borrowed flag -> " ..
        (ok and "ok" or ("FAILED: " .. tostring(err))))
    if not ok then
        print("BUG: a persisted borrowed flag makes the stored machine unloadable even with clear_hash_tree=true")
        bug = true
    else
        err:destroy()
    end
    sh("rm -rf " .. dir)
end

sh("rm -rf " .. W)
os.exit(bug and 1 or 0)
