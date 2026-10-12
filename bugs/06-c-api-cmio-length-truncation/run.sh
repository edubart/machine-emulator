#!/bin/sh
# Builds and runs cmio-length-truncation.c against the in-tree libcartesi.
# Run from the repo root after sourcing bugs/env/env.sh: sh <this dir>/run.sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
gcc -std=c11 -Wall -Wextra -Werror -I src "$here/cmio-length-truncation.c" -L src -lcartesi -o "$out/t"
set +e
"$out/t"
