#!/bin/sh
# JSON-RPC fork_server() accepts machines with a shared hash tree; parent and child then share the page hash-tree cache and return wrong hashes
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -x "$SRC_DIR/cartesi-jsonrpc-machine" ] || skip "missing $SRC_DIR/cartesi-jsonrpc-machine"
export CARTESI_JSONRPC_MACHINE="$SRC_DIR/cartesi-jsonrpc-machine"
# Make sure no spawned server outlives the test (pids are recorded by repro.lua)
kill_servers() {
    [ -f "$WORK_DIR/pids" ] || return 0
    while read -r pid; do
        if grep -q cartesi-jsonrpc-machine "/proc/$pid/cmdline" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    done < "$WORK_DIR/pids"
}
trap 'kill_servers; rm -rf "$WORK_DIR"' EXIT INT TERM
rc=0
out="$(timeout 120 "$LUA" "$TEST_DIR/repro.lua" "$WORK_DIR" 2>"$WORK_DIR/stderr.txt")" || rc=$?
echo "$out"
case $rc in
    0) exit 0 ;;
    1) echo "$out" | grep -q "BUG REPRODUCED" && exit 1 ;;
esac
echo "test error (exit $rc):"; tail -5 "$WORK_DIR/stderr.txt"
exit 2
