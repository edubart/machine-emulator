-- Regression test: cartesi-machine --cmio-inspect-state silently ignores a query larger than the rx buffer.
--
-- load_cmio_query() in src/cartesi-machine.lua sends the query with send_cmio_response, which is now a
-- silent no-op for data that does not fit the rx buffer (it used to fail with "CMIO response data is
-- too large"). load_cmio_input() got a warning for this case, load_cmio_query() did not. The CLI then
-- "runs" the query, which stops immediately at the previous rx-accepted yield, prints that old yield as
-- the result and exits 0 with no diagnostic: the guest never sees the query.
--
-- Run (after sourcing bugs/env/env.sh): lua5.4 <this dir>/oversized-inspect-query.lua
-- Prints "BUG REPRODUCED" and exits 1 on the buggy behaviour, "OK" and exits 0 when fixed
-- (the CLI fails or prints a diagnostic about the oversized query).
local cartesi = require("cartesi")
local util = require("cartesi.util")

local cli = assert(os.getenv("CM_CLI"), "CM_CLI not set (source bugs/env/env.sh)")
local guest = assert(os.getenv("CARTESI_TESTS_PATH"), "CARTESI_TESTS_PATH not set") .. "/computation_hash.bin"

local dir = os.tmpname()
os.remove(dir)
assert(os.execute("mkdir -p " .. dir))

local function sh(cmd)
    local p = assert(io.popen(cmd .. " 2>&1; echo \"EXIT:$?\""))
    local out = p:read("a")
    p:close()
    return out, tonumber(out:match("EXIT:(%d+)%s*$"))
end

-- Template machine stored at the guest's initial rx-accepted yield
local mcycle
do
    local m <close> = cartesi.machine({
        processor = { registers = { pc = 0x80000000 } },
        ram = { length = 1 << 20, backing_store = { data_filename = guest } },
        cmio = { rx_buffer = {}, tx_buffer = {} },
    })
    assert(m:run(math.maxinteger) == cartesi.BREAK_REASON_YIELDED_MANUALLY)
    mcycle = m:read_reg("mcycle")
    m:store(dir .. "/tpl")
end

-- computation_hash.bin command: emit 2 tx-outputs, then accept at a terminal mcycle
local query = string.pack("<c4BBI2I8I8", "CHT1", 0, 2, 0, mcycle + 600, 0)
local rx_buffer_length = 1 << cartesi.AR_CMIO_RX_BUFFER_LOG2_SIZE
util.write_file(query, dir .. "/q-ok.bin")
util.write_file(query .. string.rep("x", rx_buffer_length), dir .. "/q-big.bin")

local function inspect(q)
    return sh("cd " .. dir .. " && timeout 60 lua5.4 " .. cli .. " --load=tpl --remote-spawn --remote-address=127.0.0.1:0 --remote-shutdown"
        .. " --cmio-inspect-state=query:" .. q)
end
local ok_out, ok_code = inspect("q-ok.bin")
local big_out, big_code = inspect("q-big.bin")
os.execute("rm -rf " .. dir)

print("--- valid query, exit " .. tostring(ok_code) .. "\n" .. ok_out)
print("--- oversized query, exit " .. tostring(big_code) .. "\n" .. big_out)
-- control: a valid query reaches the guest, which emits tx-outputs
assert(ok_code == 0 and ok_out:find("Automatic yield tx%-output"), "valid query did not run as expected")
local big_ran = big_out:find("Automatic yield tx%-output") ~= nil
local diagnosed = big_out:lower():find("exceed") or big_out:lower():find("too large")
if big_code == 0 and not big_ran and not diagnosed then
    print("BUG REPRODUCED: oversized inspect query silently ignored (exit 0, no diagnostic, guest never ran)")
    os.exit(1, true)
end
print("OK")
os.exit(0, true)
