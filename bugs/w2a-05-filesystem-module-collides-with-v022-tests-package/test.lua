#!/usr/bin/env lua5.4
-- Proof: the branch ships src/cartesi/filesystem.lua as module cartesi.filesystem in the emulator
-- package, at the same install path as the v0.22 tests package's tests/lua/cartesi/filesystem.lua.
--  Part A: real dpkg upgrade (emulator 0.22 + tests 0.22 installed, then emulator 0.23 from this branch)
--          into a private dpkg root. Fails with a file conflict if the paths collide and no
--          Replaces/Breaks is declared.
--  Part B: source/overlay install (make install of this branch, then v0.22 make install-tests, which
--          copies tests/lua/cartesi over $(LUA_INSTALL_PATH)) and run the shipped CLI and hash-tree.
-- Exits non-zero with BUG: lines when the defect is present.

-- Run from the repository root. REPO may be overridden with the REPO environment variable.
local function trim(s) return (s:gsub("%s+$", "")) end
local REPO = os.getenv("REPO")
if not REPO then
    local p = assert(io.popen("git rev-parse --show-toplevel 2>/dev/null || pwd"))
    REPO = trim(p:read("a"))
    p:close()
end
local V022 = "f9e4f82003a6f5acc9821c06f8a29025e0f895e3" -- v0.22.0
-- Scratch directory (removed and recreated). Override with WORK; defaults to a fresh mktemp dir.
local WORK = os.getenv("WORK")
if not WORK then
    local p = assert(io.popen("mktemp -d -t w2a-05-fs-collision.XXXXXX"))
    WORK = trim(p:read("a"))
    p:close()
end
local LUADIR = "usr/share/lua/5.4"

local bugs = 0
local function bug(msg)
    bugs = bugs + 1
    print("BUG: " .. msg)
end

local function sh(cmd)
    local p = assert(io.popen("(" .. cmd .. ") 2>&1; echo \"__rc=$?\""))
    local out = p:read("a")
    p:close()
    local rc = tonumber(out:match("__rc=(%d+)%s*$"))
    return rc, (out:gsub("__rc=%d+%s*$", ""))
end
local function must(cmd)
    local rc, out = sh(cmd)
    if rc ~= 0 then error("command failed: " .. cmd .. "\n" .. out) end
    return out
end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

must("rm -rf " .. q(WORK) .. " && mkdir -p " .. q(WORK))
-- v0.22 tests Lua tree and v0.22 Makefile/control templates (read-only git ops)
must("mkdir -p " .. q(WORK .. "/v022") .. " && cd " .. q(REPO) .. " && git archive " .. V022
    .. " tests/lua/cartesi tools/template Makefile | tar -x -C " .. q(WORK .. "/v022"))

