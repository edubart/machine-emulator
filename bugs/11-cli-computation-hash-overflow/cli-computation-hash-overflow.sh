#!/bin/bash
# Regression test: cartesi-machine --mcycle-computation-hash geometry check overflows.
# log2_mcycle_period + log2_bundle_mcycle_count wraps around in Lua integers, the range check passes,
# and the CLI spins (~2^63-iteration loop in hash_tree.frontier_get_leaf_count) instead of rejecting
# the option.
# Run (from repo root, after sourcing bugs/env/env.sh): bash bugs/11-cli-computation-hash-overflow/cli-computation-hash-overflow.sh
# Prints "BUG REPRODUCED" and exits 1 on the buggy behaviour, "OK" and exits 0 when fixed.
CM_CLI=${CM_CLI:-$(pwd)/src/cartesi-machine.lua}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W" || exit 2
# tiny machine stopped at a manual rx-accepted yield
lua5.4 -e '
local c=require"cartesi"
local m=c.machine({processor={registers={pc=0x80000000}},ram={length=1<<20,backing_store={data_filename=os.getenv("CARTESI_TESTS_PATH").."/computation_hash.bin"}},cmio={rx_buffer={},tx_buffer={}}})
assert(m:run(math.maxinteger)==c.BREAK_REASON_YIELDED_MANUALLY); m:store("tpl")' || exit 2
# control: an out-of-range bundle is rejected immediately
timeout -s KILL 20 lua5.4 "$CM_CLI" --load=tpl --no-revert --cmio-advance-state=input_file_index_end:0 \
  --mcycle-computation-hash=log2_mcycle_period:1,log2_bundle_mcycle_count:48 --no-init-splash > control.log 2>&1 </dev/null
echo "control (log2_bundle_mcycle_count:48) exit=$?: $(grep -o 'computation hash bundle cannot exceed.*' control.log | head -1)"
# overflowing bundle count: 1 + 0x7fffffffffffffff wraps to a negative number <= 48
timeout -s KILL 20 lua5.4 "$CM_CLI" --load=tpl --no-revert --cmio-advance-state=input_file_index_end:0 \
  --mcycle-computation-hash=log2_mcycle_period:1,log2_bundle_mcycle_count:0x7fffffffffffffff --no-init-splash > ovf.log 2>&1 </dev/null
rc=$?
echo "overflow (log2_bundle_mcycle_count:0x7fffffffffffffff) exit=$rc"
sed 's/^/  | /' ovf.log
if [ $rc -eq 137 ]; then echo "BUG REPRODUCED: CLI accepted the overflowing option and spun until killed"; exit 1; fi
if grep -q 'computation hash bundle cannot exceed' ovf.log; then echo "OK"; exit 0; fi
echo "BUG REPRODUCED: option not rejected (exit $rc)"; exit 1
