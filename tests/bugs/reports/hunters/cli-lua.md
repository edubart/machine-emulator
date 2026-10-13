# Angle: cli-lua (cartesi-machine CLI, Lua helpers, Lua C bindings)

Scope: `src/cartesi-machine.lua`, `src/cartesi-machine-stored-hash.lua`, `src/cartesi/util.lua`,
`src/cartesi/hash-tree.lua` (CLI use), `src/clua.cpp/.hpp`, `src/clua-cartesi.cpp`,
`src/clua-cartesi-jsonrpc.cpp`, `src/clua-i-machine.cpp/.hpp`.

`<SCRATCH>` = `<SCRATCH>`
PoCs: `<SCRATCH>/work/cli-lua/<dir>/run.sh` (each prints `BUG REPRODUCED` and exits 1 when the bug is present).

Instrumentation used: `<SCRATCH>/work/cli-lua/luasan2/lua-5.4.6/src/lua` is Lua 5.4.6 (official tarball, sha256
7d5ea1b9…ad88) built with `-fsanitize=address`, so that writes performed by the Lua API on behalf of the
bindings are checked. It is combined with the campaign's ASan build of `cartesi.so` (`<SCRATCH>/asan/src`).
A second build `luasan/` adds `-DLUA_USE_APICHECK`.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| cli-lua-1 | Lua<->JSON conversion in the bindings never reserves Lua stack space: nested tables/JSON overflow the Lua stack (heap-buffer-overflow) | PROVEN | High |
| cli-lua-2 | `--load-config` silently ignores command-line options for fields omitted from the config file (documented fallback not implemented) → different machine / root hash | PROVEN | Medium |
| cli-lua-3 | `--replace-memory-range` is silently undone by `--revert-mode=stored`; printed `--initial-hash` is not the machine that runs | PROVEN | Medium |
| cli-lua-4 | `clua_tojson` converts numeric keys in place during `lua_next` → spurious errors, silently dropped fields, or infinite loop (hash-seed dependent) | PROVEN | Low |
| cli-lua-5 | `last_output_proof` is used without any validation; `target_address = 2^64-1` hangs the CLI forever | PROVEN | Low |
| cli-lua-6 | `--print-uarch-cycle-root-hashes` without `start:` uses absolute window `[0,count)`: on a loaded machine nothing is printed | PROVEN | Low |
| cli-lua-7 | `parse_ipv4` shifts the 2nd octet by 18 instead of 16 → wrong port-forward IP addresses | PROVEN | Low |

---

### cli-lua-1: Lua<->JSON conversion never reserves Lua stack space: nesting overflows the Lua stack (heap-buffer-overflow)
- Status: PROVEN
- Area: Lua bindings (clua) / CLI
- Category: memory-safety
- Where: `src/clua-i-machine.cpp:364-433` (`clua_push_managed_toclose_json_ref`, used by `clua_tojson` and
  `clua_tojsonschemadict`), `:436-517` (`clua_push_json_value`, used by `clua_fromjson`), `:254-275`
  (`clua_get_array_table_len`). There is no `lua_checkstack`/`luaL_checkstack` call anywhere in `src/clua*.cpp`.
- Problem: a C function is only guaranteed `LUA_MINSTACK` (20) free stack slots. Both converters are
  recursive and push Lua values at every nesting level without ever growing the stack:
  `clua_push_managed_toclose_json_ref` keeps ~4 slots alive per object level (the to-be-closed json userdata,
  a copy of the table, the `lua_next` key and the value) plus 3 transient slots in
  `clua_get_array_table_len`; `clua_push_json_value` keeps 1 table per level (+3 for Base64/Hex strings). Once
  the pushes pass `ci->top` they write past the end of the Lua stack allocation (`lua_push*` does no bounds
  check unless Lua is built with `LUA_USE_APICHECK`). With `LUA_USE_APICHECK` the API assertion
  `"stack overflow"` already fires at nesting depth 4 for `cartesi.tojson`; the actual heap overflow happens
  at depth 8 for `tojson` and ~15-30 for `fromjson` in a fresh `lua` process, and at ~150 levels inside the
  CLI (whose main chunk has a large stack). Every API that converts a table or JSON document is affected:
  `cartesi.tojson/fromjson`, `cartesi.machine(config, runtime)`, `machine:create/load/set_runtime_config/
  replace_memory_range/verify_step_uarch/verify_reset_uarch/verify_send_cmio_response/
  collect_*(…, previous_partial_bundle / revert_uarch_tail)` and every method returning JSON.
