# Portability / UB audit (angle: `portability`)

Work dir: `<SCRATCH>/work/portability/` (`<SCRATCH>` = `<SCRATCH>`)

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| PORTABILITY-1 | `require()` in Solidity-converted `uarch-step.cpp` is a C `assert`: a crafted uarch step log aborts any verifier process (and kills `cartesi-jsonrpc-machine`) in the default/packaged build, is ACCEPTED by a `release=yes` build, and is rejected by Solidity | PROVEN (same root cause as ASSERTS-1, found independently) | High |
| PORTABILITY-2 | RISC Zero guest wraps `mcycle_end` (dup of STEP-PROOF-2 / COORD-1): re-confirmed with the real guest code compiled for rv32im/ilp32 | DUPLICATE (extra evidence) | (Medium, see STEP-PROOF-2) |
| PORTABILITY-5 | Host SIGSEGV in the fast store path through a WRITE-TLB slot to a non-writable range (dup of DYNAMIC-1): hit by a cross-path differential fuzzer within 400 files of the project's own seed corpus | DUPLICATE (extra evidence) | (see DYNAMIC-1) |
| PORTABILITY-3 | Cross-compiler / cross-flag / cross-target differential campaign (GCC vs Clang, -O0/-O2/-O3, strict aliasing/overflow on, `AVOID_NATIVE_UINT128_T`, `-funsigned-char`, no multiversioning, switch dispatch (WASM path), SIMD lane counts 1/2/4/8/16, hash-tree thread counts, rv32im RISC Zero replay, uarch) | REJECTED (no divergence found) | - |
| PORTABILITY-4 | UB scans: GCC ASan+UBSan, sanitized native ZK replay, valgrind memcheck, native-vs-emulated `uint128` fuzz | REJECTED (no UB found on deterministic paths) | - |

---

### PORTABILITY-1: `require()` in the Solidity-converted uarch step is an `assert`: crafted log aborts the verifier (default build), is accepted by `release=yes` builds, and reverts on-chain
- Status: PROVEN. Same root cause and conclusion as ASSERTS-1 (`findings/asserts.md`), found independently from the NDEBUG/target-flag angle; the coordinator should merge them. Extra evidence here: the crafted log is recorded by a `-DNDEBUG` uarch-step build at a misaligned pc (0x60e0da) whose bits decode to a legal `addi` in the stock uarch image (no custom image needed), and the same log is accepted by the NDEBUG verifier.
- Area: uarch / step-log (uarch access-log verification) / JSON-RPC
- Category: divergence (build-flag dependent semantics), DoS / crash reachable by untrusted logs, proof-soundness between C++ builds and Solidity
- Where: `src/uarch-solidity-compat.hpp:251-254` (`template <...> void require(T1 condition, T2 message) { assert((condition) && (message)); }`),
  used by `src/uarch-step.cpp:38,44,53,70,81,89,100` (`readUint64/readUint32/readUint16/writeUint64/copyBits/writeUint32/writeUint16`);
  build flags: `src/Makefile:209-215` (default `relwithdebinfo` puts `-DNDEBUG` only on `interpret.cpp`; `release=yes` puts `-DNDEBUG` on everything). The Dockerfile/Debian package builds the default (`Dockerfile:64`), so packaged binaries keep the assert.
- Problem: `uarch-step.cpp` is the C++ reference of the on-chain (Solidity) uarch step. In Solidity `require(cond, msg)` reverts the step (a clean "invalid" result). In C++ the shim maps it to `assert`, so the behaviour depends on how the library was compiled:
  1. default / packaged / debug / sanitize builds: `assert` fails -> `abort()` -> the whole process dies (SIGABRT). This happens in every API that executes `uarch_step` (verified: `cm_verify_step_uarch`, `cm_log_step_uarch`, `cm_run_uarch`, and `verify_step_uarch` over JSON-RPC; `cm_collect_uarch_cycle_root_hashes` uses the same `uarch_step`). The check is evaluated before any memory read, right after the logged `pc` read, so the attacker only has to provide 3 valid accesses (cycle, halt, pc) for a state of their choosing.
  2. `release=yes` (`-DNDEBUG`) builds: the check disappears; `readUint32` silently reads the aligned-down 64-bit word and shifts it, executes whatever instruction falls out, and `cm_verify_step_uarch` returns OK (likewise a misaligned `writeUint32` at byte offset 6 silently skips the `copyBits` bound check and writes only 16 bits).
  3. Solidity: reverts.
  So three implementations that must agree produce three different results (crash / accept / reject) for the same (root_hash_before, log).
