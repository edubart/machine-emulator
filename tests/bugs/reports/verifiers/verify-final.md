# verify-final: independent verification of DEVICES2-1, cli-hashes-1/2/3, UARCH-ISA-1, lua-lifecycle-1/2

Verifier: `verify-final`. Work dir: `<SCRATCH>/verify/verify-final/` (`<SCRATCH>` = `<SCRATCH>`).
No fuzzing. Each candidate has a targeted reproducer of my own (`<id>/run.sh`, exit 1 + `BUG REPRODUCED` when the defect
is present, exit 0 when fixed) that uses a different technique from the hunter's. I also re-ran each hunter PoC from a
clean copy (`verify-final/hunter/`). All of them reproduced as documented.

Fix validation: I applied each fix in a private copy (`verify-final/build/src`, release flags, `nice make -j2`; Lua fixes in
`verify-final/fixlua/`). All fix diffs are in `verify-final/fixes.diff`. Every reproducer passes with its fix.
`build/src/machine.cpp` also carries an env-gated **log-generator hack** for UARCH-ISA-1 (`VF_ALLOW_UARCH_X0_WRITE`). It is
not a fix.

| ID | Verdict | Severity (mine) | Hunter's |
|----|---------|-----------------|----------|
| DEVICES2-1 | CONFIRMED | Low | Low |
| cli-hashes-1 | CONFIRMED | Low | Low |
| cli-hashes-2 | CONFIRMED | Low | Low |
| cli-hashes-3 | CONFIRMED (plus a worse plain-run variant) | Low (upper end, borderline Medium) | Medium (borderline Low) |
| UARCH-ISA-1 | CONFIRMED, also against the C++ replay verifier with real proofs | Low standalone (merge into crafted-state-1 / verify-uarch-NEW-1) | Low |
| lua-lifecycle-1 | CONFIRMED through the C API too; the failed-create path also leaks | Medium (lower end) | Medium |
| lua-lifecycle-2 | CONFIRMED; affects all six conversion helpers | Low | Low |

---

### DEVICES2-1: the host API can enable HTIF getchar on a reproducible machine; `cm_run` then diverges from uarch / step log
- **Verdict: CONFIRMED.** Hunter PoC (`hunter/getchar/run.sh`, `setrc`) reproduces exactly.
- **Independent reproducer:** `verify-final/devices2-1/run.sh`. It uses the Lua bindings and a JSON-RPC server, with a
  hand-encoded guest (no toolchain needed). It covers three ways to set the flag (`write_reg`, the full-shadow
  `write_memory` "manual snapshot" path, and `set_runtime_config(from_buffer)` over JSON-RPC), plus a control case.
  ```
  [0] control: reproducible machine, iconsole untouched                    -> agree (ba4004700555874a)
  [1] write_reg('htif_iconsole', 3):  run() answer=0x0100000000000005 root=54e5206b60781363
                                      log_step()+verify_step() / run_uarch() answer=0x0100000000000000 root=e8da268221ae24ac -> DIVERGENCE
  [1b] getchar bit via write_memory(0, <0x8000-byte shadow>)               -> DIVERGENCE (same hashes)
  [2] JSON-RPC, set_runtime_config(from_buffer)+write_console_input('Q'): remote run() answer=0x0100000000000052
      (create() with the same runtime config: "TTY stdin is only supported in unreproducible machines")
  [3] store: ok; load: TTY stdin is only supported in unreproducible machines
  BUG REPRODUCED
  ```
- **Root cause:** the invariant "console input ⇒ unreproducible" is enforced only at construction and load
  (`src/machine.cpp:325-332`, `machine::init_console`). It is not enforced at runtime:
  - `machine::write_reg(reg::htif_iconsole)` (`src/machine.cpp:1356-1357`) accepts the getchar bit.
  - The full-shadow `write_memory` path (`src/machine.cpp:1734-1745`) copies any `iconsole`.
  - `machine::set_runtime_config` (`src/machine.cpp:388-394`) accepts any `input_source`.

  The interactive accessor then serves real input: `device_state_access::do_getchar` (`src/device-state-access.hpp:153-158`)
  calls `machine::getchar()` (`src/machine.hpp:849-851`), with EOT=4 for `from_null`. Every non-interactive accessor returns
  `-1`: the uarch (and therefore the on-chain step), record/replay, and collect. The source comment at
  `src/htif-address-range.cpp:104-106` states that reaching getchar "in blockchain" means "some serious bug".
  `store()` checks only `is_unreproducible()` (`src/machine.cpp:400-402`), so it writes a snapshot that `init_console` later
  rejects.