- Scenario: the CLI parses JSON files with `cartesi.fromjson` and converts them back with `tojson`:
  `--load-config=<file>.json` (config files are shared between developers), `last_output_proof`, and the
  epoch state files `outputs_frontier` / mcycle `frontier` (persisted between invocations in resumable
  epochs). A corrupted or malicious file with a deeply nested (even unknown/ignored) field corrupts the heap
  of the process that builds snapshots / computes template and computation hashes. Lua tools built on the
  bindings are hit with much shallower data: any JSON or table nested 8 levels deep (common in real JSON)
  overflows the stack when converted from a shallow call context.
- Evidence: `<SCRATCH>/work/cli-lua/deepjson/run.sh`
  ```
  [release] cartesi-machine --load-config=deep-config.json  -> exit code 139
  BUG REPRODUCED: CLI crashed with SIGSEGV
  calling cartesi.tojson on a table nested 8 levels
  ==2568==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x517000000350 ...
  WRITE of size 8 at 0x517000000350 thread T0
      #0 lua_newuserdatauv lapi.c:1348
      #1 ...clua_push_new_managed_toclose_ptr<nlohmann::json>...
      #2 clua_push_managed_toclose_json_ref clua-i-machine.cpp:366
      #3 clua_push_managed_toclose_json_ref clua-i-machine.cpp:391
  0x517000000350 is located 0 bytes after 720-byte region [0x517000000080,0x517000000350)
    (allocated by stack_init lstate.c:183, i.e. the Lua stack)
  BUG REPRODUCED: heap-buffer-overflow writing past the Lua stack
  ```
  (`deep-config.json` = `{"ram":{"length":134217728},"x":[[[[…1000 levels…]]]]}`.) Under the ASan Lua the CLI
  itself reports `heap-buffer-overflow ... lua_pushnil ... clua_get_array_table_len clua-i-machine.cpp:260` for a
  150-level config. `fromjson` overflows too (`lua_createtable`/`lua_setfield` from `clua_push_json_value`,
  depth 30). With the release build, `fromjson`+`tojson` of a 15-level array segfaults and 25 levels hangs
  (corrupted heap).
