# Emulator branch review

Review branch: `codex/emulator-0.23-bugs`, based on `feature/prt` at
`77880e1bc2cf6f4d37fae4584544763b66c1f7e4`, compared with `main` at
`f9e4f82003a6f5acc9821c06f8a29025e0f895e3`.

Scope: shipped emulator C/C++/Lua libraries and `cartesi-machine`. The experimental
Lua validator is excluded; branch `prt.lua` and README supply PRT semantics.
Existing defects in touched code are identified explicitly. Review is ongoing.

Workflow: separate agents inspect different areas and propose candidates; executable
reproductions establish behavior; independent reviewers try to disprove each
candidate. Only confirmed findings appear below. Each is committed and pushed with
its reproduction as it is confirmed. Reproductions assert the observed bug and exit
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
