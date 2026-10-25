# Emulator branch review

Review branch: `codex/emulator-0.23-bugs`, based on `feature/prt` at
`77880e1bc2cf6f4d37fae4584544763b66c1f7e4`, compared with `main` at
`f9e4f82003a6f5acc9821c06f8a29025e0f895e3`.

Scope: shipped emulator C/C++/Lua libraries and `cartesi-machine`. The experimental
Lua validator is excluded; branch `prt.lua` and README supply PRT semantics.
Existing defects in touched code are identified explicitly. Two review rounds are
complete. Material blocked by automated safeguards was skipped at the user's
request and is not included as an unconfirmed finding.

Workflow: separate agents inspect different areas and propose candidates; executable
reproductions establish behavior; independent reviewers try to disprove each
candidate. Only confirmed findings appear below. Each is committed locally with
its reproduction as it is confirmed; pushing was cancelled by the user.
Reproductions assert the observed bug and exit
successfully when it occurs; they are not fixes. Run commands from the repository
root with the branch built (`make`). Severity considers validator availability and
dispute deadlines, as well as general API consumers.

| ID | Finding | Severity | Origin |
| --- | --- | --- | --- |
| 001 | Successful persistence of truncated tree files | High, conditional on I/O failure | Introduced |
| 002 | Lost proof descendants after forest reload | High for deadline-sensitive recovery | Introduced |
| 003 | Incomplete hash-tree integrity check | Medium | Existing |
| 004 | CLI dump rejects valid directory names | Low | Existing |
| 005 | Empty dynamic-element ABI arrays rejected | Medium | Existing decoder, new API exposure |
| 006 | Exponential reconstruction of shared forest subtrees | High for tall affected trees | Introduced |
| 007 | Nesting a lazy forest loses its source storage context | Medium; conditional dispute availability risk | Introduced |
| 008 | Failed persisted expansion is omitted by later successful stores | Medium, conditional on persistence error | Introduced |
| 009 | Collected uarch reset differs from verified reset for custom initial RAM | High for validators accepting the affected initial state | Existing |

## 001 — Forest persistence commits truncated tree files after a failed write

- **Problem:** The durable hash-tree writer ignores `file:write()` failure. A
  subsequent successful `fflush`/`fsync` does not establish that the earlier write
  succeeded. The truncated file is renamed into place, marked durable, and
  referenced by a successfully committed frontier.
- **Area/category:** Lua hash-tree persistence; unchecked I/O error and persistent
  data loss. **Introduced** in this branch.
- **Location:** `src/cartesi/hash-tree.lua:509–513` (`write_file`), reached by
  `store_tree`, `frontier_store`, and `frontier_forest_store`;
  `src/clua-cartesi-filesystem.cpp:120–123` explains why the later sync succeeds.
- **Evidence:** `bash tests/bugs/001-forest-short-write.sh` uses a process-local
  1 KiB file-size limit with `SIGXFSZ` ignored. Storing a 256-leaf forest reports
  success, writes a 153-byte frontier and a truncated 1024-byte tree, then loading
  the frontier fails with a JSON parse error at column 1025. The hunter,
  orchestrator, and an independent reviewer reproduced this behavior.
- **Scenario:** A validator persists a computation forest while a filesystem
  write fails because of a file-size limit, quota, or capacity constraint. Its
  checkpoint appears successful, but recovery cannot read the proof material.
  The test directly establishes the file-size-limit case; other write errors
  depend on when the underlying filesystem reports them.
- **Possible solution:** Check every `file:write()` result before syncing or
  renaming; propagate the error and leave the previous committed frontier intact.
  Check close errors as well. Publish and mark data durable only after all required
  writes have succeeded.
- **Severity:** **High** for validator persistence: unavailable proof material can
  prevent an honest player meeting a dispute deadline. Medium for ordinary uses
  without a deadline or recovery requirement.
- **Risks/limits:** Requires an actual I/O failure. This does not demonstrate a
  wrong Merkle root or acceptance of an invalid proof; it demonstrates silent
  checkpoint corruption and failed recovery.

## 002 — Saving a richer forest can silently discard its proof material

- **Problem:** Two trees can have the same Merkle root while retaining different
  amounts of descendant information. Persistence deduplicates only by root hash
  and keeps the first file. Saving a fully expanded flat tree after a coarser tree
  with the same root neither updates that file nor saves its missing descendants.
  Reloading the richer forest therefore loses leaf queries that succeeded before
  the supposedly successful store.
