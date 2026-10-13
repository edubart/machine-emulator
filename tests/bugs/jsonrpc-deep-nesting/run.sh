#!/bin/sh
# A single deeply-nested JSON request crashes the whole cartesi-jsonrpc-machine server (stack overflow)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
command -v python3 >/dev/null 2>&1 || skip "missing python3"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# --- server management: bind 127.0.0.1:0 only, own process group, group-killed on exit ---
# setsid gives the server a fresh session/process group; we read its pid/pgid/port from the log it
# prints itself, so the group kill is correct whether or not setsid forks. We never pkill by name.
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
kill_group() { [ -n "$SRV_PGID" ] && kill -KILL "-$SRV_PGID" 2>/dev/null; return 0; }
trap 'kill_group; rm -rf "$WORK_DIR"' EXIT INT TERM

LOG="$WORK_DIR/srv.log"
start_server "$LOG" || { echo "server did not start/bind"; exit 2; }
echo "server pid=$SRV_PID pgid=$SRV_PGID port=$SRV_PORT"

# 1) Control: a moderate depth is parsed and answered (confirms the harness can tell alive from dead,
#    and that the server survives ordinary nesting). jsonrpc-remote-machine.cpp:1915 json::parse has no
#    depth cap and the body limit is uint64_max, so depth is bounded only by the C++ recursion/stack.
timeout 30 python3 -I "$TEST_DIR/nest.py" 127.0.0.1 "$SRV_PORT" 20000
if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "server died at the control depth; cannot characterise"; exit 2
fi
echo "control: server alive after depth 20000 (expected)"

# 2) Attack: a large depth (~400 KB body) overflows the parser/destructor recursion. A SIGSEGV is fatal
#    and cannot be caught by the per-method or main try/catch, so the whole process (and its in-memory
#    machine) dies.
timeout 30 python3 -I "$TEST_DIR/nest.py" 127.0.0.1 "$SRV_PORT" 200000
sleep 0.5
if kill -0 "$SRV_PID" 2>/dev/null; then
    echo "OK: server survived the deeply-nested request (nesting-depth capped)"
    exit 0
fi
# Server is gone: reap it opportunistically to report the signal (works when it is our direct child).
wait "$SRV_PID" 2>/dev/null; st=$?
if [ "$st" -ge 128 ]; then
    echo "BUG REPRODUCED: one deeply-nested JSON request killed the server (signal $((st - 128)))"
else
    echo "BUG REPRODUCED: one deeply-nested JSON request terminated the server"
fi
exit 1
