#!/bin/sh
# cartesi-machine --print-uarch-cycle-root-hashes=count:N without start: uses the absolute window [0,N) and prints nothing for a loaded machine
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# src/cartesi-machine.lua sets uarch_cycle_root_hashes_start = o.start or 0, and the runner then collects within
# [start, start + count). With start omitted the window is [0, count), so for a machine that is already past mcycle
# count nothing is collected and no warning is given. --print-mcycle-root-hashes, in contrast, treats a missing start
# as "from the current mcycle". Without start, the output must match an explicit start at the current mcycle.
cd "$WORK_DIR"
CM="$SRC_DIR/cartesi-machine.lua"
printf '\157\000\000\000' >loop.bin # RAM image: "j ." (0x0000006f), an endless loop
# Store a tiny machine (64 KiB RAM, small page hash-tree cache: about 7 MB on disk) at mcycle 1000.
"$LUA" "$CM" --no-root-flash-drive --ram-image=loop.bin --ram-length=64Ki --hash-tree=phtc_size:512 \
    --max-mcycle=1000 --store=snap >store.txt 2>&1 || { cat store.txt; echo "could not store the machine"; exit 2; }
# Load it and ask for the uarch-cycle root hashes of the next 2 mcycles, without and with an explicit start.
"$LUA" "$CM" --load=snap --print-uarch-cycle-root-hashes=count:2 --max-mcycle=1002 >implicit.txt 2>&1 ||
    { cat implicit.txt; echo "cartesi-machine failed (count:2)"; exit 2; }
"$LUA" "$CM" --load=snap --print-uarch-cycle-root-hashes=count:2,start:1000 --max-mcycle=1002 >explicit.txt 2>&1 ||
    { cat explicit.txt; echo "cartesi-machine failed (count:2,start:1000)"; exit 2; }
# Lines "<mcycle>,<uarch cycle>: 0x<hash>" are the per-uarch-cycle hashes.
grep -E '^[0-9]+,[0-9]+: 0x' implicit.txt >implicit.hashes || true
grep -E '^[0-9]+,[0-9]+: 0x' explicit.txt >explicit.hashes || true
n_implicit=$(wc -l <implicit.hashes | tr -d ' ')
n_explicit=$(wc -l <explicit.hashes | tr -d ' ')
echo "machine loaded at mcycle 1000, count:2            -> $n_implicit uarch-cycle root hashes"
echo "machine loaded at mcycle 1000, count:2,start:1000 -> $n_explicit uarch-cycle root hashes"
[ "$n_explicit" -gt 0 ] || { cat explicit.txt; echo "the explicit-start control printed no uarch-cycle hashes"; exit 2; }
if cmp -s implicit.hashes explicit.hashes; then
    echo "OK: count without start collects the uarch-cycle root hashes from the current mcycle"
    exit 0
fi
if [ "$n_implicit" -eq 0 ]; then
    echo "BUG REPRODUCED: requested uarch-cycle root hashes silently not printed (window taken as [0,count))"
else
    echo "BUG REPRODUCED: count without start does not collect the next count mcycles from the current mcycle"
fi
exit 1
