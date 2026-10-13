# uarch-isa: RV64I audit of src/uarch-step.cpp (and uarch-solidity-compat.hpp / EmulatorCompat.sol)

Angle: check every `executeXXX`, the decoder and the compat helpers of the microarchitecture that runs the
rv64i-compiled interpreter during disputes and is transpiled to the on-chain `UArchStep.sol`. The method was
deterministic and systematic (exhaustive immediates/encodings plus edge-value tables). No fuzzing.

## Summary

| ID | Title | Status | Severity |
|---|---|---|---|
| UARCH-ISA-1 | uarch `x0` is not hardwired to zero. A uarch store to the `uarch_x0` shadow word (or to an unknown shadow word) aborts on the host but is accepted by Solidity/replay, which also makes x0 non-zero | PROVEN (needs a non-pristine uarch RAM image, same precondition class as crafted-state-1 / DYNAMIC-1) | Low on its own (addendum to crafted-state-1) |
| UARCH-ISA-N | RV64I semantics of uarch-step.cpp, C++ vs Solidity equivalence, pristine image instruction set | REJECTED: no defect. 27.1M single-step cases plus 61,060 program steps on 5 execution paths, 0 mismatches | n/a |

**Bottom line:** I found no RV64I implementation defect in `uarch-step.cpp`. Decoding, immediates,
sign and zero extension, W-variant results, shift masking, SLT*/SLTI*, LUI/AUIPC, JAL/JALR and branches,
loads and stores all match the spec on every case tested. The C++ and transpiled Solidity behave
identically. The only divergence found needs a crafted uarch program (UARCH-ISA-1).

---

### UARCH-ISA-1: uarch `x0` is not hardwired; a store to the `uarch_x0` shadow word aborts on the host but is a valid transition for Solidity/replay
- Status: PROVEN (precondition: a non-pristine uarch RAM image, which only a template machine can carry; `reset_uarch` restores the pristine image)
- Area: uarch / divergence (host `uarch_state_access` + `uarch_record_state_access` vs `uarch_replay_state_access` + Solidity `UArchStep`)
- Category: divergence, spec-violation (x0 must read as zero)
- Where:
  - `src/uarch-solidity-compat.hpp:92` `readX()` returns `a.read_uarch_x(reg)` for `reg == 0`. Every `executeXXX` in `src/uarch-step.cpp` reads `rs1`/`rs2` through it, so x0 is whatever the shadow word `0x400018` holds. The same applies to `EmulatorCompat.readX` in Solidity.
  - `src/machine.cpp:1937-1945` `machine::write_word`: a word write into the shadow uarch state goes to `write_reg()`. For `uarch_x0`, `write_reg` throws `"register is read-only"` (`machine.cpp:1362-1363`). For padding words it throws `"unhandled write to shadow uarch state"`. The same host-only rejection exists for unknown words of the big-machine shadow registers (`machine.cpp:1928-1935`).
  - `src/uarch-replay-state-access.hpp:359` (`do_write_word` only checks the proof) and `EmulatorCompat.writeWord` (Solidity) accept the same write as an ordinary leaf update.
- Problem: an rv64i `sd` to `0x400018` (the `uarch_x0` shadow word) has three different outcomes:
  - Host (`run_uarch`, `log_step_uarch`, and also `collect_*`, which share `machine::write_word`): aborts the step with "register is read-only".
  - On-chain step and C++ `verify_step_uarch`: the step is valid, x0 becomes the stored value, and every later instruction that reads x0 sees it. That includes every `li`/`mv` idiom (`addi rd, x0, imm`).
  - RISC-V: x0 is hardwired to 0, and a uarch has no reason to write its own shadow state.
- Scenario: only reachable when the uarch RAM is not the pristine interpreter. That means a template whose `uarch.ram` backing store holds a custom program, the root cause already filed as crafted-state-1 / verify-uarch-NEW-1. In that setting the honest host cannot produce the step log for this transition (`log_step_uarch` throws), while the on-chain `UArchStep` and C++ `verify_step_uarch` treat it as valid. This is the same honest-party-cannot-prove asymmetry as DYNAMIC-1, but on the uarch's own register file.
  - With the pristine image it is unreachable. All 27,974 executable words of `uarch/uarch-ram.elf` decode to the 50 supported RV64I instructions (see UARCH-ISA-N, item D). Guests cannot reach `0x400000-0x401000` or uarch RAM, because those ranges are registered with `pmas=false` (`machine-address-ranges.cpp:111-125, 348-363`).