-- Emulator Lua module list, from each Makefile's EMU_TO_LUA_PATH
local function emu_lua_files(makefile)
    local f = assert(io.open(makefile))
    local s = f:read("a")
    f:close()
    local line = assert(s:match("\nEMU_TO_LUA_PATH=([^\n]*)"))
    local t = {}
    for w in line:gmatch("%S+") do t[#t + 1] = w end
    return t
end
local branch_files = emu_lua_files(REPO .. "/Makefile")
local v022_files = emu_lua_files(WORK .. "/v022/Makefile")

------------------------------------------------------------------------------------------------
-- Part A: dpkg
------------------------------------------------------------------------------------------------
local function control(template, version)
    local f = assert(io.open(template))
    local s = f:read("a")
    f:close()
    return (s:gsub("ARG_VERSION", version):gsub("ARG_ARCH", "all"))
end
local function build_deb(name, ctl, populate)
    local root = WORK .. "/deb-" .. name
    must("mkdir -p " .. q(root .. "/DEBIAN") .. " " .. q(root .. "/" .. LUADIR .. "/cartesi"))
    local f = assert(io.open(root .. "/DEBIAN/control", "w"))
    f:write(ctl)
    f:close()
    populate(root)
    must("dpkg-deb -Znone --root-owner-group --build " .. q(root) .. " " .. q(WORK .. "/" .. name .. ".deb"))
    return WORK .. "/" .. name .. ".deb"
end

local emu022 = build_deb("emu-0.22.0", control(WORK .. "/v022/tools/template/control.template", "0.22.0"),
    function(root)
        for _, p in ipairs(v022_files) do
            must("cd " .. q(REPO) .. " && git show " .. V022 .. ":" .. p .. " > "
                .. q(root .. "/" .. LUADIR .. "/cartesi/" .. p:match("[^/]*$")))
        end
    end)
local tests022 = build_deb("tests-0.22.0",
    control(WORK .. "/v022/tools/template/tests-control.template", "0.22.0"), function(root)
        -- same as v0.22 install-tests: cp -RP tests/lua/cartesi $(LUA_INSTALL_PATH)
        must("cp -RP " .. q(WORK .. "/v022/tests/lua/cartesi") .. " " .. q(root .. "/" .. LUADIR))
    end)
local emu023 = build_deb("emu-0.23.0", control(REPO .. "/tools/template/control.template", "0.23.0"),
    function(root)
        for _, p in ipairs(branch_files) do
            must("install -m0644 " .. q(REPO .. "/" .. p) .. " " .. q(root .. "/" .. LUADIR .. "/cartesi"))
        end
    end)

local droot = WORK .. "/dpkgroot"
must("mkdir -p " .. q(droot .. "/var/lib/dpkg/info") .. " " .. q(droot .. "/var/lib/dpkg/updates")
    .. " " .. q(droot .. "/var/lib/dpkg/triggers") .. " && touch " .. q(droot .. "/var/lib/dpkg/status")
    .. " " .. q(droot .. "/var/lib/dpkg/available"))
-- external deps (lua5.4, libslirp0, ...) are not present in the private root; ignore only those
local DPKG = "timeout 60 dpkg --root=" .. q(droot) .. " --force-depends --force-not-root --force-script-chrootless"
    .. " --log=/dev/null -i "
must(DPKG .. q(emu022))
must(DPKG .. q(tests022))
local rc, out = sh(DPKG .. q(emu023))
io.write("[A] dpkg -i emulator 0.23 over emulator 0.22 + tests 0.22: rc=", rc, "\n")
for l in out:gmatch("[^\n]+") do
    if l:find("overwrite") or l:find("error") then print("    " .. l) end
end
if rc ~= 0 and out:find("trying to overwrite", 1, true) then
    bug("dpkg upgrade of cartesi-machine-emulator to 0.23 aborts: file conflict with installed "
        .. "cartesi-machine-tests 0.22 (no Replaces/Breaks declared)")
elseif rc ~= 0 then
    error("unexpected dpkg failure:\n" .. out)
end

------------------------------------------------------------------------------------------------
-- Part B: source install of branch emulator, then v0.22 `make install-tests` (cp -RP over it)
------------------------------------------------------------------------------------------------
local prefix = WORK .. "/prefix/" .. LUADIR
must("mkdir -p " .. q(prefix .. "/cartesi"))
for _, p in ipairs(branch_files) do -- branch install-lua-libs
    must("install -m0644 " .. q(REPO .. "/" .. p) .. " " .. q(prefix .. "/cartesi"))
end
must("mkdir -p " .. q(prefix .. "/cartesi/third-party") .. " && install -m0644 "
    .. q(REPO .. "/src/cartesi/third-party/bint.lua") .. " " .. q(prefix .. "/cartesi/third-party"))
must("cp -RP " .. q(WORK .. "/v022/tests/lua/cartesi") .. " " .. q(prefix)) -- v0.22 install-tests

local env = "LUA_PATH_5_4=" .. q(prefix .. "/?.lua;;") .. " LUA_CPATH_5_4=" .. q(REPO .. "/src/?.so;;")
    .. " LD_LIBRARY_PATH=" .. q(REPO .. "/src") .. " CARTESI_IMAGES_PATH=/usr/share/cartesi-machine/images "

-- B1: cartesi-machine --final-hash
local hashfile = WORK .. "/final-hash.bin"
rc, out = sh("cd " .. q(WORK) .. " && " .. env .. "timeout 60 lua5.4 " .. q(REPO .. "/src/cartesi-machine.lua")
    .. " --ram-length=32Mi --max-mcycle=0 --final-hash=" .. q(hashfile))
local hf = io.open(hashfile, "rb")
local content = hf and hf:read("a")
if hf then hf:close() end
io.write("[B1] cartesi-machine --final-hash rc=", rc, " hash file exists=", tostring(content ~= nil),
    " size=", tostring(content and #content), "\n")
if not (rc == 0 and content and #content == 32) then
    local stray = {}
    local p = io.popen("ls -1 " .. q(WORK))
    for name in p:lines() do
        if name ~= "v022" and not name:find("^deb%-") and not name:find("%.deb$") and name ~= "dpkgroot"
            and name ~= "prefix" then
            stray[#stray + 1] = string.format("%q", name)
        end
    end
    p:close()
    bug("cartesi-machine --final-hash did not write a 32-byte hash file (rc=" .. tostring(rc)
        .. ", file " .. (content and ("has " .. #content .. " bytes: " .. string.format("%q", content))
        or "missing") .. "); other files created in cwd: " .. table.concat(stray, ", "))
    for l in out:gmatch("[^\n]+") do
        if l:find("error") or l:find("nil") then print("    " .. l) end
    end
end

-- B2: hash-tree frontier_store
local script = WORK .. "/b2.lua"
local f = assert(io.open(script, "w"))
f:write(string.format([[
local cartesi = require("cartesi")
local ht = require("cartesi.hash-tree")
local fr = ht.frontier(4)
ht.frontier_push_back(fr, string.rep("\1", 32))
ht.frontier_store(fr, %q)
print("frontier_store ok")
]], WORK .. "/frontier.json"))
f:close()
rc, out = sh(env .. "timeout 60 lua5.4 " .. q(script))
io.write("[B2] hash-tree frontier_store rc=", rc, "\n")
if rc ~= 0 then
    bug("cartesi.hash-tree.frontier_store fails with the installed cartesi.filesystem: "
        .. (out:match("[^\n]*error[^\n]*") or out:match("[^\n]+") or ""))
end

if bugs > 0 then
    print(string.format("%d defect(s) found", bugs))
    os.exit(1)
end
print("OK: no collision/regression")
os.exit(0)
