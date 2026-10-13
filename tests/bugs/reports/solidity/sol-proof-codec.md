# Findings: sol-proof-codec (on-chain proof checking vs the emulator's access-log encoding)

Scope: machine-solidity-step PR #104 (branch `pr104`, v0.16.0-test2), prod `AccessLogs` (readWord, writeWord,
readRegion/readLeaf, writeRegion/writeLeaf with a prover-supplied old subtree hash, write4Words, revert root hash read
as value + leaf hash), `Buffer.sol` (unchecked `peekBytes32`, `peekRoot`/`getRoot`), `Memory.sol` (stride/size
validation, `truncateToLeaf`), `MetaStep` / `UArchReset` / `SendCmioResponse` entry points; against the emulator's
access-log semantics (`src/access-log.hpp`, `uarch-record-state-access.hpp`, `uarch-replay-state-access.hpp`,
`replay-send-cmio-state-access.hpp`, `json-util.cpp`) and the chain encoder used by Dave
(`prt/client-lua/computation/machine.lua` `encode_access_logs`, `cartesi-rollups/node/src/engine/machine_stf.rs`
`encode_access_log`; same rule as the PR's `test/AccessLogJsonParse.sol`).

Work dir: `<SCRATCH>/work/sol-proof-codec/` (`<SCRATCH>` = `<SCRATCH>`).
Emulator side uses the upstream v0.22.0-test2 library (`<SCRATCH>/sol/upstream`, pristine uarch hash = the Solidity
constant). One command: `bash <SCRATCH>/work/sol-proof-codec/run.sh` (about 1 min; `--full` adds the fuzz campaign
and the replay of all PR step logs, about 6 min on the loaded machine). It prints `BUG REPRODUCED` and exits 1 while
SOL-PROOF-CODEC-1 is present.

## Summary

| ID | Title | Status | Severity |
|----|-------|--------|----------|
| SOL-PROOF-CODEC-1 | `Memory.validateStrideLength` off by one (`stride * size < 2^59 - 1`): the last 32-byte hash-tree leaf (0xffffffffffffffe0..ff) cannot be read or written on-chain, yet the emulator logs and verifies a uarch step that reads it (`MetaStep.step` reverts with Panic(0x01)). Reachable only with a non-pristine uarch in the committed state. | PROVEN | Low |
| SOL-PROOF-CODEC-2 | `UArchReset.reset` / `SendCmioResponse.sendCmioResponse` (and `UArchStep.step`) do not check exact consumption, and `peekBytes32` reads past `data.length`: a consumer that calls them alone accepts trailing bytes, and accepts a truncated proof if the bytes past `data.length` are the honest remainder (an in-memory slice). The root is still the honest one in every case. | REJECTED (no wrong root; the existing consumers check exact consumption) | - |
| N-1 | Property (b) completeness: every honest log accepted with the same root and consumed exactly: 426 corpus logs (365 uarch steps incl. TLB-slot and RAM writes, 25 resets incl. rx-accepted and rx-rejected/revert, 25 MetaStep step+reset, 11 CMIO 0..2^21+1 bytes / inspect / no-op), the PR's 5 reset/CMIO fixtures, and all 16049 steps of the PR's 53 `rv64ui-*` step logs through `MetaStep.step` | REJECTED (no divergence) | - |
| N-2 | Property (a) soundness: 1555 JSON-level mutants (emulator verdict from `verify_*`), 17752 deterministic buffer mutants (one bit per 32-byte word, every truncation), 3000 fuzz runs (bit flips, truncation, appended bytes, word swap/dup/delete/replace, access swap/dup/delete, cross-access leaf/sibling substitution): no buffer is accepted with a root other than the honest one, with or without the exact-consumption check | REJECTED (no divergence) | - |
| N-3 | Property (c): every mutant the emulator rejects but the chain accepts encodes to the honest buffer byte for byte (fields not in the encoding: address, word-access type and read_hash, written_hash/written, read data on region writes, log2_size of the uarch-state region, reorders of accesses to the same leaf) | REJECTED (benign by construction) | - |
| N-4 | Log types (none / annotations / large data / both) encode identically; no binary access-log format is consumed on-chain | REJECTED | - |
| N-5..N-9 | `truncateToLeaf` byte offset, assert vs require, `Memory.size` literal shift, double sibling read in write paths, gas | REJECTED (details below) | - |

## SOL-PROOF-CODEC-1: last hash-tree leaf cannot be proven on-chain (`validateStrideLength` off by one)
- Status: PROVEN
- Area: on-chain step (Solidity `Memory.sol`) vs emulator uarch step log
- Category: divergence (emulator accepts, chain rejects) / proof-completeness
- Where: machine-solidity-step `src/Memory.sol:103` (`validateStrideLength`: `assert(Stride.unwrap(stride) * s < MAX_STRIDE)`,
  `MAX_STRIDE = MAX_SIZE - 1 = 2^59 - 1` at `src/Memory.sol:66`), reached from every `AccessLogs` access through
  `Memory.regionFromStride` (`src/AccessLogs.sol:128` readWord, `:154` writeWord, `:82`/`:109` leaf access).
- Problem: a region of `s` leaves at stride `k` is valid iff `(k + 1) * s <= 2^59`, i.e. `k * s <= 2^59 - s`. The check
  `k * s < 2^59 - 1` is exact for every `s >= 2` (multiples of `s`) but for `s = 1` it rejects `k = 2^59 - 1`: the last
  32-byte leaf of the 2^64-byte state, physical addresses 0xffffffffffffffe0..0xffffffffffffffff. `readWord`/`writeWord`
  of any word in that leaf, with a perfectly valid Merkle proof, revert with Panic(0x01) before the proof is looked at.
  The emulator's hash tree covers the whole 2^64 space (`HASH_TREE_LOG2_ROOT_SIZE` = 64): `machine::read_word` of an
  unmapped address returns pristine zeros (`machine.cpp:1661` `read_memory`), `uarch_record_state_access` logs the read
  with a full 59-sibling proof, and `verify_step_uarch` accepts it.
- Scenario: the pristine uarch never touches that leaf (it only accesses the shadow/uarch state and memory inside PMAs; an
  address range must satisfy `start + length < 2^64 - 1` with a page-aligned end, so the last page is never mapped, and
  the uarch verifies cold TLB slots against the PMAs). The access needs a uarch program that issues it, i.e. a committed
  template whose uarch RAM is not pristine (the precondition of crafted-state-1 / SOL-ONCHAIN-1). Then there is a
  meta-step that every node computes identically and that the emulator logs and verifies, but that nobody can prove with
  `MetaStep.step` / Dave's `CartesiStateTransition`: the leaf match can only end by timeout. This adds an "unprovable
  honest step" outcome to the custom-uarch templates; it is also a latent trap for any future change that maps memory in
  the last page or touches it from the uarch.
- Evidence: `bash <SCRATCH>/work/sol-proof-codec/run.sh` (custom uarch `guest/uarch_lastleaf.S`: `li t0,-8; ld t1,0(t0); li a7,1; ecall`;
  `gen_lastleaf.lua` logs and verifies the steps with the upstream library; `mss/test/CodecUnit.t.sol` replays them):
  ```
  uarch step 2: emulator log_step_uarch + verify_step_uarch OK, root 0x32b1119df2caa420 -> 0x094f7bbc80d14ab1
    accesses: read@0x400008 read@0x400000 read@0x400010 read@0x600000 read@0x400040 read@0xfffffffffffffff8 write@0x400048 write@0x400010 write@0x400008
  [FAIL: emulator-verified step rejected on-chain] testLastLeafStepEmulatorAcceptsChainRejects()
    uarch step 1: MetaStep root matches emulator: yes
    uarch step 2: emulator verify_step_uarch accepted; MetaStep.step REVERTED (Panic(0x01) from Memory.validateStrideLength)
    BUG REPRODUCED: emulator-valid uarch step log (read of paddr 0xfffffffffffffff8) cannot be proven on-chain
  [PASS] testSizeAndStrideEdges()
    regionFromStride(2^59-1, log2 0) (last leaf, 0xffffffffffffffe0): Panic(0x01)
    readWord(0xffffffffffffffd8) with a valid proof: ok (second-to-last leaf)
    readWord(0xfffffffffffffff8) with a valid proof: Panic(0x01)
  ```
- Possible solution: `assert(Stride.unwrap(stride) * s <= MAX_STRIDE);` (equivalently `require(uint256(stride) * s + s <= MAX_SIZE)`).
  Validated in a scratch copy: with `<=` the last-leaf step reproduces the emulator root (`uarch step 2: MetaStep root
  matches emulator: yes`), and the PR's AccessLogs, Memory, UArchReset and SendCmioResponse tests plus the 426-log honest
  corpus and 1555-mutant differential still pass. Optionally also reject non-pristine uarch state at the start of a
  computation (see SOL-ONCHAIN-1), which removes the only path to this access.
- Severity: Low. Needs a non-pristine uarch in the committed template (already a High/Critical precondition elsewhere);
  with the pristine uarch the access is unreachable.
- Risks: unfixed: one more way for an adversarial template to make an honest step unprovable. Fix: no root-hash change, no
  emulator change; it only admits one more leaf (the check still rejects regions that leave the tree).

## SOL-PROOF-CODEC-2: library entry points without an exact-consumption check (REJECTED as a soundness issue)
- Status: REJECTED (behavior proven; no wrong root; MetaStep and Dave enforce exact consumption)
- Where: `src/Buffer.sol:59-75` (`peekBytes32` = unchecked `mload`), `src/UArchReset.sol` `reset`, `src/SendCmioResponse.sol`
  `sendCmioResponse`, `src/UArchStep.sol` `step`; the only check is `src/MetaStep.sol:55-58`. Dave's
  `CartesiStateTransition._requireAccessLogProofFullyConsumed` checks every branch.
- What was tested (`mss/test/CodecUnit.t.sol` testStandaloneTruncationAndTrailingData, `CodecFuzz.t.sol`):
  ```
  reset, copy truncated by 32: reverted            (bytes past data.length are unrelated memory)
  reset, length shortened in place by 32: accepted, root == honest, offset 7168 vs data.length 7136
  reset, length shortened in place by 1920: accepted, root == honest, offset 7168 vs data.length 5248
  reset, 64 trailing bytes: accepted, root == honest, offset 7168 vs data.length 7232
  cmio, copy truncated by 32: reverted
  cmio, length shortened in place by 32: accepted, root == honest, offset 15360 vs data.length 15328
  cmio, 32 trailing bytes: accepted, root == honest, offset 15360 vs data.length 15392
  deterministic sweep (23 fixtures, every word-aligned truncation as a fresh copy): 0 accepted standalone
  ```
- Why not a soundness defect: every consumed value is bound by a Merkle check against the current root (leaf data for
  words, subtree hash for regions, value + leaf hash for the revert root hash) and every sibling is read from the same
  offsets by `peekRoot` and `getRoot`; reads past `data.length` can only succeed when the memory there already holds the
  honest siblings, and the resulting root is the honest one. Zero memory never passes (no keccak node is zero). An
  overread always leaves `offset > data.length`, so MetaStep's and Dave's `offset == data.length` check rejects both
  truncation and trailing data. A new consumer that calls the libraries on its own should copy that check (a
  `require(buffer.offset == buffer.data.length)` helper in `Buffer.sol` would make this harder to miss); noted for the
  maintainers, not rated.

## Negative results (property checks)

N-1 (b) honest logs: `CodecCorpus.t.sol` testHonestCorpus: `honest records: 426 (uarch step 365, reset 25, cmio 11,
MetaStep step+reset 25)`, `rejected or not exactly consumed on-chain: 0`. Corpus from `gen.lua` (bare-metal guest
`guest/codec.S`: sd/sw/sh/sb/ld/lw/lbu, rx-accepted and rx-rejected manual yields; mcycles 0, 12-18, 23, 29 fully
stepped through the uarch, closing step of every other mcycle): uarch steps with WRITE_TLB slot writes (`write4Words`)
and RAM word writes, plain / rx-accepted / rx-rejected (revert root hash read) resets, MetaStep step+reset with counter
2^20, CMIO advance with 0, 1, 28, 32, 33, 1000, 65536, 2^21 bytes, 2^21+1 (no-op), inspect, advance at an rx-rejected
yield (no-op). `replay_all.sh`: all 53 PR step logs (16049 steps, incl. `ecall-write-tlb`) through `MetaStep.step` with
the exact-consumption check, chained roots equal the catalog final roots (the PR's own replay tests reuse an oversized
buffer and never check consumption; this closes that gap). Max gas of one exact-mode verification in the corpus:
1,450,614.

N-2 (a) mutations (`CodecCorpus.t.sol` testMutantCorpus, emulator verdict from `verify_step_uarch` /
`verify_reset_uarch` / `verify_send_cmio_response` on the mutated Lua log; chain verdict in exact mode = MetaStep or the
Dave-style check, and standalone):
```
op | emu acc/rej | chain(exact) acc/rej | standalone acc (not exactly consumed) | emu-rej&chain-acc | emu-acc&chain-rej | wrong root
flip_sibling_lo/mid/top | 0/96 each | 0/96 | 0 | 0 | 0 | 0
flip_read               | 0/85 | 0/85 | 0 (0)   | 0  | 0 | 0
flip_read_hash          | 0/96 | 83/13| 83 (0)  | 83 | 0 | 0     (word accesses: read_hash is not encoded)
flip_written_hash       | 0/34 | 34/0 | 34 (0)  | 34 | 0 | 0
flip_written            | 0/23 | 23/0 | 23 (0)  | 23 | 0 | 0
address                 | 0/96 | 96/0 | 96 (0)  | 96 | 0 | 0
log2_size               | 0/91 | 6/85 | 6 (0)   | 6  | 0 | 0     (uarch.state 22->21: same encoding)
type                    | 0/85 | 83/2 | 83 (0)  | 83 | 0 | 0
drop / drop_sibling / swap_siblings / leaf_from_other_{raw,consistent} / wrong_root_before / region_read_value_only: all rejected by both
dup / add_sibling / append_trailing | 0/96, 0/96, 0/14 | all rejected | 14 (14) each: trailing data, honest root
swap_next               | 0/80 | 15/65| 15 (0)  | 15 | 0 | 0     (consecutive reads of the same leaf: identical bytes)
set_read_on_region_write| 0/5  | 5/0  | 5 (0)   | 5  | 0 | 0
emulator-rejected mutants accepted on-chain whose encoded buffer differs from the honest one: 0
```
`CodecFuzz.t.sol`: 23 fixtures (the PR's reset/rejected/accepted/CMIO/no-op logs, rv64ui-simple step 0, 17 corpus
logs); testExhaustiveWordFlipsAndTruncations `deterministic mutants: 17752, accepted in exact mode: 0, accepted
standalone: 0`; testFuzz_bufferMutation 3000 runs pass (any acceptance must give the honest root).

N-3 (c): see the table: the only emulator-rejected logs the chain accepts encode to the honest bytes, so emulator-only
fields cannot change the on-chain result. The emulator is strictly stricter than the chain on the log; the chain is
never stricter on an emulator-valid log except SOL-PROOF-CODEC-1. 101 mutants were not encodable by Dave's encoder
(word access without `read`, region read turned into a write, etc.); the encoder asserts, so no buffer is produced.

N-4: `gen.lua` logs the same step, reset and CMIO response with log types 0, annotations, large data and both: the
encoded buffers are identical (`log types ... encode identically: true`); annotations/brackets are dropped and large
data only adds `read`/`written` to region writes, which the encoder ignores. Word reads/writes always carry the 32-byte
leaf and the revert root hash read always carries its value (`uarch-record-state-access.hpp` `log_read_word_access`,
`log_read_revert_root_hash_access`). JSON from the C API is base64; the Lua/Rust bindings decode to raw bytes before
encoding; the PR fixtures use hex; both encode to the same buffers. The only binary log in v0.22 is the `--log-step`
big-step file for the ZK verifier, which Solidity does not consume.

N-5: `truncateToLeaf` returns a byte offset that `readWord`/`writeWord` use as a byte shift (`offset << 3` bits): correct
for 8-byte-aligned addresses. A misaligned address would read bytes `[o, o+8)` of the leaf (zeros past byte 31), while
the emulator aligns down (`adjust_access`); unreachable, because `UArchStep` requires alignment for every
`readUint64/32/16`/`writeUint64/32/16` and all other callers pass constant aligned addresses (the misaligned case on the
emulator side is ASSERTS-1 / SOL-ONCHAIN-4).

N-6: `assert` vs `require`: in Solidity 0.8 both revert (Panic(0x01) vs Error(string)) without burning the remaining
gas; the verdict is the same. `strideFromPhysicalAddress` asserts only see constant or computed aligned addresses.

N-7: `Memory.size(log2)` (`uint64(1 << s.log2())` with a literal left operand) returns 2^k for k = 0..59 (checked);
all regions in use (uarch state 2^22 bytes, rx buffer up to 2^21, 32-byte leaves) validate. `writeTlbECALL` uses checked
arithmetic for `set * 8192 + slot * 32`: an out-of-range set index reverts on-chain while C++ wraps; only reachable with a
non-pristine uarch (uarch-1).

N-8: write paths read the siblings twice (`peekRoot` to check the old root, `getRoot` for the new one). Within
`data.length` the bytes are never modified; past it, only by a consumer that skipped the consumption check, and all
17752 truncation mutants reverted anyway. Every honest TLB-slot write (`write4Words` packing vaddr_page, vp_offset,
pma_index, 0 as little-endian words) matches the emulator's `shadow_tlb_fill_slot` hash.

N-9 (observation, not a defect): with the default OpenMP thread count on an oversubscribed host, `log_step_uarch` slowed
from ~1.4 ms to ~45 ms per step once the guest had executed its first RAM store (each `get_proof` then cost ~22 ms,
presumably an OpenMP parallel region under CPU contention); `OMP_NUM_THREADS=1` restores ~1.4 ms. Relevant only to proof-generation throughput of nodes on loaded hosts.

## Files
- `run.sh` (one command), `env.sh`, `gen.lua` (corpus + JSON-level mutants + emulator verdicts + Dave encoder),
  `gen_lastleaf.lua`, `guest/codec.S`, `guest/uarch_lastleaf.S`, `encode_replay.py` + `replay_all.sh` (PR step logs).
- `mss/test/CodecRecords.sol` (record format, runners), `CodecCorpus.t.sol`, `CodecFuzz.t.sol`, `CodecUnit.t.sol`,
  `CodecReplayExact.t.sol`. Generated data in `mss/test/uarch-log/codec/` is regenerated by `run.sh` (~20 s).
