-- collect_uarch_cycle_root_hashes must reject log2_bundle_uarch_cycle_count outside {0..20},
-- like collect_uarch_cycle_bundle does. Values >20 cause UINT64_C(1) << (20 - log2) (negative shift, UB)
-- in append_uarch_reset_root_hash and return a malformed layout instead of an error.
local cartesi = require("cartesi")
local jsonrpc = require("cartesi.jsonrpc")
local MAX = 20
local bugs = 0

local function new_local() return cartesi.machine({ ram = { length = 4096 } }) end

local function check(label, make)
  -- sanity: valid value 20 works, bundle API rejects 21
  local m = make()
  local rh = m:read_revert_root_hash()
  local tail = { rh, rh }
  local ok, r = pcall(m.collect_uarch_cycle_root_hashes, m, 2, MAX, tail)
  assert(ok, label .. ": valid log2=20 failed: " .. tostring(r))
  print(label, "log2=20 ok:", #r.hashes, "entries, offsets", table.concat(r.mcycle_hash_offsets, ","))
  local okb, errb = pcall(m.collect_uarch_cycle_bundle, m, 0, MAX + 1, tail)
  print(label, "collect_uarch_cycle_bundle(0,21):", okb and "accepted" or ("rejected: " .. tostring(errb)))
  for _, lb in ipairs({ 21, 32, 40, 63 }) do
    local mm = make()
    local ok2, r2 = pcall(mm.collect_uarch_cycle_root_hashes, mm, 2, lb, tail)
    if ok2 then
      print(string.format("BUG: %s collect_uarch_cycle_root_hashes accepted log2_bundle_uarch_cycle_count=%d "
        .. "(valid range 0..%d): %d entries, offsets %s (per-mcycle entry count %d, which exceeds 2^(20-%d))",
        label, lb, MAX, #r2.hashes, table.concat(r2.mcycle_hash_offsets, ","),
        r2.mcycle_hash_offsets[2] and (r2.mcycle_hash_offsets[3] - r2.mcycle_hash_offsets[2]) or -1, lb))
      bugs = bugs + 1
    else
      print(label, "log2=" .. lb .. " rejected:", r2)
    end
  end
end

check("local", new_local)

local srv <close>, address = jsonrpc.spawn_server()
assert(srv, "failed to spawn server")
srv:set_timeout(30000)
check("jsonrpc", function()
  return srv(new_local():get_initial_config())
end)

if bugs > 0 then
  print(string.format("BUG: %d out-of-range log2_bundle_uarch_cycle_count values accepted", bugs))
  os.exit(1)
end
print("OK: out-of-range values rejected")
os.exit(0)
