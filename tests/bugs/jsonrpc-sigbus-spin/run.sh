#!/bin/sh
# The JSON-RPC server routes SIGBUS through a Boost.Asio signal_set, so a synchronous SIGBUS from guest execution becomes an endless busy loop (no reply, no exit, SIGTERM ignored)
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
[ -f "$SRC_DIR/cartesi/jsonrpc.so" ] || skip "missing Lua jsonrpc bindings"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# repro.lua spawns a server (binds 127.0.0.1:0 by default), creates a machine with a flash drive backed
# by a 1 MiB file, writes a guest program that loads from the flash region, then TRUNCATES the backing
# file to 0 while the machine runs. The guest load then faults with SIGBUS. install_termination_signal_
# handlers() adds SIGBUS to an asio signal_set, whose handler only writes to a pipe and returns, so the
# faulting instruction re-executes forever: the server spins (state R, cpu ticks climbing), never answers,
# and even SIGTERM (same pipe) is ignored. A local machine in the same situation dies with SIGBUS
# (fail-fast). A fixed server (SIGBUS not in the signal_set) dies on the fault and the client sees an
# immediate connection error. All bounded: 3 s RPC timeout inside, server SIGKILLed by the Lua.
#
# We locate the server binary via CARTESI_JSONRPC_MACHINE and run the whole reproducer in its own session
# (setsid) so the Lua process and the server it spawns form one process group, which we SIGKILL on exit as
# a safety net. The session leader records its own pgid to a file (robust whether or not setsid forks),
# and we decide from the printed verdict rather than a propagated exit code.
export CARTESI_JSONRPC_MACHINE="$SERVER_BIN"
OUT="$WORK_DIR/out.txt"
PGF="$WORK_DIR/pgid"
setsid sh -c 'echo $$ >"$1"; exec timeout -s KILL 90 "$2" "$3" "$4"' \
    sh "$PGF" "$LUA" "$TEST_DIR/repro.lua" "$WORK_DIR" >"$OUT" 2>&1 &
WRAP=$!
i=0; while [ ! -s "$PGF" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
WPGID=$(tr -d ' ' <"$PGF" 2>/dev/null)
trap '[ -n "$WPGID" ] && kill -KILL "-$WPGID" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT INT TERM
wait "$WRAP" 2>/dev/null
# make sure the verdict line is present (covers a setsid-forked wait that returned early)
i=0; while ! grep -q 'REPRODUCED' "$OUT" 2>/dev/null && [ "$i" -lt 950 ]; do sleep 0.1; i=$((i + 1)); done
cat "$OUT"
[ -n "$WPGID" ] && kill -KILL "-$WPGID" 2>/dev/null

if grep -q 'BUG REPRODUCED' "$OUT"; then
    exit 1
elif grep -q 'NOT REPRODUCED' "$OUT"; then
    echo "OK: the server died on the SIGBUS fault instead of spinning"
    exit 0
fi
echo "test harness error (no verdict)"
exit 2