- **Documented/intended?** Partly. The README says "external modifications to the state break the reproducibility" and
  that writing state "requires extreme care" (`doc/README.md.template:2706-2708`). The difference here is that the
  poked state is a well-defined hashed state, yet paths that must agree compute different successors from it. The
  create/load guard shows the state is meant to be unreachable for reproducible machines.
- **Severity: Low (agree).**
  - Only the machine's owner can reach it, by misusing the host API (C, Lua or JSON-RPC). The guest cannot, because
    `iconsole` is read-only to the guest.
  - No honest node creates this state.
  - The effects are unprovable `cm_run` results and unloadable snapshots for whoever pokes the register.
- **Fix assessment:** validated in a private build. Three changes:
  1. `machine::getchar()` returns `{-1,false}` when `!is_unreproducible()`. This mirrors `poll_external_interrupts` and
     covers every way the bit can get set, including the shadow path.
  2. `write_reg(htif_iconsole)` and `set_runtime_config` reject getchar or console input on reproducible machines.
  3. `store()` refuses a reproducible machine that has getchar set.

  With these, the reproducer prints `OK`, `htif-console.lua` passes, and `spec-runtime-console.lua` keeps its baseline
  result (37/1; the one failure is "unable to open a TTY", the same as unpatched).

  No root hash of a legitimately configured machine changes. One note: because `init_processor` calls `write_reg`, the
  check in (2) changes the error message `cm_create` gives for a reproducible config with getchar. Keep the old
  message or check before `init_processor`. Change (1) alone fixes the divergence. (2) and (3) fix the store/load
  asymmetry. Related: REPRO-1 (`iunrep` shadow vs config). Fix (1) uses the config copy, consistent with the other guards.

---

### cli-hashes-1: `--print-uarch-cycle-root-hashes` prints a fabricated uarch group after an rx-rejected yield
- **Verdict: CONFIRMED.** Hunter PoC (`hunter/cli-hashes/uarch-print-reject/run.sh`) reproduces: 2 printed entries,
  43 canonical.
- **Independent reproducer:** `verify-final/cli-hashes-1/run.sh`.
  - Own guest: an rx-accepted manual yield, a loop, then an rx-rejected manual yield.
  - Takes the real tail from `collect_uarch_cycle_root_hashes(mcycle, 0)` at the waiting state.
  - Stores the machine right after `send_cmio_response`, runs `cartesi-machine --load=… --print-uarch-cycle-root-hashes=1000,start:<m>`.
  - Compares **every** printed hash, position by position, with the canonical collection.
  ```
  revert uarch tail: 43 entries; canonical collection: 10378 entries, 16 mcycles
  CLI printed 10337 per-uarch-cycle entries (canonical 10378)
  first mismatch at entry 10336 (the reverted-machine group starts at entry 10336):
    entry 10336: CLI 20,1  0xf109c8f0a2013a9d | canonical 0x716a82ce9d152217
    entry 10337: CLI 21    0xf109c8f0a2013a9d | canonical 0x4541f9319d000741
  BUG REPRODUCED
  ```
  All 10335 entries before the group match. The fabricated lines are labelled `20,1` and `21:`, but mcycle 21 never
  happens because the machine stays at 20.
- **Root cause:** `src/cartesi-machine.lua:3836-3846` passes `fake_revert_uarch_tail = {R, R}`. The comment assumes a
  rejection "never happens outside cmio mode". A loaded mid-input snapshot reaches one without cmio mode.
  `append_revert_uarch_tail_period` (`src/machine.cpp:2615-2625`) then emits the fake 2-entry period.
  Documented behaviour of the API: `cm.h:969-973`.
- **Severity: Low (agree).** The output is diagnostic only. The computation-hash builders pass the real tail.
- **Fix assessment:** validated (`fixlua/cartesi-machine.lua`). When a collect chunk ends at an rx-rejected manual
  yield, the fix drops the final group and prints a note. The reproducer passes: all printed entries are canonical, and
  the post-rejection group is omitted. An optional `revert_uarch_tail:<file>` sub-option would allow printing the full
  canonical group. No hash or format changes.

