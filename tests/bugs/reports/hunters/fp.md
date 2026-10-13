# Findings: angle `fp` (F/D extensions, soft-float, uint128, host floating point)

Scope: `src/soft-float.hpp`, F/D handling in `src/interpret.cpp` (decode, rounding-mode and illegal-instruction rules,
NaN-boxing, sign extension, fflags accrual, mstatus.FS gating, FP CSRs), `src/uint128.hpp` +
`third-party/llvm-flang-uint128` (software `Int128` used by the uarch and risc0 builds via `AVOID_NATIVE_UINT128_T`),
`src/riscv-warl.hpp` (fcsr legalisation), plus every use of *host* floating point in state-affecting code
(only `src/json-util.cpp` number parsing; the other uses are statistics printing). Zfh/Zfa are not implemented
(their encodings must trap; checked).

**Summary**
- The guest-visible F/D implementation is correct: no discrepancy against Berkeley SoftFloat (RISCV specialization,
  the Spike reference) in >4 billion operation checks, no cm_run vs uarch vs step-log vs rv32 (ZK-build) divergence,
  correct illegal-instruction/FS behaviour. All FP-ISA candidates REJECTED (listed below with reasons).
- One PROVEN host-floating-point bug, fp-J1: JSON uint64 inputs equal to 2^64 written as a float are accepted and
  converted with an out-of-range (UB) double->uint64 cast whose value depends on the host ISA (0 on x86-64,
  2^64-1 on aarch64/riscv64).

### fp-J1: JSON number 2^64 (float form) passes validation and is converted by an out-of-range double->uint64 cast (UB): 0 on x86-64, 2^64-1 on aarch64/riscv64
- Status: PROVEN
- Area: C API / JSON-RPC (config and parameter parsing), host floating point
- Category: input-validation, nondeterminism (host-ISA dependent), undefined behaviour
- Where: src/json-util.cpp:810-817 (`ju_get_opt_field<K>(..., uint64_t &value, ...)`, float branch); same pattern in
  src/json-util.cpp:843-850 (int64_t variant, `f > (double)INT64_MAX` admits 2^63). The uint32/uint16/uint8 variants
  (json-util.cpp:864-912) parse through the uint64 one.
- Problem: when a JSON integer does not fit in uint64, nlohmann stores it as a double. The float branch rejects
  `f > static_cast<double>(UINT64_MAX)`, but `static_cast<double>(UINT64_MAX)` rounds up to exactly 2^64, so
  f == 2^64 (the JSON text `18446744073709552000`, `1.8446744073709552e19`, ...) passes and reaches
  `static_cast<uint64_t>(f)`, which is undefined behaviour for f >= 2^64. GCC/Clang x86-64 code
  (`cvttsd2si` + 2^63 bias trick) yields **0**; aarch64 `fcvtzu` and riscv64 `fcvt.lu.d` saturate to
  **0xffffffffffffffff**. Hence the same JSON is (a) silently mis-parsed on x86 (an out-of-range value becomes 0
  instead of being rejected) and (b) parsed differently by x86 and ARM/RISC-V builds of the emulator/server.
  For uint32/uint16/uint8 fields the x86 build accepts the value as 0 while ARM/RISC-V builds reject it
  ("out of range"). The int64 branch has the same flaw at 2^63 (x86 -> INT64_MIN, ARM -> INT64_MAX).
- Scenario: `18446744073709552000` is exactly what JavaScript/TypeScript (`JSON.stringify(2**64-1)` or any
  `Number` holding UINT64_MAX) and other double-based JSON encoders emit for "UINT64_MAX". (1) A JS client of the
  JSON-RPC server calls `machine.run` with `mcycle_end = UINT64_MAX` ("run until yield/halt"): an x86 server runs
  **0 cycles** and returns `reached_target_mcycle`, while an ARM server runs to halt — node logic built on that
  client stalls or diverges depending on the host the server runs on. The same applies to every uint64 RPC parameter
  (`log_step`/`verify_step` mcycle counts, `collect_mcycle_root_hashes` mcycle_end, addresses/lengths, register
  values in `write_reg`). (2) A machine config (`cm_create_new`, JSON-RPC `machine.create`, CLI `--load-config=<f>,format:json` /
  Lua `cartesi.fromjson` — the Lua path was also checked and yields mcycle 0 on x86) containing such a value creates
  a machine with a different initial state (different root hash) on x86 vs ARM hosts; on x86 the root hash equals
  that of the config with `0`.
