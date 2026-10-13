#!/bin/sh
# `const` C API hash queries (cm_get_root_hash / cm_get_node_hash / cm_get_proof) are not thread-safe on one machine: concurrent const queries race and produce spurious errors or heap-corruption aborts
# Expected: exits 1 and prints "BUG REPRODUCED: ..." while the bug is present; exits 0 and prints "OK: ..." once fixed.
. "$(dirname "$0")/../common.sh"
need_lib
set +e

# Root cause: machine::update_hash_tree() const runs before every get_root_hash/get_node_hash/get_proof
# and mutates `mutable` members (the dirty-page trees, the page-hash-tree-cache LRU and its `borrowed`
# flags, the unordered_map index, and a std::pmr::unsynchronized_pool_resource) with no lock. The const
# signatures invite bindings to treat these as concurrent-safe readers.
#
# repro.c runs several forked trials: a monitor thread polls cm_get_root_hash while a worker asks for
# word-level cm_get_node_hash on ONE idle machine, with no external synchronization. Any spurious error,
# wrong result, or crash/abort in a trial == the race (BUG REPRODUCED). A fixed library (an internal
# per-machine lock around the update+read) makes the unsynchronized calls safe -> all trials clean (OK).
# The "locked" control (pass as an argument) serializes every call with an external mutex and must be
# clean; the default run below is the unsynchronized reproducer. Each trial is a short forked child that
# main reaps; runtime is a few seconds, bounded by the outer timeout.
build_c repro "$TEST_DIR/repro.c" -pthread || { echo "failed to build reproducer"; exit 2; }

timeout 120 "$WORK_DIR/repro"
rc=$?
case $rc in
    0) echo "OK: concurrent const queries on one machine were race-free"; exit 0;;
    1) exit 1;;                                   # repro already printed BUG REPRODUCED
    124|137) echo "BUG REPRODUCED: concurrent const queries hung (timeout)"; exit 1;;
    *) echo "test harness error (exit $rc)"; exit 2;;
esac
