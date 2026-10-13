-- Runs pte_fault.S (linked at 0x80000000) on the interpreter with a 4 KiB read-only flash drive at
-- 0x80000000000000 whose first doubleword is a leaf megapage PTE -> RAM 0x80000000 with R|W|V and A=0, D=0.
-- Prints "exit=<HTIF exit code>" followed by the observed mcauses and the flash PTE after the accesses.
-- Usage: lua5.4 run.lua prog.bin flash.bin   (flash.bin is created by this script)
local cartesi = require("cartesi")
local bin, flash = assert(arg[1]), assert(arg[2])
local f = assert(io.open(flash, "wb"))
f:write(string.pack("<I8", ((0x80000000 >> 12) << 10) | 0x7), string.rep("\0", 4096 - 8))
f:close()
local machine = cartesi.machine({
    ram = { length = 1 << 20, backing_store = { data_filename = bin } },
    flash_drive = {
        { start = 0x80000000000000, length = 4096, read_only = true, backing_store = { data_filename = flash } },
    },
})
machine:run(1000000)
if machine:read_reg("iflags_H") == 0 then
    io.stderr:write("program did not halt\n")
    os.exit(2)
end
print(
    string.format(
        "exit=%d load-via-CLINT-PTE=%d store-via-CLINT-PTE=%d fetch-via-CLINT-PTE=%d load-RO-PTE=%d store-RO-PTE=%d RO-PTE-after=0x%x",
        machine:read_reg("htif_tohost_data") >> 1,
        machine:read_reg("x12"), -- a2
        machine:read_reg("x13"), -- a3
        machine:read_reg("x14"), -- a4
        machine:read_reg("x15"), -- a5
        machine:read_reg("x16"), -- a6
        machine:read_reg("x19") -- s3
    )
)
