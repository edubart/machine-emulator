-- Drives cartesi.gdbstub over a real loopback TCP connection, acting as the GDB client, and checks the replies to
-- 'M' (write memory) packets. Exit 1 if a reply is wrong, 0 if both are right, 2 on a test failure.
local cartesi = require("cartesi")
local GDBStub = require("cartesi.gdbstub")
local socket = require("socket")

local function packet(data)
    local sum = 0
    for i = 1, #data do
        sum = sum + data:byte(i)
    end
    return string.format("$%s#%02x", data, sum % 256)
end

local machine = cartesi.machine({ ram = { length = 0x10000 } })
local stub = GDBStub.new(machine)

-- Listening socket on a kernel-chosen port; the stub takes ownership of its descriptor.
local server = assert(socket.tcp())
assert(server:bind("127.0.0.1", 0))
assert(server:listen(1))
local _, port = assert(server:getsockname())
local fd = server:getfd()
server:setfd(-1) -- ownership moves to the stub, do not close it here

-- The connection completes in the listen backlog, so the whole GDB session can be queued up front:
-- '+' (session start), then each packet followed by the '+' that acknowledges the stub's reply.
local client = assert(socket.connect("127.0.0.1", port))
assert(client:settimeout(10))
assert(client:send(table.concat({
    "+",
    packet("M80000000,4:efbeadde") .. "+", -- write 4 bytes to RAM (M-mode, bare satp: virtual == physical)
    packet("M10000000,4:00000000") .. "+", -- write 4 bytes to an unmapped address
    packet("D") .. "+", -- detach
})))

stub:wait_gdb_fd(fd)
stub:run(0) -- handles the queued packets until the detach; the machine itself does not advance

local stream = assert(client:receive("*a"))
client:close()
local replies = {}
for data in stream:gmatch("%$([^#]*)#%x%x") do
    replies[#replies + 1] = data
end
if #replies ~= 3 then
    print(string.format("unexpected reply stream %q", stream))
    os.exit(2)
end

local word = machine:read_memory(0x80000000, 4)
local ok_unmapped = pcall(machine.write_virtual_memory, machine, 0x10000000, "\0\0\0\0")
if word ~= "\xef\xbe\xad\xde" or ok_unmapped then
    print("unexpected machine state: the RAM write did not land or the unmapped write succeeded")
    os.exit(2)
end
print(string.format("M80000000,4 (valid RAM, memory now %s) -> reply %q (expected \"OK\")", cartesi.tohex(word), replies[1]))
print(string.format("M10000000,4 (unmapped address, write fails) -> reply %q (expected an \"Exx\" error)", replies[2]))
local bad = replies[1] ~= "OK" or not replies[2]:match("^E%x%x$")
os.exit(bad and 1 or 0)
