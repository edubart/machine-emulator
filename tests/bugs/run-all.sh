#!/bin/sh
# Runs every bug regression test in tests/bugs/*/run.sh.
# A test exits 1 while its bug is present, 0 once fixed, 77 when skipped (missing prerequisite).
# Usage: tests/bugs/run-all.sh [slug...]
cd "$(dirname "$0")"
present=0; fixed=0; skipped=0; failed=0
for t in ${*:-*/}; do
    t="${t%/}"
    [ -x "$t/run.sh" ] || continue
    out="$("$t/run.sh" 2>&1)"; rc=$?
    case $rc in
        0) fixed=$((fixed+1)); echo "FIXED    $t";;
        1) present=$((present+1)); echo "PRESENT  $t";;
        77) skipped=$((skipped+1)); echo "SKIPPED  $t";;
        *) failed=$((failed+1)); echo "ERROR($rc) $t"; echo "$out" | tail -5 | sed 's/^/    /';;
    esac
done
echo "present=$present fixed=$fixed skipped=$skipped error=$failed"
