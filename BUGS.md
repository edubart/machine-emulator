# Release review: feature/v0.22.0-test2 against main

**Important newly introduced bugs confirmed: 0.**

No candidate with a demonstrated important impact on emulator users was confirmed
as a regression caused by the reviewed changes. There are no qualifying issue
entries.

## Exact scope

- Base `main`: `bd09538131e589319e371d7d65e81c2c82dd3411`.
- Reviewed `feature/v0.22.0-test2`: `8236e69335ed5b3f6da5bef10217cbc2cf2349f7`.
- The branch is 26 commits ahead; the review emphasized the 25 changed files in
  `src/` and `uarch/` and their callers, state accessors, and existing tests.
- Areas: CPU stopping conditions and CMIO transitions; native mcycle/uarch
  collection and canonical state hashes; mapped memory, cache persistence,
  storage/clone/locking; libcartesi C/C++/Lua and JSON-RPC APIs; CLI epoch
  continuation, rejected-input reversion, outputs/proofs, computation hashing;
  frontier forests, utility helpers, and GDB collection.

Six agents performed the initial reasoning pass and proposed concrete scenarios
before writing additional tests. Three separate agents independently reviewed the
code and the candidate dispositions. Only bugs important to fix for emulator
users were eligible; documentation, formatting, typos, and missing tests were
excluded.

## Executable validation

The exact reviewed feature snapshot was built with GCC 14, including its uarch
image. The additional checks below are retained in `tests/release-review/`.
They use actual emulator execution or independently constructed Merkle trees as
oracles and passed against the unmodified feature sources.

| Check | Passed evidence |
| --- | --- |
| Native bundle equivalence | 344 mcycle cases against independent `run()` sampling and final state; 296 uarch/boundary cases against existing collection |
| Direct uarch execution | 5 cycle-by-cycle `run_uarch()` traces with state-root and reset-state comparisons |
| Buffered console and yields | 72 bundles against independently stepped execution, including budgets, partial sampling periods, and unsigned saturation |
| Frontier forests | 1,600 randomized small forests and 240 forests at heights 59–62; 6,926,560 counted node/proof/root assertions across Keccak-256 and SHA-256 |
| Plain frontier padding | 1,560 reference-root cases, including heights 62, 63, 64, and 72 |
| Cache persistence | 840 eviction/store/load/clone/update checks across both hash functions and cache capacities 1, 2, 3, and 16 |
| Local/remote APIs | Supported bundle arguments agreed; remote `move()` preserved ownership, timeout, and cleanup behavior |

The bundle cases include automatic/manual yields, rejection, halt, initial fixed
points, randomized input budgets and sampling periods, skipped bundles,
Keccak-256/SHA-256, uint64 saturation, and rejection of partial uarch state without
mutation.

Run the retained validation after building the emulator and Lua bindings:

```sh
bash tests/release-review/run.sh
```

The runner requires Lua 5.4 and the normal emulator runtime dependencies. It sets
the repository module paths and defaults OpenMP to one thread. Its tiny-machine
checks do not require downloaded Linux/rootfs images or a network connection.

Additional existing suites passed: native/Lua/remote hash collection (88), Lua
hash-tree (49), machine API (33), backing
stores (19), JSON schemas (19), utilities (7), GDB (3), CLI computation-hash
scenarios (13), CLI incremental-frontier scenarios (4), and C API suites locally
and remotely (153 each), and step-verification failure checks locally/remotely
(48 combined).

## Verification limits

- The C JSON-RPC suite initially passed 41 of 42 cases. Its concurrent
  `spawn_during_store_test` failed once when immediate reload could not acquire
  `hash_tree.phtc`'s lock. Repeating that test yielded 59 passes and one failure in
  60 runs. An instrumented feature run loaded successfully after joining the
  spawning thread while keeping all nine servers alive. The identical diagnostic
  with the preserved `main` library failed immediately and continued failing
  after joining, with fourteen servers alive. This supports a preexisting
  pre-exec lock-retention window; the branch fixes persistent retention after
  exec. The scheduling-sensitive failure is excluded from new-bug findings, and
  the initial failed suite run is not counted as passing.
- The shell proxy refused connections. Repository Git objects were imported
  through the GitHub connector and checked against their original Git SHA-1s.
  The new Linux 6.18.38 image could not be downloaded; kernel-backed CLI checks
  used the cached Linux 6.5.13 Cartesi image and guest-tools v0.18.0 rootfs.
- Execution covered Linux x86-64/GCC 14. Other hosts, sanitizers, the full ISA
  corpus, and RISC Zero were outside the executed validation. The reviewed
  source and the exercised scenarios bound this result.
