# verify-misc: independent verification report

`<V>` = `<SCRATCH>/verify/verify-misc`. Every reproducer runs with one command (`sh <V>/<dir>/run.sh`). It prints
`BUG REPRODUCED` and exits 1 while the defect is present, and exits 0 once it is fixed.
The bare-metal reproducers share one driver, `<V>/common/runbin.lua`. It runs the program to halt twice, once with the
interpreter (`machine:run`) and once with the microarchitecture (`run_uarch`/`reset_uarch` per mcycle). It then
compares exit codes and root hashes and exits 125 if the two paths diverge.

| id | verdict | severity (mine) | hunter's rating |
|---|---|---|---|
| fp-J1 | CONFIRMED, with a stronger realistic trigger found | Medium (low end) | Medium |
| interp-isa-1 | CONFIRMED | Low | Low |
| interp-isa-2 | CONFIRMED (both halves; the A/D half is now proven) | Low | Low |
| interp-priv-4 | CONFIRMED (own reproducer, observes interrupts actually taken) | Low | Low |
| gdbstub write-mem (side note) | CONFIRMED | Low | n/a |

---

### fp-J1: float-form JSON integers equal to 2^64 (or 2^63) pass the range check and reach an out-of-range double→integer cast (UB, host-ISA dependent)

**Verdict: CONFIRMED.**

**Reproducers:**
- Hunter's PoC, re-run from a clean copy in `<V>/fpJ1-hunter/` (`sh run.sh`, rc=1): `mcycle=18446744073709552000 -> 0`, `machine.run(18446744073709552000) -> reached_target_mcycle, mcycle 0`, plus the UBSan report on the replica.
- My own reproducer: `<V>/fpJ1/run.sh`. It uses different techniques from the hunter's.
  1. It compiles the **real** `src/json-util.cpp` with `-fsanitize=float-cast-overflow` (about 2 minutes, cached as
     `json-util.o`). It then probes `ju_get_field` with JSON-RPC positional params, the way `jsonrpc-remote-machine.cpp:673` does.
  2. It calls the real `libcartesi.so` through the C API and through the Lua bindings.
  3. It shows a realistic trigger: the emulator's own default config, round-tripped through JavaScript.

  Actual output (abridged):
  ```
  json-util.cpp:816:39: runtime error: 1.84467e+19 is outside the range of representable values of type 'long unsigned int'
  json-util.cpp:850:38: runtime error: 9.22337e+18 is outside the range of representable values of type 'long int'
  literal 18446744073709551616 : is_number_unsigned=0 is_number_float=1      <- even exact integer text 2^64 becomes a float
  uint64  18446744073709552000   -> ACCEPTED value=0
  uint64  18446744073709551616   -> ACCEPTED value=0
  int64   9223372036854775808.0  -> ACCEPTED value=-9223372036854775808
  uint32  18446744073709552000   -> ACCEPTED value=0
  uint16  18446744073709552000   -> ACCEPTED value=0
  int32   9223372036854775808.0  -> rejected (out of range)
  C API mcycle=18446744073709551616 (2^64, integer text) -> ACCEPTED, mcycle reg = 0
  lua config mcycle=2^64 -> ACCEPTED, mcycle reg = 0
  lua config mcycle=18446744073709551615 (Lua 5.4 decimal literal overflow -> float) -> 0
  --- (3) default config round-tripped through JavaScript JSON.parse/stringify
  js.json:"ilrsc":18446744073709552000
  base.json: ilrsc=0xffffffffffffffff imcyclemax=0xffffffffffffffff root=f35ca515... run(1000): REACHED_TARGET mcycle=1000
  js.json:   ilrsc=0x0000000000000000 imcyclemax=0x0000000000000000 root=4f711ff9... run(1000): MCYCLE_OVERFLOW mcycle=0
  BUG REPRODUCED
  ```

