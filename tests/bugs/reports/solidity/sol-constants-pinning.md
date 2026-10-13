# sol-constants-pinning: constants and generated artifacts shared by the emulator and the on-chain step

Angle: are the constants and generated artifacts that the on-chain step relies on consistent between the emulator
(v0.22.0-test2 sources) and machine-solidity-step PR #104 (v0.16.0-test2)? Does a node whose values differ fail loudly
before it commits claims that the chain cannot reproduce?

PoC directory: `<SCRATCH>/work/sol-constants-pinning/`. Command: `bash run.sh`. It prints `BUG REPRODUCED` and exits 1.
It takes about 5 s: it stores a 49 MB machine, uses it, and deletes it. The optional `uarch-toolchains.sh` takes about
2 min and rebuilds the uarch image with two toolchains. `RUN_EMULATOR_TESTS=1 bash run.sh` also runs `tests/lua/machine-bind.lua`.

## Summary

| ID | Title | Status | Severity |
|---|---|---|---|
| SOL-CONSTANTS-PINNING-1 | The uarch pristine image/hash depends on the toolchain and is not pinned or exposed. A from-source build with another riscv GCC keeps `MARCHID` 22, loads official snapshots, passes its own verification and the test suite, but computes post-reset roots that `UArchReset`/`MetaStep` never reproduce. Its own `cm_run`, reset and collect paths also give three different next-mcycle roots. | PROVEN | Medium |
| SOL-CONSTANTS-PINNING-2 | A node with a mismatched MARCHID is not detected | REJECTED (`cm_load` refuses: "marchid mismatch, emulator version is incompatible") | - |
| (negative) | All 50 `EmulatorConstants` values (47 generated, 3 hand-written) plus the 4 `Memory` tree-geometry values match the emulator headers, the local library and the upstream library. The only exception is `UARCH_PRISTINE_STATE_HASH` on the local build. | - | - |

---

### SOL-CONSTANTS-PINNING-1: the uarch pristine hash is toolchain-dependent and nothing checks it against the canonical value; a mismatching node is not detected and cannot prove any reset step on-chain
- Status: PROVEN
- Area: build system (uarch image generation), uarch reset, C API. This is the interface between the emulator and the on-chain step.
- Category: missing guard / divergence (off-chain post-reset root differs from on-chain `UArchReset`), proof-soundness for the honest party (liveness)
- Where:
  - `uarch/Makefile:133-139` (`uarch-pristine-hash.c: compute-uarch-pristine-hash`, `uarch-pristine-ram.c: uarch-ram.bin`). These rules regenerate the embedded image and its hash from whatever `$(TOOLCHAIN_PREFIX)gcc` compiled. No step compares the result with an expected value. The only validation is `validate-instruction-set`.
  - `src/Makefile:635-643` (`generate-uarch-pristine`). When `uarch/uarch-pristine-hash.c` is missing, it runs `make uarch` with the host toolchain if `DEV_ENV_HAS_TOOLCHAIN=yes`. Otherwise it uses the Docker toolchain. The top-level `make uarch` (help: "Build microarchitecture") always uses the host toolchain.
  - `src/machine.cpp:2027-2044` (`machine::reset_uarch`), `src/uarch-replay-state-access.hpp:370` (`cm_verify_reset_uarch` expects `get_uarch_pristine_state_hash()`), and `src/machine-address-ranges.cpp:365` (the embedded image is used only for newly created uarch RAM). These use the library's own image and hash with no reference value.
  - `src/machine.cpp:196-207` (`validate_processor_shadow`) checks marchid/mvendorid/mimpid at load. It does not check the uarch image.
  - `src/cm.h` has no accessor for the pristine uarch hash. Only Lua exposes `cartesi.UARCH_PRISTINE_STATE_HASH`, and that is the library's own value.
  - On-chain: `EmulatorConstants.UARCH_PRISTINE_STATE_HASH = fa022ea7…` (src/EmulatorConstants.sol:28). `EmulatorCompat.resetState` (src/EmulatorCompat.sol:145) writes it over the 2^22-byte uarch subtree at every `MetaStep` whose counter is a multiple of 2^20.
- Problem:
  - The 32-byte uarch pristine hash commits to the exact bytes of `uarch-ram.bin`. Those bytes are the RV64I compilation of `interpret.cpp` and friends, so they depend on the riscv compiler version and packaging.
  - The canonical value exists in only two places: in `add-generated-files.diff` and the release debs, and as a constant in the Solidity contract. The emulator source tree, its build and its runtime never compare against it.
  - A build made with any other toolchain therefore:
    - (a) compiles and installs without warning;
    - (b) keeps `CM_MARCHID`/`cartesi.MARCHID` = 22, because MARCHID is a version number and does not identify the uarch image;
    - (c) loads official snapshots, whose uarch RAM is the canonical image, without complaint;
    - (d) accepts its own `log_reset_uarch`/`log_step_uarch` logs in `verify_*`;
    - (e) passes the emulator test suite, which compares only against the library's own `UARCH_PRISTINE_STATE_HASH`.
  - Yet every reset it performs writes a different uarch subtree than the chain writes.