- Evidence: `<SCRATCH>/work/fp/jsonfloat/run.sh` (exit 1 = reproduced). Output:
  ```
  mcycle=0                      -> mcycle reg 0x0000000000000000
  mcycle=18446744073709551615   -> mcycle reg 0xffffffffffffffff
  mcycle=18446744073709552000   -> mcycle reg 0x0000000000000000 (root hash == hash(mcycle=0): 1, == hash(mcycle=2^64-1): 0)
  BUG REPRODUCED: out-of-range JSON value 2^64 accepted and converted via UB to 0 on this host
  machine.run(mcycle_end=18446744073709551615) -> halted, mcycle after = 5
  machine.run(mcycle_end=18446744073709552000) -> reached_target_mcycle, mcycle after = 0
  BUG REPRODUCED: mcycle_end=2^64 (float) accepted and silently converted to 0 on this x86-64 host ...
  --- UBSan on an exact replica of json-util.cpp:810-817:
  ubsan_replica.cpp:14:38: runtime error: 1.84467e+19 is outside the range of representable values of type 'long unsigned int'
  ```
  Host-ISA dependence, same replica source (`replica.cpp`, exact copy of the parsing function):
  ```
  x86-64 host:                                   18446744073709552000 -> 0x0000000000000000
  riscv64 build run inside the Cartesi guest:    18446744073709552000 -> 0xffffffffffffffff
  (aarch64 codegen of static_cast<uint64_t>(double): `fcvtzu x0, d0` -> saturates, same as riscv64)
  ```
  (`replica_rv64` was built with `riscv64-linux-gnu-g++-14 -static` and run with
  `cartesi-machine.lua ... --flash-drive=label:rep,data_filename:jsonfloat/rep.ext2 -- /mnt/rep/replica_rv64`.)
- Possible solution: reject anything not strictly below the type range before casting, e.g.
  `if (f < 0 || f >= 18446744073709551616.0 /* 2^64 */ || std::fmod(f, 1.0) != 0) throw ...;` and for int64
  `if (f < -9223372036854775808.0 || f >= 9223372036854775808.0 || ...) throw ...;` (do not compare against
  `static_cast<double>(UINT64_MAX/INT64_MAX)`, which round up to 2^64/2^63). Optionally reject floats altogether
  for integer fields (exact integers are what the emulator itself emits).
- Severity: Medium — host-dependent mis-parsing of API/config inputs (wrong `run` target, different initial machine
  state on x86 vs ARM nodes) reachable with a common client encoding; not reachable by guest code and does not
  affect stored snapshots' registers (those come from the shadow-state file).
- Risks: unfixed, x86 and ARM deployments behave differently on the same request/config and x86 silently turns
  "UINT64_MAX" into 0. The fix only turns previously-UB inputs into errors; no root-hash or step-format change.

## Method / coverage (all under `<SCRATCH>/work/fp/`)

1. **Reference**: Berkeley SoftFloat-3 built with `SPECIALIZE_TYPE=RISCV` (the reference Spike uses: canonical NaN,
   tininess after rounding, RISC-V integer-conversion saturation values) + Berkeley TestFloat `testfloat_gen` for
   hard operands. Clones in `sf3/`, `tf3/`.
2. **Host differential test of `soft-float.hpp`** (`fpcmp.cpp`, built by `build.sh` into four variants: native
   `__uint128_t`, software `Int128` (`-DAVOID_NATIVE_UINT128_T=1`, i.e. the uarch/risc0 arithmetic), and both of them
   again under UBSan). Compared result bits AND fflags for every rounding mode (RNE/RTZ/RDN/RUP/RMM) for:
   add, sub, mul, div, sqrt, fma (+ targeted near-cancellation / exponent-gap / subnormal / overflow operands),
   min, max, feq, flt, fle, fclass, f32<->f64, all 8 float->int conversions and all 8 int->float conversions,
   single and double.
   - random biased operands: 831M + 277M (soft Int128) checks, 0 mismatches
   - TestFloat level 1 (all functions) and level 2 (`-forever`, 4M operand lines per type, x5 rounding modes):
     ~1.0G checks, 0 mismatches; additional 30M-line level-2 FMA runs for f32 and f64 (see "Evidence")
   - UBSan builds (native and soft Int128): 83M checks, no UB reported in soft-float/Int128
   - exhaustive `fsqrt.s` over all 2^31 non-negative inputs (RNE) + all mantissas of 9 exponents in RTZ/RDN/RUP/RMM
     (the digit-by-digit `sqrtrem_u` is Cartesi's own replacement of Bellard's code): 2,449,473,536 checks, 0 mismatches
   - TestFloat level 2 `mulAdd` operands, 30M lines each for f32 (native) and f64 (soft Int128) x 5 rounding modes:
     300M checks, 0 mismatches
