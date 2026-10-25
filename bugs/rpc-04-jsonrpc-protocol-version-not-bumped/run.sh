#!/bin/bash
# Proof for rpc-04: builds (once) a cartesi-jsonrpc-machine from origin/main,
# then runs the branch Lua client (test.lua) against it.
#
# Run from the repo root after `eval $(make -s env)`:
#   bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh
#
# Env overrides:
#   CARTESI_JSONRPC_MACHINE  use an existing old (main / v0.22.0) server binary, skip the build
#   OLD_REF                  git ref to build the old server from (default: origin/main)
#   OLD_BUILD_DIR            where to build it (default: ${TMPDIR:-/tmp}/rpc-04-old-server)
# The first build takes a few minutes.
set -e
W=$(cd "$(dirname "$0")" && pwd)
R=$(git rev-parse --show-toplevel 2>/dev/null || (cd "$W/../.." && pwd))  # run from the repo root
if [ -z "$CARTESI_JSONRPC_MACHINE" ]; then
  B=${OLD_BUILD_DIR:-${TMPDIR:-/tmp}/rpc-04-old-server}
  if [ ! -x "$B/src/cartesi-jsonrpc-machine" ]; then
    mkdir -p "$B"
    git -C "$R" archive "${OLD_REF:-origin/main}" | tar -x -C "$B"
    # generated (untracked) uarch sources; they come from the built repo tree
    cp -a "$R/uarch/uarch-pristine-hash.c" "$R/uarch/uarch-pristine-ram.c" "$B/uarch/"
    make -C "$B/src" -j"$(nproc)" cartesi-jsonrpc-machine > "$B/build.log" 2>&1 \
      || { echo "old server build failed, see $B/build.log"; exit 2; }
  fi
  CARTESI_JSONRPC_MACHINE="$B/src/cartesi-jsonrpc-machine"
fi
export CARTESI_JSONRPC_MACHINE
timeout 60 lua5.4 "$W/test.lua"
