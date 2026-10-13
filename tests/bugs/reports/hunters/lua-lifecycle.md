# Angle: lua-lifecycle (object lifetimes in the Lua bindings)

Scope: `src/clua.cpp/.hpp`, `src/clua-i-machine.cpp/.hpp`, `src/clua-cartesi.cpp`, `src/clua-cartesi-jsonrpc.cpp`,
plus the JSON-RPC client lifetime code they drive (`src/jsonrpc-machine.cpp`, `src/cm-jsonrpc.cpp`).
Topics covered: `machine:move()` (commit 66a8a67), `swap`, `__gc`/`__close` ordering, use after move/close/destroy,
machines held by closures and coroutines, errors raised while C++ objects are on the stack, remote handles after
server shutdown or fork, and the lifetime of returned strings and buffers.

`<SCRATCH>` = `<SCRATCH>`
Reproducers: `<SCRATCH>/work/lua-lifecycle/run.sh` runs all of them (exit 1 = a bug reproduced). Instrumented runs
use the campaign ASan `cartesi.so`/`jsonrpc.so`/server with the ASan Lua 5.4.6 from `work/cli-lua/luasan2`
(see `work/lua-lifecycle/env.sh`).

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| lua-lifecycle-1 | Remote `machine(config)` (`cm_clone_empty` on a JSON-RPC handle) forks a server whose handle has cleanup NOTHING and no timeout: closing every handle leaks a server process that still holds the machine | PROVEN | Medium |
| lua-lifecycle-2 | Every input rejected by the Lua conversion helpers leaks about 400 bytes, because `luaL_error` longjmps out of a C++ `catch` (adds measurements to a cli-lua observation) | PROVEN (extra evidence) | Low |
| lua-lifecycle-3 | `luaL_error(L, "%s", cm_get_last_error_message())` formats a pointer into the C API's thread-local error string after `luaL_where()` can already have run a GC step and Lua finalizers | UNPROVEN | Low |

