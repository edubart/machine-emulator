#!/bin/sh
# Spawned JSON-RPC servers inherit the client's open sockets (no CLOEXEC, posix_spawnp with no file actions), so a newly spawned server holds a duplicate of the client's connection to another server
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
SERVER_BIN="$SRC_DIR/cartesi-jsonrpc-machine"
[ -x "$SERVER_BIN" ] || skip "missing server $SERVER_BIN"
[ -f "$SRC_DIR/cartesi/jsonrpc.so" ] || skip "missing Lua jsonrpc bindings"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
command -v setsid >/dev/null 2>&1 || skip "missing setsid"
set +e

# repro.lua (deterministic inode-matching part): the client keeps an open connection to server A, then
# spawns server B. It compares the socket inodes in /proc/<client>/fd against /proc/<serverB>/fd. Asio
# creates sockets without SOCK_CLOEXEC and cm_jsonrpc_spawn_server calls posix_spawnp with no file
# actions (jsonrpc-machine.cpp:466-486), so B's forked grandchild keeps a duplicate of the client's fd to
# A. A shared inode present in BOTH processes == the leak (BUG REPRODUCED). A fixed client/server closes
# inherited fds (CLOEXEC / addclosefrom_np / close_range), so no inode is shared. Both servers are
# shut down by the Lua; we also run in our own session (setsid) and SIGKILL the whole group as a safety
# net. The session leader records its own pgid to a file (robust whether or not setsid forks), and we
# decide from the printed verdict rather than a propagated exit code.
export CARTESI_JSONRPC_MACHINE="$SERVER_BIN"
OUT="$WORK_DIR/out.txt"
PGF="$WORK_DIR/pgid"
setsid sh -c 'echo $$ >"$1"; exec timeout -s KILL 60 "$2" "$3"' \
    sh "$PGF" "$LUA" "$TEST_DIR/repro.lua" >"$OUT" 2>&1 &
WRAP=$!
i=0; while [ ! -s "$PGF" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
WPGID=$(tr -d ' ' <"$PGF" 2>/dev/null)
trap '[ -n "$WPGID" ] && kill -KILL "-$WPGID" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT INT TERM
wait "$WRAP" 2>/dev/null
# make sure the verdict line is present (covers a setsid-forked wait that returned early)
i=0; while ! grep -q 'REPRODUCED' "$OUT" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
cat "$OUT"
[ -n "$WPGID" ] && kill -KILL "-$WPGID" 2>/dev/null

if grep -q 'BUG REPRODUCED' "$OUT"; then
    exit 1
elif grep -q 'NOT REPRODUCED' "$OUT"; then
    echo "OK: the spawned server did not inherit the client's sockets"
    exit 0
fi
echo "test harness error (no verdict)"
exit 2
