#!/bin/sh
# cartesi-machine --replace-memory-range is silently undone by --revert-mode=stored; the printed --initial-hash is not the machine that runs
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
[ -f "$SRC_DIR/cartesi.so" ] || skip "missing Lua bindings $SRC_DIR/cartesi.so"
command -v "$LUA" >/dev/null 2>&1 || skip "missing $LUA"
# The CLI applies --replace-memory-range to the live machine and prints --initial-hash. With --revert-mode=stored
# it then builds the stored-revert object, which destroys the machine and reloads it from the load directory
# (snapshot(): destroy, clone_stored, load). machine::replace_memory_range does not record the new backing store in
# the config, so the reloaded machine has the ORIGINAL range contents and the run silently continues on it.
# Fixed behaviour: either the replacement survives (final hash == initial hash after 0 cycles and the drive holds
# the replacement), or the CLI refuses the combination with an error.
cd "$WORK_DIR"
"$LUA" -e 'io.write(string.rep("A", 4096))' >data1.img
"$LUA" -e 'io.write(string.rep("B", 4096))' >data2.img
CM="$SRC_DIR/cartesi-machine.lua"
# 1. Tiny base snapshot (64 KiB RAM, no kernel) with a 4 KiB flash drive "data" holding 'A's.
"$LUA" "$CM" --no-ram-image --no-root-flash-drive --ram-length=64Ki --hash-tree=phtc_size:16 \
    --flash-drive=label:data,data_filename:data1.img,mount:false --max-mcycle=0 --store=base >base.txt 2>&1 ||
    { cat base.txt; echo "failed to store base machine"; exit 2; }
# 2. Clone+load it (sharing:all, which requires --revert-mode=stored), replace "data" with 'B's, run 0 cycles.
rc=0
timeout 120 "$LUA" "$CM" --load=work,clone:base --revert-mode=stored \
    --replace-memory-range=label:data,data_filename:data2.img \
    --initial-hash --final-hash --max-mcycle=0 --final-proof=label:data,filename:final-proof.lua >out.txt 2>&1 || rc=$?
if [ $rc -ne 0 ]; then
    # Accept an explicit refusal of the combination, provided the same run without the replacement works.
    tail -3 out.txt
    rc2=0
    timeout 120 "$LUA" "$CM" --load=work2,clone:base --revert-mode=stored --initial-hash --final-hash --max-mcycle=0 \
        >control.txt 2>&1 || rc2=$?
    if [ $rc2 -eq 0 ]; then
        echo "OK: cartesi-machine refuses --replace-memory-range with --revert-mode=stored (exit code $rc)"
        exit 0
    fi
    cat control.txt
    echo "cartesi-machine failed even without --replace-memory-range"
    exit 2
fi
init=$(grep -E '^0: 0x' out.txt | head -1 | cut -d' ' -f2)
final=$(grep -E '^0: 0x' out.txt | tail -1 | cut -d' ' -f2)
[ -n "$init" ] && [ -n "$final" ] && [ -f final-proof.lua ] || { cat out.txt; echo "missing hashes or final proof"; exit 2; }
content=$("$LUA" "$TEST_DIR/which-data.lua" final-proof.lua)
echo "  --initial-hash (printed after the replacement): $init"
echo "  --final-hash   (after 0 cycles):                $final"
echo "  final content of flash drive \"data\": $content"
if [ "$init" != "$final" ] || [ "$content" != "replacement" ]; then
    echo "BUG REPRODUCED: --replace-memory-range silently undone by --revert-mode=stored (0 cycles run, final hash differs from printed initial hash, drive holds the $content image)"
    exit 1
fi
echo "OK: the replacement survives --revert-mode=stored and the printed initial hash matches the machine that ran"
exit 0
