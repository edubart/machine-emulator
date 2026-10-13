# arm64 (aarch64 host) audit (angle: `arm64`)

Work dir: `<SCRATCH>/work/arm64/` (`<SCRATCH>` = `<SCRATCH>`)

Question: does a node operator running the emulator on an arm64 host compute the same thing as one on x86-64? I
built the emulator for aarch64 and ran deterministic workloads under `qemu-aarch64`, comparing everything against
the x86-64 build of the same tree (same uarch image).

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| ARM64-1 | Same JSON input gives a different machine on aarch64 and x86-64: `uint64` fields given as the double 2^64 (how JavaScript writes UINT64_MAX) become `0` on x86-64 and `UINT64_MAX` on aarch64. Root hashes differ, and over JSON-RPC `machine.run` halts on aarch64 but runs 0 cycles on x86-64 | PROVEN on a real aarch64 libcartesi/JSON-RPC build. Same root cause as **fp-J1** (`findings/fp.md`), which showed the aarch64 behaviour only by reading compiled code. This entry adds executed cross-host evidence | (as fp-J1: Medium) |
| ARM64-2 | Determinism between x86-64 and aarch64 (interpreter, uarch, step logs, uarch logs, collectors, proofs, hashers, stored machines, JSON-RPC, Lua CLI) | REJECTED (no divergence) | - |
| ARM64-3 | Host page size 64 KiB / 16 KiB (RHEL, Oracle Linux and Ampere arm64 kernels; Asahi) | REJECTED (no divergence, no failure) | - |
| ARM64-4 | Many-core arm64 servers (64 to 192 OpenMP threads for hash-tree updates) | REJECTED (no divergence) | - |
| ARM64-5 | Review of arm64-specific hazards (weak memory model, `char` signedness, float-to-int casts, integer divide by zero, shift and clz semantics, NEON lane counts, struct layout of stored files) | REJECTED (only the cast in ARM64-1 is a problem) | - |

---

### ARM64-1: Same JSON config or RPC request produces a different machine on aarch64 and x86-64 (executed evidence for fp-J1)
- Status: PROVEN (on real aarch64 builds of `libcartesi` and `cartesi-jsonrpc-machine`). **Duplicate of fp-J1**: same root cause and fix. Only the evidence is new.
- Area: C API / JSON-RPC (config and parameter parsing)
- Category: divergence between hosts (x86-64 vs arm64), input validation, undefined behaviour
- Where: `src/json-util.cpp:810-817` (`ju_get_opt_field<K>(..., uint64_t &value, ...)`, float branch:
  `f > static_cast<double>(UINT64_MAX)` lets f == 2^64 through, then `static_cast<uint64_t>(f)`). The uint32, uint16 and uint8
  variants go through this function. The int64 variant has the same flaw at 2^63 but has no int64 users.
- Problem: when a JSON integer field holds 2^64 written as a double (`18446744073709552000`, `1.8446744073709552e19`,
  what `JSON.stringify` writes for `2**64-1`), the out-of-range cast is UB. x86-64 GCC code (`cvttsd2si` with a
  2^63 bias) yields `0`, while aarch64 `fcvtzu` saturates to `0xffffffffffffffff`. The same request therefore
  creates a different machine, or runs a different number of cycles, depending on the host CPU.
- Scenario: a validator fleet with mixed x86-64 and arm64 hosts, or a Node.js/TypeScript client of
  `cartesi-jsonrpc-machine`, sends `mcycle_end = UINT64_MAX` ("run until halt or yield") or a config with
  `imcyclemax = UINT64_MAX`:
  - On x86-64 the server runs 0 cycles and answers `reached_target_mcycle`.
  - On arm64 the same server binary runs to halt.
  - A config containing such a value has a different initial root hash on the two hosts, so the template hash differs.
