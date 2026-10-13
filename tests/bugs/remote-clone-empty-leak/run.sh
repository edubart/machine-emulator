#!/bin/sh
# cm_clone_empty() on a JSON-RPC machine returns an object with cleanup NOTHING and no timeout, so cm_delete() leaves the forked server (and its machine) running
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
[ -f "$SRC_DIR/libcartesi_jsonrpc.so" ] || skip "missing $SRC_DIR/libcartesi_jsonrpc.so"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
build_c clone_leak "$TEST_DIR/clone_leak.c" || build_failed clone_leak
set +e

# clone_leak.c spawns a server, makes two cm_clone_empty() objects (one with a successful cm_create, one with a
# failed one) and a cm_jsonrpc_fork_server() reference, deletes everything and probes every server address.
# Spawned and forked servers stay in the client's process group, so the client runs in its own session (setsid);
# the session leader records its pgid, and the whole group is SIGKILLed at exit as a safety net in case the client
# dies before it shuts the leaked servers down itself.
export CARTESI_JSONRPC_MACHINE="$SERVER_BIN"
PGF="$WORK_DIR/pgid"
trap 'g=$(cat "$PGF" 2>/dev/null); [ -n "$g" ] && kill -KILL "-$g" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT INT TERM
setsid -w sh -c 'echo $$ >"$1"; exec timeout -s KILL 60 "$2"' sh "$PGF" "$WORK_DIR/clone_leak"
rc=$?
g=$(cat "$PGF" 2>/dev/null)
if [ -n "$g" ]; then
    left=$(ps -e -o pgid= -o stat= | awk -v g="$g" '$1 == g && $2 !~ /^Z/ {n++} END {print n + 0}')
    echo "live processes left in the test's process group after the client exited: $left (killed at exit)"
fi
case $rc in
    0|1) exit $rc;;
    137) echo "ERROR: client timed out"; exit 2;;
    *) echo "ERROR: client failed (exit $rc)"; exit 2;;
esac