- Scenario: (a) Any service that verifies uarch step logs it did not produce (a node checking the opponent's proof off-chain before posting a transaction, a shared/remote `cartesi-jsonrpc-machine`, a "verifier" microservice) can be killed by one request: the attacker builds a state whose uarch `pc` (or a load/store address computed from uarch registers) is misaligned, records a log for it with a `release=yes` build (or writes the JSON by hand), and submits `(root_hash_before, log)`. Every verifier built the default way aborts. (b) A node that runs a `release=yes` build accepts as valid a uarch transition that the on-chain Solidity step rejects, i.e. off-chain and on-chain verifiers disagree on validity. (c) API misuse (`cm_write_reg(UARCH_PC, odd)` then `cm_run_uarch`/`cm_log_step_uarch`) kills the process instead of returning an error. The state is not reachable by honest guest execution (the uarch binary is built with `-mstrict-align`), so the impact is DoS and verifier inconsistency rather than a wrong honest result.
- Evidence: `<SCRATCH>/work/portability/uarchpc/run.sh` (crafted log `crafted-uarch-log.json` + `crafted-root-hash.txt`, recorded by `mklog.c` linked against a library whose `uarch-step.o` was compiled with `-DNDEBUG` (`<SCRATCH>/work/portability/v/ndebug`), for a machine whose uarch pc was set to 0x60e0da = misaligned pc whose 32 bits decode to a legal `addi`; `REGEN=1 ./run.sh` regenerates it). Output:
  ```
  == 1) local cm_verify_step_uarch (default libcartesi build) ==
  calling cm_verify_step_uarch on untrusted log...
  verify: uarch-solidity-compat.hpp:253: void cartesi::require(T1, T2) [with T1 = bool; T2 = const char*]: Assertion `(condition) && (message)' failed.
  exit code 134
  BUG REPRODUCED: verifier process aborted on untrusted log
  == 2) remote verify_step_uarch on cartesi-jsonrpc-machine ==
  server version: {"build":"","major":0,"minor":8,"patch":0,"pre_release":""}
  remote verify_step_uarch returned -6 (jsonrpc error: post error contacting 127.0.0.1:50642 (end of stream ...))
  BUG REPRODUCED: JSON-RPC server died:
  cartesi-jsonrpc-machine: uarch-solidity-compat.hpp:253: void cartesi::require(T1, T2) [...]: Assertion `(condition) && (message)' failed.
  == 3) same log, -DNDEBUG (release=yes) uarch-step.o ==
  calling cm_verify_step_uarch on untrusted log...
  cm_verify_step_uarch returned 0 (ok)
  ```
  Also `<SCRATCH>/work/portability/uarchpc/t.c` (`./t run` / `./t log`): `cm_write_reg(CM_REG_UARCH_PC, 0x600002)` + `cm_run_uarch` or `cm_log_step_uarch` -> `Assertion ... failed`, exit 134.
- Possible solution: make `require` match Solidity in every build, e.g.
  ```cpp
  template <typename UarchState, typename T2>
  static inline void require(bool condition, T2 message) {
      if (!condition) [[unlikely]] { throw std::runtime_error(message); }   // == revert
  }
  ```
  (the C++ uarch interpreter already reports `throwRuntimeError` for ebreak/illegal instruction, so callers already handle exceptions; `uarch_interpret`/`verify_step_uarch` then fail cleanly with an error code). Do the same for any other assert that guards data coming from logs. Never let `NDEBUG` change the accept/reject decision of a verifier.