- Toolchain sensitivity (same sources; `uarch-toolchains.sh`, `out/uarch-toolchains.txt`):

  | toolchain | uarch-ram.bin | pristine hash |
  |---|---|---|
  | official: Debian `gcc-riscv64-unknown-elf=14.2.0+19` (Docker, release) | 626456 B | `fa022ea7…` (= Solidity constant; amd64 deb, arm64 deb, release `uarch-ram.bin` and `add-generated-files.diff` all agree) |
  | Ubuntu 24.04 `gcc-riscv64-unknown-elf` 13.2 (`make DEV_ENV_HAS_TOOLCHAIN=yes`) | 640848 B | `8c396c5e…` (byte-identical to this campaign's local build; the build exits 0) |
  | Ubuntu 24.04 `riscv64-linux-gnu-gcc-14` 14.2 | 626448 B | `8fab8a89…` |

- Scenario:
  - A node operator or a distribution packager builds the emulator from source. Two examples: the development branch per the "regenerate files" note, or `make uarch` from `make help`, with the host's riscv GCC rather than the pinned Docker image. They run an honest PRT/Dave node on the official application snapshot.
  - Root hashes agree with the chain at load, and everything driven by `cm_run` agrees.
  - In a dispute that reaches the uarch level, the node's commitment for the mcycle ends with the uarch reset. The node's post-reset root (and the `collect_uarch_cycle_root_hashes` last leaf) is not the value that `MetaStep` computes from the same pre-state, and its own reset log reverts on-chain. Because a reset runs at every counter that is a multiple of 2^20, the node cannot prove any span boundary. It loses disputes it should win and its bond.
  - If the node instead built its template from config, the genesis hash already differs (`56e7a251…` vs `7b9ac0f7…` for the same config). The node is self-consistent off-chain, but the on-chain reset still reverts.
  - Nothing tells the operator. MARCHID matches, and the emulator offers no way to compare the image with `EmulatorConstants.UARCH_PRISTINE_STATE_HASH`, which PR 104 does not export as a check in any case.
- Evidence (`bash run.sh`, `out/run.log`):
  - Part A, constants diff (`out/consts_diff.txt`). It compares the forge dump of `EmulatorConstants` plus `Memory.*` with the emulator headers (C++ program `consts/consts_hdr.cpp`), the local library and the upstream library (`consts/consts_lib.lua`, using `cartesi.*` and `get_reg_address`):
    ```
    UARCH_PRISTINE_STATE_HASH  0xfa022ea7...  DIFF(0x8c396c5e...) | DIFF(0x8c396c5e...) | ok
    CM_MARCHID                 0x16           ok | ok | ok
    headers(local)   mismatches vs Solidity: UARCH_PRISTINE_STATE_HASH
    lib(local)       mismatches vs Solidity: UARCH_PRISTINE_STATE_HASH
    lib(upstream)    mismatches vs Solidity: none
    ```
  - Part B, one stored machine (created and stored by the upstream library), then one uarch span and the reset, logged by each library:
    ```
    LIB_MARCHID              upstream=22   local=22
    LOADED_ROOT              upstream=0xf5c5e4e0…  local=0xf5c5e4e0…   (same state, canonical uarch RAM)
    ROOT_PRE_RESET           upstream=0x648a3a68…  local=0x648a3a68…
    ROOT_POST_RESET          upstream=0xb858c7b2…  local=0x7e1e3bc5…
    ROOT_CM_RUN_NEXT_MCYCLE  upstream=0xb858c7b2…  local=0xb858c7b2…
    COLLECT_UARCH_LAST_LEAF  upstream=0xb858c7b2…  local=0xde4e91db…   (partial reset of touched words, cf. HT-7)
    SELF_VERIFY_RESET        upstream=accepted     local=accepted
    VERIFY upstream-reset log with lib pristine 0x8c396c5e...: rejected: written hash for uarch.state does not match expected hash in 1st access
    VERIFY local-reset log with lib pristine 0xfa022ea7...: rejected: written hash for uarch.state does not match expected hash in 1st access
    release log: VERIFY release-reset (downloaded, sha-pinned reset-uarch-steps.json) with lib pristine 0x8c396c5e...: rejected
    LOAD_WITH_MARCHID_21: rejected: marchid mismatch, emulator version is incompatible   (positive control)
    ```
  - On-chain, forge `test/PristinePin.t.sol` (copied from `forge/`). It replays through `UArchReset.reset` and through `MetaStep.step(counter = 2^20)` using the concatenated halted-step and reset logs:
    ```
    RESULT onchain_pristine=0xfa022ea739039235779f3cbd3bd5c053797ec3a7a98ee991f3b9167db5474805
    RESULT root_pre_reset=0x648a3a68b02e8695f9451cee7d1c4809112e03a93c9576066aea5c6ec82755be
    RESULT onchain_root_from_upstream_log=0xb858c7b264eaf6a94e658ce3bbbffb3466b85049128a954255e49b77d92fa12d
    RESULT local_claimed_post_root=0x7e1e3bc5a44a2b27970ad208f545d76f228105cfb1278d315be356a4b918f513
    RESULT onchain_local_log=REVERTED(Read word root doesn't match)
    RESULT metastep_onchain_root_upstream_logs=0xb858c7b2…
    RESULT metastep_local_logs=REVERTED(Read word root doesn't match)
    RESULT genesis_local_claimed_post_root=0xeeacd619…   genesis_onchain_local_log=REVERTED(Read word root doesn't match)
    BUG REPRODUCED: a from-source build with a non-canonical uarch image (pristine 0x8c396c5e...) keeps MARCHID 22, …
    ```
    The local log reverts because, after `resetState` writes `fa022ea7…`, the `iflags.Y` read proof in the log carries the local subtree hash `8c396c5e…` as a sibling.
  - Would anything have flagged it?
    - MARCHID: identical (22).
    - `cm_load`: accepts the snapshot.
    - Self-verification: accepts the node's own logs.
    - `tests/lua/machine-bind.lua local`: "All machine binding tests for type local passed" (`out/machine-bind-local.log`). Its reset tests compare against the library's own `cartesi.UARCH_PRISTINE_STATE_HASH`.
    - `tests/lua/uarch-riscv-tests.lua run`: "PASSED all 56 tests" (`out/uarch-riscv-tests-local.log`).
    - No file under `tests/` pins the pristine hash or any root hash that contains the uarch image.
    - What does detect it: replaying the release's own reset logs (sha256-pinned only in the Solidity repo's `shasum-download`) with the local `cm_verify_reset_uarch` rejects them. Feeding locally generated logs to the Solidity `test-replay` fails. CI's Docker-only `doc/README.md` sync check, and `test-computation-hash` against the released corpus, would probably also detect it, but neither is in a from-source operator's build or test path.
  - Documented path vs missing guard:
    - The README's release recipe (`git apply add-generated-files.diff`, which contains `uarch-pristine-{ram,hash}.c` generated in Docker) and `make uarch-with-toolchain` (Docker pins Debian `gcc-riscv64-unknown-elf=14.2.0+19` and `debian:trixie-20250811`) both produce `fa022ea7…`.
    - No document says that the image must be byte-identical to the release, or that it depends on the toolchain. `doc/README.md` describes the uarch image only as "the same interpreter source-code … compiled".
    - `make uarch` is advertised in `make help` (with a toolchain name, `riscv64-cartesi-linux-gnu-*`, that the Makefile does not use). It, and `DEV_ENV_HAS_TOOLCHAIN=yes`, silently produce non-canonical images.
    - So this is a missing guard, not documented behaviour. The protocol-critical value is pinned only on-chain.