**Root cause:**
- nlohmann stores any integer literal that does not fit in uint64 as `number_float`. That covers `18446744073709551616` as well as float forms like `18446744073709552000` or `1.8446744073709552e19`.
- `ju_get_opt_field(..., uint64_t&)` (`src/json-util.cpp:810-817`) accepts floats and rejects them only if `f > (double)UINT64_MAX`. That bound rounds up to exactly 2^64, so 2^64 passes and reaches `static_cast<uint64_t>(f)` at line 816, which is UB.
- The int64 variant (`json-util.cpp:843-850`) has the same flaw at 2^63, via `(double)INT64_MAX`.
- Host codegen (checked with `-S`):
  - x86-64: `cvttsd2siq` plus `btcq $63`, so 2^64 becomes **0** and 2^63 as int64 becomes INT64_MIN.
  - riscv64: `fcvt.lu.d`/`fcvt.l.d` with rtz saturate (RISC-V F spec), giving 2^64-1 and INT64_MAX.
  - aarch64 `fcvtzu`/`fcvtzs` also saturate.

**Answers to the requested checks:**
- (a) Entry points.
  - Every uint64 field parsed through `ju_get_field`/`ju_get_opt_field` is affected:
    - all machine config fields (`cm_create_new`, JSON-RPC `machine.create`, `--load-config=…,format:json`);
    - runtime config;
    - every JSON-RPC uint64 parameter (`machine.run` mcycle_end, `log_step`, `collect_*`, `write_reg`, addresses and lengths, …).
  - Float-form numbers are explicitly allowed by the `is_number_float()` branch.
  - Lua tables are also affected. `clua-i-machine.cpp:399-406` turns non-integer Lua numbers into JSON floats. In Lua 5.4 the decimal literal `18446744073709551615` is itself a float (an overflowing decimal numeral becomes a float). The CLI's numeric options are safe because `util.parse_number` rejects floats.
- (b) On x86, 2^64 is accepted as 0. The UBSan report above comes from the real `json-util.cpp`, not a replica.
- (c) Which clients produce such JSON.
  - The emulator's own C++ JSON-RPC client, Go `encoding/json` with uint64, Rust serde, Python `json`, and jq 1.7 all emit exact integers. jq 1.7 preserved `18446744073709551615` in my test.
  - JavaScript/TypeScript `JSON.parse`/`JSON.stringify` without BigInt handling always produce `18446744073709552000` for any value in [2^64-1024, 2^64-1]. The same holds for other double-based encoders; jq 1.6 is reportedly one, but I did not test it.
  - **The new realistic trigger:** `cm_get_default_config()` (and `get_initial_config`) itself emits `"ilrsc":18446744073709551615` and `"imcyclemax":18446744073709551615`. A JS tool that reads a config and writes it back produces a JSON that:
    - on **x86-64**, creates a machine with `imcyclemax = 0`. That machine is at the `MCYCLE_OVERFLOW` fixed point and **never executes an instruction**, and its root hash is different;
    - on **aarch64** (e.g. Apple Silicon developer machines) or riscv64 hosts, works normally because the cast saturates to 2^64-1.

    The same JSON therefore gives a different template hash and a different behaviour depending on the host CPU.
- (d) Narrower and signed paths.
  - uint32/uint16/uint8 parse through uint64. x86 accepts 2^64 as 0, while ARM/RISC-V get 2^64-1 and reject it as "out of range". So the host decides whether the input is accepted or rejected.
  - The int64 path is reached only through int32 (`output_fd`/`input_fd`). It still executes UB, but both ISAs end up rejecting the value (INT64_MIN and INT64_MAX are both outside the int32 range), so there is no observable divergence.
  - No field parses int64 directly.

**Severity: Medium (low end).**
- Why Medium:
  - It is undefined behaviour in the parsing of untrusted JSON-RPC and config input.
  - The result depends on the host ISA, so x86 and ARM deployments diverge.
  - A realistic, non-adversarial path exists: round-tripping the emulator's own config through JS silently zeroes `imcyclemax`/`ilrsc` on x86 only.
- Why not High:
  - There is no memory corruption.
  - Stored snapshots are unaffected, because registers are loaded from the binary shadow state.
  - Proofs and step verification are unaffected.
  - The input is already non-canonical (the client lost precision), and the divergence shows up as a different root hash at creation time.

**Fix assessment:**
- The hunter's fix is correct. I validated it on a private copy (`<V>/fpJ1/fix/json-util.cpp`) by changing the two upper bounds to `f >= 18446744073709551616.0` and `f >= 9223372036854775808.0`.
  - With the fix, every out-of-range probe is rejected.
  - `18446744073709549568.0` (the largest double below 2^64) and `-2^63` are still accepted.
  - No UBSan report remains.