- Evidence: `<SCRATCH>/work/arm64/jsonfloat/run.sh` (exit 1 = reproduced; builds `jf.c` for both hosts and calls
  `<SCRATCH>/work/arm64/jsonrpc/rpc.sh` for the raw JSON-RPC requests). Output:
  ```
  -- x86-64 libcartesi:
  imcyclemax=0                        -> reg=0x0000000000000000 root=c488e5179d5e58c8
  imcyclemax=18446744073709551615     -> reg=0xffffffffffffffff root=e81b85100cd7cb2d
  imcyclemax=18446744073709552000     -> reg=0x0000000000000000 root=c488e5179d5e58c8
  imcyclemax=1.8446744073709552e19    -> reg=0x0000000000000000 root=c488e5179d5e58c8
  -- aarch64 libcartesi (qemu-aarch64):
  imcyclemax=0                        -> reg=0x0000000000000000 root=c488e5179d5e58c8
  imcyclemax=18446744073709551615     -> reg=0xffffffffffffffff root=e81b85100cd7cb2d
  imcyclemax=18446744073709552000     -> reg=0xffffffffffffffff root=e81b85100cd7cb2d
  imcyclemax=1.8446744073709552e19    -> reg=0xffffffffffffffff root=e81b85100cd7cb2d
  [x86] run(mcycle_end=1.8446744073709552e19): {"id":3,"jsonrpc":"2.0","result":"reached_target_mcycle"}
  [x86] read_reg(mcycle): {"id":4,"jsonrpc":"2.0","result":0}
  [arm] run(mcycle_end=1.8446744073709552e19): {"id":3,"jsonrpc":"2.0","result":"halted"}
  [arm] read_reg(mcycle): {"id":4,"jsonrpc":"2.0","result":97}
  BUG REPRODUCED: same machine config JSON -> different initial machine (root hash) on x86-64 vs aarch64
  BUG REPRODUCED: same machine.run request -> x86-64 server: result":"reached_target_mcycle, aarch64 server: result":"halted
  ```
- Possible solution: as in fp-J1. Reject `f >= 18446744073709551616.0` (2^64) and `f >= 9223372036854775808.0` (2^63)
  before casting, or reject floats for integer fields. Never compare against `static_cast<double>(UINT64_MAX)`, which
  rounds up to 2^64.
- Severity: Medium (as fp-J1). The behaviour depends on the host and is reachable with a common client encoding. Guest code
  cannot reach it, and stored machines are unaffected.
- Risks: the fix only turns inputs that are now UB into errors. Root hashes and the step format do not change.

---

### ARM64-2: Determinism campaign, x86-64 vs aarch64 (no divergence)
- Status: REJECTED (all results identical).
- Builds:
  - **aarch64:** copy of the git-tracked tree in `<SCRATCH>/work/arm64/tree`, built with
    `aarch64-linux-gnu-g++-14` (GCC 14.2) and the repo's default flags (`relwithdebinfo`: `-O2 -g`, the interpreter with
    `-DNDEBUG -fstrict-aliasing -fno-gcse ...`), `slirp=no`, header-only Boost, and Lua 5.4.6 built from lua.org sources.
    It uses the **same generated uarch image** as the x86 build (`uarch/uarch-pristine-{ram,hash}.c` copied from the repo).
    The build produced no warnings. On aarch64 the generic hasher paths run with NEON lane counts
    (keccak 2 lanes, sha256 4 lanes) and no AVX multiversioning.
  - **x86-64:** the repo's release build (`/home/user/machine-emulator/src`, AVX-512 hashers).
  - Rebuild with `<SCRATCH>/work/arm64/build.sh`.
  - Harness `<SCRATCH>/work/arm64/harness/ah.c`, compiled for both hosts (`ah_x86`, `ah_arm`). Modes:
    `run`, `cmp`, `slog` (log_step+verify_step), `ulog` (log_step_uarch/log_reset_uarch+verify, JSON dumped),
    `coll`, `ucoll`, `store`, `load`, `hash`, `proof`, `vstep`, `vulog` (verify a log produced on the other host).
  - aarch64 binaries run with `qemu-aarch64` (QEMU 8.2.2), `QEMU_LD_PREFIX=/usr/aarch64-linux-gnu`.
