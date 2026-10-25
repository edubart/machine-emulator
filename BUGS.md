# Emulator branch review

Review branch: `codex/emulator-0.23-bugs`, based on `feature/prt` at
`77880e1bc2cf6f4d37fae4584544763b66c1f7e4`, compared with `main` at
`f9e4f82003a6f5acc9821c06f8a29025e0f895e3`.

Scope: shipped emulator C/C++/Lua libraries and `cartesi-machine`. The experimental
Lua validator is excluded; branch `prt.lua` and README supply PRT semantics.
Existing defects in touched code are identified explicitly. Review is ongoing.

Workflow: separate agents inspect different areas and propose candidates; executable
reproductions establish behavior; independent reviewers try to disprove each
candidate. Only confirmed findings appear below. Each is committed locally with
its reproduction as it is confirmed; pushing was cancelled by the user. Reproductions assert the observed bug and exit
successfully when it occurs; they are not fixes. Run commands from the repository
root with the branch built (`make`). Severity considers validator availability and
dispute deadlines, as well as general API consumers.

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
