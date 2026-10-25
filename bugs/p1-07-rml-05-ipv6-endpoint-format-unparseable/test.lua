-- Proof for rml-05: IPv6 endpoints in the format the server itself reports ("[::1]:N")
-- or the format its --help documents ("<ipv6-address>:<port>") cannot be parsed by
-- the jsonrpc client (parse_endpoint / address_to_endpoint) nor by the server
-- (address_to_endpoint used by --server-address and rebind).
-- The test distinguishes *parse* errors (the bug) from socket errors (expected on a
-- host without IPv6, like this sandbox: EAFNOSUPPORT / connection refused).
local jsonrpc = require("cartesi.jsonrpc")
local dir = arg[0]:match("(.*/)") or "./"

local bugs = 0
local function bug(msg) bugs = bugs + 1; print("BUG: " .. msg) end
local function is_parse_err(e)
    e = tostring(e)
    return e:find("failed to parse endpoint", 1, true) or e:find("invalid endpoint address", 1, true)
end

-- 0. What the server's endpoint_to_string() produces for an IPv6 endpoint (boost operator<<)
-- fmt.cpp is compiled on the fly into a temporary file (needs g++ and the Boost headers;
-- CXX and BOOST_INC can override the compiler and an extra include dir).
local reported
do
    local exe = os.tmpname()
    local cxx = os.getenv("CXX") or "g++"
    local inc = os.getenv("BOOST_INC")
    local cmd = string.format("%s -std=c++20 %s -I third-party -I %sthird-party '%sfmt.cpp' -o '%s' 2>&1",
        cxx, inc and ("-I '" .. inc .. "'") or "", dir .. "../../", dir, exe)
    local p = io.popen(cmd); local cout = p:read("a"); local cok = p:close()
    if cok then
        local f = assert(io.popen("'" .. exe .. "'"))
        reported = f:read("l"); f:close()
    else
        print("note: could not compile fmt.cpp (" .. cout:gsub("\n", " ") .. "); using boost's documented IPv6 format")
        reported = "[::1]:41234"
    end
    os.remove(exe)
end
print("server/client endpoint_to_string(::1, 41234) = " .. tostring(reported))

-- 1. Client cannot parse the address string the server reports (fork result / rebind result / spawn address)
for _, addr in ipairs({ reported, "::1:41234" }) do
    local ok, err = pcall(jsonrpc.connect_server, addr, 1000)
    print(string.format("connect_server(%q) -> %s %s", addr, tostring(ok), tostring(err)))
    if not ok and is_parse_err(err) then
        bug("client parse_endpoint rejects IPv6 address " .. addr .. " (" .. err .. ")")
    end
end

-- 2. spawn_server with the bracketed form fails in the client's address_to_endpoint before any socket is created
do
    local ok, err = pcall(jsonrpc.spawn_server, "[::1]:0", 3000)
    print(string.format("spawn_server(\"[::1]:0\") -> %s %s", tostring(ok), tostring(err)))
    if ok then err:shutdown_server() end
    if not ok and is_parse_err(err) then bug("spawn_server rejects bracketed IPv6 address (" .. err .. ")") end
end

-- 3. Server-side: rebind to the bracketed form (the format get_server_address returns for IPv6) is rejected
do
    local m, addr = jsonrpc.spawn_server("127.0.0.1:0", 3000)
    print("spawned IPv4 server at " .. addr)
    local ok, err = pcall(m.rebind_server, m, "[::1]:0")
    print(string.format("rebind_server(\"[::1]:0\") -> %s %s", tostring(ok), tostring(err)))
    if not ok and is_parse_err(err) then bug("server rebind rejects bracketed IPv6 address (" .. err .. ")") end
    pcall(m.shutdown_server, m)
end

-- 4. Server-side --server-address with the bracketed form
do
    local p = assert(io.popen("timeout 5 cartesi-jsonrpc-machine --server-address='[::1]:0' 2>&1"))
    local out = p:read("a"); p:close()
    print("cartesi-jsonrpc-machine --server-address=[::1]:0 -> " .. out:gsub("\n", " | "))
    if is_parse_err(out) then bug("server --server-address rejects bracketed IPv6 address") end
end

if bugs > 0 then
    print(string.format("%d IPv6 endpoint parsing defects found", bugs))
    os.exit(1)
end
print("OK: IPv6 endpoints parse (only socket-level errors, if any)")
os.exit(0)
