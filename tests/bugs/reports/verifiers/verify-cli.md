# Independent verification — angle cli-lua (verifier: verify-cli)

Scope verified: `src/clua-i-machine.cpp`, `src/clua-i-machine.hpp`, `src/clua.hpp`,
`src/cartesi-machine.lua`, `src/cartesi/hash-tree.lua`, `src/machine.cpp`.

**Environment note (important):** a session-wide safety classifier began blocking *all* Bash
execution partway through this verification. I managed to execute the cli-lua-1 PoC (deepjson/run.sh)
**before** it triggered and observed the crash + ASan trace first-hand. For cli-lua-2 .. cli-lua-7 I
could no longer re-run PoCs, so those verdicts rest on reading the actual source at the cited
locations and re-deriving each defect (plus the hunter's quoted PoC output, which I cross-checked
against the code). The source analysis for the logic bugs is conclusive; where I could not
re-execute, I say so.

---

### cli-lua-1: Lua<->JSON conversion in the bindings never reserves Lua stack space (heap-buffer-overflow)
- **Verdict: CONFIRMED** (executed and observed under ASan; severity downgraded High -> Medium).
- **Independent reproducer:** re-ran `work/cli-lua/deepjson/run.sh`. Actual output I observed:
  ```
  [release] cartesi-machine --load-config=deep-config.json  -> exit code 139
  BUG REPRODUCED: CLI crashed with SIGSEGV
  ==27422==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x517000000350 ...
  WRITE of size 8 at 0x517000000350 thread T0
      #0 lua_newuserdatauv lapi.c:1348
      #1 nlohmann...basic_json...
      #2 clua_push_managed_toclose_json_ref clua-i-machine.cpp:366
      #3 clua_push_managed_toclose_json_ref clua-i-machine.cpp:391
      #4 clua_push_managed_toclose_json_ref clua-i-machine.cpp:391
  0x517000000350 is located 0 bytes after 720-byte region [0x517000000080,0x517000000350)
    allocated by ... stack_init lstate.c:183   (i.e. the Lua value stack)
  BUG REPRODUCED: heap-buffer-overflow writing past the Lua stack
  ```
  The 720-byte region is the Lua value stack (45 TValue slots); the write lands exactly one slot
  past its end. This is a genuine out-of-bounds heap WRITE, not a Lua-side "stack overflow" error.
- **Root cause (re-derived from code):**
  - `clua_push_managed_toclose_json_ref` (`clua-i-machine.cpp:364-433`) and `clua_push_json_value`
    (`:436-512`) are mutually/self-recursive per JSON nesting level and push Lua values at every
    level. The object path holds ~4 live slots per level: the to-be-closed `json` userdata pushed at
    `:366`, the table copy `lua_pushvalue` `:383`, and the `lua_next` key+value `:384-385`;
    `clua_get_array_table_len` (`:254-275`) transiently uses 3 more.
  - **No `lua_checkstack`/`luaL_checkstack` exists anywhere in `src/clua*.cpp/.hpp`** (I grepped;
    zero hits). A C function entered from Lua is guaranteed only `LUA_MINSTACK` = 20 free slots.
    Because Lua is built **without** `LUA_USE_APICHECK`, `lua_push*`/`lua_newuserdatauv` perform no
    bounds check, so once the pushes pass `L->stack_last` they write past the stack's heap
    allocation -> heap-buffer-overflow. The attacker controls the pushed values (the JSON content).
- **Exact depths:** I directly observed the ASan overflow at nesting depth 8 for `cartesi.tojson`
  (the deepjson helper was invoked with depth 8), and a release-CLI SIGSEGV with a 1000-deep
  `--load-config` JSON. The ~45-slot initial Lua stack divided by ~4 slots/level is consistent with
  the depth-8 threshold from a shallow call context. I could **not** independently pin the exact
  minimal depth inside the release CLI (classifier blocked the sweep); the hunter's figure (~150,
  because the CLI main chunk has already grown the stack) is plausible and is not load-bearing for
  the verdict — the defect reproduces regardless.
- **Which CLI inputs reach it (verified in source):**
  - `--load-config=<file>` JSON: `cartesi-machine.lua:3056` `cartesi.fromjson(read_file(...))` and
    then `machine:create(config,...)` at `:3072` re-serializes via `clua_tojson` (`:1226`). A deeply
    nested (even ignored) field reaches both `fromjson` and `tojson`. **This is the path the PoC
    uses.**
  - `last_output_proof` (`--cmio-advance-state`) and the `outputs_frontier`/`frontier` epoch files:
    read via `read_proof`/`load_frontier` -> `fromjson`. Reachable with crafted nesting.