3. **In-emulator differential test** (`emugen.cpp` + `emurun.c` + `runemu.sh`): generates bare-metal programs with
   random F/D instructions (all 58 F/D computational instructions + FLW/FSW/FLD/FSD/C.FLD/C.FSD/C.FLDSP/C.FSDSP),
   random register numbers (f0-f31, x0 and other x regs as source/destination, aliasing), static rm 0-4 or dynamic rm
   with random frm, random prior fflags (accrual), improperly NaN-boxed single operands (upper bits 0, almost-all-ones,
   random doubles). Expected values from SoftFloat + an independent model of the spec glue (unbox -> canonical NaN,
   box results, FMV.X.W raw sign-extension, FCVT.W[U] sign-extension, FSGNJ on unboxed, FCLASS on unboxed, FSW raw
   low 32 bits, FLW boxing). 200k+ instructions via `cm_run`: 0 mismatches.
   **uarch divergence**: 6x20000 + 2x3000 instructions executed by `cm_run_uarch` (uarch-ram.bin compiled by GCC 13
   for rv64i with software Int128) -> identical result tables and identical root hashes vs `cm_run`.
   **step log**: `steplog.c` runs the FP program in chunks with `cm_log_step` + `cm_verify_step` and compares with
   `cm_run`: all chunks verify and match.
4. **ZK (risc0) build proxy** (`zk32/`): the soft-float dispatch kernel compiled exactly with the risc0 guest flags
   (`-march=rv32im -mabi=ilp32 -DZKARCHITECTURE=1 -DAVOID_NATIVE_UINT128_T=1`, i.e. ILP32 + software Int128 +
   `a - b*quo` remainder path) and executed in a small RV32IM interpreter (`rv32run.cpp`), compared with the host
   native build: 5.1M random records over all 40 soft-float entry points, 0 mismatches.
5. **Illegal-instruction / FS gating test** (`illegal/`): 633 encodings: static rm 5/6, dynamic rm with frm 5/6/7,
   rm-insensitive ops with invalid frm (must NOT trap), fmt=H/Q for OP-FP and fused ops, Zfa encodings (fli, fround,
   fminm, fleq, fcvtmod, fmvh), bad rs2/funct3, FLH/FLQ/FSH/FSQ, FS=Off for every FP class including CSR
   fflags/frm/fcsr reads/writes and the four compressed FP loads/stores; mcause and mtval checked (mtval for
   compressed = 16 bits). 0 mismatches; same program also identical under uarch and step-log verification.

## FP-ISA candidates (all REJECTED)

### fp-1: `sfloat_cvt_f64_f32` discards the normalized mantissa of an f64 subnormal input
- Status: REJECTED (harmless)
- Area: FP
- Where: src/soft-float.hpp:910 (`i_sfloat64::mant_normalize_subnormal(&a_exp, a_mant);` result ignored)
- Reason: any f64 subnormal is < 2^-1022, far below half of the smallest f32 subnormal (2^-150); only the sticky
  (non-zero) information matters and it is preserved, so results and flags (UF|NX, 0 or +-min-subnormal per rounding
  mode) are correct. Verified against SoftFloat for all 5 rounding modes (random + TestFloat f64 vectors). Code-quality only.

### fp-2: FMA `shift >= F_SIZE+1` branch drops the low word of the swapped operand
- Status: REJECTED (harmless)
- Where: src/soft-float.hpp:517-519 (`c_mant0 = mant_rshift_rnd(c_mant1, shift - F_SIZE)` ignores old `c_mant0`)
- Reason: only reachable after the swap (old `c_mant0`=0 otherwise); then `c_mant1 != 0` so the jammed result is
  non-zero, all of it lies far below the rounding position and `r_mant0` is 0, so borrow/sticky behaviour is identical
  to the exact value. Confirmed by the FMA differential tests (incl. TestFloat level 2 `f32/f64_mulAdd` operands).

### fp-3: `assert()` in `normalize`/`normalize2` active in uarch (no NDEBUG) but compiled out in host builds
- Status: REJECTED (unreachable)
- Where: src/soft-float.hpp:274, 291; uarch/Makefile:50 (NDEBUG commented out) vs src/Makefile:212
- Reason: every caller bounds the mantissa below 2^(F_SIZE-1) (add: <2^(MANT+5); mul: high word of
  2^(F-2)*2^(F-1) product; div quotient <2^(F-1); sqrt <2^(F-1); fma after carry <2^(F-1); cvt_i_f reduces to F-1
  bits), so `shift >= 0` always holds; never triggered in >2G checks and uarch runs.

