#!/bin/sh
# A JSON-RPC batch containing "fork" forks the server in both parent and child: a non-idempotent batch entry runs twice, so one batch of 2 forks yields 2^2 live servers instead of 3
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
command -v python3 >/dev/null 2>&1 || skip "missing python3"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# Root cause: the batch loop iterates entries by value and dispatches each
# (jsonrpc-remote-machine.cpp:1930 `for (auto ji : j) jsonrpc_dispatch_method(ji, session)`). In the
# fork handler the child branch does its asio housekeeping and then FALLS THROUGH to the shared
# `return jsonrpc_response_ok(...)` with no break/exit, so control returns to the same loop in BOTH
# parent and child. Every batch entry after a fork is therefore executed in both processes.
#
# We send a batch of exactly 2 fork entries (so at most 2^2 = 4 processes). The SECOND fork is the
# non-idempotent entry whose double execution we observe: parent forks child1 (entry 1), then parent
# AND child1 each run entry 2 -> 4 live servers. A correct server (child stops the batch, or fork is
# refused inside a batch) yields at most 3 (parent + 2 linear forks, or fewer). We count/kill ONLY our
# own process group; every forked child inherits the server's pgid.
N=2
SRV_PID=""; SRV_PGID=""; SRV_PORT=""
start_server() { # logfile
    : > "$1"
    setsid "$SERVER_BIN" --server-address=127.0.0.1:0 --log-level=info >"$1" 2>&1 </dev/null &
    i=0
    while [ "$i" -lt 200 ]; do
        SRV_PORT=$(grep -oE 'bound to 127.0.0.1:[0-9]+' "$1" | head -1 | grep -oE '[0-9]+$')
        SRV_PID=$(grep -oE 'pid:[0-9]+' "$1" | head -1 | cut -d: -f2)
        SRV_PGID=$(grep -oE 'pgid:[0-9]+' "$1" | head -1 | cut -d: -f2)
        [ -n "$SRV_PORT" ] && [ -n "$SRV_PGID" ] && return 0
        sleep 0.05; i=$((i + 1))
    done
    return 1
}
count_group() { # processes currently in our server's process group
    [ -n "$SRV_PGID" ] || { echo 0; return; }
    ps -e -o pgid= -o pid= | awk -v g="$SRV_PGID" '$1==g{n++} END{print n+0}'
}
kill_group() { [ -n "$SRV_PGID" ] && kill -KILL "-$SRV_PGID" 2>/dev/null; return 0; }
trap 'kill_group; rm -rf "$WORK_DIR"' EXIT INT TERM

LOG="$WORK_DIR/srv.log"
start_server "$LOG" || { echo "server did not start/bind"; exit 2; }
echo "server pid=$SRV_PID pgid=$SRV_PGID port=$SRV_PORT"
base=$(count_group)
echo "baseline processes in my group = $base (expect 1)"

timeout 30 python3 -I "$TEST_DIR/forkbatch.py" 127.0.0.1 "$SRV_PORT" "$N"

# Let the fork cascade settle (each forked child re-binds a fresh ephemeral acceptor and keeps serving).
sleep 1.5
cnt=$(count_group)
echo "after one $N-fork batch: processes in my group = $cnt (linear fix would be <= $((N + 1)); 2^N = $((1 << N)))"

kill_group
sleep 0.4
left=$(count_group)
echo "cleanup: processes left in my group = $left"

if [ "$cnt" -gt $((N + 1)) ]; then
    echo "BUG REPRODUCED: one $N-fork batch produced $cnt processes (the forked child re-ran the remaining batch entry)"
    exit 1
fi
echo "OK: batch fork count was not exponential ($cnt processes)"
exit 0