---

### cli-hashes-2: `hash_tree.get_data_root_hash("", n)` returns nil
- **Verdict: CONFIRMED.** The hunter's one-liner prints `nil`.
- **Independent reproducer:** `verify-final/cli-hashes-2/run.sh`. It compares against the machine itself
  (`get_proof` of an all-zero NVRAM), then runs the documented recipe flow
  (`doc/recipes/slice-calculator-output.lua:26,36`: `string.unpack("z", nvram)` returns `""` for an empty output,
  followed by `verify_splice`).
  ```
  get_data_root_hash(empty string, 12) = nil   WRONG
  get_data_root_hash(one zero byte, 12) = 0x292c23a9aa1d8bea  matches machine
  get_data_root_hash(empty string, word) = nil
  recipe flow (result=""): verify_splice raised: hash-tree.lua:20: bad argument #1 to 'hash_function' (string expected, got nil)
  BUG REPRODUCED
  ```
- **Root cause:** `src/cartesi/hash-tree.lua:45-68`. With empty data, level 0 is empty, the pairing loop creates no
  parents, and the function returns `level[1] == nil`. The header comment says the data "need not fill the tree".
- **Severity: Low (agree).** It fails closed: a valid empty value raises an error and nothing invalid is accepted. It is
  reachable through the documented recipe when the output is empty.
- **Fix assessment:** `if #level == 0 then level[1] = pristine end` before the loop. Validated
  (`fixlua/cartesi/hash-tree.lua`): the empty, word-size and recipe cases all pass. No other behaviour changes.

---

### cli-hashes-3: under `--gdb`, `stepc` onto an automatic-yield mcycle never completes
- **Verdict: CONFIRMED.** Hunter PoC (`hunter/cli-hashes/gdb-stepc-yield/run.sh`) reproduces both (A) and (B). I found a
  further plain-run variant.
- **Independent reproducer:** `verify-final/cli-hashes-3/run.sh`. It uses its own guest (a single progress yield at
  mcycle 27, halt at 50) and its own Python RSP client, independent of the hunter's Lua client. The client sends exactly
  what gdb sends for `break *addr` and for the gdbinit `stepc` macro.
  ```
  [control] stepc 26: gdb stop reply S02; CLI exit 0, halted, final hash line '50: …'
  [A] stepc 27, no breakpoints: no stop reply (connection closed); CLI exit=0, not halted, last hash line '27: 0xa20ac1bf…'
  [B] stepc 27 + any breakpoint inserted: no stop reply; plain run (no cmio) never ends, the single yield is
      re-serviced 2,846,245 times in ~8 s (killed)
  BUG REPRODUCED
  ```
  Variant [B] is new. It needs no cmio or computation-hash options: a plain `--gdb` run with any breakpoint plus
  `stepc` onto a yield loops forever and floods stderr at about 10 MB/s.
- **Root cause:** `src/cartesi/gdbstub.lua:475-521` (`_handle_continue`).
  1. The step target `mcycle_limit` lands on a yield, and the outer call is suspended so the CLI can service the yield.
     That part is correct.
  2. When `_pump_session` (`:612-616`) resumes, it re-enters `_handle_continue` with `mcycle == mcycle_limit`, so no
     transition happens and `iflags_X` is still set.
  3. Without breakpoints, `_advance` returns a zero-length `REACHED_TARGET_MCYCLE`. `GDBStub:run` (`:648-658`) hands it
     back to `run_to_stop`, which treats it as the CLI's own target. The CLI prints the final hash and exits 0.
  4. With breakpoints, the loop is skipped and the stale `YIELDED_AUTOMATICALLY` is returned. `run_to_stop`
     (`cartesi-machine.lua:4344-4355`) re-services the same yield forever.
- **Documented?** `stepc` is documented: `cartesi-machine.lua:1059`, `tools/gdb/gdbinit`. Existing tests
  (`tests/lua/spec-cm-cli.lua:4988-5042`) exercise stepc but never one that lands on a yield.