- Rejecting floats for integer fields altogether would also be acceptable and simpler.
- Effects of the fix:
  - No root-hash or step-format change.
  - Inputs that triggered UB now get an error. JS clients sending "UINT64_MAX" must switch to exact integers, e.g. BigInt-aware JSON.

---

### interp-isa-1: misaligned SC.W/SC.D does not raise an exception (returns rd=1)

**Verdict: CONFIRMED.**

**Reproducers:**
- Hunter's PoCs, re-run from `<V>/hunter-isa/`: `sc_misaligned` and `sc_sentinel` print `BUG REPRODUCED … identical in interpreter and uarch`.
- My own reproducer: `<V>/isa1/run.sh` (`sc_misaligned.S`). The trap handler counts traps and the program checks three cases:
  - T1: `sc.w` at buf+1 with no reservation;
  - T2: `lr.d` on an aligned buf, then `sc.d` at buf+4;
  - T3: `sc.d` at buf+6 with no reservation;
  - control: `lr.w` at buf+2, which does trap (cause 4).

  Output:
  ```
  [interp] halted=1 exit=7 ... a3=0x1 a4=0x1 a5=0x1 ... s0=0x1 s1=0x4      (only the LR control trapped; all 3 SCs returned 1)
  [uarch ] identical; interp vs uarch root hash equal: true
  BUG REPRODUCED: misaligned SC did not trap (failure mask=7 ...)
  ```

**Root cause:**
- `execute_SC` (`src/interpret.cpp:1277-1296`) compares `ilrsc == vaddr` before checking alignment.
- A misaligned LR traps and never creates a reservation. So a misaligned SC can only match the reservation sentinel `-1`, which is why `csr_counters.S` "works", or an LR.W address used by an SC.D (that path does trap, inside `write_virtual_memory`).
- Every other misaligned SC takes the `val = 1` path without trapping.

**Spec:**
- Unprivileged ISA, Zalrsc: "If the address is not naturally aligned, an address-misaligned exception or an access-fault exception will be generated."
- This is mandatory. Zam does not apply to LR/SC.
- Spike checks alignment in `check_load_reservation` whether or not a reservation is held.
- No deviation is documented in `doc/` or in comments, and no test asserts the current behaviour.

**Severity: Low.**
- It is a guest-visible spec deviation, but it is deterministic and identical in the interpreter, uarch and step (same source).
- Compilers and Linux never emit misaligned LR/SC.

**Fix assessment:**
- The proposed early alignment check (raise `MCAUSE_STORE_AMO_ADDRESS_MISALIGNED`, tval = vaddr) is correct.
- It changes semantics. That means a new uarch RAM image and pristine hash, plus an update to the on-chain step verifier.
- I did not rebuild the emulator: the host load average was about 47 on 4 cores.

---

### interp-isa-2: PTE access that violates a PMA raises a page fault instead of an access fault; A/D write-back to a read-only PTE silently does nothing

**Verdict: CONFIRMED (both halves).** The A/D half, listed by the hunter as "not separately proven", is now proven.

**Reproducers:**
- Hunter's `pte_access_fault` PoC, re-run in `<V>/hunter-isa/`: mcause 13 in both the interpreter and uarch.
- My own reproducer: `<V>/isa2/run.sh` (`pte_fault.S`, plus a 4 KiB read-only flash drive generated at 0x80000000000000). It uses different targets from the hunter's:
  - `root[1]` is a non-leaf PTE pointing into **CLINT** (an I/O device), not unmapped space. I test load and store through MPRV=S, and an instruction fetch from real S-mode.
  - `root[3]` is a non-leaf PTE pointing into the read-only flash drive. Its leaf megapage PTE has R|W|V with A=0 and D=0.

  Output:
  ```
  [interp] exit=31 a2=0xd a3=0xf a4=0xc a5=0x0 a6=0x0 s3=0x20000007
  [uarch ] identical; root hashes equal
  ```
  - Load, store and fetch through the CLINT PTE give 13/15/12. The spec requires 5/7/1.
  - The load and the store through the read-only leaf PTE **succeed** (no trap). The PTE is left unchanged (0x20000007, A=D=0). The spec requires load/store access faults (5/7).

