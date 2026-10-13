# Angle `jsonrpc` — remote machine stack audit (v0.22.0)

Scope: `src/jsonrpc-remote-machine.cpp` (server `cartesi-jsonrpc-machine`), `jsonrpc-machine.cpp/.hpp`
(client), `cm-jsonrpc.cpp/.h`, `json-util.cpp/.hpp`, `base64.cpp`, `hex.cpp`, `os.cpp`,
`jsonrpc-{discover,fork-result,cmio-request,version}.*`.

Work dir / PoCs: `<SCRATCH>/work/jsonrpc/`  (`<SCRATCH>` =
`<SCRATCH>`).
All PoCs are self-contained; the exact run command is in a comment at the top of each file.

## Summary of candidates
| ID | Title | Status | Severity |
|----|-------|--------|----------|
| jsonrpc-1 | Deeply-nested JSON request crashes the whole server (stack overflow) | PROVEN | Medium |
| jsonrpc-2 | Batch of N `fork` entries forks the server 2^N times (fork bomb) | PROVEN | Medium |
| jsonrpc-3 | `read_memory`/`read_virtual_memory`/`read_console_output` + huge length ⇒ unbounded server allocation (OOM); request body is also unbounded | PROVEN | Medium |
| jsonrpc-4 | `delay_next_request` with a huge `ms` freezes the single-threaded server for every client | PROVEN | Low |
| jsonrpc-5 | Equivalence / robustness checks that PASSED (negative results, for assurance) | N/A | — |

Threat model note: the server binds `127.0.0.1` by default, but the C API (`cm_jsonrpc_spawn_server`,
`cm_jsonrpc_rebind_server`, `--server-address`) lets it bind any address, and the task states the
Rollups Node "may drive machines remotely". The guide explicitly puts "server robustness against
malicious/malformed requests (a server exposed on a socket)" — deeply nested JSON, huge lengths,
fork/rebind races — in scope. Each finding below is reachable by any peer that can open the socket;
none requires authentication (there is none). All are denial-of-service: I found **no** divergence,
nondeterminism, proof-soundness or silent-corruption bug (see jsonrpc-5).

---

### jsonrpc-1: Deeply-nested JSON request crashes the entire server (stack overflow)
- Status: PROVEN
- Area: JSON-RPC (server)
- Category: DoS / input-validation (unbounded recursion)
- Where: `src/jsonrpc-remote-machine.cpp:1915` (`json::parse(req.body().data())`), `:1923`
  (`j = json::array({std::move(j)})` — copies the parsed value), `:1930` (`for (auto ji : j)` — copies
  each top-level batch element by value); no JSON nesting-depth limit anywhere; body size is unbounded
  (`:202` `req_parser->body_limit(uint64_max)`). The crash escapes the per-method `try/catch`
  (`jsonrpc_dispatch_method`, `:1795/1864`) because it is a SIGSEGV, and even a thrown exception would
  escape `handle_request` and reach the top-level `catch` in `main` (`:2151` `ioc.run()`, `:2155`),
  which `return 1`s — i.e. the whole process dies either way.
- Problem: A single HTTP POST whose body is a deeply-nested JSON array (e.g. `[[[…]]]`) makes the server
  recurse to a depth equal to the nesting. nlohmann's deep-nested `json` copy (lines 1923/1930) and
  destructor are recursive; at ≈100 000 levels (~200 KB body) the main thread's 8 MiB stack overflows
  and the process receives SIGSEGV. This terminates the **entire** server process: the in-memory
  `cartesi::machine` and all other client connections are lost. It is not catchable.
- Scenario: The machine server holds the node's live machine (mid-`run`, mid-dispute-proof generation).
  Any local process — or, if the server is bound to a routable address for remote driving, any network
  peer — sends one ~200 KB request and the node's machine-in-progress is destroyed; the node sees a
  dropped connection and lost state. Repeatable at will ⇒ the node can be kept permanently down.