- Possible solution:
  1. Pin the canonical value in the tree and fail the build on mismatch. For example, commit `uarch/uarch-pristine-hash.expected` (or `CM_UARCH_PRISTINE_HASH` in `cm-version.h`), and add a rule after `uarch-pristine-hash.c` that compares the generated bytes with the pinned value. On mismatch it should fail with a message naming the required toolchain and `make uarch-with-toolchain`. Provide an explicit override (`UARCH_PRISTINE_HASH_CHECK=no`) for intentional uarch changes; such changes must also bump MARCHID and regenerate the Solidity constants.
  2. Expose the value to API users, for example `CM_API cm_error cm_get_uarch_pristine_hash(cm_hash *h)` or a `cm.h` constant, so nodes can assert `== EmulatorConstants.UARCH_PRISTINE_STATE_HASH` at startup. Do this alongside the `CM_MARCHID` check that PR 104 enables, because MARCHID alone does not identify the image.
  3. Add a load-time guard in `validate_processor_shadow`, or in a uarch validation next to it, that also respects `skip_version_check`. When the uarch registers hold their reset values, require `get_node_hash(UARCH_STATE_START_ADDRESS, UARCH_STATE_LOG2_SIZE) == get_uarch_pristine_state_hash()`, and otherwise throw "uarch image mismatch, emulator build is incompatible". An official snapshot loaded by a non-canonical build then fails loudly, like the marchid check. The same check closes the crafted-template precondition of crafted-state-1 / SOL-ONCHAIN-1.
  4. Add a test asserting `cartesi.UARCH_PRISTINE_STATE_HASH` equals the pinned value, and that the root of `cartesi.machine{ram={length=0x20000}}` equals the release catalog value `0x87e8a17a…`.