**Root cause:**
- `translate_virtual_address` (`src/translate-virtual-address.hpp:171`) returns plain `false` when `read_ram_uint64` fails. Callers map `false` to a page fault.
- At line 240, `write_ram_uint64(a, pte_addr, update_pte)` ignores its return value; the comment says "Can't fail since read succeeded earlier". But `write_ram_uint64` also requires `is_writeable()`. The PMAs range, the CMIO rx buffer and read-only flash or nvram drives are R but not W, so the write fails silently.

**Spec (Priv. ISA, virtual address translation):**
- Step 2: "If accessing pte violates a PMA or PMP check, raise an access-fault exception corresponding to the original access type."
- A/D update (when Svade is not used): "If a store to pte would violate a PMA or PMP check, raise an access-fault exception corresponding to the original access type."

**Severity: Low.**
- Both cases need page tables pointing at non-RAM or read-only memory, which only a broken or adversarial guest kernel would set up. The guest only harms itself.
- Behaviour is deterministic and identical in all implementations, so there is no consensus or proof impact.

**Fix assessment:**
- The proposed tri-state result (ok / page fault / access fault) is correct.
- It must also cover the A/D write failure, by returning an access fault when `write_ram_uint64` fails.
- Root hashes change only for programs that hit these paths. The uarch image and the on-chain verifier must be regenerated.
- Note: all implementations must agree; do not make one of them "tolerant".

---

### interp-priv-4: S-mode can set sip.STIP and clear sip.SEIP

**Verdict: CONFIRMED.** I wrote my own reproducer, which the previous verifier did not.

**Reproducer:** `<V>/priv4/run.sh` (`sip.S`). Instead of reading the CSR back, it observes which interrupts are actually **taken**.
- M delegates STI and SEI (`mideleg=0x220`), enables STIE and SEIE, **sets mip.SEIP itself** (legal for M), and enters S with SIE=0.
- S executes `csrc sip,SEIP` and `csrs sip,STIP`, then sets sstatus.SIE. The S handler records each interrupt taken and disables its source.
- The script first runs a control: the same program with the two `sip` writes replaced by `nop`.

Output:
```
control: a2=0x200 (SEI taken) exit=0
test:    a2=0x20 (only STI taken; SEI lost) a3(sip)=0x20 exit=3 ; uarch identical
BUG REPRODUCED: S-mode modified read-only sip bits (mask=3: 1 = set STIP -> STI taken, 2 = cleared SEIP -> SEI lost)
```

**Root cause:** `write_csr_sip` (`src/interpret.cpp:2181-2187`) uses `mask = mideleg`, so every delegated bit is writable. The spec makes only SSIP writable in `sip`: "If implemented, STIP is read-only in sip … SEIP is read-only in sip".

**Severity: Low.** Only S-mode can do this, and it only affects S's own interrupts. It is deterministic, and Linux does not do it.

**Fix assessment:**
- `mask = a.read_mideleg() & MIP_SSIP_MASK` is correct.
- This is a semantics change, so the uarch image and the on-chain verifier must be regenerated.

---

### gdbstub `M` (write memory) replies are inverted

**Verdict: CONFIRMED.**

**Reproducer:** `<V>/gdb/run.sh` (`gdbwrite.lua`). It drives `GDBStub:_handle_write_mem` on a real machine and captures `_send`.
```
M80000000 (valid RAM) -> reply "E01", memory now 0xefbeadde     <- write happened, error reported
M10000000 (unmapped)  -> reply "OK" (direct write_virtual_memory ok=false: attempted write is not entirely within single memory range)
BUG REPRODUCED
```

**Root cause:** `src/cartesi/gdbstub.lua:412` reads `if ok then return self:_send_error() end`. It should be `if not ok then`.

**Effect:**
- GDB `set var`, `set {T}addr = v` and `load`, which use `M` packets, report "Cannot access memory" even though the machine state was modified.
- A write to an invalid address reports success.
- Breakpoints are unaffected, because they use `Z`/`z`.

**Severity: Low.** It only affects interactive debugging (`--gdb`) and has no consensus impact.

**Fix:** negate the condition.