- Evidence:
  - PoC `work/jsonrpc/t_nest.py` (+ `cli.py`), driven by a spawned server. Depth 100 000:
    ```
    sending nested depth 100000 ... BUG REPRODUCED: server unreachable after nested request: ConnectionRefusedError(111)
    .../cartesi-jsonrpc-machine ... Segmentation fault
    ```
    Threshold: depth 50 000 → server ALIVE; depth 100 000 → DEAD (segfault). (`t_nest.py` run output.)
  - Characterization `work/jsonrpc/t_flatvsnest.py`: a *flat* array of 2 000 000 elements (4 MB body)
    → server ALIVE; *nested* 100 000 → DEAD. Confirms it is recursion depth, not body size.
    Run: `bash -c 'source work/jsonrpc/lib.sh; start_server /tmp/s.log; python3 -I work/jsonrpc/t_nest.py 127.0.0.1 $SRV_PORT 100000'`
- Possible solution: Parse with a hard nesting-depth limit (nlohmann SAX parser + a callback that
  rejects at e.g. depth 64, which is far above any legitimate request), and set a sane `body_limit`
  (a few MiB). Iterating batch entries by `const auto&` avoids the copy at 1930 but the recursive
  destructor still overflows, so a parse-time depth cap is the robust fix. Apply the same cap to the
  client's response parse (see note in jsonrpc-3).
- Severity: Medium — trivially-triggered, unauthenticated DoS that destroys in-flight machine state and
  all connections; per the guide's definitions a DoS caps at Medium, but it is at the high end (one small
  request, not catchable, repeatable).
- Risks if unfixed: node kept offline / in-progress computations repeatedly lost by any socket peer.
  Fix risk: none to correctness (a depth cap only rejects pathological input).

---

### jsonrpc-2: A batch of N `fork` entries forks the server 2^N times (fork bomb)
- Status: PROVEN
- Area: JSON-RPC (server) / fork semantics
- Category: DoS (resource exhaustion / fork bomb)
- Where: `src/jsonrpc-remote-machine.cpp:823` `jsonrpc_fork_handler` (after `fork()`, the child returns
  a normal result and keeps running), dispatched from the batch loop `handle_request` `:1930`
  (`for (auto ji : j) { … jsonrpc_dispatch_method(ji, session); … }`).
- Problem: JSON-RPC batch requests are processed by iterating the top-level array and dispatching each
  entry. `fork` forks the process; the child re-binds to a fresh port and then **continues the same
  `for` loop over the remaining batch entries**, forking again for each. A batch of N `fork` entries
  therefore produces 2^N live server processes (each a full copy of the machine). N≈25 ⇒ ~33 million
  processes — a classic fork bomb that exhausts PIDs/RAM on the host, not just the one server.
- Scenario: One request `[{"jsonrpc":"2.0","id":0,"method":"fork"}, …(N times)…]` from any socket peer
  takes down the whole host the node runs on.
- Evidence: PoC `work/jsonrpc/run_forkbatch2.sh` (+ `t_forkbatch.py`):
  ```
  $ bash work/jsonrpc/run_forkbatch2.sh 4
  clean start, cartesi procs = 0
  server pid=17013 ... port=34293  procs=1
  after a single 4-fork batch: cartesi procs = 16   (linear would be ~5; 2^N = 16)
  ```
  (procs 1 → 16 for N=4; the children persist because each re-binds a new acceptor and keeps serving.)
- Possible solution: In the child branch of `jsonrpc_fork_handler`, stop processing the rest of the
  batch (e.g. clear/short-circuit the remaining entries, or return a sentinel that makes
  `handle_request` break out of the loop in the child). More generally, forbid `fork` inside a batch,
  or cap the number of `fork` operations per connection.
- Severity: Medium (DoS; host-level fork bomb). Exotic request shape but trivially reachable and severe.
- Risks if unfixed: host resource exhaustion from a single request. Fix risk: none (legitimate clients
  never batch `fork`).

---