- Severity: High - untrusted step log crashes the verifier process / JSON-RPC server in the packaged build, and `release=yes` builds accept a uarch step that the on-chain Solidity verifier rejects.
- Risks: if left, any remote verification endpoint is a one-request DoS, and off-chain/on-chain uarch verifiers disagree depending on build flags. The fix does not change any root hash nor the uarch image (it only touches host C++); it turns the abort into an error identical to a Solidity revert.

---

### PORTABILITY-2: RISC Zero replay wraps `mcycle_end` (DUPLICATE of STEP-PROOF-2 / COORD-1, extra evidence)
- Status: DUPLICATE (independent re-proof with the real guest code, both natively and as rv32im)
- Where: `risc0/cpp/risc0-replay-steps.cpp:38` vs `src/machine.cpp:2179,2206`.
- Extra evidence: `<SCRATCH>/work/portability/zkhost/run.sh` builds the unmodified `risc0/cpp/risc0-replay-steps.cpp` + `interpret.cpp` with the exact `risc0/cpp/Makefile` defines (`-DZKARCHITECTURE -DNO_STD_VECTOR -DAVOID_NATIVE_UINT128_T`, ZK shim with SHA-256 like `methods/guest/src/main.rs`). With initial mcycle 2^64-10 and mcycle_count 20: host `cm_verify_step` accepts the honest log and rejects the forged (after==before) log; the ZK guest rejects the honest log (`final root hash mismatch`) and accepts the forged one -> `BUG REPRODUCED`. The same guest code compiled for rv32im/ilp32 (see PORTABILITY-3, `<SCRATCH>/work/portability/rv32/`) behaves identically.

---

### PORTABILITY-5: Host SIGSEGV through a WRITE-TLB slot that targets a non-writable memory range (DUPLICATE of DYNAMIC-1)
- Status: DUPLICATE (extra evidence)
- Where: `src/shadow-tlb.hpp` (`shadow_tlb_verify_slot` does not check the access permission of the set), `src/interpret.cpp:1173` (`write_virtual_memory` fast path) -> `state-access.hpp:480`.
- Extra evidence: `<SCRATCH>/work/portability/fuzzx/fuzz-cross.cpp` is the project's `tests/fuzz/fuzz-interpret-step.cpp` with the per-cycle loop replaced by: (1) one big `cm_run` to mcycle+2000, (2) `cm_run_uarch`+`reset_uarch` per mcycle, (3) `cm_run` one mcycle at a time, (4) one `cm_log_step` over all cycles + `cm_verify_step`; all four root hashes must match. Run over 400 files of `tests/fuzz/seed-corpus` (`./fuzz-cross -runs=0 ../fuzz/seeds`), it crashed on `crash-53671679624243069f3171ae9d97a628c31d523c`:
  ```
  ==4791==ERROR: AddressSanitizer: SEGV on unknown address 0x7f5e1fa830d8 ... The signal is caused by a WRITE memory access.
    #0 aliased_aligned_write<unsigned long> strict-aliasing.hpp:32
    #2 state_access::do_write_memory_word state-access.hpp:480
    #4 write_virtual_memory<unsigned long, state_access> interpret.cpp:1173
    #6 execute_C_SDSP interpret.cpp:5503
    #10 machine::run machine.cpp:2221  /  #12 cm_run cm.cpp:737
  ```
  Reproduce: `cd <SCRATCH>/work/portability/fuzzx && ./fuzz-cross crash-53671679624243069f3171ae9d97a628c31d523c` (or `fuzz-cross-asan` for the ASan report). `fuzz-cross2` drops TLB slots whose PMA lacks the R/W/X permission of their set and passes on the same input.

---

