#!/bin/sh
# End-to-end: cartesi-machine --final-hash exits 0 but leaves an empty file when the
# final flush fails (simulated with a file-size limit of 0 and SIGXFSZ ignored -> EFBIG).
# Run from the repo root after: eval $(make -s env)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
# stdout/stderr must go to a pipe (not a file), since the size limit applies to every file write
LOG=$( ( trap '' XFSZ; ulimit -f 0; timeout 120 cartesi-machine.lua --ram-length=64Mi \
    --final-hash="$OUT/final.bin" -- true 2>&1; echo "cli_exit=$?" ) )
echo "$LOG" | tail -3
rc=$(echo "$LOG" | sed -n 's/^cli_exit=//p')
size=$(wc -c <"$OUT/final.bin" 2>/dev/null || echo missing)
echo "final.bin size=$size"
if [ "$rc" = "0" ] && [ "$size" != "32" ]; then
    echo "BUG: cartesi-machine exited 0 although the --final-hash file was not written (size=$size)"
    exit 1
fi
echo "OK: failure was reported or file was written"
exit 0