- Possible solution: at the top of each recursive step call `luaL_checkstack(L, 8, "JSON nesting too deep")`
  (in `clua_push_managed_toclose_json_ref`, `clua_push_json_value` and `clua_get_array_table_len`), and impose an
  explicit maximum depth (e.g. 256) to also bound C-stack recursion (nlohmann's `dump()` is recursive too).
- Severity: High — heap memory corruption in the Lua bindings triggered by data (JSON nesting), reachable
  from files the CLI reads; Lua tools using the bindings hit it at nesting depth 8.
- Risks: unfixed, crafted/corrupted config, proof or epoch files can crash the CLI or corrupt its heap while it
  computes hashes. The fix has no effect on hashes or formats (adds only a nesting limit).

---

### cli-lua-2: `--load-config` silently ignores command-line options for omitted fields → different machine and root hash
- Status: PROVEN
- Area: CLI
- Category: input-validation / silent misconfiguration
- Where: `src/cartesi-machine.lua:3055-3072` (`config = setmetatable(<loaded>, { __index = config })` then
  `main_machine:create(config, …)`), `src/clua-i-machine.cpp:254-275, 383-397` (serialization uses raw
  `lua_next`, metatables are ignored).
- Problem: the help text says: "load initial machine config from <filename>. If a field is omitted on the config
  table, it will fall back into the respective command-line argument or into the default value." The CLI tries to
  do this with an `__index` metatable on the loaded table, but `machine:create` serializes the table with
  `clua_tojson`, which walks it with raw `lua_next`. Metatables are ignored, so every top-level field missing from
  the file gets the C++ default. The command-line value is never used. Options silently dropped include
  `--hash-tree=hash_function:…`, `--no-htif-yield-manual/automatic`, `--unreproducible` and the `iunrep` that
  `--network/-v/-it/--sync-init-date` force, `--ram-length/--ram-image`, `--flash-drive/--nvram`, the
  bootargs/init/entrypoint options and the command after `--`, `--uarch-*`, `--pmas`, `--cmio-*-buffer`.
- Scenario: a developer keeps a partial config (e.g. just `ram`, `dtb`, `flash_drive`) and adds the rest on the
  command line, e.g. `--hash-tree=hash_function:sha256` or `--no-htif-yield-automatic`. The machine is created and
  stored without error, with a different hash function and HTIF configuration than requested. The template hash
  differs from what the command line implies and cannot be reproduced from it. A partial config that drops
  `processor` also silently clears the `iunrep` flag that the non-reproducible options set.
- Evidence: `<SCRATCH>/work/cli-lua/loadcfg/run.sh` (partial config = full stored config minus `hash_tree` and
  `processor`; command line gives `--hash-tree=hash_function:sha256 --no-htif-yield-automatic`):
  ```
  with --load-config:    0: 0x184a6f0df09ab4483f62f34c69d97bb775d1552b7549f42a045283fa54daa000
  without --load-config: 0: 0x20a339abca648bc55e62f2b7d6a52bc4c064b3c1678e71fa6ba3c3bdc21a1268
  effective hash_function=keccak256 (requested sha256), htif.iyield=3 (requested 1 = manual only)
  BUG REPRODUCED: command-line options silently ignored for fields omitted from --load-config file
  ```
  A file with only `processor` makes creation fail with "RAM length cannot be zero" even though `--ram-length`
  defaults to 128Mi on the command line.
- Possible solution: merge explicitly before calling `create`, e.g.
  `for k, v in pairs(cmdline.config) do if loaded[k] == nil then loaded[k] = v end end` (or a recursive merge), and
  drop the metatable. Alternatively, make `clua_tojson` honor `__pairs`/`__index`, or reject `--load-config` when
  config-shaping options are also present.
- Severity: Medium — options silently ignored, giving a different machine and template hash than requested.
- Risks: if fixed by merging, a config that relied on C++ defaults for omitted fields will pick up CLI
  defaults (e.g. the 128Mi RAM, the default rootfs drive), which can change hashes for such users. The documented
  behaviour is the merge.

---

### cli-lua-3: `--replace-memory-range` is silently undone by `--revert-mode=stored`; printed `--initial-hash` is not the machine that runs
- Status: PROVEN
- Area: CLI / store-load
- Category: data-loss / silent misconfiguration (wrong printed hash)
- Where: `src/cartesi-machine.lua:3100-3103` (`replace_memory_range` applied to the live machine),
  `:3636-3644` (`--initial-hash` printed), `:3732-3750` (`make_revert_stored` → `snapshot()` at `:3693-3703`:
  `m:destroy(); m:clone_stored(dir, dir..".revert"); …; m:load(dir, …)`). The same reload happens in `revert()`
  (`:3714-3722`). `machine::replace_memory_range` (`src/machine.cpp:628-673`) does not update `m_c`, so the
  directory's `config.json` keeps the original backing store.
- Problem: with `--revert-mode=stored` (the mode required for `--load=…,sharing:all`/`clone:` and for `--create`),
  the CLI applies `--replace-memory-range`, prints `--initial-hash`/`--initial-proof` and checks the
  `state_hash` epoch file. It then builds the stored-revert object, which destroys the machine and reloads it from
  `<directory>`. The reloaded machine has the original range contents because nothing persisted the
  replacement. The run continues on that machine with no error. `--final-hash`, `--store`, outputs and
  computation hashes all describe a machine without the requested replacement, while the printed initial hash
  describes the replaced one. Every later `revert()` (rejected input, inspect) reloads the same way.
- Scenario: an operator loads a template (`--load=work,clone:template`, stored revert) and replaces a data
  drive with `--replace-memory-range=label:data,data_filename:inputs.img` (the documented use of
  `--replace-memory-range`), then runs advance/inspect. The application runs on the template's original drive.
  The printed initial hash (with the replacement) does not match the outputs or final hash. The results are
  silently wrong and cannot be reproduced with `--revert-mode=fork`.
- Evidence: `<SCRATCH>/work/cli-lua/replace-stored/run.sh` (0 cycles executed):
  ```
    0: 0x8e2e5e0857da0e6a4207e297eb6e08a28e9b2bc525dbebca9d9a43d206c0bd18   <- --initial-hash (after replacement)
    0: 0x8cfde5a9384f6aa171337334d05da3f2b12f93ac843c331a7fb24972359838e9   <- --final-hash
    final content of flash drive "data": data1 (A, ORIGINAL)
  BUG REPRODUCED: 0 cycles executed but final hash != printed initial hash; replacement silently lost
  ```
- Possible solution: in the CLI, reject `--replace-memory-range` together with `--revert-mode=stored`. Otherwise,
  build the revert object first and apply the replacements afterwards, re-applying them after every reload,
  which only works for read-only or shared replacements. The real fix is for `replace_memory_range` to record
  the new backing store in the machine config, so that `store`/`destroy`+`load` round-trip it.
- Severity: Medium — state silently differs from what was requested, and the printed hash does not match the
  executed machine.
- Risks: rejecting the combination is safe. Recording replacements in the config changes what `store` writes
  but not root hashes.

---

### cli-lua-4: `clua_tojson` converts numeric keys in place during `lua_next` → errors, dropped fields or infinite loop
- Status: PROVEN
- Area: Lua bindings
- Category: input-validation / DoS / silent data loss
- Where: `src/clua-i-machine.cpp:385-397`: `lua_isstring(L, -2)` accepts numbers and then
  `lua_tostring(L, -2)` converts the key slot in place. The Lua manual forbids this inside a `lua_next` loop.
- Problem: a table that is not a pure array (any non-positive-integer key) but holds numeric keys is traversed
  with a corrupted key. `{[1]=1, x=2}` raises "invalid key to 'next'". `{[1]="a", ["1"]="b", x=3}` gives
  `{"1":"a","x":3}`, `{"1":"a"}` (field `x` silently dropped) or never returns, depending on the per-process
  string hash seed. A sparse array such as `{[2^40]=1}` makes the array path push 2^40 JSON nulls (memory DoS).
- Scenario: a Lua tool or `--load-config` Lua file that builds a table with mixed keys gets non-deterministic
  output or a hang. Impact is limited because well-formed configs are pure arrays or string-keyed maps.
- Evidence: `<SCRATCH>/work/cli-lua/tojson-keys/run.sh`
  ```
  false	invalid key to 'next'
  20 runs of tojson({[1]='a',['1']='b',x=3}): 4 infinite loops, 6 outputs missing key x
  BUG REPRODUCED
  ```
- Possible solution: require `lua_type(L, -2) == LUA_TSTRING` (error otherwise), or convert a copy
  (`lua_pushvalue(L,-2); k = lua_tostring(L,-1); …; lua_pop(L,1)`). Bound the array length by `lua_rawlen` or
  the number of entries.
- Severity: Low — needs malformed tables, but gives non-deterministic output or a hang.
- Risks: none; does not affect valid inputs.

---

### cli-lua-5: `last_output_proof` is not validated; `target_address = 2^64-1` hangs the CLI
- Status: PROVEN
- Area: CLI / cartesi.hash-tree
- Category: input-validation / DoS
- Where: `src/cartesi-machine.lua:3364-3370` (only `log2_root_size == 63` and `log2_target_size == 0` are
  checked; no `verify_slice`, no range check on `target_address`), `src/cartesi/hash-tree.lua:395-399`
  (`leaf_count = target_address + 1` wraps to 0, so `while (leaf_count & (1 << (level-1))) == 0` never ends).
- Problem: the previous epoch's proof seeds the outputs frontier. A proof whose siblings do not roll up to
  `root_hash`, or whose `target_address` is out of range for a 63-level tree, is accepted. With
  `target_address = 2^64-1` the frontier constructor loops forever. Other bad proofs give a wrong frontier.
  The default `check_outputs_merkle_root:true` detects that frontier only when an input is accepted. With
  `check_outputs_merkle_root:false` the CLI writes wrong output proofs.
- Scenario: corrupted or hostile previous-epoch proof file → hang, or silently wrong output proofs when root
  checking is disabled.
- Evidence: `<SCRATCH>/work/cli-lua/lastproof/run.sh` → `cartesi-machine exit code: 124` /
  `BUG REPRODUCED: CLI hangs forever in hash_tree.frontier()`.
- Possible solution: `hash_tree.verify_slice(proof)` plus `assert(math.ult(proof.target_address, 1 << 63))`
  before `hash_tree.frontier(proof, …)`. In `frontier()`, assert `leaf_count ~= 0` and that it fits the height.
- Severity: Low.
- Risks: none.

---

### cli-lua-6: `--print-uarch-cycle-root-hashes=count:N` without `start:` prints nothing for a loaded machine
- Status: PROVEN
- Area: CLI
- Category: option silently ignored
- Where: `src/cartesi-machine.lua:2432` (`uarch_cycle_root_hashes_start = o.start or 0`), `:3821-3833`
  (`window_end = self.start + self.count` is absolute). Compare `--print-mcycle-root-hashes`, where a missing
  start means "from the current mcycle" (`:4602`).
- Problem: when `start` is omitted the window is `[0, count)`. For a machine loaded at mcycle ≥ count the window
  is in the past, so the runner prints the initial hash, runs plainly, and emits no uarch hashes and no
  warning.
- Scenario: a user debugging a dispute loads a snapshot and asks for uarch root hashes of the next N mcycles.
  The run finishes without them and without an error.
- Evidence: `<SCRATCH>/work/cli-lua/uarchhashes/run.sh`
  ```
  uarch-cycle hash lines, loaded at mcycle 1000, count:2 (no start):  0
  uarch-cycle hash lines, loaded at mcycle 1000, count:2,start:1000: 1169
  BUG REPRODUCED: requested uarch cycle root hashes silently not printed
  ```
- Possible solution: keep `start = nil` when not given and set `self.window_end = mcycle + count` from the
  current mcycle at first run. Reject explicit `start` values that are in the past.
- Severity: Low (diagnostic tool).
- Risks: none.

---

### cli-lua-7: `parse_ipv4` shifts the second octet by 18 bits
- Status: PROVEN
- Area: CLI
- Category: input-validation
- Where: `src/cartesi-machine.lua:1370`: `(a << 24) | (b << 18) | (c << 8) | d` should be `b << 16`.
- Problem: every port-forward host/guest IP whose second octet is non-zero is wrong (`127.1.2.3` → `127.4.2.3`,
  `192.168.1.1` → `194.160.1.1`). It works only for the defaults `127.0.0.1` and `10.0.2.15`.
- Evidence: `<SCRATCH>/work/cli-lua/ipv4/run.sh` →
  `requested host_ip 127.1.2.3, configured host_ip 127.4.2.3 (0x7f040203)` / `BUG REPRODUCED`.
- Possible solution: `b << 16`.
- Severity: Low (non-reproducible networking feature only).
- Risks: none.

---

### Other observations (Low, not separately reported)
- With `--load` (and `--no-remote-create`), every option that shapes the config is accepted and silently
  ignored: `--flash-drive`, `--hash-tree`, `--ram-*`, `--no-htif-yield-*`, `--unreproducible`, `--network`, and
  the command after `--`. A warning or error would avoid surprises.
- The bindings map JSON `number_unsigned` ≥ 2^63 to negative Lua integers and serialize them back as negative
  JSON numbers. For example, `--store-config=x.json` writes `"misa": -9223372036853460691`, `"ilrsc": -1`,
  `"imcyclemax": -1`, unlike `cm_get_initial_config`. The emulator round-trips these, but external tools
  expecting uint64 reject them.
- `--assert-rolling-template` only checks for a manual rx-accepted yield and the outputs root. It does not check
  `htif.iyield` (a template built with `--no-htif-yield-automatic` passes) or that the uarch is in reset state
  (e.g. after `--max-uarch-cycle`/`--log-step-uarch` before `--store`).
- `luaL_error` is raised from inside C++ `catch` handlers (`read_memory`, `read_virtual_memory`,
  `read_console_output` on `bad_alloc`, `clua_tojson`/`clua_fromjson`, `cartesi_mod_*`). The longjmp skips
  `__cxa_end_catch`, which leaks the exception object and is formally undefined behaviour.
- `clua_gc`/`clua_close` (`src/clua.hpp:146-163`) do not type-check argument 1:
  `getmetatable(m).__gc(other_userdata)` runs `~clua_managed_cm_ptr` on foreign memory. This needs trusted Lua
  code that calls metamethods directly.
- `report_halt` passes the 47-bit halt payload to `os.exit`, so the exit status is taken modulo 256 (payload 256
  exits with 0).
- Checked and found sound: `util.parse_number` (exact uint64 hex, rejects decimals > 2^63-1, floats, negatives,
  overflowing shifts); `umin`/`usaturating_add`/gdbstub mcycle comparisons (unsigned); `--store-config` →
  `--load-config` round trip (Lua and JSON give identical root hashes); jsonrpc binding type checks
  (`convert_from_c` checks `is_jsonrpc_machine`); `machine:move/swap`, and `__close`/`__gc` ordering for to-be-closed
  managed pointers.
