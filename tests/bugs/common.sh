#!/bin/sh
# Common environment for the bug regression tests in tests/bugs/.
# Each test sources this file, builds its reproducer into a temporary directory and runs it.
# Convention: a test prints "BUG REPRODUCED: ..." and exits 1 while the bug is present,
# prints "OK: ..." and exits 0 once it is fixed. Exit 77 means "skipped" (missing prerequisite).
set -e
BUGS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$BUGS_DIR/../.." && pwd)"
SRC_DIR="${CARTESI_SRC_DIR:-$REPO_DIR/src}"
IMAGES_DIR="${CARTESI_IMAGES_PATH:-$REPO_DIR/tests/build/images}"
export LD_LIBRARY_PATH="$SRC_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LUA_PATH_5_4="$SRC_DIR/?.lua;$REPO_DIR/tests/lua/?.lua;;"
export LUA_CPATH_5_4="$SRC_DIR/?.so;;"
CC="${CC:-gcc}"
CXX="${CXX:-g++}"
RISCV_PREFIX="${RISCV_PREFIX:-riscv64-unknown-elf-}"
LUA="${LUA:-lua5.4}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cm-bug-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"

skip() { echo "SKIP: $*"; exit 77; }
need_lib() { [ -f "$SRC_DIR/libcartesi.so" ] || skip "build the emulator first (make)"; }
need_riscv() { command -v "${RISCV_PREFIX}gcc" >/dev/null 2>&1 || skip "missing ${RISCV_PREFIX}gcc"; }
need_images() { [ -f "$IMAGES_DIR/linux.bin" ] && [ -f "$IMAGES_DIR/rootfs.ext2" ] || skip "missing test images (make -C tests images)"; }

# Build a C program against libcartesi
build_c() { # out src...
    out="$1"; shift
    "$CC" -std=gnu11 -O1 -g -I"$SRC_DIR" "$@" -o "$WORK_DIR/$out" -L"$SRC_DIR" -lcartesi -lcartesi_jsonrpc -Wl,-rpath,"$SRC_DIR"
}
# Build a C++ program against the static library (for tests that use internal headers)
build_cxx_static() { # out src...
    out="$1"; shift
    "$CXX" -std=gnu++23 -O1 -g -fno-strict-aliasing -fno-strict-overflow -I"$SRC_DIR" -I"$REPO_DIR/third-party/ankerl" \
        -I"$REPO_DIR/third-party/llvm-flang-uint128" -I"$REPO_DIR/third-party/nlohmann-json" -D_FILE_OFFSET_BITS=64 \
        "$@" -o "$WORK_DIR/$out" "$SRC_DIR/libcartesi.a" -lslirp -fopenmp
}
# Assemble a bare-metal RISC-V program linked at 0x80000000 into a raw binary
build_rv() { # out.bin src...
    out="$1"; shift
    "${RISCV_PREFIX}gcc" -march=rv64gc -mabi=lp64d -nostdlib -nostartfiles -static -Wl,-Ttext=0x80000000 \
        -Wl,--no-warn-rwx-segments "$@" -o "$WORK_DIR/${out%.bin}.elf"
    "${RISCV_PREFIX}objcopy" -O binary "$WORK_DIR/${out%.bin}.elf" "$WORK_DIR/$out"
}
