#!/bin/bash
# End-to-end (timing-based) companion of interrupted-update-stale-root.lua.
# SIGKILLs a process while get_root_hash() updates the hash tree of a machine loaded with sharing "all",
# then reloads the directory and compares its root hash with an independent reconstruction from memory.
# Run (from repo root, after sourcing bugs/env/env.sh): bash kill-during-update.sh [trials]
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/mkbase.lua" <<'LUA'
local cartesi = require("cartesi")
local m <close> = cartesi.machine({ ram = { length = 64 << 20 }, hash_tree = { phtc_size = 512 } })
m:get_root_hash()
m:store(arg[1], cartesi.SHARING_ALL)
LUA
cat > "$T/hash.lua" <<'LUA'
local cartesi = require("cartesi")
local m = cartesi.machine(arg[1], {}, cartesi.SHARING_ALL)
local blk = string.rep(string.char(65 + tonumber(arg[2]) % 26), 200)
for p = 0, (64 << 20) // 4096 - 1 do m:write_memory(0x80000000 + p * 4096 + (p % 64) * 32, blk:sub(1, 64 + p % 100)) end
io.stdout:write("HASHING\n"); io.stdout:flush()
m:get_root_hash()
io.stdout:write("DONE\n"); io.stdout:flush()
LUA
cat > "$T/check.lua" <<'LUA'
local cartesi = require("cartesi")
local tests_util = require("cartesi.tests.util")
local m = cartesi.machine(arg[1], {}, cartesi.SHARING_NONE)
local ok, h = pcall(m.get_root_hash, m)
if not ok then ok, h = pcall(m.get_root_hash, m) end -- first update may fail on leftover borrowed cache entries
if not ok then print("ERROR " .. tostring(h)) os.exit(2) end
if h ~= tests_util.calculate_emulator_hash(m) then
    print("STALE root hash (verify_hash_tree() = " .. tostring(m:verify_hash_tree()) .. ")") os.exit(7)
end
print("consistent")
LUA
cat > "$T/clone.lua" <<'LUA'
require("cartesi").machine:clone_stored(arg[1], arg[2])
LUA
set -o pipefail
lua5.4 "$T/mkbase.lua" "$T/base" || { echo "test setup failed"; exit 2; }
bugs=0; inconclusive=0
for i in $(seq 1 "${1:-4}"); do
  rm -rf "$T/t"; lua5.4 "$T/clone.lua" "$T/base" "$T/t" || { echo "clone failed"; exit 2; }
  delay=$(awk -v i="$i" 'BEGIN{printf "%.3f", 0.02 * i}')
  coproc H { exec lua5.4 "$T/hash.lua" "$T/t" "$i"; }
  pid=$H_PID
  read -r started <&"${H[0]}"    # wait until hashing starts
  [ "$started" = HASHING ] || { echo "hashing process failed to start"; exit 2; }
  sleep "$delay"; kill -KILL "$pid" 2>/dev/null
  read -r -t 1 done_line <&"${H[0]}" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$done_line" = DONE ]; then echo "trial $i: update finished before kill (inconclusive)"; inconclusive=$((inconclusive+1)); continue; fi
  r=$(timeout 120 lua5.4 "$T/check.lua" "$T/t" 2>&1); rc=$?
  echo "trial $i (kill after ${delay}s): $r"
  [ $rc -eq 7 ] && bugs=$((bugs+1))
  [ $rc -ne 0 ] && [ $rc -ne 7 ] && { echo "check failed"; exit 2; }
done
if [ $bugs -gt 0 ]; then echo "BUG REPRODUCED"; exit 1; fi
[ $inconclusive -eq "${1:-4}" ] && { echo "all trials inconclusive"; exit 2; }
echo "OK"