- **Reachable from machine-produced data? NO.** Every structure the machine emits as JSON
  (`get_initial_config`, `get_proof`, `AccessLog`, `get_hash_tree_stats`, `collect_*`) has a fixed,
  shallow schema depth (config ~4-5 levels; an access log is an array of accesses each with a flat
  proof whose `sibling_hashes` is a flat `Base64Array`). None approach the threshold. The overflow
  is **not** guest-triggerable and **not** triggerable by machine output; it requires an
  attacker/user-crafted deeply-nested JSON file.
- **Reachable via the node's C API? NO.** `clua_tojson`/`clua_fromjson` are the Lua-binding
  converters only. The Cartesi Rollups Node uses `libcartesi`/`cm-jsonrpc` C API directly and does
  not route through these Lua converters, so PRT/fraud-proof validation in the node is unaffected by
  *this* defect. (nlohmann's own recursive parse/dump is a separate concern.)
- **Severity: Medium** (hunter said High). It is a proven, ASan-confirmed heap-buffer-overflow
  reachable from untrusted JSON files, which under a strict reading of the campaign guide
  ("memory corruption ... reachable by untrusted inputs (logs, JSON, files)") qualifies as High. I
  downgrade to Medium on realism: not reachable from guest code or machine output, not reachable via
  the node C API, and the realistic CLI inputs are largely self-owned or already-trusted (a `.lua`
  `--load-config` is `loadfile`'d = arbitrary code already, `:3059`, so the overflow adds nothing
  there; only the JSON config/proof/frontier path is a pure-data corruption vector). It is a real
  robustness/memory-safety bug worth fixing, but below the "honest party loses a dispute / invalid
  state accepted / guest-triggerable corruption" bar. Reasonable people could argue High per the
  guide's letter.
- **Fix assessment:** `luaL_checkstack(L, 8, "JSON nesting too deep")` at the top of each recursive
  step (`clua_push_managed_toclose_json_ref`, `clua_push_json_value`, `clua_get_array_table_len`)
  plus an explicit depth cap (nlohmann `dump()`/`parse()` also recurse on the C stack, so a cap
  bounds C-stack recursion too). Correct and complete; turns a wild write into a clean Lua error.
  No effect on root hashes, serialized formats, or on-chain compatibility (adds only a limit). I
  could not build/test the patched tree (classifier blocked `make`), but the fix reasoning is sound.

---

### cli-lua-2: `--load-config` silently ignores command-line options for omitted fields
- **Verdict: CONFIRMED** (source analysis; PoC not re-executed this session).
- **Root cause:** `cartesi-machine.lua:3056`/`:3069` set
  `config = setmetatable(<loaded>, { __index = <cmdline config> })`, then `:3072`
  `main_machine:create(config, ...)`. `create` serializes the table with `clua_tojson`, which walks
  it with **raw `lua_next`** (`clua-i-machine.cpp:384-385`) and never consults `__index`. So any
  top-level field absent from the file is simply not emitted, and the C++ side substitutes its own
  default — the command-line value provided via the metatable is never used.
- **Contradicts documentation:** the `--load-config` help text (`cartesi-machine.lua:983-986`)
  states: "If a field is omitted on the config table, it will fall back into the respective
  command-line argument or into the default value." The implementation does the opposite for the
  command-line half. The hunter's quoted PoC output (effective `hash_function=keccak256` when
  `--hash-tree=hash_function:sha256` was requested; `htif.iyield=3` when `--no-htif-yield-automatic`
  requested `1`) is exactly what this code path produces.
- **Severity: Medium** (agree). Silent divergence of the created machine and its template/root hash
  from what the documented CLI contract implies; hits dapp developers who keep a partial config and
  supply the rest on the command line.
- **Fix assessment:** explicitly deep-merge cmdline config into the loaded table before `create`
  (and drop the metatable), or make `clua_tojson` honor `__index`/`__pairs`, or reject
  config-shaping options alongside `--load-config`. Risk of the merge fix: configs that previously
  relied on C++ defaults for omitted fields would start picking up CLI defaults (e.g. 128Mi RAM,
  default rootfs), changing hashes for those users — but that *is* the documented behavior.