- **Area/category:** Lua forest serialization; loss of proof data. **Introduced**
  in this branch.
- **Location:** `src/cartesi/hash-tree.lua:562–594`, especially the existing-file
  guard at line 581 and the child traversal at lines 567–569.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/002-forest-representations.lua`.
  The test stores two opaque height-1 hashes, then the corresponding four explicit
  leaves in the same directory. Both roots match and both stores succeed.
  After reloading the second frontier, its first leaf is unavailable:
  `nil, "the node is below an opaque hash"`. The original expanded forest still
  answers that query. Independently reproduced by hunter, orchestrator, and reviewer.
- **Scenario:** A consumer shares content-addressed storage between computation
  forests constructed with different bundling or expansion histories. Following
  restart, an honest validator cannot retrieve proof material it had saved and
  must reconstruct it before the dispute deadline.
- **Possible solution:** Reconcile representations before deduplicating: preserve
  every available descendant needed by either representation, or publish a richer
  representation after its required child files are durable. Merely finding the
  root-hash filename does not prove that all query data has been saved.
- **Severity:** **High** when recovery must supply dispute proofs on a deadline;
  medium for other persistence consumers.
- **Risks/limits:** Requires different representations sharing a storage directory.
  Roots remain correct; this demonstrates loss of available descendants, not
  acceptance of a false proof. Reconstruction may recover the data at a time cost.

## 003 — Hash-tree integrity verification accepts inconsistent internal nodes

- **Problem:** `verify_hash_tree` compares memory with page hashes, but does not
  verify all internal dense and sparse parent hashes. It also prints a mismatch
  between a dense root and its sparse leaf without setting its result to false.
  A successful check can therefore be followed by an invalid Merkle proof.
- **Area/category:** C/C++ hash-tree integrity API, also exposed in Lua and
  JSON-RPC; incomplete consistency validation. **Pre-existing** on `main` in
  code modified by the cache refactor.
- **Location:** `src/hash-tree.cpp:650–714`, particularly the leaf-only check at
  lines 658–696 and non-failing mismatch at lines 707–710; public API
  `cm_verify_hash_tree` in `src/cm.h:1158–1163`.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/003-incomplete-integrity-check.lua`.
  A fresh stored machine has a valid proof. The test models a single local storage
  bit fault in a RAM dense-tree internal node, leaving guest memory and page hashes
  unchanged. Reloaded `verify_hash_tree()` returns true, but the full-root proof
  fails `verify_slice`. `clear_hash_tree()` rebuilds a valid proof with the original
  state root. Hunter, independent reviewer, and orchestrator reproduced it.
- **Scenario:** A consumer uses the integrity API to detect damaged cached metadata
  before producing proofs, accepts its successful result, and later obtains an
  unusable proof. Recovery must explicitly rebuild the metadata.
- **Possible solution:** Verify clean internal parent/child relationships in the
  dense trees, sparse tree, and cached page trees; make every detected mismatch
  fail verification. Respect pending dirty nodes when defining the contract.
- **Severity:** **Medium (P2)**. False assurance can delay proof generation, but
  this test requires independently damaged metadata; no ordinary execution path
  causing that damage was established.
- **Risks/limits:** The C header explicitly describes this API as used only for
  internal emulator tests. This is not evidence of spontaneous state divergence,
  a false root produced from intact metadata, or an accepted invalid proof.

## 004 — The CLI cannot dump memory to ordinary paths with shell punctuation

- **Problem:** `--dump-memory-ranges` builds `"mkdir " .. dir` and passes it to a
  shell. Valid directory names containing spaces or parentheses are parsed as
  shell syntax instead of being passed as one path, and the CLI aborts.
- **Area/category:** `cartesi-machine` CLI; incorrect pathname handling.
  **Pre-existing** on `main`, in the dump function changed by this branch.
- **Location:** `src/cartesi-machine.lua:3599–3601`, especially line 3601.
- **Evidence:** `python3 tests/bugs/004-cli-dump-path.py` creates a minimal stored
  machine and runs the CLI with an argument array, without an invoking shell.
  Destination `plain` succeeds; destination `trial (1)` fails with exit status 1
  and a shell syntax error at the internal `mkdir`. Independently confirmed by
  hunter, reviewer, and orchestrator.