- **Severity: Low (upper end, borderline Medium).** I downgrade slightly from the hunter's rating:
  - Only interactive debugging sessions are affected.
  - The developer sees the debugger stop responding, so the failure is not silent from the user's side.
  - Consensus values and the node are unaffected.

  Its weight comes from the exit-0 "final" hash or stored machine of an unfinished run, and from the unbounded log
  flood in [B].
- **Fix assessment:** the hunter's first proposal is correct and sufficient. At the top of `_handle_continue`, if
  `mcycle_limit` is set and `mcycle == mcycle_limit`, send SIGINT (step done). Validated (`fixlua/cartesi/gdbstub.lua`):
  - My reproducer: control, A and B all get `S02` and the run then halts at 50.
  - The hunter's PoC, including the cmio (B) case, passes.
  - The `--mcycle-computation-hash` of the cmio epoch with `stepc` onto the tx-output yield equals the hash without GDB:
    `0x7ff07f55…5768` in both runs.

---

### UARCH-ISA-1: a uarch store to the `uarch_x0` shadow word is refused by the host but accepted by the verifier
- **Verdict: CONFIRMED.** Hunter PoC (`hunter/uarch-isa/x0store/run.sh`, Solidity `UArchStep` with mock AccessLogs) prints
  `host … register is read-only … solidity: status=2 … x0=5 t2=10`, as claimed.
- **Independent reproducer:** `verify-final/uarch-isa-1/run.sh`. It uses the C++ replay verifier with **real Merkle
  proofs** instead of Solidity mocks. Steps:
  1. A non-pristine uarch image (`guest.S`): `sd 7 -> 0x400018`, then `addi t2, x0, 3`, the `li` idiom.
  2. A generator linked against a private libcartesi whose `write_reg(uarch_x0)` behaves like the replay. This is the
     env-gated hack, not a fix. It produces `cm_log_step_uarch` logs.
  3. A judge linked against the **official** `libcartesi.so` checks two things. First, the official host refuses the
     step. Second, the official `cm_verify_step_uarch` accepts the log of that exact step and of every later step. The
     hash chain is anchored at the official machine's initial root hash.
  ```
  generator: 11 uarch steps logged, final uarch x0=7 t2=10        (RISC-V: x0=0, t2=3)
  official host: cm_log_step_uarch refuses step 3 (uarch_cycle=3): register is read-only
  official host: cm_run_uarch -> register is read-only
  official verifier: step 3 ACCEPTED, root after=4d684644292fb7de
  official verifier accepted 11 of 11 logged steps (including every step after the refused one)
  BUG REPRODUCED
  ```
- **Root cause:**
  - The host write goes through `machine::write_word` (`src/machine.cpp:1937-1945`) to `write_reg(uarch_x0)`, which
    throws "register is read-only" (`:1362-1363` in the original source).
  - The replay's `do_write_word` (`src/uarch-replay-state-access.hpp:359-362`) checks only the proof. The Solidity
    `writeWord` does the same.
  - `readX` (`src/uarch-solidity-compat.hpp:92-94`) reads x0 from the shadow, so every later x0 read sees 7.
  - The host also asserts x0 == 0 at construction ("uarch x0 register is corrupt", `src/machine.cpp:122-125`), which
    confirms that the intended semantics is a hardwired zero.
  - By code reading, the same host-only rejection applies to uarch stores to the big machine's `x0`,
    `mvendorid/marchid/mimpid` and unknown shadow words (`machine.cpp:1043-1046, 1242-1247, 1928-1935`). This is the
    DYNAMIC-1 class. I did not run these.
- **Severity: Low standalone (agree). Merge into crafted-state-1 / verify-uarch-NEW-1 (High).**
  - It needs a non-pristine uarch image in the template. `reset_uarch` restores the pristine one, and the pristine
    interpreter never stores to the uarch shadow.
  - With such a template, the honest official node cannot run or log the uarch level at all, while the chain accepts
    the transition. This is NEW-1's "honest party cannot defend" impact.