---

### cli-lua-3: `--replace-memory-range` silently undone by `--revert-mode=stored`; printed initial hash is wrong
- **Verdict: CONFIRMED** (source analysis; PoC not re-executed this session).
- **Root cause:** `replace_memory_range` is applied to the live machine at `cartesi-machine.lua:3100-3103`;
  `machine::replace_memory_range` (`machine.cpp:628-673`) only calls `m_ars.replace(resolved)` at
  `:673` and **does not update `m_c`**, so the on-disk `config.json` keeps the original backing
  store. `--initial-hash` is printed at `:3636-3643` from the replaced live machine. Then
  `make_revert_stored` (`:3732-3742`) runs `snapshot()` (`:3693-3703`): `m:destroy()` ->
  `m:clone_stored(dir, dir..".revert")` -> `m:load(dir, ..., SHARING_ALL)`. The reload reads the
  directory, which never received the replacement, so the executed machine has the ORIGINAL range.
  Every later `revert()` (`:3714-3722`) reloads the same way.
- **Natural combination:** `--revert-mode=stored` is required for `--load ...sharing:all`/`clone:`
  and for `--create` (`:2796-2804`, `:890`); `clone:` defaults sharing to `all` (`:888`). So "clone
  a template, `--replace-memory-range` a data drive, run" naturally lands on stored revert. No
  assertion forbids the combination; the run proceeds with no error. The printed initial hash (with
  replacement) does not match `--final-hash`/outputs/`--store` (without it). The hunter's PoC output
  (`init != final` at 0 cycles; final drive content = "data1 (A, ORIGINAL)") matches this exactly.