- **Scenario:** A developer or application asks the CLI to dump a machine beneath
  a user-selected directory whose name includes spaces or parentheses.
- **Possible solution:** Use the new `fs.create_directory(dir)` API rather than
  constructing a shell command.
- **Severity:** **Low (P3)**; a supported CLI operation fails for valid filenames.
- **Risks/limits:** No effect on normal guest execution or dispute outcomes was
  demonstrated. The reproduction exercises only legitimate directory names.

## 005 — ABI decoding rejects valid empty arrays of dynamic elements

- **Problem:** The dynamic-element branch of `decode_array` initializes its end
  offset only inside the element loop. An empty array returns a nil offset, so
  the enclosing decoder rejects a valid encoding as having trailing data.
- **Area/category:** Shipped `cartesi.evmu` Lua library; ABI decoding correctness.
  **Pre-existing** shared decoder bug, newly exposed through this branch's
  `decode_abi`; the existing `decode_calldata` is also affected.
- **Location:** `src/cartesi/evmu.lua:742–750` (`last_offset`), with rejection in
  `decode_abi` at line 846 and `decode_calldata` at line 831.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/005-empty-dynamic-abi-array.lua`.
  The test constructs the canonical 64-byte encoding independently: offset 32,
  followed by length zero. Empty `string[]`, `bytes[]`, nested dynamic arrays,
  and arrays of dynamic tuples fail with `ABI data too long`; the same bytes
  decode correctly as empty `uint256[]`. Nonempty `string[]` also succeeds.
  Existing calldata decoding rejects its matching canonical encoding. Independently
  reproduced and checked against controls by a second reviewer and the orchestrator.
- **Scenario:** A consumer decodes ordinary contract return values or event data
  containing an empty array of dynamic values and unexpectedly aborts processing.
- **Possible solution:** Initialize `last_offset` to `new_offset` before iterating,
  so an empty array returns the endpoint after its length word.
- **Severity:** **Medium (P2)**; valid ABI responses cannot be processed by affected
  consumers.
- **Risks/limits:** No concrete financial-loss or dispute-loss scenario was
  established. Effect on a validator depends on which ABI schemas it consumes.

## 006 — Forest loading expands shared subtrees exponentially

- **Problem:** A mixed node's children are loaded recursively without reusing an
  already loaded tree with the same hash. Repeated references to the same subtree
  become separate recursive object graphs. A compact, valid checkpoint can require
  exponentially more reads and memory to reopen than its stored representation.
- **Area/category:** Lua forest persistence/recovery; excessive work and memory
  allocation. **Introduced** in this branch.
- **Location:** `src/cartesi/hash-tree.lua:549–553` (`load_tree` recursively loads
  both mixed children), entered from `frontier_forest_load` at line 1009.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/006-forest-shared-subtrees.lua`.
  The bounded test uses only public construction and checkpoint APIs. At heights
  4/7/10, the stored directories contain 6/9/12 files, but loading performs
  16/128/1024 file-read operations and constructs 31/255/2047 distinct tree objects. Equivalent
  forests built without intermediate checkpoints each reopen in two reads and
  one tree object. Roots and leaf queries agree. Independently confirmed with
  these controls after the orchestrator's initial reproduction.
- **Scenario:** An application checkpoints a forest while assembling repeated
  complete subtrees. Checkpointing flushes pending values and makes later carries
  produce mixed nodes; after restart, recovery expands the shared content instead
  of preserving its compact representation. At larger supported heights this can
  exhaust memory or delay a validator beyond its proof deadline.
- **Possible solution:** Memoize loaded trees by hash and height, or retain lazy
  references to mixed children and resolve them during queries. Preserve shared
  descendants when loading content-addressed data.
- **Severity:** **High (P1)** for sufficiently tall affected trees used by
  validators: recovery work and allocation grow exponentially with height.
- **Risks/limits:** Requires repeated subtrees represented by mixed nodes; ordinary
  fixed-point-only trees avoid the problem. The test deliberately stays at height
  10 and demonstrates exact operation/object counts, not an actual out-of-memory
  event or missed dispute. Unlike 002, all data is present and hashes remain correct.

## 007 — Nesting a loaded forest loses access to saved descendants

- **Problem:** Appending or padding with a completed loaded forest retains its
  root tree but discards the source forest's directory. Any descendants still
  represented by raw hashes are subsequently looked up in the destination's
  directory, or nowhere when it has none. A successful destination store also
  omits those descendants because it visits only already loaded tree objects.
