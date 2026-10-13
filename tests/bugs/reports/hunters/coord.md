# Coordinator findings

### COORD-1: RISC Zero step replay wraps mcycle_end on overflow while host verify_step saturates
- Status: PROVEN
- Area: step-log / ZK verifier (risc0/cpp)
- Category: divergence, proof-soundness
- Where: risc0/cpp/risc0-replay-steps.cpp:37-38 (risc0_replay_steps) vs src/machine.cpp:2205 (machine::verify_step uses saturating_add) and src/machine.cpp:2178 (log_step)
- Problem: the ZK guest entry point computes `mcycle_end` with `__builtin_add_overflow(a.read_mcycle(), logged_mcycle_count, &mcycle_end)` and ignores the overflow flag, so the wrapped (small) value is used. Host log_step/verify_step use `saturating_add` (UINT64_MAX). When mcycle + mcycle_count > 2^64-1, the risc0 replay executes 0 cycles (interpret returns immediately because mcycle >= mcycle_end).
- Scenario: a machine whose mcycle is within mcycle_count of 2^64 (only reachable through the initial config `processor.registers.mcycle` or cm_write_reg; mcycle is not guest-writable). The honest step log (which executes up to mcycle = 2^64-1, mcycle_overflow) is REJECTED by the ZK verifier ("final root hash mismatch"), while a forged log (a 0-cycle log whose header claims mcycle_count=16 and root_hash_after == root_hash_before) is ACCEPTED by the ZK verifier and rejected by host verify_step. The ZK verifier and the host/Solidity verifier disagree on which transition is valid.
- Evidence: <SCRATCH>/coord/risc0-wrap/run.sh (replicates risc0_replay_steps exactly, using the non-ZK by-value instantiation of interpret<replay_step_state_access> linked from libcartesi.a). Output:
  ```
  initial mcycle = 18446744073709551611
  host log_step(16): break=8 final mcycle=18446744073709551615
  host verify_step(honest) -> ACCEPT
  risc0 replay(honest) -> final root hash mismatch
  BUG REPRODUCED: risc0 verifier rejects the honest step log
  host verify_step(forged, claims after==before) -> required page not found
  risc0 replay(forged) -> ACCEPT (mcycle_count=16)
  BUG REPRODUCED: risc0 verifier accepts a false 16-cycle transition rejected by host verify_step
  ```
- Possible solution: `uint64_t mcycle_end = saturating_add(a.read_mcycle(), context.logged_mcycle_count);` (include algorithm.hpp) — identical to machine::verify_step.
- Severity: Medium — soundness break of the ZK step verifier, but requires a template with initial mcycle near 2^64.
- Risks: if left, a template with a crafted initial mcycle makes risc0 proofs disagree with the canonical verifier; the fix does not change any root hash.