Negative results (ASan, `work/lua-lifecycle/negative/run.sh`, all clean): `move()` out of a `<close>` scope and reuse of
the source; `move()` of empty or destroyed handles; `swap(self)`; use after `<close>` through the handle or through a
cached method (`clua_gc`/`clua_close` clear the metatable, so the call fails with a Lua error before it reaches C++);
machines captured by closures; `<close>` machines in coroutines that error, are closed, or are abandoned and
collected; conversion errors inside coroutines. Remote handles: use after `shutdown_server()` (clean "remote server
was shutdown" error), `fork_server()`/`swap`/`move` combinations, a second handle whose server was shut down through
another handle, and DESTROY cleanup against a dead server (fails silently as documented). The order of finalizers is
safe: a finalizer that touches an already-finalized machine gets a Lua error, not a use-after-free. Temporary strings
returned by the C API (`cm_set_temp_string`) are always copied (`lua_pushstring`/`json::parse`) before the bindings
make any Lua allocation, so a GC step cannot overwrite them first. Already reported elsewhere and not repeated here:
Lua stack overflow in the JSON converters (cli-lua-1), `clua_gc`/`clua_close` without a type check, and the
numeric-keys issue (cli-lua-4).

---

### lua-lifecycle-1: remote `machine(config)` leaks a forked server process (cleanup and timeout not inherited)
- Status: PROVEN
- Area: Lua bindings / JSON-RPC client (also C API `cm_clone_empty`)
- Category: resource leak / DoS
- Where: `src/jsonrpc-machine.cpp:605-622` (`jsonrpc_machine::do_clone_empty`: `fork_server()` then
  `new jsonrpc_machine(fork_result.address)` with the default `m_call = cleanup_call::nothing` and `m_timeout = -1`),
  reached from `src/clua-i-machine.cpp:1506-1534` (`machine_meta_call`, the `__call` "class constructor" of every
  machine object) and `src/cm.cpp:569-581` (`cm_clone_empty`). Compare `src/cm-jsonrpc.cpp:143-145`
  (`cm_jsonrpc_fork_server`), which copies the cleanup call and the timeout from the source handle as documented in
  `cm-jsonrpc.h:89-92`.
- Problem: calling a remote handle as a constructor (`remote(config)` / `remote(dir)`) forks a new server process
  and returns a handle to it. That handle has cleanup NOTHING, so closing or collecting it never shuts the forked
  server down. The source handle's own SHUTDOWN/DESTROY policy covers only the original server. The new handle also
  loses the source's timeout (`-1` = wait forever), so a stuck server hangs the caller with no limit, even if the
  source handle had a timeout. No API documents either difference (`cm.h:459-468`).
- Scenario: `doc/recipes/run-remote-config.lua:9-20` is the documented recipe for remote machines. It opens the
  server with `set_cleanup_call(SHUTDOWN)` ("shut it down automatically on exit") and then creates the machine with
  `cartesi_jsonrpc_machine(config)`. `run-rolling-calculator.lua:55` and `run-rolling-calculator-output-proofs.lua:66`
  load templates the same way. Each run leaves an orphan `cartesi-jsonrpc-machine` process holding the whole machine
  (RAM and drives). A long-lived Lua service or C API client that builds machines this way leaks one server per
  machine until the host runs out of memory or processes. The test suites never hit this because they use
  `fork_server():set_cleanup_call(SHUTDOWN)` instead (`tests/lua/machine-bind.lua:259-260`).
- Evidence: `<SCRATCH>/work/lua-lifecycle/clone-leak/run.sh` (release build; the leaked server is shut down at the end)
  ```
  source handle  timeout/cleanup:	5000	2
  machine(config) timeout/cleanup:	-1	0
  fork_server()   timeout/cleanup:	5000	2
  server at 127.0.0.1:46685 still alive after all handles were closed (machine present: true)
  BUG REPRODUCED: remote machine(config) leaks a forked server process
  ```
- Possible solution: in `do_clone_empty`, give the clone the same policy as `fork_server`:
  `clone->set_cleanup_call(m_call); clone->set_timeout(m_timeout);`. A source with cleanup NOTHING (from
  `connect_server`) still yields a clone that owns a server nobody else knows about, so it is better to default the
  clone to `cleanup_call::shutdown` (the server was created for this handle, as with `spawn_server`). Document the
  behaviour in `cm_clone_empty`.
- Severity: Medium — the documented API usage leaks a server process (with a full machine) per machine created.
  Repeated use exhausts host memory or processes. Hashes are not affected.
- Risks: if unfixed, remote recipes and tools leak servers. The fix changes cleanup behaviour only. Code that kept
  using the forked server after deleting its handle (unlikely, since its address is only reachable through that
  handle) would need `set_cleanup_call(NOTHING)`.

---

### lua-lifecycle-2: each input rejected by the Lua conversion helpers leaks about 400 bytes (`luaL_error` from inside `catch`)
- Status: PROVEN (quantifies a Low item in cli-lua "Other observations"; same root cause)
- Area: Lua bindings
- Category: memory leak / DoS
- Where: `src/clua-i-machine.cpp:616-618` (`clua_tojson`), `:631-633` (`clua_fromjson`), `:228-233`,
  `:1159-1161`; `src/clua-cartesi.cpp:123-184` (`tobase64`/`frombase64`/`tohex`/`fromhex`/`tojson`/`fromjson`).
- Problem: these functions call `luaL_error` inside a C++ `catch` block. Lua is built as C, so `lua_error` longjmps
  and `__cxa_end_catch` never runs: the exception object stays on the thread's caught-exception list forever.
  Destructors of C++ objects that are still live on the stack are skipped as well, which is formally undefined
  behaviour.
- Scenario: `doc/recipes/game-transport.lua:583` runs `pcall(cartesi.fromjson, line)` on every line received from a
  network peer, and `:489` does the same for replies (with schemas). Every malformed line leaks memory for the life
  of the server process. A long-running Lua service that validates untrusted JSON, Base64 or hex with these helpers
  grows without bound.
- Evidence: `<SCRATCH>/work/lua-lifecycle/catch-leak/run.sh`
  ```
  200000 rejected JSON documents: RSS 14940 kB -> 92024 kB (395 bytes per rejected input)
  BUG REPRODUCED: memory leaked on every rejected input
  ```
- Possible solution: never raise a Lua error from inside a handler. Copy the message, leave the `catch`, then raise:
  `bool failed = false; try { ... } catch (const std::exception &e) { lua_pushstring(L, e.what()); failed = true; }
  if (failed) return lua_error(L);`. Use a small helper (`clua_protect(L, fn)`) so the pattern is applied everywhere.
- Severity: Low — slow, unbounded leak driven by rejected inputs (about 400 bytes each).
- Risks: none. Error messages stay the same.

---

### lua-lifecycle-3: error message pointer formatted after a possible GC step
- Status: UNPROVEN (code reading; a bounded attempt to show it under ASan did not reproduce it)
- Area: Lua bindings / C API error reporting
- Category: lifetime of returned strings
- Where: about 60 call sites of the form `return luaL_error(L, "%s", cm_get_last_error_message());` across
  `src/clua-i-machine.cpp` and `src/clua-cartesi-jsonrpc.cpp`. `cm_get_last_error_message()` returns
  `c_str()` of a thread-local `std::string` (`src/cm.cpp:69-71,155-171`), which every later C API call clears or
  reassigns.
- Problem: the pointer is evaluated before `luaL_error` runs. `luaL_error` calls `luaL_where()` first, and its
  `lua_pushfstring` can trigger a GC step, which can run Lua `__gc` finalizers. Only after that does
  `lua_pushvfstring` read the pointer. If a finalizer calls any cartesi method in between, the binding reports the
  wrong message: an empty one if the inner call succeeds (`clear()`), or a stale buffer if a longer error message
  forced the string to reallocate. Bindings that keep `m.get()` across a call that can allocate are affected in a
  similar way. Examples are `log_step` with a numeric filename and the argument-evaluation order under clang/macOS,
  where `m.get()` is evaluated first.
- Scenario: needs Lua code whose finalizers call the machine API (for example a wrapper whose `__gc` calls
  `machine:destroy()` on a remote handle). The release CLI and the recipes do not do this during normal calls.
- Possible solution: copy the message before any Lua allocation, e.g.
  `static int clua_cm_error(lua_State *L) { lua_pushstring(L, cm_get_last_error_message()); luaL_where(L, 1);
  lua_insert(L, -2); lua_concat(L, 2); return lua_error(L); }` (`lua_pushstring` copies the string before its own GC
  check). Load `m.get()` only right before each C API call.
- Severity: Low — needs unusual finalizers; the effect is a wrong or garbled error message.
- Risks: none.