- **Area/category:** Shipped Lua hash-tree composition and persistence; loss of
  access to proof data. **Introduced** in this branch.
- **Location:** `src/cartesi/hash-tree.lua:698–700` drops the storage context;
  `descend_tree` at lines 645–647 uses the destination context; `store_children`
  at lines 565–569 cannot discover the unloaded source trees.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/007-lazy-forest-composition.lua`.
  A completed source forest contains two retained bundles and is stored and
  reloaded without warming its descendants. Nesting it in a larger forest loses
  leaf queries before storage and after a successful store/reload in a fresh
  directory. An independently loaded source and an eager-source destination answer
  those queries, and all roots agree. The independent reviewer also reproduced
  the defect with two `push_back` calls rather than padding: 0/8 leaves available
  for a cold nested source versus 8/8 for eager or warmed controls.
- **Scenario:** A consumer reopens a saved computation subtree and combines it
  into a larger commitment in another storage directory. The resulting commitment
  cannot supply descendants that remain available in the source checkpoint.
  Completed-forest nesting is expressly supported by the public API.
- **Possible solution:** Preserve the storage context of lazy references, or load
  and copy all required descendants before transferring a tree between contexts.
  If storage contexts cannot be combined, reject the operation before mutation
  rather than accepting an incomplete destination.
- **Severity:** **Medium (P2)** for supported composition and checkpointing;
  potentially high if rebuilding the missing proof access costs a validator its
  dispute deadline.
- **Risks/limits:** Requires unloaded descendants under a nested source root.
  Source files remain intact and roots remain correct. Warming the required
  descendants or sharing their storage directory avoids the failure. Unlike 002,
  this occurs in a fresh destination without competing same-root representations.

## 008 — Failed persisted expansion remains unsaved through successful retries

- **Problem:** `expand_leaf` installs a replacement tree in memory before saving
  it. If persistence fails, the replacement stays installed while the ancestor
  remains marked durable. Retrying the same expansion fails because the leaf is
  already expanded. Later successful stores skip that durable ancestor and never
  save the new descendant, so reopening loses the available expansion.
- **Area/category:** Shipped Lua forest persistence; incorrect recovery after a
  reported I/O error. **Introduced** in this branch.
- **Location:** `src/cartesi/hash-tree.lua:894–895` mutates before persisting;
  `store_tree` at line 578 skips the ancestor and its new children. The expansion
  retry reaches the height check at line 892.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/008-failed-expansion-retry.lua`.
  The test temporarily moves a checkpoint directory aside and restores it after
  `expand_leaf` correctly reports its sync error. The expanded leaf is now visible
  in memory, but the identical expansion retry fails. Two subsequent stores return
  successfully; reloading still cannot retrieve the leaf, and the expansion's
  tree file is absent. This holds for both an originally stored forest and a
  freshly loaded one. Discarding the mutated object, reloading the prior checkpoint,
  and expanding again succeeds and persists the leaf. Independently confirmed.
- **Scenario:** A validator handles a transient storage failure while saving newly
  computed proof descendants and retries its checkpoint after storage recovers.
  Successful checkpoint calls fail to preserve the new proof material.
- **Possible solution:** Persist the replacement before installing it, roll back
  installation on failure, or track unsaved expansions and traverse them on the
  next store. Retrying an identical expansion can also be made idempotent.
- **Severity:** **Medium (P2)**, conditional on a persistence error; a deadline can
  increase the impact on proof availability.
- **Risks/limits:** Mutation after a failed call alone would not establish a bug
  because strong exception atomicity is not promised. The demonstrated failure is
  that later successful stores still omit available data. Recovery by discarding
  the object and reloading works. Unlike 001, the initial I/O error is reported;
  unlike 002, no existing expansion file prevents the missing write.

## 009 — Collection's implicit uarch reset can disagree with a verified reset

- **Problem:** Micro-cycle collection restores only uarch RAM words written during
  the current collection period. An untouched non-pristine word already present
  in the initial RAM survives the implicit reset, whereas `reset_uarch` and
  `log_reset_uarch` restore the entire canonical pristine state. Collection therefore
  emits a reset root and leaves a machine state inconsistent with the valid reset
  proof for the same halted state.
- **Area/category:** C/C++ collection API, also exposed in Lua and JSON-RPC;
  incorrect state transition and commitment. **Pre-existing** on `main` in the
  reviewed machine code and PRT collection APIs.
