-- Kill-based repro: SIGKILL a process while get_root_hash() runs on a SHARING_ALL machine,
-- then try to reload the stored directory with {clear_hash_tree=true}.
local cartesi = require"cartesi"
local here = arg[0]:match("(.*/)") or "./"
local work = here .. "tmpkill"
local MiB = tonumber(arg[1] or "512")
os.execute("rm -rf " .. work .. " && mkdir -p " .. work)
do local m <close> = cartesi.new():create({ ram = { length = MiB << 20 } }); m:get_root_hash(); m:store(work .. "/orig") end
local bugs = 0
for _, delay in ipairs({ 0.02, 0.05, 0.1, 0.15, 0.2, 0.3 }) do
    local d = work .. "/d" .. delay
    os.execute("cp -a " .. work .. "/orig " .. d)
    -- start child, wait until it reports it is hashing, sleep `delay`, SIGKILL it, wait for it to die
    os.execute(string.format([[bash -c 'coproc C { exec lua5.4 %skill_child.lua %s %d 2>&1; }; pid=$C_PID; read -r -u ${C[0]} line; sleep %s; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; while kill -0 $pid 2>/dev/null; do sleep 0.01; done' ]],
        here, d, MiB, delay))
    local ok, err = pcall(function() local m <close> = cartesi.new():load(d, { clear_hash_tree = true }, cartesi.SHARING_ALL) end)
    print(string.format("kill %.2fs into get_root_hash -> reload(clear_hash_tree=true, SHARING_ALL): %s", delay, ok and "ok" or err))
    if not ok and tostring(err):find("borrowed entry") then bugs = bugs + 1 end
end
os.execute("rm -rf " .. work)
if bugs > 0 then print("BUG: " .. bugs .. " killed machines became unloadable ('borrowed entry') even with clear_hash_tree=true"); os.exit(1) end
print("OK")
