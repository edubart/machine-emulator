#!/bin/sh
# machine.read_memory allocates the attacker-chosen `length` with no upper-bound validation: a huge length is actually attempted (allocation) instead of being rejected up front
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
command -v python3 >/dev/null 2>&1 || skip "missing python3"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# Root cause: jsonrpc-remote-machine.cpp:1405 (read_memory) does make_unique_calloc<unsigned char>(length)
# then read_memory(..., length) with `length` an unbounded untrusted uint64. We cap the server's virtual
# memory with `ulimit -v` and ask for 2^40 (1 TiB) so the HOST is never at risk: with the bug the server
# tries the allocation and calloc fails under the cap -> a std::bad_alloc error comes back (allocation was
# attempted). A fixed server validates `length` against the addressed range BEFORE allocating and returns a
# clean validation error with no allocation. We therefore reproduce iff the error is bad_alloc.
#
# The server binds 127.0.0.1:0 only and runs in its own session (setsid) under the rlimit; we kill only its
# process group. The 4 MiB machine stays tiny; the 1 TiB request never allocates for real.
CAP_KB=2097152   # 2 GiB virtual address space: enough to start + create a 4 MiB machine, far below 1 TiB
HUGE=1099511627776   # 2^40 bytes == 1 TiB

SRV_PID=""; SRV_PGID=""; SRV_PORT=""
start_capped_server() { # logfile
    : > "$1"
    setsid sh -c 'ulimit -v '"$CAP_KB"'; exec "$1" --server-address=127.0.0.1:0 --log-level=info' \
        sh "$SERVER_BIN" >"$1" 2>&1 </dev/null &
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
start_capped_server "$LOG" || { echo "server did not start/bind under the rlimit"; exit 2; }
echo "capped server pid=$SRV_PID pgid=$SRV_PGID port=$SRV_PORT (ulimit -v ${CAP_KB} KiB)"

OUT="$WORK_DIR/out.txt"
timeout 60 python3 -I "$TEST_DIR/readmem.py" 127.0.0.1 "$SRV_PORT" "$HUGE" >"$OUT" 2>&1
cat "$OUT"

if kill -0 "$SRV_PID" 2>/dev/null; then
    echo "server still alive after the request"
else
    echo "note: server process is gone after the request"
fi

if grep -q '^RESULT=bad_alloc' "$OUT"; then
    echo "BUG REPRODUCED: the 1 TiB read_memory was attempted (std::bad_alloc under the rlimit), not rejected by validation"
    exit 1
fi
if grep -q '^RESULT=validation_error' "$OUT"; then
    echo "OK: the huge read_memory length was rejected by validation before allocating"
    exit 0
fi
echo "unexpected outcome (no bad_alloc and no validation error)"
exit 2
