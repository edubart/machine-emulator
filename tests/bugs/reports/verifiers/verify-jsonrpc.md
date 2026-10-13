# Independent verification — angle `jsonrpc` (verifier: verify-jsonrpc)

Target: `cartesi-jsonrpc-machine` server (`src/jsonrpc-remote-machine.cpp`), client lib
`src/jsonrpc-machine.cpp`. All four candidates are **denial-of-service** issues. I re-derived each
from the source, wrote my own independent reproducers (different technique / safer process handling
than the hunter), and ran them. All four reproduced.

My reproducers (one command each, print `BUG REPRODUCED` + exit 1 when present):
`<SCRATCH>/verify/verify-jsonrpc/{j1_nest,j2_forkbatch,j3_readmem,j4_delay}/run.sh`
(shared helper `common.sh`). **Safety note:** a *different* agent was running the same server
binary concurrently, so my scripts never use `pkill`/`pgrep` on the binary name (the hunter's
`run_forkbatch2.sh` does — it would have killed the other agent's server). Instead each reproducer
starts its own server with `setsid` (fresh process group), counts/kills **only its own process
group**, and binds only to `127.0.0.1:0`. After every run I confirmed with `ps` that all my groups
were gone and the other agents' processes were untouched.

## Threat model (assessed from the code + docs)
- The server has **no authentication**. `jsonrpc_dispatch_method` (`jsonrpc-remote-machine.cpp:1795`)
  dispatches any method to any peer that can open the socket. `fork` and `delay_next_request` are
  plain RPC methods, **always registered** — not gated behind a debug flag.
- Default bind is loopback: `main` falls back to `127.0.0.1:0` (`:2135`), help text says default
  `"127.0.0.1:0"` (`:1997`), `cm-jsonrpc.h:42` says the spawn address is "in the local host", and
  `doc/README.md.template:1139-1180` shows the server bound to `127.0.0.1:PORT` with the client in
  the *same* container, explicitly noting that to reach it from outside the container the port must
  be *exposed*. So the intended deployment is: the Rollups Node / CLI spawns the server **locally per
  machine** and drives it over loopback.
- Therefore a realistic attacker is (a) **another local process** on the same host/container (a
  co-tenant or compromised sidecar that can reach the loopback port — there is no auth to stop it),
  or (b) anyone who can reach a **mis-bound / container-exposed** port (operator binds `0.0.0.0` or
  publishes the port). Not a remote internet attacker in the default deployment.
- **The client library never batches.** `jsonrpc_post_data` (`jsonrpc-machine.cpp:98-105`) always
  emits a single object `{"jsonrpc","method","id":0,"params":[...]}`; the `json::array()` there is
  only the positional-params array. `cm_jsonrpc_fork_server` sends one `fork` (never a batch). So a
  trusted node/CLI can **never** send a batched request, let alone a batch of forks — jsonrpc-2 is
  reachable only via crafted raw requests by an attacker on the socket.
- Per the campaign severity guide, pure DoS of the node by API (mis)use tops out at **Medium**;
  there is no memory corruption with a controllable payload, and no proof-soundness / divergence /
  nondeterminism issue here (the hunter's jsonrpc-5 negative results are consistent with my reading).

---

### jsonrpc-1: Deeply-nested JSON request crashes the whole server (stack overflow)
- **Verdict: CONFIRMED.**
- Independent reproducer: `<SCRATCH>/verify/verify-jsonrpc/j1_nest/run.sh`. Unlike the hunter (who
  only probes liveness), I `wait()` on my own server pid and read its **exit signal**. Output:
  ```
  control server ... (sending depth 20000)
    depth=20000 bodybytes=40000 -> got 236 response bytes
    control: server ALIVE after depth 20000 (expected)
  attack server ... (sending depth 200000)
    depth=200000 bodybytes=400000 -> got 0 response bytes
  attack server wait-status=139          <-- 128+11 = SIGSEGV
  cleanup: processes left in my groups = 0
  BUG REPRODUCED: one nested JSON POST killed the server with SIGSEGV (status 139)
  ```
  Depth 20 000 is parsed and answered with a normal JSON-RPC error; depth 200 000 (a ~400 KB body)
  kills the process with SIGSEGV. Confirms it is recursion depth, not body size.
- Root cause: `jsonrpc-remote-machine.cpp:1915` `j = json::parse(req.body().data())` with no
  nesting-depth limit, and body size unbounded (`:202` `req_parser->body_limit(uint64_max)`).
  nlohmann parses, copies (`:1923`, and the by-value batch loop `for (auto ji : j)` at `:1930`) and
  destroys the value recursively, so nesting depth ≈ C++ recursion depth. At a few × 10⁴ levels the
  main thread's 8 MiB stack overflows → SIGSEGV. The crash is a fatal signal, so the per-method
  `try/catch` in `jsonrpc_dispatch_method` (`:1864`) and the top-level `catch` in `main` (`:2155`)
  cannot save it; even a *thrown* exception would escape to `main` and `return 1`. Either way the
  whole process — the in-memory `cartesi::machine` and every other connection — dies.
- Severity: **Medium** (high end). Agrees with the hunter. Unauthenticated, one small request,
  not catchable, repeatable at will → the node's machine-in-progress is destroyed and the node can
  be held down. Capped at Medium because it is DoS (a crash, not a controllable corruption) and in
  the default deployment the peer must already be local / the port mis-exposed.
- Fix assessment: parse with a SAX depth cap (reject at e.g. 64, far above any real request) and a
  sane `body_limit` (a few MiB). Iterating batch entries by `const auto&` removes the `:1930` copy
  but the recursive destructor still overflows, so a **parse-time depth cap is the robust fix**. Same
  cap belongs on the client response parse (`jsonrpc-machine.cpp:246/297`, also `body_limit(uint64_max)`
  + unbounded `json::parse`), which a malicious/compromised remote server could use against the node.
  No root-hash / on-chain impact — it only rejects pathological input.

---

### jsonrpc-2: A batch of N `fork` entries forks the server 2^N times (fork bomb)
- **Verdict: CONFIRMED** (both the DoS and the underlying logic bug the task asked me to double-check).
- Independent reproducer: `<SCRATCH>/verify/verify-jsonrpc/j2_forkbatch/run.sh`, **N=3** (≤4 as
  mandated → at most 2³=8 processes), process-group-scoped counting and kill. Output:
  ```
  my server pid=... pgid=30519 ...
  baseline processes in my group = 1 (expect 1)
    batch of 3 forks -> 3 response objects; fork addresses returned to parent:
        ['127.0.0.1:38461', '127.0.0.1:43479', '127.0.0.1:39755']
  after one 3-fork batch: processes in my group = 8   (linear would be 4; 2^N = 8)
  BUG REPRODUCED: one 3-fork batch produced 8 processes (exponential; forked children re-run the batch)
  ```
  I then confirmed with `ps` that all 8 were cleaned (the 2 transient `<defunct>` entries were
  zombies, reaped by init within 2 s) and that the other agent's servers were untouched.
- Root cause (verified by reading the batch loop + fork handler, as the task asked): the batch loop
  iterates the top-level array **by value** and dispatches each entry —
  `jsonrpc-remote-machine.cpp:1930` `for (auto ji : j) { ... jsonrpc_dispatch_method(ji, session); }`.
  In `jsonrpc_fork_handler` (`:823`) the **child branch** (`pid==0`, `:842-859`) does its ASIO
  `notify_fork`/`close_sessions`/`rebind` housekeeping and then **falls through to the shared
  `return jsonrpc_response_ok(j, result)` at `:878`** — there is *no* `break`/`exit`/flag to stop the
  batch in the child. So control returns to the same `for` loop, and **both** parent and child
  continue to the next entry. Each remaining `fork` is thus executed in both processes ⇒ 2^N live
  servers (each re-binds a fresh ephemeral acceptor and keeps serving in `ioc.run()`, so they
  persist). The task's concern is correct: **a batch `[fork, X, Y]` would run X and Y in BOTH the
  parent and the child** — the fork count (8 for N=3) proves the child re-enters the loop and
  processes the subsequent entries.
- Can a trusted client ever hit this? **No.** The client library never batches (see threat model),
  and `cm_jsonrpc_fork_server` sends exactly one `fork`. So this is unreachable by the node/CLI in
  normal use; it is a server-side robustness bug against an attacker who crafts raw batch requests.
- Severity: **Medium**. Agrees with the hunter. A single request becomes a host-level fork bomb
  (PIDs/RAM exhaustion affecting the whole host, not just this server). Exotic request shape but
  trivially reachable by any socket peer; capped at Medium as DoS. (Note: the pure "logic bug"
  framing is moot in practice because nothing legitimate batches — the severity rests on the DoS.)
- Fix assessment: in the child branch, stop processing the remaining batch (return a sentinel that
  makes `handle_request` break out of the loop in the child), and/or forbid `fork` inside a batch,
  and/or cap forks per connection. Correct and side-effect-free: no legitimate client batches `fork`,
  so behaviour for real clients is unchanged; no root-hash / on-chain impact.

---

### jsonrpc-3: `read_memory` (+ `read_virtual_memory` / `read_console_output`) with a huge length ⇒ unbounded server allocation (OOM)
- **Verdict: CONFIRMED.**
- Independent reproducer: `<SCRATCH>/verify/verify-jsonrpc/j3_readmem/run.sh`. I measure **VmHWM**
  (peak RSS, which persists — the hunter's VmRSS reading is confounded because glibc munmaps the big
  buffer on free). Part A uses bounded 64/256 MiB reads against a 4 MiB-RAM machine; Part B caps the
  server with `ulimit -v 1.5GiB` and requests 2⁴⁰ (1 TiB) so the host is never at risk. Output:
  ```
  after create (4 MiB machine): peakRSS(VmHWM)=67500 kB
    length=67108864  -> server built a 89478524-byte  response body   # 64 MiB read
  after 64 MiB  read: peakRSS(VmHWM)=307584 kB                         # +~240 MB
    length=268435456 -> server built a 357913980-byte response body   # 256 MiB read
  after 256 MiB read: peakRSS(VmHWM)=1028604 kB                        # +~960 MB (~1 GB for a 256 MiB read)
  --- Part B (ulimit -v 1.5GiB) ---
    length=1099511627776 -> ERROR {'code':-32603,'data':-16,'message':'std::bad_alloc'}
    capped server STILL ALIVE (returned clean bad_alloc; without a cap the host would be OOMed)
  BUG REPRODUCED: server peak RSS scales with the untrusted read length (unbounded allocation)
  ```
  A 4 MiB machine services a request that makes it build ~1 GB of peak RSS; the 1 TiB request shows
  the server tries to allocate exactly the attacker-chosen `length` (gated only by the rlimit).
- Root cause: `jsonrpc-remote-machine.cpp:1405` (`read_memory`) and `:1437`
  (`read_virtual_memory`): `make_unique_calloc<unsigned char>(length)` then `read_memory(..., length)`
  — `length` is an untrusted `uint64` with **no upper bound**; reads past the end of RAM return
  pristine zeros (no error), so the whole buffer is filled, then base64-encoded (~1.33× more). The
  `calloc` lands in `unique-c-ptr.hpp:56` (throws `bad_alloc` on NULL — hence the clean error *only*
  when an rlimit makes `calloc` fail; with default overcommit the mapping is granted and the fill
  faults pages until the OOM killer hits). `read_console_output` (`:1495`) value-initialises
  `std::vector<uint8_t> buffer(max_length)`, touching all pages immediately. Request body is also
  unbounded (`:202`).
- Severity: **Medium**. Agrees with the hunter. One small request OOM-kills the node's machine server
  (losing in-flight state) or pressures host memory; DoS → Medium.
- Fix assessment: validate `length`/`max_length` against the addressed range (or a hard ceiling =
  total machine memory) before allocating; optionally stream large reads in bounded chunks; set a
  reasonable `body_limit`. No impact on legitimate reads (bounded by real memory ranges); no root-hash
  change.

---

### jsonrpc-4: `delay_next_request` with a huge `ms` freezes the single-threaded server for all clients
- **Verdict: CONFIRMED.**
- Independent reproducer: `<SCRATCH>/verify/verify-jsonrpc/j4_delay/run.sh` (safe 3 s delay). Uses
  **two separate TCP connections**: connection A sets `ms=3000` and closes; connection B (a different
  connection) then issues `get_version`. Output:
  ```
  victim get_version (separate connection) blocked 3.00s
  BUG REPRODUCED: one client's delay_next_request froze an unrelated client's request
  ```
  Because B is a distinct connection yet is blocked for the full 3 s, the whole server — not just the
  attacker's connection — is frozen.
- Root cause: `jsonrpc_delay_next_request_handler` (`:1055`) stores an untrusted, unbounded `uint64`
  into `handler->delay`; the batch loop applies it as
  `std::this_thread::sleep_for(milliseconds(delay))` (`:1959-1962`). The server is **single-threaded**
  on purpose (`BOOST_ASIO_DISABLE_THREADS`, `asio::io_context ioc{1}`, one `ioc.run()` at `:2081/2151`),
  so that sleep blocks the one thread that serves every connection. `ms` up to 2⁶³ ⇒ effectively
  permanent. The method is always registered (not debug-gated).
- Severity: **Low**. Agrees with the hunter. It is clearly a debugging/testing hook and the freeze is
  a hang (the node can mitigate with its own request timeout). Still trivially abusable and always on,
  but least impactful of the four.
- Fix assessment: cap `delay` to a small maximum and/or only register the method under an explicit
  debug/testing flag. No correctness/root-hash impact.

---

## Summary table
| id | verdict | my severity | hunter severity |
|----|---------|-------------|-----------------|
| jsonrpc-1 (nested JSON → SIGSEGV)       | CONFIRMED | Medium | Medium |
| jsonrpc-2 (fork batch → 2^N fork bomb)  | CONFIRMED | Medium | Medium |
| jsonrpc-3 (read_memory huge length OOM) | CONFIRMED | Medium | Medium |
| jsonrpc-4 (delay_next_request freeze)   | CONFIRMED | Low    | Low    |

All severities concur with the hunter. All four are unauthenticated DoS reachable by any peer that
can open the (by default loopback, no-auth) socket; none is a soundness/divergence/corruption issue.
The common hardening is input validation at the server boundary: a JSON nesting-depth cap + a sane
`body_limit`, length bounds on `read_memory`/`read_virtual_memory`/`read_console_output`, a child
loop-break (or batch-fork ban) in the fork handler, and a cap/flag on `delay_next_request`.