### fp-4: software `Int128` (uarch / risc0) vs native `__uint128_t` divergence in mul/div/rem/sqrt paths
- Status: REJECTED
- Reason: reviewed `operator* / / % << >> + - < ==` for the operand ranges soft-float uses (high words 0 for mul,
  divisor < 2^64, shifts 0..126); host build with `AVOID_NATIVE_UINT128_T=1` is bit-identical to SoftFloat and to the
  native build; uarch runs give identical root hashes. `divrem_u`'s `a - b*quo` (MICROARCHITECTURE/ZKARCHITECTURE)
  is mathematically identical to `a % b`.

### fp-4b: ILP32 / rv32im (risc0 ZK guest) portability of soft-float
- Status: REJECTED
- Reason: nothing in soft-float depends on `sizeof(long)`; on riscv32 newlib (`uint32_t`/`int32_t` =
  `unsigned long`/`long`) the `clz`/`make_long_uint` specialisations and `Int128` constructors still resolve to the
  same widths; the GCC rv32im/ilp32 build (item 4, glibc headers) matches the host bit-for-bit.

### fp-5: fcsr reserved bits / invalid frm handling
- Status: REJECTED
- Reason: `write_csr_fcsr` stores the raw value but every `write_fcsr`/`read_fcsr` goes through `WARL_fcsr`
  (src/riscv-warl.hpp:112, `& 0xff`), so `insn_get_rm()` sees only frm 0..7; frm 5/6/7 with rm=DYN and static rm 5/6
  raise illegal instruction (also for FCVT.D.S/FCVT.D.W[U], matching Spike); rm-insensitive instructions ignore frm.

### fp-6: mstatus.FS dirty tracking
- Status: REJECTED (intentional, spec-permitted)
- Reason: `WARL_mstatus`/`write_csr_mstatus` force FS=Dirty (and SD=1) whenever FS != Off (comment at
  interpret.cpp:2259), which the privileged spec allows ("may track dirtiness imprecisely by reporting the state to be
  dirty even when it has not been modified"); FS=Off correctly makes all FP instructions and FP CSR accesses illegal
  (checked for all classes incl. compressed).

### fp-7: NaN-boxing / sign-extension / flag semantics in the interpreter glue
- Status: REJECTED
- Reason: `float_unbox` (canonical NaN for non-boxed inputs) is applied to every single-precision computational,
  compare, FSGNJ*, FMIN/FMAX, FCLASS, FCVT.*.S input; FMV.X.W/FSW use the raw low 32 bits; results are boxed;
  FCVT.W[U].{S,D} and FMV.X.W sign-extend; fflags are accrued (OR) and written even when rd=x0; fma(inf,0,qNaN)
  raises NV; sqrt(-0) = -0 without flags; fmin/fmax follow the v2.2 minimumNumber rules (-0 < +0, sNaN -> NV,
  both NaN -> canonical NaN); feq quiet, flt/fle signaling. All verified in-emulator against the model above.

## Evidence
- One-command re-check of the FP-ISA results: `bash <SCRATCH>/work/fp/run.sh` (prints `NO FP DISCREPANCY FOUND`, exit 0).
- fp-J1: `sh <SCRATCH>/work/fp/jsonfloat/run.sh` (exit 1 while the bug is present).
- Sample outputs:
  ```
  ./fpcmp_native rand 3000000 1          -> tests=831000000 failures=0
  ./fpcmp_soft128 rand 1000000 2         -> tests=277000000 failures=0
  testfloat_gen -forever f64 3 | head -4000000 | ./fpcmp_soft128 f64_3 -> tests=20000000 failures=0
  ./fpcmp_ubsan rand 200000 7            -> tests=55400000 failures=0 (no UBSan report)
  ./exh_sqrt                             -> exhaustive sqrt.s: tests=2449473536 failures=0
  testfloat_gen -forever f64 3 | head -30000000 | ./fpcmp_soft128 f64_3 -> tests=150000000 failures=0
  zk32/rv32run target.bin 100000 <seed 10..60> -> rv32im(ZK build) vs host: records=100000 mismatches=0 (x51)
  ./runemu.sh 20000 21 uarch             -> cm_run results: 20000 tests, 0 mismatches vs SoftFloat reference
                                            uarch: mcycle=173971 total_uarch_cycles=111792798 table_diffs=0 root_hash_equal=1
  ./steplog tmp/prog.bin 997             -> 26 chunks, 0 bad
  illegal/illrun ill.bin tests.txt 0x80100200 -> 633 tests, 0 mismatches
  ```