### PORTABILITY-3: cross-compiler / cross-flag / cross-target differential campaign (no divergence found)
- Status: REJECTED (no divergence; reported as coverage)
- Builds (own copies under `<SCRATCH>/work/portability/v/*`, harness `<SCRATCH>/work/portability/harness/hh.c`, `run` mode = cm_run + root hash, `cmp` mode = cm_run vs cm_run_uarch+reset_uarch every mcycle):
  - `rel`: the repo's release build (GCC 14 -O2, `-fstrict-aliasing` on interpret.cpp, AVX-512 multiversioned hashers: keccak 8 lanes / sha256 16 lanes)
  - `clang`: full clang-18 build (default flags)
  - `clangsw`: clang -O3 + `-DNO_COMPUTED_GOTO` (switch dispatch with `__builtin_unreachable` default = the WebAssembly code path)
  - `o3strict`: GCC -O3 with strict aliasing, strict overflow and null-pointer-check deletion enabled (no UBCFLAGS)
  - `o0`: GCC -O0 for interpret/uarch/hash objects
  - `misc`: `-DAVOID_NATIVE_UINT128_T=1 -DNO_MULTIVERSIONING -funsigned-char` (emulated Int128 like uarch/risc0, generic hashers: keccak 2 lanes / sha 4 lanes, ARM/RISC-V-like unsigned `char`)
  - `lanes1`, `lanes4`: generic hashers forced to 1 lane (keccak/sha) and 4/8 lanes (AVX2-host lane counts, never exercised on this AVX-512 host)
  - hash-tree concurrency 1/3/16 threads (`concurrency.update_hash_tree`, `OMP_NUM_THREADS=16`)
  - uarch (rv64i, `-DMICROARCHITECTURE -DAVOID_NATIVE_UINT128_T`, GCC 13) via `cmp` mode
  - RISC Zero guest code (`ZKARCHITECTURE`) compiled natively (`zkhost/zkreplay`) and compiled for **rv32im/ilp32** with `riscv64-unknown-elf-g++ -march=rv32im -mabi=ilp32 -mstrict-align` (flags of `risc0/cpp/Makefile`) running on a purpose-written RV32IM ISS (`<SCRATCH>/work/portability/rv32/iss.c`, `guest.elf`), compared against host `cm_log_step`/`cm_verify_step` (sha256 trees).
- Workloads: 266 `tests/build/machine` configs; 300 random RV64GC programs (`rand/genprog.py`: M/A/F/D incl. special FP operands, all rounding modes, fcsr ops, AMO/LR/SC, loads/stores, traps); 120 random S-mode programs (`rand/genprog2.py`: Sv39 paging, M-mode trap handler, CLINT timer/MSIP interrupts, compressed insns, S CSRs, sfence.vma, wfi, ecall); Linux boot + `awk` FP workload (84M cycles, hash every 10M) and `tar|gzip|sha256sum` (71M cycles), keccak and sha256 trees.
- Results: all root hashes identical across `rel/clang/clangsw/o3strict/o0/misc/lanes1/lanes4` and thread counts (266 tests + 300 random v1 + 120 random v2 programs + Linux checkpoints every 10M cycles); cm_run vs uarch identical for all 300 v1 and 120 v2 programs; host `verify_step` vs native ZK replay vs rv32im ZK replay identical for 401 windows (40 random programs x 3 windows, 266 tests, 15 Linux windows of 1/1000/100000 cycles at 1M..60M; rv32 path added for the later part) + 220 more windows checked on the rv32 path (120 random + 100 tests) + 180 windows of the v2 (S-mode/paging/interrupt) programs on all three verifiers. rv32 replay performs 0 misaligned accesses when the log buffer is >= 4-byte aligned (risc0's bump allocator guarantees word alignment); with a 1- or 2-byte aligned buffer it would do ~30k misaligned word loads per Linux step (not reachable with risc0's allocator, noted only).
- Further invariance checks (all identical): page-hash-tree cache size `phtc_size` 1/2/3/64 vs default (Linux awk, all 10M checkpoints); interpreter chunking (`cm_run` 1 mcycle at a time, random 1..997-cycle chunks, and one single call; Linux awk + bench end hashes and all random programs); `cm_log_step` files are byte-identical between GCC/clang/-O3-strict builds (sha256 Linux window + random programs) and verify on every build; uarch access logs (3000 `log_step_uarch`/`log_reset_uarch` with proofs, 76 MB of JSON) have the same FNV hash in the `rel`, `clang`, `o0` and `misc` builds; worst-case uarch cycles per big-machine cycle observed 20,710 (far from `UARCH_CYCLE_MAX` = 2^20-1, uarch stack has 1.39 MB of headroom), so compiler-dependent uarch code size/speed cannot push an mcycle into uarch cycle overflow.
- Evidence: `<SCRATCH>/work/portability/results/*/` (per-variant hash lists), `zkhost/zkbatch*.txt`, `runvariant.sh`, `runlinux.sh`, `runlanes.sh`, `run_v2.sh`, `zkhost/zkdiff.sh`, `harness/chunk.c`, `harness/ulog.c`, `harness/hhmax.c`, `quick_matrix.sh` (re-runs a subset of the matrix with the built harnesses).