### jsonrpc-3: `read_memory` / `read_virtual_memory` / `read_console_output` with an attacker-chosen huge length ⇒ unbounded server allocation (OOM); request body is also unbounded
- Status: PROVEN
- Area: JSON-RPC (server)
- Category: DoS (allocation bomb / OOM)
- Where:
  - `src/jsonrpc-remote-machine.cpp:1403` `read_memory`: `make_unique_calloc<unsigned char>(length)`
    then `read_memory(address, data.get(), length)`; `:1437` identical for `read_virtual_memory`.
  - `:1495` `read_console_output`: `std::vector<uint8_t> buffer(max_length)` (value-initialised ⇒ it
    memsets, i.e. *touches*, all pages immediately).
  - `length`/`max_length` are untrusted `uint64` from the request with no upper bound; reads past the
    end of RAM return pristine zeros (no error — see PoC), so the server fills the whole buffer.
  - Request body itself is unbounded: `:202` `body_limit(uint64_max)` with `http::string_body`, so the
    server also buffers an arbitrarily large request in RAM before dispatch.
- Problem: Unlike the local C API (where the caller owns the buffer and never asks for an absurd size),
  the **server** allocates and fills a buffer whose size is the client-supplied `length`. The base64
  encoding of the result adds another ~1.33×. A single request
  `{"method":"machine.read_memory","params":{"address":2147483648,"length":1099511627776}}` makes the
  server attempt a ~1 TiB allocation+fill → under default memory overcommit the fill faults in pages
  until the OOM killer terminates the server (or the host thrashes).
- Scenario: Any socket peer OOM-kills the machine server (losing in-flight state), or exhausts host
  memory, with one small request.
- Evidence: PoC `work/jsonrpc/run_readmem_dos.sh` (+ `cli.py`):
  ```
  after create:  RSS=67524 kB
  read_memory length=67108864 (64 MiB) -> response body bytes=89478524   # base64 of 64 MiB
  (server RSS measured 67 MB -> 155 MB, i.e. +~88 MB for one 64 MiB read: allocation scales ~1:1 with the untrusted length)
  # under an artificial 1.5 GiB address-space ulimit (host kept safe):
  length=2^40 -> {"error":{"code":-32603,"data":-16,"message":"std::bad_alloc"}}  (server survives only because the rlimit makes calloc fail;
                 with the default no-rlimit deployment the 1 TiB mmap is granted by overcommit and the fill OOM-kills the server)
  ```
  The out-of-bounds behaviour (reads past RAM succeed with zeros, no cap) is confirmed by
  `work/jsonrpc/err.c` (`read_memory_oob` at addr 0x90000000 returns `local=0 remote=0`, i.e. success).
- Possible solution: Validate `length`/`max_length` against the addressed range (or a hard ceiling,
  e.g. total machine memory) before allocating; stream large reads in bounded chunks; set a reasonable
  `body_limit` on the request parser.