- Evidence: `<SCRATCH>/work/uarch-isa/x0store/run.sh` builds `x0store.S` (`sd 5 -> 0x400018`, then `add t2, x0, x0`), runs it on libcartesi and through the Solidity `UArchStep` (mock AccessLogs). Output:
  ```
  host run_uarch: ok=false err=register is read-only uarch_cycle=5; host log_step_uarch fails at uarch cycle 5: register is read-only
  solidity: status=2 (2=halted) cycle=11 x0=5 t2(add t2,x0,x0)=10
  BUG REPRODUCED: host uarch aborts the step (x0 read-only) while the Solidity step accepts it and x0 becomes non-zero
  ```
  The program halts with `lui a7,0; addi a7,a7,1`. With `li a7,1` the Solidity run reverts with "unsupported ecall function", because `li` reads the corrupted x0 (a7 = 6). That revert is a side demonstration of the same problem.
- Possible solution: make the shared (transpiled) step agree with the host and with RISC-V.
  - (a) In `uarch-step.cpp`, have the memory write helper (`writeUint64`, which every store goes through) reject paddr in `[UARCH_SHADOW_START, +UARCH_SHADOW_LENGTH)` with `throwRuntimeError(a, "write to uarch shadow state")`. Do the same for shadow-register words the host rejects.
  - (b) And/or hardwire x0 by making `readX(a, 0)` return 0 without an access. This changes the access-log format (one fewer read per instruction with an x0 operand), so it must be co-released with the Solidity `UArchStep` and new step logs.
  - Option (a) alone keeps the log format for all honest programs.
- Severity: Low as a standalone (a crafted uarch program is required). It is a further instance of the "non-pristine uarch state is not validated" root cause (crafted-state-1, High/Critical-conditional) and of "host-only checks in `machine::write_word`" (DYNAMIC-1). If crafted-state-1 is fixed by enforcing a pristine uarch in templates, this becomes unreachable.
- Risks: if left unfixed and a non-canonical uarch template is ever accepted, an honest party cannot log a step that the chain accepts. Fix (a) changes `UArchStep.sol` (redeploy) but neither the pristine uarch RAM image nor its hash, and it changes no honest log. Fix (b) changes the logs of every step that reads x0.

---

### UARCH-ISA-N: RV64I correctness of uarch-step.cpp and C++/Solidity equivalence
- Status: REJECTED (no defect found; reported for coverage)
- Area: uarch / Solidity step
- **A. Exhaustive single-step differential**: `<SCRATCH>/work/uarch-isa/unit/run.sh`, about 25 s.
  - The current `src/uarch-step.cpp` is used verbatim, via `mkcopy.sh`, which only drops the 4 production instantiations and routes `require()` to a throwing `ut_require`. It is instantiated with a mock `i_uarch_state_access`.
  - It is compared after every step (all 32 regs, pc, cycle, halt, memory, putchar/write_tlb calls, failure kind) against an independent reference model written from the RV64I spec (`ref::` in `harness.cpp`).
  - Result: `cases=27097031 mismatches=0`. Coverage:
    - Decoder: all 2^17 (opcode, funct3, funct7) × 8 fills of rd/rs1/rs2, plus a SYSTEM-opcode sweep. This covers reserved encodings: SLLI/SRLI/SRAI imm[11:6], SLLIW/SRLIW/SRAIW bit 25 (illegal), M-extension funct7=1, FENCE.I, CSR, and non-exact ECALL/EBREAK.
    - R-type, all 15 ops: 50×50 edge values × 11 register triples (rd=rs1, rd=rs2, rs1=rs2, x0 in each position), plus rs2 shift amounts 0..127 with high garbage bits.
    - I-type ALU and ADDIW: all 4096 immediates × 50 values × 3 rd choices, plus rs1=x0.
    - Shift-immediates: all 4096 imm fields (every shamt and funct6/7 pattern) × 50 values.
    - LUI/AUIPC: all 2^20 immediates, AUIPC at 7 pcs including 2^64 wrap.
    - JAL: all 2^20 offsets at 5 pcs including wrap.
    - JALR: all 4096 immediates × odd/even bases × rd≠rs1 / rd=rs1 / rd=x0 / rs1=x0 (link and target, LSB clear).
    - Branches: 6 ops × 50×50 values × 12 offsets, plus all 4096 even offsets taken and not taken at 3 pcs, plus rs1=rs2 and x0 operands.
    - Loads: 7 types × all 4096 immediates × 8 alignments × rd=rs1 / rd=x0, with edge byte patterns.
    - Stores: 4 types × all 4096 immediates × 8 alignments × rs2=rs1 / rs2=x0, checking the neighbour bytes.
    - Also: 2^64 address wrap; ECALL a7 ∈ {0..6, high bits}; cycle/halt boundaries (`UARCH_CYCLE_MAX`-2..+1, 2^63, 2^64-1; halt 0/1/2/2^63); misaligned pc; all 2^17 FENCE field patterns.
  - Sensitivity: `unit/mutate.sh` (output in `unit/mutate.out`) killed all 8 non-equivalent seeded mutants: SLTIU zero-extended imm, JALR without LSB clear, LWU sign-extended, SRAIW matched with funct6, SRAW masked with 63, JAL imm[11] dropped, loose ECALL match, SLLI matched with full funct7. The one survivor, m1, is provably equivalent: SRLIW decoding forces bit 25 = 0, so shamt5 = shamt6.