### PORTABILITY-4: UB / uninitialized-memory scans (no finding)
- Status: REJECTED (nothing found on deterministic paths)
- GCC ASan+UBSan build (`<SCRATCH>/asan`, `-O1`, no `-fno-strict-overflow`, `_GLIBCXX_ASSERTIONS`): 266 tests + 150 random programs in run mode, tests/random in cmp (uarch C++ interpreter) mode: no runtime error.
- Sanitized native ZK replay (`<SCRATCH>/work/portability/zkasan`, ZKARCHITECTURE code path, ASan+UBSan+`_GLIBCXX_ASSERTIONS`): 80 random-program logs, 266 test logs, 6 Linux logs: no report.
- Clang-18 ASan+UBSan (+`-fsanitize=builtin` for `__builtin_clz/ctz(0)`, `float-divide-by-zero`, `local-bounds`) build of libcartesi (`<SCRATCH>/work/portability/v/clangsan`): 266 tests + 100 random v1 + 60 random v2 programs: no report.
- libFuzzer `tests/fuzz/fuzz-interpret.cpp` (hostile registers/CSRs/page tables/TLB entries) on the clang ASan+UBSan build, seeded with 400 seed-corpus files, 25 minutes: 318,384 executions, 3,837 new units, 3,638 edges, no crash or sanitizer report (`<SCRATCH>/work/portability/fuzz/fuzz.log`).
- valgrind memcheck (`--track-origins`) on cmp runs (interpret + uarch C++ + hashing): no uninitialised-value report.
- Native `__int128` vs emulated `Fortran::common::Int128` (`<SCRATCH>/work/portability/u128/run.sh`): every soft-float op (f32/f64 add/sub/mul/div/sqrt/fma variants, min/max/cmp/class, all int<->float conversions, f32<->f64), MULH/MULHSU/MULHU expressions verbatim from interpret.cpp, `mul_u`, `divrem_u` (both the host `a % b` and the uarch/ZK `a - b*q` forms) and `sqrtrem_u`; 20M+ random/special inputs, GCC -O0/-O2, clang -O3, GCC and clang UBSan: 0 mismatches, 0 UB reports.
- Static review notes (no defect): all signed shifts rely on C++20 semantics (all targets build with -std=c++23/gnu++23); signed arithmetic in interpret.cpp and uarch-step.cpp goes through `__builtin_*_overflow`; every `__builtin_clz` call is guarded (`ilog2` with constant masks, `plic ilog2(ipmask!=0)`, `uint32Log2(dataLength>0)`, soft-float `clz` handles 0); risc0 `__clzdi2(0)` relies on libgcc `__clzsi2(0)==32` but is never called with 0; masks are `enum : uint64_t` (no 32-bit `~` truncation, including on ILP32); `tlb_is_hit`'s `~(sizeof(T)-1)` is correct on ILP32; Solidity-converted files have at most one state access per statement (access-log order is compiler independent) and no unchecked raw arithmetic that could overflow; hashed state structs have no implicit padding; dirty-word sets are sorted before hashing (container iteration order cannot leak into hashes); interpreter `assert`s that are live only in the uarch/ZK builds (`assert_no_brk`, `get_highest_priority_irq_num`, soft-float `normalize`) were checked to be unreachable (mip/mie/mideleg are WARL-masked on every read).
