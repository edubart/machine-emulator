#!/bin/bash
# Runs every bug regression test from the repository root and summarizes the results.
# Each test exits 1 and prints "BUG REPRODUCED" while the bug is present, and exits 0 with "OK" once fixed.
# Usage (from repo root): bash bugs/run-all.sh
source bugs/env/env.sh
tests=(
  "lua5.4 bugs/01-stale-root-after-interrupted-update/interrupted-update-stale-root.lua"
  "lua5.4 bugs/02-gio-response-code-zero/gio-response-code-zero.lua local"
  "lua5.4 bugs/02-gio-response-code-zero/gio-response-code-zero.lua jsonrpc"
  "lua5.4 bugs/03-mcycle-bundle-oom-abort/test-mcycle-bundle-oom-abort.lua"
  "lua5.4 bugs/03-mcycle-bundle-oom-abort/test-mcycle-bundle-oom-abort.lua jsonrpc"
  "lua5.4 bugs/04-overlong-revert-uarch-tail/test-overlong-revert-uarch-tail.lua"
  "lua5.4 bugs/05-bundle-log2-truncation/test-bundle-log2-truncation.lua"
  "sh bugs/06-c-api-cmio-length-truncation/run.sh"
  "lua5.4 bugs/07-cli-oversized-inspect-query/oversized-inspect-query.lua"
  "lua5.4 bugs/08-rpc-discover-version/test-discover-version.lua"
  "lua5.4 bugs/09-hash-tree-frontier-validation/test-hash-tree-frontier-validation.lua"
  "lua5.4 bugs/10-phtc-lru-cycle-hang/phtc-lru-cycle-hang.lua"
  "bash bugs/11-cli-computation-hash-overflow/cli-computation-hash-overflow.sh"
)
log=$(mktemp); trap 'rm -f "$log"' EXIT
for t in "${tests[@]}"; do
  # Output goes to a file (not a pipe), so a leaked child process cannot stall the runner
  timeout 600 $t > "$log" 2>&1 < /dev/null; rc=$?
  if [ $rc -eq 0 ]; then status="OK (fixed)"; elif grep -q "BUG REPRODUCED" "$log"; then status="BUG REPRODUCED"; else status="ERROR rc=$rc"; fi
  printf '%-18s %s\n' "$status" "$t"
done
