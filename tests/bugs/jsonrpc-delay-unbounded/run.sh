#!/bin/sh
# delay_next_request accepts an unbounded delay and the server is single-threaded, so one client's delay freezes every other client
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
command -v python3 >/dev/null 2>&1 || skip "missing python3"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# Root cause: jsonrpc_delay_next_request_handler stores an unbounded uint64 `ms`, and the batch loop
# applies std::this_thread::sleep_for(ms) on the one asio thread that serves every connection
# (asio::io_context{1}, single ioc.run()). The method is always registered, not debug-gated. We use a
# bounded 2000 ms delay and show an UNRELATED second connection is held off for ~that long. A fixed
# server caps the delay to a small maximum (or gates/removes the method), so the victim is not frozen.
DELAY_MS=2000

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

OUT="$WORK_DIR/out.txt"
timeout 30 python3 -I "$TEST_DIR/delay.py" 127.0.0.1 "$SRV_PORT" "$DELAY_MS" >"$OUT" 2>&1
cat "$OUT"

secs=$(sed -n 's/^BLOCKED_SECONDS=//p' "$OUT" | head -1)
[ -n "$secs" ] || { echo "no timing measured"; exit 2; }
# reproduced if the unrelated victim was blocked for most of the 2 s delay (threshold 1.5 s)
over=$(awk -v s="$secs" 'BEGIN{print (s > 1.5) ? 1 : 0}')
if [ "$over" = 1 ]; then
    echo "BUG REPRODUCED: an unrelated client's request was frozen for ${secs}s by another client's delay_next_request"
    exit 1
fi
echo "OK: the victim request was not frozen (${secs}s); delay is bounded or the method is gated"
exit 0
