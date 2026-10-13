-- Compares the effective config of the machine created with --load-config=<partial file> (got) with the one
-- created from the same command-line options without --load-config (ref).
-- Usage: lua5.4 compare.lua got.lua ref.lua got-hash ref-hash
local got, ref = dofile(arg[1]), dofile(arg[2])
local fields = {
    { "hash_tree.hash_function (--hash-tree=hash_function:sha256)", function(c) return c.hash_tree.hash_function end },
    { "processor.registers.htif.iyield (--no-htif-yield-automatic)", function(c) return c.processor.registers.htif.iyield end },
    { "dtb.bootargs (--no-root-flash-drive)", function(c) return c.dtb.bootargs end },
}
local bad = 0
for _, f in ipairs(fields) do
    local g, r = f[2](got), f[2](ref)
    print(string.format("  %s: with --load-config %q, command line requested %q", f[1], tostring(g), tostring(r)))
    if g ~= r then bad = bad + 1 end
end
print(string.format("  initial root hash with --load-config:    %s", arg[3]))
print(string.format("  initial root hash without --load-config: %s", arg[4]))
if arg[3] ~= arg[4] then bad = bad + 1 end
os.exit(bad == 0 and 0 or 1)