- Results (all identical between the two hosts):
  1. Hash primitives: `cm_get_hash` and `cm_get_concat_hash` for keccak256 and sha256 over every length 0..1100 at
     unaligned offsets, plus 4095/4096/4097/64 KiB/1 MiB: same digests.
  2. All 266 `tests/build/machine` configs (2.15M mcycles in total), `cm_run` to halt: same final
     mcycle, tohost, pc, icycleinstret and root hash. `cm_log_step` over **each whole test** (count = test cycles):
     the step-log files are **byte-identical** (same SHA-256) and `cm_verify_step` accepts them on both hosts
     (`results/{x86,arm}/run.txt`, `slog.txt`).
  3. Official runner `tests/lua/cartesi-machine-tests.lua`, run with aarch64 Lua 5.4.6 and the aarch64 `cartesi.so`:
     - `hash --periodic-action=97` on 16 tests: root hash every 97 **uarch** cycles, 43,049 hashes over about 4.2M uarch cycles.
       The output files are byte-identical to x86-64.
     - `run_host_and_uarch` (host interpreter vs uarch, compared after every mcycle) passes all 16 on both hosts.
     - The tests are access, amo, clint_ops, compressed, csr_counters, csr_semantics, dont_write_x0, ebreak, fclass,
       htif_invalid_ops, illegal_insn, lrsc_semantics, mcycle_write, pte_reserved_exception, sd_pma_overflow and shadow_ops.
     - `run` / `run_step` (keccak and sha256) over all 267 tests: the output files are **byte-identical** to x86-64 (`run`: same 107 'failures', all from the known mcycle+3 toolchain baseline; `run_step` keccak and sha256: PASSED all 267 on both hosts)
     - Lua spec suites (`tests/lua/spec-*.lua`) on aarch64 give the same pass/fail counts as on x86-64: json 19/19, hash-functions 8/8,
       fuzzer-bugs 21/21, hash-tree-lua 49/49, util 7/7, machine-api 33/33 (local and remote), verify-step-failure 48/48,
       backing-stores 19/19, hash-tree 24/24, verify-uarch-failure 65 pass / 7 fail.
       - The 7 verify-uarch-failure failures also happen on x86-64: the local tree lacks `tests/build/uarch/rv64ui-uarch-ecall-write-tlb.bin`.
       - runtime-console passes 32/32 on aarch64. Its posix-dependent cases are skipped there because luaposix is not
         built for aarch64 Lua; x86-64 passes 37 and fails 1 (no TTY).
       - collect-hashes was not run on aarch64 because it takes more than 20 minutes even on x86-64.
       - For the remote cases, the aarch64 library spawned the aarch64 server under qemu through `CARTESI_JSONRPC_MACHINE`
         (`<SCRATCH>/work/arm64/arm-jsonrpc-server.sh`).
  4. Linux (`linux.bin` + `rootfs.ext2`, 128 MiB RAM). Four workloads run to halt, with the root hash every 5M cycles:
     - `echo hello`: 57.4M cycles
     - awk floating-point loop, keccak tree: 84.5M cycles
     - the same awk loop, sha256 tree: 84.5M cycles
     - whetstone, dhrystone and `tar|gzip|sha256sum`: 71.6M cycles

     All 65 root hashes (61 periodic checkpoints and 4 final) are identical. The aarch64 Lua CLI
     (`cartesi-machine.lua --initial-hash --final-hash -- "echo hello; uname -m"`) prints the same initial hash
     (`0xcaa0e7ea...`) and final hash (`58200135: 0x58d7b1f8...`) as the x86-64 CLI.
  5. Step logs inside Linux: `cm_log_step` windows (sha256 tree at 10M for 1000 cycles; keccak at 31M for 100 cycles; bench at 45M for 5000 cycles)
     are byte-identical. **Cross-verification:** x86-64-made logs verify on aarch64 and aarch64-made logs verify on x86-64,
     with the same obtained hash.
  6. Uarch access logs (annotations + large data): 600 `log_step_uarch` calls from Linux mcycle 20M
     (they complete that mcycle's instruction, so mcycle reaches 20000001) and 400 from 33M. The JSON is **byte-identical** (15.3 MB and 10.2 MB), every entry verifies on its
     own host, and the whole chain verifies on the other host (`results/{x86,arm}/extra/xverify.txt`).
  7. Collectors give identical JSON (SHA-256 of the result):
     - `cm_collect_mcycle_root_hashes` over a whole Linux boot (period 2^20, no bundling) and the sha256 awk run (period 2^22, bundle 2^3)
     - `cm_collect_uarch_cycle_root_hashes` over 3 Linux mcycles (no bundling) and 2 mcycles (bundle 2^4)
  8. `cm_get_proof` and `cm_get_node_hash` at 7 addresses x 5 sizes on a Linux machine at 40M: identical.
  9. Stored machines: a Linux machine stored at 20M (`CM_SHARING_ALL`, 385 MB) on x86-64 and on aarch64 produced
     **byte-identical directories** (all `.bin/.dht/.dpt`, `hash_tree.sht`, `hash_tree.phtc`, `config.json`). Each
     host loads the other's directory with `verify_hash_tree` true and the same root hash. Running on to 30M
     gives the same checkpoints as an uninterrupted run.
  10. JSON-RPC: the x86-64 Lua CLI drove the aarch64 `cartesi-jsonrpc-machine` (`--remote-address`) through a full
      Linux boot and got the same initial and final hashes as a local x86-64 run. Apart from ARM64-1, raw requests gave
      identical responses.
- Limits of the method:
  - qemu-user runs on an x86 host (TSO), so arm64 weak memory ordering is not exercised; see ARM64-5.
  - Performance was not measured.
  - macOS arm64 was not built: different page size, no OpenMP by default, clang.

---

### ARM64-3: 64 KiB and 16 KiB host pages (no divergence, no failure)
- Status: REJECTED.
- Why it matters: RHEL, Oracle Linux and some Ampere/NVIDIA arm64 kernels use 64 KiB pages, and Asahi Linux uses
  16 KiB. `os-mapped-memory.cpp` handles the host page size (`sysconf(_SC_PAGESIZE)`, at least 4096) when it maps
  a backing file shorter than its range: anonymous map + `MAP_FIXED` file map + zero-fill of the partial page.
  The test images exercise that path with non-aligned sizes:
  - `linux.bin` is 19,653,304 bytes (`% 4096 = 696`, `% 65536 = 58040`).
  - `rootfs.ext2` is a multiple of 4 KiB but not of 64 KiB (`% 65536 = 4096`).
- Method: the aarch64 harness under `qemu-aarch64 -p 65536` and `-p 16384`. `sysconf` and the mmap granularity
  follow the emulated page size; checked with `<SCRATCH>/work/arm64/pg/pg.c`. Runs:
  - all 266 machine tests
  - the Linux bench workload to halt, with checkpoints every 5M cycles
  - store of a Linux machine at 20M, then reload and run to 30M
  - load of the **x86-64-stored** machine, then run to 30M
- Result: everything is identical to the x86-64 4 KiB-page results (`results/arm/extra/pg{65536,16384}_*.txt`).
  Code review agrees: every `mmap` length/offset is page-size agnostic, offsets are always 0, and the partial-page
  zeroing uses the runtime page size. The emulator's dirty tracking works at 4 KiB granularity in software, not
  through host page protections.

### ARM64-4: many-core arm64 hosts (no divergence)
- Status: REJECTED.
- Why it matters: arm64 servers commonly expose 64 to 192 cores (Graviton4: 96, Ampere Altra: 80-128,
  AmpereOne: 192). The hash-tree update concurrency defaults to `omp_get_max_threads()` (`hash-tree.cpp:903`),
  and the batch and block sizes depend on it and on the NEON lane count.
- Method: the Linux awk workload (keccak) to halt under `OMP_NUM_THREADS` and
  `concurrency.update_hash_tree` = 1, 64 and 192. 65 and 193 threads were observed in the qemu process.
- Result: all 18 checkpoints match x86-64 for every thread count (`results/arm/extra/omp_awk_{1,64,192}.txt`).

### ARM64-5: review of arm64-specific hazards (no new finding)
- Status: REJECTED (apart from the cast in ARM64-1).
- **Weak memory ordering** (cannot be exercised by qemu-user on an x86 TSO host, so reviewed instead):
  - `src/` has no `std::atomic`, `__atomic`, `__sync`, `memory_order`, `volatile` synchronisation or lock-free
    structure.
  - The only multi-threaded code is the two OpenMP `parallel for` loops in `hash-tree.cpp` (`:283`, `:435`). Each
    iteration writes only its own borrowed page-cache entries, dense-tree nodes and per-thread SIMD queue, and the
    counters are OpenMP reductions. `page_hash_tree_cache::enqueue_hash_entry` touches only the entry passed in plus
    read-only pristine data. The implicit barrier at the end of each region gives the needed ordering on any
    architecture.
  - The JSON-RPC server runs a single-threaded `io_context`.
  - So nothing relies on x86-TSO. (CONC-5, unsynchronised concurrent const C-API calls, is a data race on every
    architecture; on arm64 its effects may differ, but the fix is the same.)
- **`char` signedness** (unsigned on aarch64): base64 and hex decoding index their tables with `uint8_t`. JSON
  parsing is nlohmann's. The only signedness-dependent call is `isprint(str[i])` in a debug printer (`clua.cpp:66`).
- **Float-to-integer casts**:
  - The only host casts of untrusted floats are in `json-util.cpp`, i.e. ARM64-1.
  - Lua integers go through `lua_tointegerx`/`luaL_checkinteger`, which check the range.
  - `std::fmod` is exact.
  - nlohmann parses numbers identically on both hosts.
- **Integer divide by zero / `INT64_MIN / -1`** (x86 traps, arm64 returns 0 or saturates):
  - The RISC-V DIV/REM paths guard both cases. The rv64um tests give identical results, and so do the
    random-program FP/ALU checks of other angles.
  - Host divisions by API-controlled values have divisors that are constants, powers of two from `bit_ceil`, or
    validated `1 << log2_mcycle_period` (checked `< 64`).
- **Shifts by register / `clz(0)`**:
  - Variable 64-bit shifts mask the count mod 64 on both ISAs.
  - Keccak and SHA rotations use constant amounts in 1..63.
  - All `__builtin_clz`/`ctz` calls are guarded (portability agent, clang `-fsanitize=builtin`).
- **SIMD**: the generic hasher code uses GCC vector extensions. On aarch64 it runs with 2 keccak lanes and 4 sha256
  lanes (NEON) instead of 8 and 16 (AVX-512). Results are identical on every workload in ARM64-2.
- **On-disk formats**: stored machines, `hash_tree.sht` and `hash_tree.phtc` are byte-identical between hosts
  (ARM64-2 item 9). Both are LP64 little-endian, and the entry layouts are static_asserted fixed-size `uint64_t` fields.

## Coverage summary / negative results
- Machine tests: 266/266 identical final state. 266/266 whole-test step logs byte-identical and accepted on both hosts.
- Linux:
  - 4 workloads, 65 root-hash checkpoints, identical.
  - Step logs byte-identical and cross-verified in both directions.
  - Uarch logs (1000 steps) byte-identical and cross-verified in both directions.
  - Official runner: `hash` gives identical root hashes every 97 uarch cycles (43k hashes); `run`, `run_step` (keccak) and `run_step` (sha256) outputs are byte-identical.
  - Lua spec suites: same pass/fail counts on both hosts.
  - Collectors and proofs identical.
  - Stored machine directories byte-identical and cross-loadable.
- JSON-RPC: the aarch64 server driven by the x86-64 Lua CLI gives identical hashes. Raw requests match except ARM64-1.
- 64 KiB / 16 KiB pages and 1/64/192 hash-tree threads: identical.
- Build: the aarch64 GCC 14.2 cross build of the full tree (libcartesi, JSON-RPC server, Lua bindings) compiles
  without a single warning, with `slirp=no`.

## How to reproduce (all under `<SCRATCH>/work/arm64/`)
- `build.sh`: copies the tracked tree, builds the aarch64 libraries, server, Lua bindings, Lua 5.4.6 and both harness binaries.
- `run_tests.sh {x86|arm}`: 266 machine tests, `run` + whole-test `slog`. Output in `results/<arch>/run.txt` and `slog.txt`.
- `linux_steps.sh {x86|arm}`: Linux step logs, uarch logs, collectors and proofs. Output in `results/<arch>/linux/steps.txt`.
- `arm_jobs.sh`, `arm_jobs2.sh`, `arm_final.sh`: aarch64 Linux checkpoints, cross verification, OpenMP thread
  counts, 64 KiB/16 KiB pages, store/load. Output in `results/arm/extra/`. x86 side: `results/x86/extra/xverify.txt`.
- `runner_subset2.sh {x86|arm} {hash|all}` and `arm_runner_more.sh`: official runner. Output in `results/<arch>/runner/`.
- `specs.sh {x86|arm} <suite...>`: Lua spec suites. Output in `results/<arch>/specs/`.
- `jsonfloat/run.sh`: ARM64-1 reproducer (exit 1 = reproduced).
- `armlua.sh`: runs aarch64 Lua with the aarch64 cartesi modules under qemu. Example:
  `cd tree/src && ../../armlua.sh ./cartesi-machine.lua --ram-image=... -- "echo hello"`.
- Stored Linux machines and uarch JSON logs (about 1 GB) were deleted after use. The scripts regenerate them.