- **B. Program-level, 5 execution paths**: `<SCRATCH>/work/uarch-isa/run_all.sh` (`LOG=1` adds the full log/verify pass).
  - Three generated rv64i programs:
    - `isa-alu`: 36,463 steps, 12,031 results. All R/I/shift/LUI/AUIPC/FENCE forms, every register x1..x31 as rd/rs1/rs2.
    - `isa-mem`: 24,578 steps, 4,242 results. All loads and stores at every aligned offset with imm ∈ {-2048, …, 2047}, all branch ops on 400 value pairs forward and backward, JAL/JALR with odd targets, rd=rs1, rd=x0.
    - `isa-far`: branches at +4092/-4096 and JAL at +0xffffc/-0x100000, with zero-filled (illegal) gaps.
  - Final state (32 regs, pc, cycle, halt, whole image RAM) is **byte-identical** across:
    - (1) the reference model, run in lockstep with uarch-step;
    - (2) libcartesi `run_uarch` (`uarch_state_access`);
    - (3) Solidity `UArchStep` with mock AccessLogs (forge, `sol/mss/test/UArchIsaDump.t.sol`).
  - (4) `log_step_uarch` + `verify_step_uarch` on **all 61,060 steps** (record and replay): every verify returns `get_root_hash()`, and the final root hash equals the `run_uarch` one.
  - (5) Solidity prod `UArchReplay` of 819 C++-logged steps in 9 windows (loads, stores, branches, jumps, W-ops, I-type, W-shifts, far jumps, LUI/AUIPC/FENCE tail). All pass, and a tampered final hash is rejected.
  - An independent Python check of the 6,000 R-type results also matches.
- **C. Static review**:
  - Decoder masks and the order of `executeInsn` checks; the operand decoders (Imm12/Imm20/Jimm20/Sbimm12/Simm12/Shamt5/6).
  - C++ compat helpers: wrapping `__builtin_add_overflow`, masked shifts.
  - `EmulatorCompat.sol` equivalents: `unchecked` add/sub, signed `>>` is arithmetic, `int64(int32)` sign-extends, `int32(int64)` truncates.
  - Every Solidity checked-arithmetic site in `UArchStep.sol` cannot overflow for any reachable input:
    - `copyBits`: `uint64ShiftLeft(1,count) - 1` with count ∈ {8,16,32}, and `offset + count <= 64`;
    - `cycle + 1` with cycle < `UARCH_CYCLE_MAX`;
    - `index << 3` in uint8 with index ≤ 31.
  - No full-expression in uarch-step.cpp, uarch-reset-state.cpp or send-cmio-response.cpp contains two state accesses, so C++'s unspecified argument-evaluation order cannot reorder log accesses.
- **D. Pristine uarch image** (`uarch/uarch-ram.elf`, built `-march=rv64i -mstrict-align`):
  - Every executable word (27,974 instructions over all `.text*` sections) disassembles to one of the 50 instructions uarch-step supports.
  - None are compressed, `.word` or unknown. There is no FENCE.I, CSR or M-extension, and no FENCE or SLTI.
- **E. Spec deviations that are by design and consistent across C++ and Solidity** (not reported separately):
  - No instruction-address-misaligned exception: JAL/JALR/branches to pc%4≠0 commit, and the next fetch fails `require`.
  - Misaligned loads and stores fail `require`; this is the known ASSERTS-1 issue for the `NDEBUG` host build.
  - Only RV64I is supported (no Zifencei/Zicsr/M).
  - ECALL/EBREAK are exact-match only.
  - Halting ECALL does not advance pc.
  - An aborted step commits nothing (verified by the harness for every failing case).
- Severity: n/a