- Severity: Medium. An honest node built this way cannot prove any span-boundary reset, which is a Critical-class consequence for that operator. However, the precondition is a non-release build path, it is not adversary-controlled, and the release and Docker paths are correct.
- Risks: if left unfixed, from-source and distribution builds silently become unable to defend disputes, and the failure appears only on-chain. Fixes 1, 2 and 4 change no hashes. Fix 3 rejects snapshots whose uarch is non-pristine but at its reset registers, which is intended. The pinned value must be updated together with MARCHID and `EmulatorConstants.sol` whenever the uarch sources change.

### SOL-CONSTANTS-PINNING-2: a node with a mismatched MARCHID is not detected (REJECTED)
- Status: REJECTED. A stored machine whose shadow `marchid` was patched to 21 and loaded by the v0.22 library gives `rejected: marchid mismatch, emulator version is incompatible` (`out/marchid.txt`; `machine.cpp:199`).
- `marchid` is in the shadow registers, so it is committed by the root hash. The uarch returns the compile-time `MARCHID_INIT`, which is baked into the uarch image (`state-access.hpp:133`), so the on-chain value comes from the committed image.
- `EmulatorConstants.CM_MARCHID` (new in PR 104) is unused by the on-chain code. It is informational for off-chain consumers (Dave). That is fine, but it is not sufficient on its own; see -1.

## Negative results (briefly)
- Constants. All of the following match the C++ headers, the local library and the upstream library (forge `test/ConstantsDump.t.sol` vs `consts_hdr` vs `consts_lib.lua`):
  - every auto-generated value: addresses from `get_reg_address`, uarch/shadow/TLB/CMIO ranges, HTIF masks/shifts/reasons, rollup log2 constants, ecall codes, the revert-root-hash address, `UARCH_STATE_LOG2_SIZE`;
  - the hand-written `TLB_SLOT_LENGTH` 32 (= `sizeof(shadow_tlb_slot)`), `TLB_SET_SIZE` 256 and `TLB_SET_LENGTH` 8192 (= `sizeof(shadow_tlb_set)`);
  - the tree geometry: `LOG2_LEAF` 5 = `HASH_TREE_LOG2_WORD_SIZE`; `LOG2_MAX_SIZE` 59 = 64-5 = sibling count in `UArchReplay.t.sol.template`; `MAX_SIZE` 2^59.
  - Derived checks passed: the Solidity TLB slot formula equals `shadow_tlb_get_abs_addr` for all 3x256 slots; field order vaddr_page/vp_offset/pma_index/zero_padding is at 0/8/16/24; uarch x-register stride is 8 for x0..x31; the TLB state (0x6000) fits the shadow; the revert-hash leaf is 32-byte aligned; `UARCH_CYCLE_MAX` = 2^20-1.
- Regeneration. `generate_EmulatorConstants.lua` run with the upstream library and then `forge fmt` is byte-identical to the committed `src/EmulatorConstants.sol`. With the local library it differs only in the pristine hash. `generate_AccessLogs.sh prod` reproduces `src/AccessLogs.sol`. The official `generate_EmulatorConstants.sh` goes through the Docker image (pinned toolchain), so it is safe.
- Release artifacts. The amd64 deb, arm64 deb, release `uarch-ram.bin` (sha256 `6636c2ee…`) and `add-generated-files.diff` all embed `fa022ea7…`. `shasum-download` pins of the tests-data deb and the JSON-log tarball verify OK. The release catalog's `reset-uarch-steps` initial and final roots (`7b9ac0f7…` → `87e8a17a…`) are reproduced exactly by the upstream library.
- Hardening only (not reported as defects):
  - The generator takes `AR_SHADOW_TLB_START/LENGTH` and `HASH_TREE_LOG2_WORD_SIZE` from the `CM_*` enums in `cm.h`, which have no `static_assert` against the internal `AR_*`/`HASH_TREE_*` constants that the interpreter uses. They are currently equal.
  - The Solidity TLB constants are hand-written, not generated.
  - `shasum-mock`/`shasum-prod` in the Solidity repo are stale and referenced by no target.
  - `EmulatorConstants.t.sol` only re-asserts `CM_MARCHID == 22`.

## Files
- `run.sh` — the one-command reproducer for both parts.
- `consts/consts_hdr.cpp`, `consts/consts_lib.lua`, `consts/diff_consts.py`, `forge/ConstantsDump.t.sol` — the constants dumpers and the diff.
- `pristine/gen_reset.lua` — modes `make-base`, `log`, `release-style`, `verify`, `marchid-check`.
- `pristine/sol2accesslog.py`, `forge/PristinePin.t.sol`, `uarch-toolchains.sh`, `env-local.sh`, `env-upstream.sh`.
- `out/` — logs.
