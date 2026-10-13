-- Runs a bare-metal RISC-V RAM image (linked at 0x80000000, 4 MiB RAM) on the interpreter until it halts,
-- then prints "exit=<HTIF exit code>" followed by a0..a3.
-- Usage: lua5.4 run.lua prog.bin
local cartesi = require("cartesi")
local machine = cartesi.machine({ ram = { length = 4 << 20, backing_store = { data_filename = assert(arg[1]) } } })
machine:run(1000000)
if machine:read_reg("iflags_H") == 0 then
    io.stderr:write("program did not halt\n")
    os.exit(2)
end
print(
    string.format(
        "exit=%d a0=0x%x a1=0x%x a2=0x%x a3=0x%x mcycle=%d",
        machine:read_reg("htif_tohost_data") >> 1,
        machine:read_reg("x10"),
        machine:read_reg("x11"),
        machine:read_reg("x12"),
        machine:read_reg("x13"),
        machine:read_reg("mcycle")
    )
)