- **Location:** `src/machine.cpp:2766–2773` records only this execution's dirty
  words, and lines 2797–2824 restore only those words. The entry check at lines
  2678–2680 tests the cycle counter alone. The full reset at lines 2063–2066
  rewrites the pristine RAM image and clears the remainder.
- **Evidence:** `env LUA_PATH='./src/?.lua;;' LUA_CPATH='./src/?.so;;'
  LD_LIBRARY_PATH=./src lua5.4 tests/bugs/009-collection-uarch-reset.lua`.
  A supported `uarch.ram.backing_store.data_filename` contains the default uarch
  program plus a 32-byte marker in unused RAM. Machines start at cycle zero;
  collection and explicit execution produce the same halted root. The explicit
  reset log verifies, but collection's final reset root differs and retains the
  marker. Clearing cached hashes preserves that difference. Independent checks
  cover pristine/custom configurations, a stored/reloaded custom machine, and
  already halted machines requiring no revert tail. All pristine controls agree.
- **Scenario:** A consumer collects a computation commitment from a configured or
  restored machine whose initial uarch RAM is non-pristine but whose cycle is zero.
  It later builds a reset proof for the disputed boundary and cannot reproduce the
  committed reset root with the canonical verifier.
- **Possible solution:** Use a full canonical reset for a period that started from
  non-pristine uarch state, retaining the dirty-word optimization only when its
  initial-state assumption has been established. Alternatively, explicitly validate
  and reject unsupported initial states before collection executes.
- **Severity:** **High for a validator accepting the affected initial state**:
  collection commits a reset root that its valid canonical reset proof cannot
  reproduce, which can cause an honest player to lose that dispute. The reachability
  is narrow because it requires custom/non-pristine initial uarch RAM; for general
  custom-image API usage without a dispute, this is a medium correctness defect.
- **Risks/limits:** Default pristine images pass. Custom uarch RAM is supported by
  configuration; the public collection contracts describe implicit resets without
  requiring fully pristine initial RAM. This is actual retained state, not a stale
  cache or a proof-checker false positive. Ordinary guest code causing the initial
  non-pristine uarch state was not demonstrated.

## Coverage and validation

The hunting passes covered cache metadata/payload layout, eviction, dense/sparse
hashes and proofs, cache clearing and runtime configuration, mapped-memory clearing,
shared/private backing stores, C/Lua/JSON-RPC API dispatch and lifecycle contracts,
Lua frontier/forest construction and persistence, selectorless ABI wrappers and
their shared decoder, filesystem helpers, and changed CLI paths. Branch PRT usage
was consulted for semantics only. No experimental validator findings are included.

All nine committed reproductions ran successfully and established the described
incorrect behavior. Existing suites also passed: filesystem (6 cases), ABI (6),
Lua hash tree (60), backing stores (89), local/remote machine API (91), and C API
(166). The C API run passed 165 cases in the sandbox; its loopback-server case
passed separately outside the sandbox. These passing suites do not negate the
additional cases in this report.

Additional bounded comparisons found no divergence across Keccak/SHA cache
capacities 1/3/17/101, concurrency 1/4, repeated clearing, dirty writes, non-power-of-two
RAM/flash ranges, execution, proof queries, runtime clearing, shared/private loads,
and persisted reloads (64 matrix checkpoints). Collected micro-cycle hashes also
matched cleared and uncleared machines for three instructions at each cache size.
C API handle/error/configuration checks passed. `make -q -C src` confirmed the
existing build was current; no production source was changed.

The second round used fresh hunting passes and independent confirmation tasks to
find 007–009, excluding the first six findings from the candidate search. Its
additional controls covered cold/eager/warmed forest composition, separate versus
shared storage directories, expansion failure and recovery on both newly stored
and loaded forests, custom uarch configuration and snapshot reload, verified reset
proofs, and pristine-image controls including a halted machine needing no revert
tail. The existing local collection tests for one root hash and an already halted
machine also passed. A deterministic set of 1,500 bounded ABI round trips passed
across nested tuples, fixed/dynamic arrays, strings, bytes, signed/unsigned integers,
and booleans, excluding the already known empty dynamic-element-array case.

The checks ran on this Linux host, not every supported platform. No claim is made
that every possible defect was found. Findings distinguish measured failures from
conditional validator/dispute consequences; skipped blocked material is outside
the report's confirmation coverage.
