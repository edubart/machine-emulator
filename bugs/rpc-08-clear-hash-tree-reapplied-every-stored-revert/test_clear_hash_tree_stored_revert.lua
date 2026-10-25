-- Proves that cartesi-machine --revert-mode=stored --clear-hash-tree re-clears the hash tree on
-- every stored snapshot/revert reload (not only once after create/load), forcing a full rehash
-- per input. Exits 1 with "BUG:" when the defect is present.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
-- Locate the CLI: $CARTESI_MACHINE_CLI, else cartesi-machine.lua on LUA_PATH (src/ after `eval $(make -s env)`).
local CLI = os.getenv("CARTESI_MACHINE_CLI") or package.searchpath("cartesi-machine", package.path)
    or "src/cartesi-machine.lua"
local evmu = require("cartesi.evmu")
local NINPUTS = 3
local ADVANCE_SIG = [[EvmAdvance(uint256 chainId, address appContract, address msgSender, uint256 blockNumber,
    uint256 blockTimestamp, uint256 prevRandao, uint256 index, bytes payload)]]
local function encode_advance(index, payload)
    return evmu.encode_calldata(ADVANCE_SIG, {
        chainId = 0, appContract = "0x0000000000000000000000000000000000000000",
        msgSender = "0x0000000000000000000000000000000000000000", blockNumber = index,
        blockTimestamp = 0, prevRandao = 0, index = index, payload = evmu.raw(payload),
    })
end
local tmp = os.tmpname(); os.remove(tmp)
assert(os.execute("mkdir -p " .. tmp))
for i = 0, NINPUTS - 1 do
    local f = assert(io.open(string.format("%s/input-%d.bin", tmp, i), "wb"))
    f:write(encode_advance(i, "payload" .. i)); f:close()
end
local function run(with_clear)
    local dir = tmp .. (with_clear and "/m-clear" or "/m-noclear")
    local report = dir .. ".report"
    local cmd = string.format(
        "timeout 600 %s %s/wrapper.lua %s %s --ram-length=64Mi --create=%s --revert-mode=stored %s "
            .. "--cmio-advance-state=input:%s/input-%%i.bin,input_file_index_begin:0,input_file_index_end:%d,"
            .. "output:,rejected_output:,output_proof:,report:,outputs_merkle_root:,outputs_merkle_root_proof: "
            .. "--max-mcycle=4000000000 --no-init-splash --quiet -- ioctl-echo-loop --vouchers=1 > %s.log 2>&1",
        arg[-1], here, report, CLI, dir, with_clear and "--clear-hash-tree" or "", tmp, NINPUTS, dir)
    local t0 = os.time()
    local ok = os.execute(cmd)
    local elapsed = os.time() - t0
    if not ok then
        io.stderr:write(io.open(dir .. ".log"):read("a"))
        error("CLI run failed: " .. cmd)
    end
    local s = {}
    for line in io.lines(report) do
        local k, v = line:match("^(.-)=(.*)$"); s[k] = tonumber(v) or v
    end
    s.elapsed = elapsed
    return s
end
local base = run(false)
local clr = run(true)
os.execute("rm -rf " .. tmp)
local function show(name, s)
    print(string.format("%-16s creates=%d(clearing %d) loads=%d(clearing %d) get_root_hash=%d pages_rehashed=%d time=%ds",
        name, s.creates, s.clearing_creates, s.loads, s.clearing_loads, s.root_hash_calls, s.page_changes, s.elapsed))
end
show("no-clear:", base)
show("--clear-hash-tree:", clr)
-- The option promises a single clear after creating or loading the machine. Every load done by the
-- revert machinery (initial snapshot+commit, and one snapshot per input) must not clear again.
local total_clears = clr.clearing_creates + clr.clearing_loads
local extra_pages = clr.page_changes - base.page_changes
print(string.format("hash-tree clears: %d (expected 1); extra pages rehashed vs no-clear: %d", total_clears, extra_pages))
if total_clears > 1 then
    print(string.format("BUG: --clear-hash-tree cleared the hash tree %d times (%d stored-revert reloads with clear_hash_tree=true for %d inputs), "
        .. "rehashing %d extra pages (%.1fx the no-clear run)", total_clears, clr.clearing_loads, NINPUTS, extra_pages,
        clr.page_changes / math.max(1, base.page_changes)))
    os.exit(1)
end
print("OK: hash tree cleared only once")
os.exit(0)