- **Fix assessment:**
  - Hunter fix (a): `uarch-step.cpp`'s store path rejects the uarch shadow range. This restores host/verifier parity
    for this case, changes no honest log (the pristine uarch never writes there) and no pristine hash, but needs a
    redeploy of the transpiled `UArchStep.sol`.
  - For full parity, (a) should also reject the big-machine read-only and unknown shadow words that the host rejects.
  - Fix (b), hardwiring `readX(0)`, changes the access-log layout for every instruction that reads x0, so it is a
    log-format and on-chain-compatibility change.
  - Enforcing a pristine uarch in templates (NEW-1's fix) makes the case unreachable.
  - I did not validate fix (a), because that needs a uarch-step change plus a Solidity rebuild.

---

### lua-lifecycle-1: `cm_clone_empty` on a remote machine leaks a forked server (cleanup and timeout not inherited)
- **Verdict: CONFIRMED, through the C API as well as Lua.** Hunter PoC (`hunter/lua-lifecycle/clone-leak`) reproduces.
- **Independent reproducer:** `verify-final/lua-lifecycle-1/run.sh` (pure C API, servers bound to 127.0.0.1, every
  leaked server shut down at the end; I checked that no processes were left behind).
  1. `cm_jsonrpc_spawn_server`, then `set_cleanup_call(SHUTDOWN)` and `set_timeout(5000)`.
  2. `cm_clone_empty` + `cm_create`.
  3. A second `cm_clone_empty` + `cm_create` with an invalid config. The caller can only `cm_delete` this object.
  4. A reference `cm_jsonrpc_fork_server`.
  5. `cm_delete` of everything, then a probe of each address.
  ```
  source (spawned, set SHUTDOWN/5000) timeout=5000 cleanup=SHUTDOWN
  cm_clone_empty() result            timeout=-1 cleanup=NOTHING
  cm_jsonrpc_fork_server() result    timeout=5000 cleanup=SHUTDOWN
  after cm_delete of every object:
    source server / fork_server() server: gone
    clone_empty()+create server        : STILL RUNNING after cm_delete (holds a machine: yes)
    clone_empty()+failed create server : STILL RUNNING after cm_delete (holds a machine: no)
  BUG REPRODUCED: 2 server process(es) created by cm_clone_empty() outlived every handle
  ```
  The failed-create path is new evidence. In Lua, every `remote(bad_config)` error also leaks a server, because
  `machine_meta_call` (`src/clua-i-machine.cpp:1506-1534`) leaves the new handle with cleanup NOTHING.
- **Root cause:** `src/jsonrpc-machine.cpp:604-622` (`do_clone_empty`) builds `new jsonrpc_machine(fork_result.address)`
  with the defaults `m_call = nothing` and `m_timeout = -1` (`jsonrpc-machine.hpp:188-190`). Compare
  `cm_jsonrpc_fork_server` (`src/cm-jsonrpc.cpp:143-145`), which copies both, as documented at `cm-jsonrpc.h:89-92`.
  - The forked process is a separate server. Shutting down the source does not stop it.
  - `do_clone_empty`'s own error path shuts the clone down, which shows the clone is meant to own its server.
  - `cm_clone_empty`'s documentation (`cm.h:459-468`) says nothing about cleanup or timeout.
- **Severity: Medium (lower end; agree with Medium).**
  - The documented recipe `doc/recipes/run-remote-config.lua:12-20` uses exactly this path. So do the rolling-calculator
    recipes.
  - A long-lived client that creates machines this way leaks one process holding a full machine (RAM and drives) per
    machine, and one more per failed create. It also loses its configured timeout, so a stuck server hangs the client.
  - No consensus impact.
  - The CLI and the test suites use `fork_server`/`spawn_server` instead, so they are unaffected.
- **Fix assessment:** validated in a private build of `libcartesi_jsonrpc.so`. In `do_clone_empty`, right after
  construction: `clone->set_timeout(m_timeout); clone->set_cleanup_call(cleanup_call::shutdown);`. The reproducer
  then prints `cm_clone_empty() result timeout=5000 cleanup=SHUTDOWN` and all four servers are gone.
  - I chose SHUTDOWN over inheriting `m_call`, as the hunter recommends. A source from `connect_server` (NOTHING) would
    otherwise still leak, and the forked server exists only for the clone.
  - Behaviour change: code that relied on the forked server outliving its handle must now opt out with
    `set_cleanup_call(NOTHING)`. Its address is only reachable through the handle, so this is unlikely.
  - Document the policy in `cm_clone_empty`.

---

### lua-lifecycle-2: every input rejected by a Lua conversion helper leaks its C++ exception object
- **Verdict: CONFIRMED.** Hunter PoC (`hunter/lua-lifecycle/catch-leak`) prints the same 395 bytes per input.
- **Independent reproducer:** `verify-final/lua-lifecycle-2/run.sh`. It uses a different technique: an `LD_PRELOAD`
  interposer that counts `__cxa_allocate_exception` against `__cxa_free_exception`. I checked the interposer with a
  plain C++ throw/catch control, which gives 1000/1000. It also counts per helper, and measures RSS separately.
  ```
  none        allocated=    0 released=    0 never released=    0
  capi_error  allocated= 2000 released= 2000 never released=    0   (control: C API catches, binding raises after)
  fromjson    allocated= 1000 released=    0 never released= 1000
  tojson      allocated= 1000 released=    0 never released= 1000   (invalid UTF-8 string)
  frombase64  allocated= 1000 released=    0 never released= 1000
  fromhex     allocated= 1000 released=    0 never released= 1000
  RSS growth over 100000 rejected fromjson inputs: 38536 kB (395 bytes each)
  BUG REPRODUCED
  ```
- **Root cause:** `luaL_error` is called inside C++ `catch` handlers:
  - `src/clua-cartesi.cpp:115-184`: `tobase64`, `frombase64`, `tohex`, `fromhex`, `tojson`, `fromjson`, and also
    `cartesi_mod_new`.
  - `src/clua-i-machine.cpp:616-618` (`clua_tojson`) and `:631-633` (`clua_fromjson`).

  With C-built Lua 5.4, `lua_error` longjmps, so `__cxa_end_catch` never runs. Each exception stays on the thread's
  caught-exceptions chain forever. The chain is reachable from TLS, which is why LeakSanitizer does not flag it. Machine
  methods that convert Lua config tables through `clua_tojson` (for example `remote(config)` with a bad table) leak
  the same way.
- **Severity: Low (agree).**
  - About 400 bytes per rejected input, growing without bound.
  - It matters only for long-lived Lua services that validate untrusted input with these helpers, such as the
    `doc/recipes/game-transport.lua` pattern.
  - The node uses the C API, which catches correctly.
- **Fix assessment:** validated (`build/src/clua-cartesi.cpp`, `clua-i-machine.cpp`). Inside the handler, build the
  message (`luaL_where` + `lua_pushstring`/`pushfstring` + `lua_concat`), leave the handler, then call `lua_error`.
  - Result: allocated equals released for every helper, and RSS growth is 0 kB over 100,000 rejections.
  - Messages are unchanged, for example `failed to parse JSON from a string: [json.exception.parse_error.101] …`.
  - Successful conversions are unaffected.
  - The same pattern should be applied to every remaining `luaL_error` inside a `catch` in the bindings.

---

## Files
- Independent reproducers: `<SCRATCH>/verify/verify-final/{devices2-1,cli-hashes-1,cli-hashes-2,cli-hashes-3,uarch-isa-1,lua-lifecycle-1,lua-lifecycle-2}/run.sh`.
  The last outputs are in `last-output.txt` next to each one.
- Running the reproducers against the fixes:
  - `LOCAL_ONLY=1 LUA_CPATH_5_4="<V>/build/src/?.so;…"` for devices2-1 (case [2] then runs on local machines).
  - `CLI="lua5.4 <V>/fixlua/cartesi-machine.lua"` for cli-hashes-1.
  - `LUA_PATH_5_4="<V>/fixlua/?.lua;…"` for cli-hashes-2.
  - `EXTRA_LUA_PATH="<V>/fixlua/?.lua"` for cli-hashes-3.
  - `CARTESI_SRC=<V>/build/src` for lua-lifecycle-1.
  - `EXTRA_LUA_CPATH="<V>/build/src/?.so"` for lua-lifecycle-2.
- Fix diffs: `<SCRATCH>/verify/verify-final/fixes.diff`.
- Hunter PoC copies: `<SCRATCH>/verify/verify-final/hunter/`.
- The `uarch-isa-1` generator links `verify-final/build/src/libcartesi.a`. If it is deleted, rebuild it with
  `nice make -j2 libcartesi.a` in `build/src`.