- Severity: Medium (DoS/OOM of the node's machine server by a single request).
- Risks if unfixed: OOM-kill of the server / host memory pressure. Fix risk: none for legitimate reads
  (they are bounded by the real memory ranges).

---

### jsonrpc-4: `delay_next_request` with a huge `ms` freezes the single-threaded server for all clients
- Status: PROVEN
- Area: JSON-RPC (server) / debug API
- Category: DoS
- Where: `src/jsonrpc-remote-machine.cpp:1058` (`handler->delay = ms`, untrusted `uint64`, unbounded),
  applied in `handle_request` `:1959-1962` `std::this_thread::sleep_for(milliseconds(delay))` — this
  blocks the single asio thread that serves *all* connections.
- Problem: `delay_next_request` is exposed by the production server (it is a normal RPC method, not gated
  behind a debug flag). A client sets a large `ms`; the next request from *any* client makes the single
  event-loop thread sleep for that whole duration, freezing every connection. `ms` up to 2^63 (clamped
  only by `chrono::milliseconds`' 64-bit rep ≈ 292 million years) ⇒ effectively permanent freeze.
- Scenario: Any peer issues `delay_next_request` with a huge `ms`; the node's next call hangs
  indefinitely (the node's own `set_timeout`, if set, turns the hang into a hard error on every call ⇒
  the machine is unusable until the server is restarted).
- Evidence: PoC `work/jsonrpc/run_delay.sh`:
  ```
  victim request blocked 5.01s => BUG REPRODUCED (whole server frozen by another client)
  ```
  (attacker set ms=5000 on one connection; a *different* connection's `get_version` was stalled 5.01 s,
  proving the whole single-threaded server is frozen, not just the attacker's connection.)
- Possible solution: Cap `delay` to a small maximum, and/or only register this method when an explicit
  debug/testing flag is set.
- Severity: Low (it is a debugging method, but it is always on and trivially abused).
- Risks if unfixed: one request stalls the node. Fix risk: none.

---

### jsonrpc-5: Equivalence and robustness checks that PASSED (assurance / negative results)
- Status: N/A (no bug) — recorded so the coordinator knows these high-value areas were tested and are sound.
- `work/jsonrpc/equiv.c` (local `cm_*` vs remote `cm_jsonrpc_*`, same sequence): **identical** initial
  and post-run root hashes; all x0..x31, pc, mcycle, uarch_cycle; `read_memory`/`read_word`; `run` break
  reason; `log_step_uarch` access-log **byte-for-byte identical** (21370 bytes) incl. ANNOTATIONS +
  LARGE_DATA; `verify_step_uarch` obtained hash identical whether local or remote verifies either log;
  `get_initial_config` (2817 bytes) and `get_runtime_config` identical. Output: `ALL EQUAL`.
- `work/jsonrpc/err.c` (11 failing ops run on both): error **codes and messages identical** local vs
  remote (OOB read, bad log2, store to unwritable path, read-only reg, unknown reg, etc.). The
  `error.data` cm_error round-trips so the client reconstructs the exact local error type. `ALL ERROR CODES EQUAL`.
- uint64 serialization: values > 2^53 (incl. `UINT64_MAX`) are emitted as JSON **integer literals** and
  parsed losslessly by the nlohmann-based client — no float/precision loss on the C API path
  (verified on the wire: `read x1 RAW: …"result":18446744073709551615`). (A non-nlohmann JS client
  using `JSON.parse` would lose precision, but that is a client choice, not a bug in this code.)
- `verify_step_uarch` is robust to malformed attacker logs (`work/jsonrpc/t_verifylog.py`): huge/overflowing
  `log2_size`, mismatched `read` data length, empty accesses, etc. all produce clean errors, no crash —
  the verifier validates each access size against the expected size and the data size against the proof.
- Client has **no** request-retry logic (`jsonrpc_request`/`json_post` throw on timeout, never resend),
  so there is no duplicate-delivery of non-idempotent ops (`cm_run`, `cm_send_cmio_response`) at the
  libcartesi layer; any retry policy is the node's responsibility.
- `fork` refuses machines with shared address ranges (`:825`
  `machine->has_shared_address_range()` ⇒ throw), so a fork cannot corrupt the parent via shared mmapped
  backing files.
- Note (same root cause as jsonrpc-1/3, lower practical reach): the **client** response path also uses
  `body_limit(uint64_max)` and an unbounded `json::parse` (`jsonrpc-machine.cpp:246`, `:297`). A
  malicious/compromised *remote* server could therefore try to OOM/crash the node. I could not segfault
  the client even at 3 000 000-deep nesting (`client_crash.c` + `fakeserver.py` returned a clean
  "missing field" error), because the client parses on a shallow stack; but the unbounded response body
  remains an OOM vector against the node when machines are driven remotely. Worth hardening alongside the
  server.
- Note (by design, flagged per task): `machine.store/clone_stored/rename_stored/remove_stored` take
  arbitrary filesystem paths (`:1085-1141`). This is intended functionality (store/load machines to
  disk) and runs with the node's privileges; it is only a concern if the server is bound to an untrusted
  network, where `remove_stored`/`store` become arbitrary filesystem write/delete. Reporting as a
  deployment consideration, not a standalone bug.
- Minor (out of scope, noted in passing): `--log-level=warn` is listed in `--help` but rejected by the
  parser ("unknown log severity level"; it wants `warning`) — a help/impl mismatch, harmless.
