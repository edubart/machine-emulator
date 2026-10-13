-- A flash drive may be backed by an image file shorter than the drive: the rest of the drive reads as zeros (see the
-- comment on short backing files in src/os-mapped-memory.cpp). This works for writable drives, but a read-only drive
-- backed by a page-aligned short image is refused with "possible non zero partial page", although the file mapping
-- ends exactly on a page boundary and there is no partial page. When backing_file_length % page_size == 0,
-- partial_page_remaining is computed as a whole page instead of 0, so the read-only branch throws.
-- usage: lua5.4 short-image.lua <workdir>     exit 0 = fixed, 1 = bug reproduced, 2 = test error
local cartesi = require("cartesi")

local W = assert(arg[1], "usage: short-image.lua <workdir>")
local DRIVE_LEN = 0x10000
local function writefile(f, s)
    local h <close> = assert(io.open(f, "wb"))
    assert(h:write(s))
end
local function pattern(n, seed)
    local t = {}
    for i = 1, n do
        t[i] = string.char((i * seed + 1) & 0xff)
    end
    return table.concat(t)
end

local images = {
    aligned = pattern(3 * 4096, 7), -- 12288 bytes: three whole pages
    unaligned = pattern(12000, 11), -- really ends in a partial page
}
for name, data in pairs(images) do
    writefile(W .. "/" .. name .. ".bin", data)
end

-- Returns true if the drive is accepted and reads back as the image followed by zeros
local function try(name, read_only)
    local data = images[name]
    local ok, err = pcall(function()
        local m <close> = cartesi.machine({
            ram = { length = 0x10000 },
            flash_drive = {
                { length = DRIVE_LEN, read_only = read_only, backing_store = { data_filename = W .. "/" .. name .. ".bin" } },
            },
        })
        local start = m:get_initial_config().flash_drive[1].start
        local contents = m:read_memory(start, DRIVE_LEN)
        assert(contents == data .. string.rep("\0", DRIVE_LEN - #data), "drive contents differ from image + zeros")
    end)
    print(string.format("  %-14s read_only=%-5s %s", name .. ".bin", tostring(read_only),
        ok and "accepted, image + zero tail read back" or ("refused: " .. tostring(err))))
    return ok
end

local writable = try("aligned", false)
local readonly = try("aligned", true)
-- informational: an image ending in a partial page is refused for read-only drives by design
try("unaligned", true)
if not writable then
    print("ERROR: control case failed (writable drive with a short image): the test itself is broken")
    os.exit(2)
end
if not readonly then
    print("BUG REPRODUCED: a page-aligned image shorter than the drive is refused only when the drive is read-only")
    os.exit(1)
end
print("OK: a read-only drive accepts a page-aligned image shorter than the drive")
os.exit(0)