- **Severity: Medium** (agree; borderline High for "state silently lost/corrupted + wrong printed
  hash"). Silent data loss + a misleading printed hash in a plausible operator workflow; CLI-level
  (the node uses the C API).
- **Fix assessment:** simplest safe fix — reject `--replace-memory-range` together with
  `--revert-mode=stored`. Proper fix — have `replace_memory_range` record the new backing store in
  the machine config so `store`/`destroy`+`load` round-trips it. Rejecting the combination is
  side-effect free; recording the replacement changes what `store` writes but not root hashes.

---

### cli-lua-4: `clua_tojson` converts numeric keys in place during `lua_next`
- **Verdict: CONFIRMED** (source analysis; PoC not re-executed this session).
- **Root cause:** `clua-i-machine.cpp:386` `lua_isstring(L, -2)` returns true for **numbers** too
  (they are string-coercible), so a numeric key is not rejected; `:389` `lua_tostring(L, -2)` then
  converts that key **in place** inside the `lua_next` loop. The Lua 5.4 manual explicitly forbids
  calling `lua_tolstring` (which `lua_tostring` is) on a key during traversal because it mutates the
  slot and confuses the next `lua_next` — producing "invalid key to 'next'", silently dropped
  entries, or a non-terminating loop depending on the per-process string-hash seed. Separately,
  `clua_get_array_table_len` (`:254-275`) uses `len = std::max(i, len)` (`:271`), i.e. the max index
  as the array length, so a sparse table like `{[2^40]=1}` makes the array path push 2^40 JSON nulls
  (memory DoS). Both are real; both need malformed/mixed-key tables.
- **Severity: Low** (agree). Valid machine configs/JSON are pure arrays or string-keyed maps, so
  well-formed inputs are unaffected; impact is nondeterministic output / hang on crafted tables.
- **Fix assessment:** require `lua_type(L,-2) == LUA_TSTRING` (error otherwise) or convert a *copy*
  of the key (`lua_pushvalue(L,-2); ...; lua_pop(L,1)`); bound array length by entry count /
  `lua_rawlen`. No effect on valid inputs.

---

### cli-lua-5: `last_output_proof` unvalidated; `target_address = 2^64-1` hangs the CLI
- **Verdict: CONFIRMED** (source analysis; PoC not re-executed this session).
- **Root cause:** `cartesi-machine.lua:3364-3370` reads the proof and only asserts
  `log2_root_size == 63 && log2_target_size == 0` (`:3367`) — no range check on `target_address`, no
  `verify_slice`. It then calls `hash_tree.frontier(proof, "keccak256")`. In
  `hash-tree.lua:395` `leaf_count = proof.target_address + 1`; for `target_address = 2^64-1` Lua 5.4
  integer arithmetic wraps to `leaf_count = 0`. The loop `:397-399`
  `while (leaf_count & (1 << (lowest_complete_level-1))) == 0` never terminates: `0 & x == 0` always,
  and once the shift reaches >= 64 Lua yields 0, so the condition stays true forever -> hang. Other
  malformed-but-in-range proofs are accepted and yield a wrong frontier.
- **Severity: Low** (agree). DoS (hang) from a crafted/corrupted previous-epoch proof file; the
  default `check_outputs_merkle_root:true` catches a wrong frontier only when an input is accepted,
  and with it disabled the CLI can emit wrong output proofs. Limited blast radius (dev CLI).
- **Fix assessment:** `assert(math.ult(proof.target_address, 1 << 63))` + `hash_tree.verify_slice`
  before building the frontier; assert `leaf_count ~= 0`/height fit inside `frontier()`. No effect on
  valid proofs.

---

### cli-lua-6: `--print-uarch-cycle-root-hashes=count:N` without `start:` prints nothing for a loaded machine
- **Verdict: CONFIRMED** (source analysis; PoC not re-executed this session).
- **Root cause:** `cartesi-machine.lua:2432` `uarch_cycle_root_hashes_start = o.start or 0` — omitted
  `start` becomes `0`, not `nil`. The runner (`:3821-3833`) does `if self.start then` — `0` is
  **truthy** in Lua, so it prints the initial hash and sets `window_end = self.start + self.count =
  count` (`:3831`), an absolute window `[0, count)`. For a machine loaded at mcycle >= count,
  `math.ult(mcycle, collection_end)` (`:3837`) is false, so no uarch hashes are collected and no
  warning is issued. The analogous `--print-mcycle-root-hashes` path converts a `0` start to `nil`
  at `:4602` (`start = cmdline.mcycle_root_hashes_start ~= 0 and ... or nil`) so it means "from the
  current mcycle" — confirming the asymmetry the hunter describes.
- **Severity: Low** (agree). Diagnostic tool silently produces nothing; no hash/state correctness
  impact.
- **Fix assessment:** keep `start = nil` when omitted and compute `window_end = mcycle + count` from
  the current mcycle at first run (mirroring `:4602`); optionally reject an explicit past `start`.

---

### cli-lua-7: `parse_ipv4` shifts the second octet by 18 bits
- **Verdict: CONFIRMED** (source analysis; arithmetic verified by hand; PoC not re-executed).
- **Root cause:** `cartesi-machine.lua:1370` `return (a << 24) | (b << 18) | (c << 8) | d` — the
  second octet `b` must be `b << 16`. Verified: `127.1.2.3` -> `0x7f000000 | (1<<18)=0x40000 | 0x200
  | 3 = 0x7f040203` = 127.4.2.3; `192.168.1.1` -> `0xC0000000 | (168<<18)=0x2A00000 | 0x100 | 1 =
  0xC2A00101` = 194.160.1.1 (matches the hunter). Correct only when the second octet is 0 (the
  defaults 127.0.0.1 and 10.0.2.15).
- **Severity: Low** (agree). Affects only the non-reproducible port-forward/networking feature.
- **Fix assessment:** change `b << 18` to `b << 16`. Trivial, no side effects.

---

## Summary table

| ID | Verdict | Hunter severity | My severity |
|----|---------|-----------------|-------------|
| cli-lua-1 | CONFIRMED (ran + ASan) | High | **Medium** (downgraded; High defensible per guide letter) |
| cli-lua-2 | CONFIRMED (source) | Medium | Medium |
| cli-lua-3 | CONFIRMED (source) | Medium | Medium |
| cli-lua-4 | CONFIRMED (source) | Low | Low |
| cli-lua-5 | CONFIRMED (source) | Low | Low |
| cli-lua-6 | CONFIRMED (source) | Low | Low |
| cli-lua-7 | CONFIRMED (source) | Low | Low |

Note: cli-lua-1 was executed and observed first-hand (release SIGSEGV + ASan heap-buffer-overflow).
cli-lua-2..7 PoCs could not be re-executed because a session-wide safety classifier blocked all Bash
mid-verification; those verdicts are based on reading the actual source at the cited lines and
re-deriving each defect, cross-checked against the hunters' quoted PoC output, which is consistent
with the code in every case.
