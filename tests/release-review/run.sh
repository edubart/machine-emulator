#!/usr/bin/env bash
# Copyright Cartesi and individual authors (see AUTHORS)
# SPDX-License-Identifier: LGPL-3.0-or-later

set -euo pipefail
REVIEW_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export LUA_PATH_5_4="$REVIEW_REPO/src/?.lua;$REVIEW_REPO/tests/lua/?.lua;${LUA_PATH_5_4:-;;}"
export LUA_CPATH_5_4="$REVIEW_REPO/src/?.so;${LUA_CPATH_5_4:-;;}"
export LD_LIBRARY_PATH="$REVIEW_REPO/src${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
REVIEW_LUA="${LUA_BIN:-lua5.4}"

for REVIEW_CASE in bundle-equivalence uarch-direct forest-differential forest-high-boundary \
    cache-persistence console-bundle-oracle frontier-array-padding; do
    "$REVIEW_LUA" "$REVIEW_REPO/tests/release-review/$REVIEW_CASE.lua"
done
