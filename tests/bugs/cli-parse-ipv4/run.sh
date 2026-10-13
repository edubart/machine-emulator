#!/bin/sh
# cartesi-machine parse_ipv4 shifts the second octet by 18 bits instead of 16 (wrong port-forward IP addresses)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/cartesi-machine.lua parse_ipv4() computes (a << 24) | (b << 18) | (c << 8) | d, so any address whose second
# octet is not 0 is mangled (127.1.2.3 -> 127.4.2.3). Both --port-forward=host_address:IP:PORT and -p=IP:PORT:PORT
# go through it. We create a tiny machine (no kernel, 64 KiB RAM) with two port forwards and read the host_ip values
# back from the stored effective config. Host port 0 lets the kernel pick a free port; the second octets are small
# enough that the mangled addresses stay inside 127.0.0.0/8, so the bind succeeds with and without the bug.
cd "$WORK_DIR"
"$LUA" "$SRC_DIR/cartesi-machine.lua" --no-ram-image --no-root-flash-drive --ram-length=64Ki --network \
    --port-forward=host_address:127.1.2.3:0,guest_address:10.0.2.15:80 -p=127.3.0.1:0:81/udp \
    --store-config=cfg.json --max-mcycle=0 >cm.txt 2>&1 || { cat cm.txt; echo "cartesi-machine failed"; exit 2; }
rc=0
"$LUA" - <<'EOF' || rc=$?
local cartesi = require("cartesi")
local f = assert(io.open("cfg.json"))
local cfg = cartesi.fromjson(f:read("a"))
f:close()
local expected = { "127.1.2.3", "127.3.0.1" } -- in command-line order
local function fmt(ip) return string.format("%d.%d.%d.%d", (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255) end
for _, dev in ipairs(cfg.virtio or {}) do
    if dev.type == "net-user" then
        local fwd = dev.hostfwd or {}
        if #fwd ~= #expected then print("unexpected number of port forwards: " .. #fwd) os.exit(2) end
        local wrong = 0
        for i, h in ipairs(fwd) do
            local got = fmt(h.host_ip)
            print(string.format("port forward %d: requested host_ip %s, configured host_ip %s (0x%08x)", i, expected[i], got, h.host_ip))
            if got ~= expected[i] then wrong = wrong + 1 end
        end
        os.exit(wrong > 0 and 1 or 0)
    end
end
print("no net-user device in the stored config")
os.exit(2)
EOF
case $rc in
    0) echo "OK: port-forward IPv4 addresses are parsed correctly"; exit 0;;
    1) echo "BUG REPRODUCED: port-forward IPv4 addresses with a non-zero second octet are mangled by parse_ipv4"; exit 1;;
    *) echo "checker failed"; exit 2;;
esac
