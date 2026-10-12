-- Regression test: a GIO response with response code 0 is silently dropped, so a GIO host loops forever.
--
-- libcmt's cmt_gio_request() yields manual with reason = domain and reads the response code from the
-- fromhost reason field, i.e. the <reason> argument of send_cmio_response. Response code 0 is the
-- same value as HTIF_YIELD_REASON_ADVANCE_STATE, and the core treats every reason-0 response as an
-- advance-state input, which is a no-op unless the machine is on an rx-accepted yield. At a GIO
-- yield the response is ignored. v0.20.0 delivered it; v0.21.0 refused it with an error
-- ("machine is not waiting on an rx-accepted manual yield"); this branch reports success without
-- delivering it. The host then runs the machine, which is still yielded on the same GIO request
-- at the same mcycle, so a host that answers it again never makes progress.
--
-- Run (after sourcing bugs/env/env.sh): lua5.4 <this dir>/gio-response-code-zero.lua [local|jsonrpc]
-- Prints "BUG REPRODUCED" and exits 1 on the buggy behaviour, "OK" and exits 0 when fixed
-- (the response is either delivered or refused with an error).
local cartesi = require("cartesi")
local mode = arg[1] or "local"

local function new_machine()
    local cfg = { ram = { length = 1 << 20 }, cmio = { rx_buffer = {}, tx_buffer = {} } }
    if mode == "jsonrpc" then
        local jsonrpc = require("cartesi.jsonrpc")
        local server = assert(jsonrpc.spawn_server())
        server:set_cleanup_call(jsonrpc.SHUTDOWN)
        return server:create(cfg)
    end
    return cartesi.machine(cfg)
end

local GIO_DOMAIN = 0x10 -- any domain other than the rx-accepted/rx-rejected/tx-exception reasons
local m <close> = new_machine()
-- State of a guest that just issued a GIO request (cmt_gio_request): manual yield with reason = domain
m:write_reg("htif_tohost", cartesi.HTIF_DEV_YIELD << 56 | cartesi.HTIF_YIELD_CMD_MANUAL << 48 | GIO_DOMAIN << 32)
m:write_reg("iflags_Y", 1)

-- A typical GIO host loop: answer every GIO request with code 0 ("ok") and resume the machine
local mcycle0 = m:read_reg("mcycle")
local refused, delivered = nil, false
for iteration = 1, 3 do
    local cmd, reason = m:receive_cmio_request()
    if cmd ~= cartesi.HTIF_YIELD_CMD_MANUAL or reason ~= GIO_DOMAIN then break end
    local hash_before = m:get_root_hash()
    local ok, err = pcall(m.send_cmio_response, m, 0, "gio response data")
    if not ok then
        refused = err
        break
    end
    if m:get_root_hash() ~= hash_before then
        delivered = true
        break
    end
    local break_reason = m:run(m:read_reg("mcycle") + 1000)
    print(string.format("iteration %d: send succeeded, state unchanged, run -> %d at mcycle %d (started at %d)",
        iteration, break_reason, m:read_reg("mcycle"), mcycle0))
end

if refused then
    print("send_cmio_response refused the response: " .. tostring(refused))
    print("OK")
    os.exit(0, true)
elseif delivered then
    print(string.format("response delivered: fromhost reason=%d length=%d", m:read_reg("htif_fromhost_reason"),
        m:read_reg("htif_fromhost_data")))
    print("OK")
    os.exit(0, true)
end
print("BUG REPRODUCED: GIO response code 0 reported success but was never delivered; the host loops forever")
os.exit(1, true)
