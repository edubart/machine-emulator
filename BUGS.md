# Emulator bugs found reviewing `feature/prt`

Review of the emulator C/C++/Lua sources that ship in the emulator package (libcartesi C API, JSON-RPC remote machine,
Lua libraries, and the `cartesi-machine` CLI) on branch `feature/prt` against `main`. It covers bugs the branch
introduces and bugs that already existed in the APIs it touches or that the PRT validator node uses. The PRT node itself
(`doc/recipes/prt*.lua`) was not reviewed.

Each issue was proposed by a bug-hunting agent, reproduced by a separate agent with a test case, and confirmed by
independent reviewers who tried to disprove it. Issues are numbered in the order they were confirmed. The summary table is sorted by severity.

Severity scale:

- **critical**: can make an honest PRT player lose a dispute, or produce wrong or nondeterministic hashes or proofs.
- **high**: crashes, hangs, or corrupts stored state for a validator in realistic use.
- **medium**: wrong results or crashes in less common but legitimate use.
- **low**: minor.

Proofs of concept live under `bugs/<id>/`. Run them from the repo root after building (`make`) with the environment
from `eval $(make -s env)` and `CARTESI_IMAGES_PATH` pointing at a directory with `linux.bin` and `rootfs.ext2`.
A test exits non-zero and prints a `BUG:` line while the bug is present.

## Summary

77 confirmed issues: 4 high, 16 medium, 57 low.

| # | Severity | Origin | Area | Issue | Proof of concept |
|---|---|---|---|---|---|
| [B01](#b01-persisted-page-cache-is-not-checked-against-memory-so-a-reload-yields-wrong-proofs) | high | pre-existing | Hash tree (page cache, store/load) | Persisted page cache is not checked against memory, so a reload yields wrong proofs | `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/` |
| [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong) | high | introduced by branch | Hash tree (page cache, dense trees, crash consistency) | Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong | `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/` |
| [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files) | high | introduced by branch | Lua cartesi.hash-tree and cartesi.filesystem (durable writes) | frontier_forest_store and fs.sync_file ignore write errors and commit truncated files | `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/` |
| [B32](#b32-interrupted-store-or-clone_stored-leaves-a-torn-page-cache-that-loads-silently-and-gives-wrong-hashes) | high | pre-existing | Hash tree (page cache), stored machine API | Interrupted store or clone_stored leaves a torn page cache that loads silently and gives wrong hashes | `bugs/api-05-torn-phtc-silent-wrong-hash/` |
| [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree) | medium | pre-existing | Hash tree (sparse tree, crash consistency) | Crash in sparse-tree update freezes the root hash of a shared hash tree | `bugs/ht-03-persisted-sparse-marked-flag-stale-root/` |
| [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages) | medium | introduced by branch | Hash tree (clear_hash_tree) | Crash during clear_hash_tree leaves zeroed hashes on clean pages | `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/` |
| [B07](#b07-interrupted-remove_stored-leaves-a-directory-that-blocks-the-name-forever) | medium | pre-existing | Stored machine API | Interrupted remove_stored leaves a directory that blocks the name forever | `bugs/ht-09-remove-stored-not-idempotent/` |
| [B09](#b09-json-rpc-server-exits-when-an-error-message-contains-invalid-utf-8) | medium | pre-existing | JSON-RPC remote machine server | JSON-RPC server exits when an error message contains invalid UTF-8 | `bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/` |
| [B10](#b10-spawned-json-rpc-servers-inherit-client-sockets-so-concurrent-spawns-fail) | medium | pre-existing | JSON-RPC client (spawn_server) | Spawned JSON-RPC servers inherit client sockets, so concurrent spawns fail | `bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/` |
| [B12](#b12-frontier_forest_store-drops-expansions-under-single-value-fixed-point-trees) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | frontier_forest_store drops expansions under single-value fixed-point trees | `bugs/lua-02-store-skips-expanded-single-value-tree/` |
| [B13](#b13-lazily-loaded-forest-used-as-a-value-loses-its-unloaded-subtrees) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | Lazily loaded forest used as a value loses its unloaded subtrees | `bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/` |
| [B14](#b14-forest-tree-files-keyed-only-by-hash-collide-across-heights-and-representations) | medium | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | Forest tree files keyed only by hash collide across heights and representations | `bugs/lua-04-content-addressing-ignores-height-and-representation/` |
| [B17](#b17-abi-decoder-rejects-canonical-empty-arrays-of-dynamic-types) | medium | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder rejects canonical empty arrays of dynamic types | `bugs/lua-09-evmu-decode-empty-dynamic-element-array/` |
| [B35](#b35-collect_uarch_cycle_-reset-shortcut-diverges-from-reset_uarch-when-uarch-ram-is-not-the-built-in-image) | medium | pre-existing | Machine API (uarch cycle collection) | collect_uarch_cycle_* reset shortcut diverges from reset_uarch when uarch RAM is not the built-in image | `bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/` |
| [B50](#b50-rename_stored-and-remove_stored-with-a-trailing-slash-succeed-then-fail-and-skip-the-parent-fsync) | medium | pre-existing | Stored machine API | rename_stored and remove_stored with a trailing slash succeed, then fail and skip the parent fsync | `bugs/w2b-03-rename-remove-stored-trailing-slash/` |
| [B53](#b53-run-aborts-when-a-non-blocking-console-output-descriptor-is-briefly-full) | medium | pre-existing | Machine console (run) | run aborts when a non-blocking console output descriptor is briefly full | `bugs/w2b-05-console-eagain-fails-run/` |
| [B58](#b58-timed-out-fork_server-leaks-an-unreachable-server-and-a-forked-child-can-take-over-the-parents-connection) | medium | pre-existing | JSON-RPC client and server (fork) | Timed-out fork_server leaks an unreachable server, and a forked child can take over the parent's connection | `bugs/w2b-01-rpc-timeout-request-still-executes-fork-leaks-server/` |
| [B59](#b59-replace_memory_range-leaves-the-config-stale-so-store-persists-the-old-flash-image) | medium | pre-existing | Machine API (replace_memory_range, store) | replace_memory_range leaves the config stale, so store persists the old flash image | `bugs/w2b-11-replace-memory-range-stale-config-store/` |
| [B66](#b66-verifying-through-a-json-rpc-machine-object-crashes-on-short-sibling-lists-and-accepts-logs-the-local-verifier-rejects) | medium | pre-existing | JSON-RPC client (verify_*), access-log JSON | Verifying through a JSON-RPC machine object crashes on short sibling lists and accepts logs the local verifier rejects | `bugs/p2-01-jsonrpc-client-verify-reserializes-unvalidated-access-/` |
| [B67](#b67-memory-ranges-inside-the-uarch-state-hash-node-are-accepted-and-make-uarch-reset-unprovable) | medium | pre-existing | Machine config validation, uarch reset | Memory ranges inside the uarch-state hash node are accepted and make uarch reset unprovable | `bugs/p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo/` |
| [B05](#b05-cartesifilesystemwrite_file-ignores-close-errors-cli-writes-empty-hash-files) | low | pre-existing | Lua cartesi.filesystem, CLI | cartesi.filesystem.write_file ignores close errors, CLI writes empty hash files | `bugs/ht-08-filesystem-write-file-swallows-close-errors/` |
| [B08](#b08-clone_stored-fails-with-emlink-instead-of-falling-back-to-a-copy) | low | pre-existing | Stored machine API, cartesi.filesystem | clone_stored fails with EMLINK instead of falling back to a copy | `bugs/ht-10-clone-stored-emlink-no-fallback/` |
| [B11](#b11-json-rpc-request-with-an-invalid-id-is-rejected-but-still-executed) | low | pre-existing | JSON-RPC remote machine server | JSON-RPC request with an invalid id is rejected but still executed | `bugs/rpc-03-jsonrpc-invalid-id-still-executes/` |
| [B15](#b15-frontierlast_proof-hangs-on-the-last-leaf-of-a-64-bit-tree-and-does-not-validate-the-proof) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier(last_proof) hangs on the last leaf of a 64-bit tree and does not validate the proof | `bugs/lua-05-frontier-from-proof-hang-and-no-validation/` |
| [B16](#b16-verify_slice-and-verify_splice-accept-malformed-proofs) | low | pre-existing | Lua cartesi.hash-tree (proof verification) | verify_slice and verify_splice accept malformed proofs | `bugs/lua-06-verify-slice-noncanonical-address/` |
| [B18](#b18-abi-decoder-bounds-checks-overflow-and-accept-out-of-bounds-offsets) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder bounds checks overflow and accept out-of-bounds offsets | `bugs/lua-10-evmu-offset-length-overflow-accepts-oob/` |
| [B19](#b19-abi-type-parser-mangles-parameter-names-starting-with-memory-storage-or-calldata) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI type parser mangles parameter names starting with memory, storage or calldata | `bugs/lua-11-evmu-param-name-data-location-prefix-mangled/` |
| [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_next_proofs does not check tree capacity | `bugs/lua-12-next-proofs-no-capacity-check/` |
| [B21](#b21-frontier_next_proofs-is-wrong-on-trees-of-height-64-or-more) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_next_proofs is wrong on trees of height 64 or more | `bugs/lua-13-next-proofs-signed-compare-ge64/` |
| [B22](#b22-frontier_pad_back-rejects-valid-counts-and-corrupts-very-tall-frontiers) | low | pre-existing | Lua cartesi.hash-tree (frontier) | frontier_pad_back rejects valid counts and corrupts very tall frontiers | `bugs/lua-14-pad-back-tall-tree-size-wrap/` |
| [B23](#b23-json-rpc-protocol-version-not-bumped-for-the-new-clear_hash_tree-api) | low | introduced by branch | JSON-RPC client and server | JSON-RPC protocol version not bumped for the new clear_hash_tree API | `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/` |
| [B24](#b24-temporary-and-frontier-files-are-created-with-mode-0600-and-without-atomic-o_cloexec) | low | introduced by branch | Lua cartesi.filesystem and cartesi.hash-tree, CLI | Temporary and frontier files are created with mode 0600 and without atomic O_CLOEXEC | `bugs/rpc-07-frontier-files-mode-0600/` |
| [B25](#b25---clear-hash-tree-is-reapplied-on-every-stored-mode-revert) | low | introduced by branch | CLI | --clear-hash-tree is reapplied on every stored-mode revert | `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/` |
| [B26](#b26---clear-hash-tree-is-silently-ignored-for-existing-remote-machines) | low | introduced by branch | CLI | --clear-hash-tree is silently ignored for existing remote machines | `bugs/rpc-09-clear-hash-tree-ignored-existing-remote/` |
| [B27](#b27---dump-memory-ranges-runs-mkdir-through-the-shell-with-an-unquoted-path) | low | pre-existing | CLI | --dump-memory-ranges runs mkdir through the shell with an unquoted path | `bugs/rpc-10-dump-memory-ranges-shell-mkdir/` |
| [B28](#b28-get_data_root_hash-returns-nil-for-empty-data-and-rejects-root-sizes-63-and-64) | low | pre-existing | Lua cartesi.hash-tree | get_data_root_hash returns nil for empty data and rejects root sizes 63 and 64 | `bugs/lua-16-get-data-root-hash-empty-nil/` |
| [B29](#b29-frontier-api-accepts-heights-above-the-tree-height-and-silently-grows-the-frontier) | low | pre-existing | Lua cartesi.hash-tree (frontier) | Frontier API accepts heights above the tree height and silently grows the frontier | `bugs/lua-17-frontier-height-args-unvalidated/` |
| [B30](#b30-verify_hash_tree-returns-true-when-inner-nodes-or-the-root-are-corrupted) | low | pre-existing | Hash tree (verify_hash_tree) | verify_hash_tree returns true when inner nodes or the root are corrupted | `bugs/api-03-verify-hash-tree-misses-inner-nodes/` |
| [B31](#b31-a-failed-expansion-store-is-never-retried-by-later-frontier_forest_store-calls) | low | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | A failed expansion store is never retried by later frontier_forest_store calls | `bugs/lua-20-failed-expansion-store-never-retried/` |
| [B33](#b33-lua-bindings-call-lual_error-inside-c-catch-handlers-and-leak-the-exception) | low | both | Lua bindings (clua-*.cpp) | Lua bindings call luaL_error inside C++ catch handlers and leak the exception | `bugs/lua-22-lual-error-in-catch-leaks-exceptions/` |
| [B34](#b34-frontier-stores-fail-for-files-directly-under-the-filesystem-root) | low | introduced by branch | Lua cartesi.hash-tree (frontier store) | Frontier stores fail for files directly under the filesystem root | `bugs/lua-24-hash-tree-root-parent-directory/` |
| [B36](#b36-temporary-files-from-killed-stores-are-never-cleaned-up) | low | introduced by branch | Lua cartesi.hash-tree (frontier store) | Temporary files from killed stores are never cleaned up | `bugs/lua-25-leftover-temp-files/` |
| [B37](#b37-filesystemtemp_pathname-returns-a-deleted-tmp-name-that-another-user-can-claim) | low | introduced by branch | Lua cartesi.filesystem | filesystem.temp_pathname returns a deleted /tmp name that another user can claim | `bugs/lua-27-temp-pathname-toctou/` |
| [B38](#b38-abi-decoder-accepts-dirty-address-bits-and-non-zero-padding) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder accepts dirty address bits and non-zero padding | `bugs/lua-28-evmu-lenient-dirty-bits-padding/` |
| [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset) | low | pre-existing | Machine API (uarch cycle collection) | collect_uarch_cycle_* aborts the process when the uarch is halted but not reset | `bugs/api-09-collect-uarch-halted-uarch-assert-abort/` |
| [B40](#b40-over-long-revert_uarch_tail-aborts-on-an-assert-or-yields-an-invalid-mcycle-subtree) | low | pre-existing | Machine API (uarch cycle collection) | Over-long revert_uarch_tail aborts on an assert or yields an invalid mcycle subtree | `bugs/api-10-collect-uarch-revert-tail-length-unvalidated/` |
| [B41](#b41-collect_uarch_cycle_root_hashes-accepts-bundle-sizes-above-220-and-shifts-by-a-negative-amount) | low | pre-existing | Machine API (uarch cycle collection) | collect_uarch_cycle_root_hashes accepts bundle sizes above 2^20 and shifts by a negative amount | `bugs/api-11-collect-uarch-log2-bundle-unbounded/` |
| [B42](#b42-filesystemrename_file-does-not-replace-existing-files-on-windows) | low | introduced by branch | Lua cartesi.filesystem | filesystem.rename_file does not replace existing files on Windows | `bugs/lua-26-rename-not-replacing-on-windows/` |
| [B43](#b43-abi-decoders-trailing-data-check-uses-only-the-last-dynamic-tail) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder's trailing-data check uses only the last dynamic tail | `bugs/lua-29-evmu-end-offset-last-dynamic-only/` |
| [B44](#b44-json-parsers-truncate-64-bit-log2-sizes-in-access-logs-and-proofs-without-range-checks) | low | pre-existing | JSON parsing (json-util) | JSON parsers truncate 64-bit log2 sizes in access logs and proofs without range checks | `bugs/api-12-access-log2-size-truncation/` |
| [B45](#b45-abi-decoder-amplifies-memory-use-through-aliased-dynamic-offsets) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI decoder amplifies memory use through aliased dynamic offsets | `bugs/lua-30-evmu-aliased-offsets-quadratic-memory/` |
| [B46](#b46-abi-integer-encoders-wrap-values-of-2512-or-more-instead-of-rejecting-them) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI integer encoders wrap values of 2^512 or more instead of rejecting them | `bugs/lua-31-evmu-encode-int-wraps-mod-2-512/` |
| [B47](#b47-abi-encoder-emits-malformed-data-for-arrays-with-nil-holes) | low | pre-existing | Lua cartesi.evmu (ABI) | ABI encoder emits malformed data for arrays with nil holes | `bugs/lua-32-evmu-encode-array-holes-malformed/` |
| [B48](#b48-evmu-hex-decoding-accepts-sign-characters) | low | pre-existing | Lua cartesi.evmu (ABI) | evmu hex decoding accepts sign characters | `bugs/lua-33-evmu-fromhex-sign-chars/` |
| [B49](#b49-lua-hash-functions-ignore-an-empty-second-argument-and-frontier-functions-accept-non-32-byte-hashes) | low | pre-existing | Lua cartesi (hash functions), cartesi.hash-tree | Lua hash functions ignore an empty second argument and frontier functions accept non-32-byte hashes | `bugs/lua-15-concat-hash-empty-second-arg/` |
| [B51](#b51-log_step-on-an-empty-or-destroyed-local-machine-dereferences-a-null-pointer) | low | pre-existing | C API (local machine) | log_step on an empty or destroyed local machine dereferences a null pointer | `bugs/w2b-02-log-step-empty-machine-null-deref/` |
| [B52](#b52-a-full-disk-kills-a-sharing_all-machine-with-sigbus-on-writes-to-sparse-pages) | low | pre-existing | Memory mapping (os-mapped-memory), stored machines | A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages | `bugs/w2b-04-sharing-all-enospc-sigbus/` |
| [B54](#b54-a-transient-accept-error-closes-the-json-rpc-servers-listening-socket-for-good) | low | pre-existing | JSON-RPC remote machine server | A transient accept error closes the JSON-RPC server's listening socket for good | `bugs/w2b-06-jsonrpc-accept-error-kills-server/` |
| [B55](#b55-spawn_server-hangs-on-its-error-path-when-the-caller-has-sigterm-blocked) | low | pre-existing | JSON-RPC client (spawn_server) | spawn_server hangs on its error path when the caller has SIGTERM blocked | `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/` |
| [B56](#b56-out-of-range-concurrencyupdate_hash_tree-makes-every-hash-tree-update-throw) | low | pre-existing | Runtime config, hash tree | Out-of-range concurrency.update_hash_tree makes every hash-tree update throw | `bugs/w2b-08-concurrency-update-hash-tree-int-truncation/` |
| [B57](#b57-readwrite_virtual_memory-silently-do-nothing-for-ranges-that-reach-264) | low | pre-existing | C API (virtual memory access) | read/write_virtual_memory silently do nothing for ranges that reach 2^64 | `bugs/w2b-09-virtual-memory-range-wraparound/` |
| [B60](#b60-full-shadow-write_memory-skips-validation-and-never-marks-the-tlb-padding-page-dirty) | low | pre-existing | Machine API (write_memory) | Full-shadow write_memory skips validation and never marks the TLB padding page dirty | `bugs/w2b-12-shadow-snapshot-write-unvalidated-not-dirty/` |
| [B61](#b61-cm_translate_virtual_address-crashes-on-a-null-output-pointer) | low | pre-existing | C API | cm_translate_virtual_address crashes on a NULL output pointer | `bugs/w2b-14-capi-null-output-crashes/` |
| [B62](#b62-lua-to-json-conversion-fails-on-numeric-keys-and-expands-sparse-integer-keys-into-huge-arrays) | low | pre-existing | Lua bindings (JSON conversion) | Lua-to-JSON conversion fails on numeric keys and expands sparse integer keys into huge arrays | `bugs/w2b-13-clua-json-numeric-keys-lua-next/` |
| [B63](#b63-cartesifilesystemlua-collides-with-the-v022-tests-package-breaking-upgrades) | low | introduced by branch | Packaging (Lua modules) | cartesi/filesystem.lua collides with the v0.22 tests package, breaking upgrades | `bugs/w2a-05-filesystem-module-collides-with-v022-tests-package/` |
| [B64](#b64-clear_hash_tree-punches-holes-in-shared-hash-files-so-a-full-disk-later-kills-the-process-with-sigbus) | low | introduced by branch | Memory mapping (mapped_memory::clear) | clear_hash_tree punches holes in shared hash files, so a full disk later kills the process with SIGBUS | `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/` |
| [B65](#b65-frontier-stores-fail-for-native-windows-paths-because-hash-treelua-splits-paths-only-on-slashes) | low | introduced by branch | Lua cartesi.hash-tree (frontier store) | Frontier stores fail for native Windows paths because hash-tree.lua splits paths only on slashes | `bugs/w2a-07-hash-tree-lua-parent-dir-ignores-backslash/` |
| [B68](#b68-first-frontier_forest_store-of-an-in-memory-expansion-skips-the-per-level-directory-sync) | low | introduced by branch | Lua cartesi.hash-tree (frontier forest store) | First frontier_forest_store of an in-memory expansion skips the per-level directory sync | `bugs/p2-06-forest-store-batch-expansion-unordered-dir-sync/` |
| [B69](#b69-arrayindex-conversion-between-json-and-lua-silently-wraps-out-of-range-indices) | low | pre-existing | Lua bindings (JSON conversion) | ArrayIndex conversion between JSON and Lua silently wraps out-of-range indices | `bugs/p2-07-clua-arrayindex-signed-overflow/` |
| [B70](#b70-json-rpc-client-cmio-response-functions-read-from-a-null-data-pointer) | low | pre-existing | JSON-RPC client (cmio), C API | JSON-RPC client cmio response functions read from a NULL data pointer | `bugs/p2-05-jsonrpc-cmio-null-data-segfault/` |
| [B71](#b71-fromjson-rewrites-strings-that-match-a-key-of-a-struct-array-or-tuple-schema) | low | pre-existing | Lua bindings (JSON with schemas) | fromjson rewrites strings that match a key of a struct, array or tuple schema | `bugs/p3-01-fromjson-object-schema-string-enum-rewrite/` |
| [B72](#b72-tojson-and-fromjson-truncate-object-keys-at-nul-bytes-merging-distinct-keys) | low | pre-existing | Lua bindings (JSON conversion) | tojson and fromjson truncate object keys at NUL bytes, merging distinct keys | `bugs/p3-06-json-nul-in-keys-truncated-merged/` |
| [B73](#b73-fromjson-and-the-json-rpc-server-stop-parsing-at-a-nul-byte-and-accept-trailing-data) | low | pre-existing | Lua bindings and JSON-RPC server (JSON parsing) | fromjson and the JSON-RPC server stop parsing at a NUL byte and accept trailing data | `bugs/p3-05-fromjson-truncates-at-nul/` |
| [B74](#b74-tojson-silently-writes-nan-and-infinities-as-null) | low | pre-existing | Lua bindings (JSON conversion) | tojson silently writes NaN and infinities as null | `bugs/p3-07-json-nan-inf-serialized-as-null/` |
| [B75](#b75-tojson-writes-unsigned-64-bit-values-of-263-or-more-as-negative-integers) | low | pre-existing | Lua bindings (JSON conversion), CLI | tojson writes unsigned 64-bit values of 2^63 or more as negative integers | `bugs/p3-08-tojson-uint64-written-as-negative/` |
| [B76](#b76-filesystemget_file_size-returns-263-1-for-directories-and-blocks-on-fifos) | low | introduced by branch | Lua cartesi.filesystem | filesystem.get_file_size returns 2^63-1 for directories and blocks on FIFOs | `bugs/p3-09-fs-get-file-size-directory-fifo/` |
| [B77](#b77-filesystemremove_directory-deletes-files-and-remove_file-deletes-empty-directories) | low | introduced by branch | Lua cartesi.filesystem | filesystem.remove_directory deletes files and remove_file deletes empty directories | `bugs/p3-10-fs-remove-directory-removes-files/` |

## Issues

### B01. Persisted page cache is not checked against memory, so a reload yields wrong proofs

**Title**: Persisted page hash-tree cache keeps stale entries after a mixed-sharing session, so get_proof and uarch-cycle root hashes come out wrong while get_root_hash and verify_hash_tree pass

**Problem**: The page hash-tree cache (phtc) is reused across store/load with no check that its entries still match the memory of the range they describe. The only guard is in the `hash_tree` constructor. It evicts an entry only when the range's `shared` flag *in the session now loading* differs from the cache's `shared` flag. Entries go stale in an earlier session, one where the phtc and a range were persisted differently. Two cases:
- RAM shared, hash tree private: writes reach the RAM `.bin/.dht/.dpt` files, but the phtc on disk keeps the old page hashes.
- Hash tree shared, RAM private: the phtc gets hashes for content that is never written to the RAM file.

On disk, the range's dirty-page tree still says the page is clean. A later load whose flags match (`SHARING_NONE`, or `SHARING_ALL`) evicts nothing. The cache-hit paths then trust the stale entry:
- `get_page_proof`, used by `get_proof`, reads the target and sibling hashes from the entry.
- `update_words`, used by `collect_uarch_cycle_root_hashes` and by other uarch/step paths, rehashes only the written words on top of the stale cached page.
- `get_dense_node_hash` has the same exposure. It was read in the code but not exercised by a test.

`get_root_hash` stays correct because it comes from the dense hash tree. `verify_hash_tree` returns true because it inspects the cache only for pages that are not marked dirty but differ from the `.dht`, and never compares the cache entries of clean pages against memory.

**Origin**: Pre-existing. The same eviction logic and the same hit paths are on `origin/main`.

**Area**: Page hash-tree cache / hash-tree load and store (C++ core, reached through the C and Lua APIs and the `cartesi-machine` CLI `--load`/`--store`).

**Category**: Correctness. The proofs and state commitments are wrong, and nothing reports a problem.

**Location**:
- `src/hash-tree.cpp:1003-1008`: `evict_entries_if` in the `hash_tree` constructor compares only the current session's `ar.has_shared_backing_store()` with the cache's `shared` flag.
- `src/machine.cpp:476-487`: `machine::store` writes the phtc separately from each range's persistence.
- `src/page-hash-tree-cache.hpp:440-455`: loading a persisted cache marks every stored entry as valid.
- `src/hash-tree.cpp:99-133`: the `get_page_proof` cache-hit path.
- `src/hash-tree.cpp:810-830`: the `update_words` cache-hit path, which hashes only the changed words.
- `src/hash-tree.cpp:649-713`: `hash_tree::verify` does not check cached entries of clean pages.

**Evidence**: Both tests compare the machine against a reference loaded from the same directory with `clear_hash_tree = true`, which recomputes everything from memory.

In `test-proof.lua`, all three cases (two routes, three final loads) give the correct root hash and `verify_hash_tree=true`. In every case, the `get_proof(RAM, 5)` target and sibling hashes differ from the reference proof, and the proof does not even roll up to its own `root_hash`. The reference proof does roll up.
```
[A(ram shared, cache private) SHARING_NONE] mem=BBBB root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
[B(cache shared, ram private) SHARING_NONE] mem=AAAA root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
[B(cache shared, ram private) SHARING_ALL] mem=AAAA root_ok=true verify_hash_tree=true proof_target_ok=false proof_siblings_ok=false proof_rolls_to_root=false
```
In `test-uarch-cycle.lua`, the machine is created in a directory with `ram.backing_store.shared=true`, which is the default hash-tree config. A host write follows, in a `SHARING_CONFIG` session. The final load runs a three-instruction program whose `sd` writes into the stale page. In the run, 688 of the 2109 uarch-cycle root hashes differ, starting at index 1422, where the store happens. The initial and final roots match, and `verify_hash_tree` is true before and after. Two reference runs give identical hashes, so the results are deterministic.
```
[SHARING_NONE] initial_root_ok=true verify_before=true uarch_hashes=2109/2109 differing=688 first_differing=1422 final_root_ok=true verify_after=true
[SHARING_ALL] initial_root_ok=true verify_before=true uarch_hashes=2109/2109 differing=688 first_differing=1422 final_root_ok=true verify_after=true
```
Run command: `eval $(make -s env); lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua; lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua`. Each test exits 1 while the bug is present.

**Scenario**: A validator or an operator keeps snapshot directories made with per-range sharing that differs from `hash_tree.shared`. Examples:
- A machine created in a directory with a shared RAM or flash drive while the hash tree keeps its default `shared=false`.
- A shared hash tree with private ranges.

The directory is opened once with `SHARING_CONFIG`, which is the CLI `--load` default, and modified. Examples: `send_cmio_response`, `write_memory`, or running the machine. Later the same directory, or a copy of it, is loaded with `SHARING_ALL` (as `prt.lua` does) or `SHARING_NONE`. From then on:
- `get_proof` returns Merkle proofs that fail on-chain verification.
- `collect_uarch_cycle_root_hashes` produces wrong leaf-level commitments.

The honest player then commits to, or tries to prove, a state that does not match the real execution, and loses the PRT dispute. Every integrity check passes: the root hash matches and `verify_hash_tree` returns true. The bundled PRT node always uses `SHARING_ALL` with `clone_stored`, so it does not trigger this by itself. Other nodes, and mixed workflows through the CLI, can.

**Possible solution**: Make cache validity independent of the sharing mode of the session that is loading now. Options:
- Record per-range persistence or a generation id, for example a hash of the `.dht` root, in the phtc header. On load, evict the entries of any range whose recorded value does not match.
- In `machine::store`, and when loading, evict the entries of every range whose persistence differs from the cache's, so a mixed session can never leave a phtc that disagrees with the range files.
- As a cheap safety net, on load check each cached clean page's root against the `.dht` page hash and evict on mismatch. Also make `verify_hash_tree` check the cache entries of clean pages against memory.

**Severity**: High. When it triggers, the impact is critical in kind: Merkle proofs and uarch-cycle commitments are silently wrong, and an honest player can lose a dispute. Both reviewers rated it high rather than critical because it needs a mixed-sharing session followed by a load with matching flags, which the default flows (uniform `SHARING_ALL`, or everything private) do not do.

**Risks**:
- Of the bug: it fails silently. No API detects it, it persists in the directory and every copy of it, and it corrupts proofs and step or uarch commitments, not the root hash.
- Of the fix: evicting more often only costs rehashing time. A header or format change to the phtc needs a version bump and invalidates existing cache files, which is acceptable. A check on load that compares cached roots with the `.dht` adds O(cached pages) work when loading.

**Proof of concept**: `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua` (get_proof, both routes) and `bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua` (collect_uarch_cycle_root_hashes). Run them from the repo root with `eval $(make -s env); lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-proof.lua && lua5.4 bugs/ht-02-phtc-stale-entries-after-mixed-sharing-session/test-uarch-cycle.lua`. Both use temporary directories under the system temp dir, create a phtc file of about 50 MB, and print `BUG:` lines and exit 1 while the bug is present.

**ID**: `ht-02-phtc-stale-entries-after-mixed-sharing-session`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `api-06-persisted-phtc-not-validated-against-backing`: run with `eval $(make -s env); lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-replace-memory-range.lua; lua5.4 bugs/api-06-persisted-phtc-not-validated-against-backing/test-mixed-sharing.lua`. It adds a second, more common trigger: `replace_memory_range` on a machine loaded with `SHARING_ALL` writes the new image's page entries into the shared `hash_tree.phtc` while the stored range files still describe the old image. Reloading the directory with `SHARING_ALL` then gives wrong `get_proof`, `get_node_hash` and uarch-cycle root hashes, with a correct `get_root_hash`. No mixed-sharing session is needed.

### B02. Crash in sparse-tree update freezes the root hash of a shared hash tree

**Title**: A crash inside `update_sparse_tree` leaves transient `marked` flags and stale inner hashes in a shared `hash_tree.sht`; the loader accepts them and the root hash stays silently wrong (`verify_hash_tree` still returns true)

- **Problem**: `update_sparse_tree` uses `node.marked` in the sparse nodes as a transient "already queued" flag. It sets the flag when it pushes a node and clears it only when it pops that node, and it enqueues a parent only when `marked == 0`. The sparse nodes live directly in the `hash_tree.sht` mapping, which is `MAP_SHARED` when a machine is stored or loaded with `SHARING_ALL` or backed by a directory. If the process dies between push and pop, the file keeps `marked = 1`. The loading constructor rejects only `marked > 1`. It never resets the flag and never rehashes inner nodes. From then on that node (for example the root) is never enqueued again, so its hash is frozen across every later update. A kill can also land after the address-range leaf hashes were copied but before the inner nodes were rehashed (the SIMD queue defers hashing until `flush()`). On reload the leaves already match the dense roots, so nothing is enqueued and the stale inner nodes and root survive even when the flag is 0. `verify_hash_tree` never checks sparse inner nodes or the root against their children. Its leaf-vs-dense-root mismatch branch only prints a message and does not set `ret = false`, so it returns true on the corrupted tree. Only `cm_clear_hash_tree` (`hash_tree::clear`) repairs it.
- **Origin**: pre-existing. The branch did not introduce the flag logic.
- **Area**: hash tree, sparse tree (`hash_tree` loading constructor, `update_sparse_tree`, `verify`); C API `cm_load_new`/`cm_get_root_hash`/`cm_get_proof`/`cm_log_step`/`cm_verify_hash_tree` and the Lua bindings, on machines that use `SHARING_ALL` or on-disk storage.
- **Category**: correctness (crash consistency / silent hash corruption)
- **Location**:
  - `src/hash-tree.cpp:962-972`: the constructor maps an existing sht, accepts `marked <= 1`, and does not reset the flag or rehash inner nodes.
  - `src/hash-tree.cpp:497-569`: `update_sparse_tree` sets `marked = 1` on push (lines 515-518, 530-533, 559-562), clears it only on pop (line 550), and enqueues only when `marked == 0`.
  - `src/hash-tree.cpp:650-713`: `verify` ignores sparse inner nodes and the root, and the leaf-mismatch branch (lines 704-706) does not fail.
  - `src/hash-tree.cpp:717-727`: `clear` is the only code that zeroes `marked`.
  - `src/hash-tree.cpp:729-740`: `update` cleans the dirty page trees only after a full successful update. The dense part is redone after a crash; the sparse part is not.
- **Evidence**: Part A of `test.lua` makes a real kill. A child process loads a 1 MiB machine stored with `SHARING_ALL`, writes `"hello"` and calls `get_root_hash`. gdb sets a hardware watchpoint on the root node's `marked` field (sht offset 64+28) in the mapping. It fires inside `update_sparse_tree` (`hash-tree.cpp:562`, called from `machine::update_hash_tree`), and gdb sends SIGKILL. The file on disk is left with root `marked = 1`. After reload with `SHARING_ALL`, the root hash differs from a fresh machine with identical RAM. It stays wrong after more writes, and `verify_hash_tree` keeps returning true. Part B patches only the flag into an otherwise correct sht. The next write is then silently missing from the root hash.
  ```
  $ eval $(make -s env); lua5.4 bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua
  [A] root marked flag on disk after SIGKILL inside update_sparse_tree: 1
  [A] after reload           root_ok=false verify_hash_tree=true
  [A] after write 1          root_ok=false verify_hash_tree=true
  [A] after write 2          root_ok=false verify_hash_tree=true
  BUG: after a real SIGKILL inside update_sparse_tree, the reloaded SHARING_ALL machine reports a wrong root hash that stays wrong after further writes, while verify_hash_tree still says true
  [B] after reload        root_ok=true
  [B] after write         root_ok=false verify_hash_tree=true
  BUG: a persisted marked=1 on the root sparse node is accepted on load and freezes the root hash (write ignored)
  ```
  Extra experiment: zeroing the root flag in the killed directory before reload is not enough. The root is still wrong right after reload (`false`) and becomes correct only after the next write that changes a leaf.
- **Scenario**: A validator node (the in-branch PRT node, or Rollups Node / Dave if they persist machines with `sharing: all`) keeps its machine in a directory with `SHARING_ALL`. The CLI's `--revert-mode=stored` and the documented `sharing:all` workflow do the same. The node is SIGKILLed, OOM-killed or crashes while a hash-tree update is running (`get_root_hash`, `get_proof`, `log_step`, `store`, ...). After restart it reloads the directory. Every later root hash, proof and step log built from that machine carries a wrong state hash, and `verify_hash_tree` reports the tree as fine. Snapshots made by cloning the directory copy the corruption. A node that checks the reloaded root against a known hash, as `prt.lua` does, fails loudly at startup. Recovery then needs a non-obvious `cm_clear_hash_tree`. A node that trusts the reloaded root, or whose stale root happens to match the expected pre-update value while the root's flag is stuck, would commit to or prove wrong state, and an honest player could lose a dispute. Apps inside the machine are not affected; only the host-side hashes are wrong.
- **Possible solution**: When the constructor maps an existing sht, reset every `marked` to 0 and recompute all sparse inner nodes bottom-up from the leaves and pristine hashes. There are few sparse nodes, so this is cheap. Alternatively, treat any nonzero `marked` (or a persisted "update in progress" flag set before and cleared after `update_sparse_tree`) as a reason to rehash the whole sparse tree. Separately, make `verify` check every sparse inner node and the root against their children, and set `ret = false` on a leaf vs dense-root mismatch.
- **Severity**: medium. The corruption is silent, permanent and undetected by `verify_hash_tree`, and it yields wrong root hashes and proofs, which argues for high. But it needs a process death inside a short window (60 random kills never hit it), only on shared or on-disk hash trees, and nodes that check the reloaded root, like the reference PRT node, fail loudly instead of committing wrong state. Both reviewers rated it medium, and one noted that validators restarted by SIGKILL or the OOM killer could justify high.
- **Risks**: Bug: a validator silently commits to or proves a wrong state hash, or fails to restart with no clear cause, and cloned snapshots spread the corruption. Fix: rehashing the sparse tree on every load adds a small, bounded cost to load. It must use the configured hash function and handle pristine subtrees exactly as `update_sparse_tree` does, or it could itself produce wrong roots. Making `verify` stricter may start rejecting directories already corrupted in the field, which is the correct outcome but may surprise operators.
- **Proof of concept**: `bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua` (driver), `bugs/ht-03-persisted-sparse-marked-flag-stale-root/kill.py` (gdb script: watchpoint on the root `marked` field, then SIGKILL), `bugs/ht-03-persisted-sparse-marked-flag-stale-root/child2.lua` (child that loads, writes and hashes). Part A needs `gdb` and is skipped without it; Part B always runs. The test exits 1 when the bug reproduces. Run from the repo root:
  `eval $(make -s env); timeout 200 lua5.4 bugs/ht-03-persisted-sparse-marked-flag-stale-root/test.lua`

**ID**: `ht-03-persisted-sparse-marked-flag-stale-root`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-14-sht-marked-freezes-root`: run with `eval $(make -s env); timeout 120 lua5.4 bugs/rpc-14-sht-marked-freezes-root/test.lua`.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B03. Crash during hash-tree update makes a SHARING_ALL machine unloadable or silently wrong

**Title**: A process kill during a hash-tree update of a SHARING_ALL machine corrupts the stored directory: it becomes unloadable even with clear_hash_tree=true, or it loads with a silently wrong root hash

**Problem**: When a machine is loaded with `SHARING_ALL`, or created in a directory, its hash-tree state lives in `MAP_SHARED` files: the page hash-tree cache (`hash_tree.phtc`), the dense hash trees (`.dht`) and the dirty page trees (`.dpt`). The updates to these files are not crash-safe. Two failure modes follow from a kill during an update.
- **Unloadable directory.** `update_dirty_pages` borrows a whole batch of cache entries (up to `phtc_size`, 2048 by default) and keeps them borrowed while every page in the batch is hashed. The per-entry `m_borrowed` flag and the intrusive LRU links are part of the persisted metadata. If the process is SIGKILLed, OOM-killed or stopped in that window, the file keeps `borrowed=1` entries. The new `check_metadata()` then throws `corrupted page hash-tree cache: borrowed entry` (or an LRU/payload-index error for half-spliced links) inside the `page_hash_tree_cache` constructor. That constructor runs first in the `hash_tree` constructor, which runs in the `machine` member-initializer list. The new `clear_hash_tree` runtime option runs only at the end of the `machine` constructor body, so it can never recover. The directory cannot be loaded with any sharing mode, and copies made by `clone_stored` inherit the problem. Deleting `hash_tree.phtc` fails too (`unable to open backing file`). The only repair is to replace it by hand with an all-zero file of the same size. Even `get_root_hash` on a freshly loaded machine is enough to open the window, because `mark_always_dirty_pages` always marks pages dirty.
- **Silently wrong root hash.** `return_updated_dirty_pages` writes each new page hash into the persisted `.dht` leaf. The DPT is cleaned only after `update_dense_trees` and `update_sparse_tree` both succeed. After a kill inside `update_dense_trees`, no entry is borrowed, so the phtc passes validation and the directory loads normally. On the next update, each recomputed page hash already equals the stored leaf, so `changed=false` and `mark_clean_page_and_up` clears the dirty bits without ever recomputing the stale inner dense nodes or the sparse nodes above them. `get_root_hash()` returns a wrong root, and `verify_hash_tree()` still returns true, because it checks page leaves and sparse roots but not dense inner nodes. Only a load with `clear_hash_tree=true` gives the right root. The same wrong root appears after the manual "zero the phtc" repair unless `clear_hash_tree=true` is also used.

The phtc is only a cache, so rejecting the whole stored machine because of it is disproportionate.

**Origin**: Introduced by this branch for the unloadable directory: `check_metadata()` and the `clear_hash_tree` runtime option are new. On `main`, load accepted the stale flags, but `borrow_entry` later threw `already borrowed`, so hashing failed there too. The silent wrong-root mechanism (`.dht` leaves persisted before the DPT is cleaned, plus the `mark_clean_page_and_up` shortcut) appears to be pre-existing for `SHARING_ALL` directories. It was not run against a `main` build.

**Area**: Hash tree persistence: page hash-tree cache, dense hash trees and dirty page trees of stored machines; machine constructor (`clear_hash_tree` runtime option). Reached through the C API (`cm_load_new`, `cm_get_root_hash`, `cm_get_proof`, ...), the Lua API and the `cartesi-machine` CLI.

**Category**: Durability / crash safety. Leads to denial of service (unloadable snapshot) or to a silently wrong state commitment.

**Location**:
- `src/page-hash-tree-cache.hpp:440-456`: the constructor calls `check_metadata()` on an initialized file.
- `src/page-hash-tree-cache.hpp:689-724`: `check_metadata()` rejects borrowed entries (698-700), invalid payload indices and broken LRU links.
- `src/hash-tree.cpp:380-431`: `update_dirty_pages` keeps a whole batch borrowed while hashing.
- `src/hash-tree.cpp:946-948`: `m_page_cache` is the first member constructed by `hash_tree`.
- `src/machine.cpp:303` and `316-318`: `m_ht` is built in the initializer list; `clear_hash_tree()` runs only at the end of the body.
- `src/hash-tree.cpp:316-320`: persisted `.dht` page leaves are overwritten before the update is complete.
- `src/hash-tree.cpp:340-352`: the "unchanged, mark clean and up" shortcut.
- `src/hash-tree.cpp:731-739`: the DPT is cleaned only after the dense and sparse updates succeed.
- `src/hash-tree.cpp:650-713`: `hash_tree::verify` does not check dense inner nodes.

**Evidence**: The test stores a 64 MiB machine with `SHARING_ALL`. A child process loads it with `SHARING_ALL`, writes all of RAM and calls `get_root_hash`. A gdb breakpoint SIGKILLs the child at an exact point. The reference root comes from a fresh machine with the same RAM contents. Run with `eval $(make -s env); lua5.4 bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua` (about 10 s, exits 1 while the bug is present):
```
case 1: SIGKILL inside hash_tree::return_updated_dirty_pages (3rd batch borrowed, 2 batches returned)
  borrowed entries persisted in hash_tree.phtc: 2048
  load SHARING_ALL                          -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_NONE                         -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_NONE + clear_hash_tree=true  -> FAILED: corrupted page hash-tree cache: borrowed entry
  load SHARING_ALL + clear_hash_tree=true   -> FAILED: corrupted page hash-tree cache: borrowed entry
  after zeroing hash_tree.phtc by hand:
  load SHARING_ALL                          -> ok, root ~= expected
  load SHARING_NONE + clear_hash_tree=true  -> ok, root == expected
case 2: SIGKILL inside hash_tree::update_dense_trees (all page entries returned)
  borrowed entries persisted in hash_tree.phtc: 0
  load SHARING_NONE -> ok; root ~= expected; verify_hash_tree() = true
  with clear_hash_tree=true root == expected
case 3: load with clear_hash_tree=true after persisting one borrowed flag -> FAILED: corrupted page hash-tree cache: borrowed entry
```
Earlier timed kills (no gdb) of a 64 MiB loop made the later load fail in 5 of 6 runs, and a 256 MiB variant killed after 0.3 s also failed.

**Scenario**: A validator (Rollups Node, Dave, a PRT player) runs a stored machine in place with `SHARING_ALL`, as `prt.lua` and the README's disk-based driver do, and reopens its directories after a crash. A SIGKILL, OOM kill, container stop or restart arrives during `get_root_hash`, `get_proof`, `log_step`, `collect_*_root_hashes` or a run that updates the hash tree. Hashing a large RAM takes seconds, so the window is wide. On restart:
- either `cm_load_new(dir, {"clear_hash_tree":true}, ...)` fails with `borrowed entry` under every sharing mode, the snapshot is unusable, and the node must replay from an older snapshot or wait for a manual repair, possibly missing dispute deadlines;
- or the directory loads and the node computes a wrong root hash and wrong proofs that `verify_hash_tree` does not flag. A node that does not compare the root against a known value commits to a wrong state and loses the dispute. `prt.lua` asserts the root against the expected state hash, so for that node it becomes a failure rather than a wrong commitment.

**Possible solution**:
- Treat the phtc as disposable: on any validation failure (borrowed entry, bad LRU link, bad payload index, tag mismatch), reinitialize the cache instead of throwing. Do not persist the borrowed flag (or clear all borrowed flags on load).
- Pass `clear_hash_tree` into the `hash_tree` / `page_hash_tree_cache` constructors so that validation is skipped and the cache is rebuilt before it is used.
- For the wrong-root mode, evicting borrowed entries is not enough. Persist an "update in progress" marker (set before the first `.dht` leaf write, cleared after the DPT is cleaned) and on load, if it is set, force a full rebuild or a bubble-up of all dirty pages instead of the "unchanged, mark clean" shortcut. Alternatively, do not take that shortcut for pages whose leaf may have been written by an interrupted update.
- Make `verify_hash_tree` also check dense inner nodes so the inconsistency is at least detectable.

**Severity**: High. Both reviewers rated it high: a routine process kill during an in-place `SHARING_ALL` update leaves the stored machine either unloadable, with the documented `clear_hash_tree` recovery ineffective, or loadable with a silently wrong root hash that `verify_hash_tree` accepts. The wrong-root mode approaches critical, but it requires a crash during an in-place update, and nodes that load immutable snapshots with `SHARING_NONE` or clone them first are not affected.

**Risks**:
- Of the bug: a validator cannot restart from its own snapshot without manual file surgery, or it silently computes wrong hashes and proofs. The corrupted state persists in the directory and in any `clone_stored` copy.
- Of the fix: reinitializing the cache costs only rehashing time. An "update in progress" marker or format change needs a phtc/dht version bump. A full rebuild on load after a crash can take a long time on large machines. Not persisting borrowed flags must not break concurrent hashing within one process.

**Proof of concept**: `bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua`, with helpers `child.lua` (the process that gets killed) and `killat.py` (gdb Python script that sends SIGKILL at the N-th hit of a function). Run from the repo root with `eval $(make -s env); lua5.4 bugs/ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover/test-phtc-crash.lua`. It needs `gdb` with Python for the deterministic kill points; without gdb, case 1 falls back to a timed SIGKILL and case 2 is skipped. It uses a temporary directory under the system temp dir and prints `BUG:` lines and exits 1 while the bug is present.

**ID**: `ht-01-phtc-crash-borrowed-unloadable-clear-cannot-recover`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-13-phtc-borrowed-unloadable`: run with `eval $(make -s env); lua5.4 bugs/rpc-13-phtc-borrowed-unloadable/test.lua; lua5.4 bugs/rpc-13-phtc-borrowed-unloadable/kill_test.lua 512`. Unloadable-directory mode.
- `rpc-12-crash-during-update-stale-dense`: run with `eval $(make -s env); lua5.4 bugs/rpc-12-crash-during-update-stale-dense/test_stale_dense.lua; bugs/rpc-12-crash-during-update-stale-dense/test_sigkill_gdb.sh`. Silent wrong-root mode (stale dense inner nodes).
- `api-02-phtc-borrowed-unrecoverable-even-with-clear`: run with `eval $(make -s env); lua5.4 bugs/api-02-phtc-borrowed-unrecoverable-even-with-clear/test.lua`. Unloadable-directory mode.
- `api-01-kill-during-hash-update-stale-root`: run with `eval $(make -s env); lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test.lua; lua5.4 bugs/api-01-kill-during-hash-update-stale-root/test-boundary.lua`. Silent wrong-root mode. It also shows that the reloaded root is often exactly the root from before the interrupted write, so a node that compares against the previous known state hash would accept it, and that this mode is pre-existing on main.

**Related**: [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree), [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages).

### B04. Crash during clear_hash_tree leaves zeroed hashes on clean pages

**Title**: hash_tree::clear punches a range's .dht before marking its .dpt dirty, so a process kill mid-clear leaves a stored machine whose reload silently reports wrong root hashes and zero proofs

**Problem**: `hash_tree::clear` processes each address range in this order:
1. It zeroes the range's dense hash tree with `ar.get_dense_hash_tree().clear()`. For a shared `.dht` file this becomes `mapped_memory::clear`, which calls `fallocate(PUNCH_HOLE|KEEP_SIZE)` on the backing file.
2. Only afterwards does it mark the range's pages dirty in the `.dpt` with `mark_dirty_pages_and_up(0, bit_ceil(len))`, a per-page loop.

Everywhere else, the code keeps this rule: "a page marked clean in the `.dpt` has a valid `.dht`". For example, `hash_tree::update` writes the dense trees first and cleans the dpt last. The `memory_address_range` constructor marks everything dirty when it has to rebuild. `clear()` is the only path that breaks the rule, and it stays broken until the marking loop finishes. If the process dies after the punch and before the loop completes, the stored directory has zero dense hashes for pages the dpt still reports as clean. A later normal load skips those pages, and `update_sparse_tree` copies the zero dense root into the sparse tree. The root hash and proofs are then wrong, and no error is raised.

**Origin**: Introduced by this branch (commit ba0b00e, "add hash-tree cache clearing APIs and load option"). `origin/main` has no dense-tree clear.

**Area**: Hash tree cache maintenance (`hash_tree::clear`, `dense_hash_tree::clear`, `os::mapped_memory::clear`). It is reachable from `cm_clear_hash_tree`, from Lua `machine:clear_hash_tree()`, from the runtime option `clear_hash_tree=true` at load, and from CLI `--clear-hash-tree` with `--load=...,sharing:all`.

**Category**: Crash consistency / durability (silently wrong hashes and proofs).

**Location**:
- `src/hash-tree.cpp:717-728`: `ar.get_dense_hash_tree().clear()` runs before `ar.get_dirty_page_tree().mark_dirty_pages_and_up(...)`.
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear` punches a hole in the shared backing file.
- `src/dense-hash-tree.hpp:80-82`: `do_clear` forwards to `m_mapped_memory.clear()`.
- `src/machine.cpp:316-317`: `clear_hash_tree()` is called from the machine constructor when `runtime.clear_hash_tree` is set.

**Evidence**: An `LD_PRELOAD` shim (`killshim.c`) forwards `fallocate` to libc. When the call has just punched the RAM `.dht` (`0000000080000000-400000.dht`), the shim sends a real `SIGKILL`. That is the point between the two steps above. The child process uses only the public Lua API: `cartesi.machine(dir, {}, SHARING_ALL)` followed by `m:clear_hash_tree()`. The test then reloads the directory normally (`SHARING_NONE`, no clear):
```
shim: punched /tmp/tmp.ZmTjAdRIq9/work/m/0000000080000000-400000.dht, sending SIGKILL
child:	nil	exit	137
good root    :	b1f4d32d6c7704054d22d2045d055a0123e530464fbedaebd1bf7a8d67d4830a
reloaded root:	1034679ae63987d15e6b4119dff3bc0c11084ade2a3c6bf206a30e632f170c2d
ref root     :	b1f4d32d6c7704054d22d2045d055a0123e530464fbedaebd1bf7a8d67d4830a
BUG: reloaded machine's proof of RAM page 0 has target_hash 0000...0000 but the true page hash is 7cb685a7...9624
BUG: root hash after interrupted clear_hash_tree is wrong on reload
BUG: after one RAM write, reloaded machine root differs from correct root (stale zero dense hashes reused)
exit=1
```
The data is intact: reloading with `clear_hash_tree=true` rebuilds the correct root (`b1f4...`). Only the hash cache is inconsistent, and a normal load never runs `verify_hash_tree`. To run it: `eval $(make -s env); sh bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`. On a 2 GiB RAM machine, `clear_hash_tree` takes about 42 ms of CPU, and the window grows with RAM size.

**Scenario**: An operator or validator node (Rollups Node, Dave, or another PRT node) suspects its stored cache is bad. To scrub it, the node calls `cm_clear_hash_tree`, or it loads a `SHARING_ALL` directory with `clear_hash_tree=true` or CLI `--clear-hash-tree`. During that call the process is SIGKILLed, OOM-killed, or its container is stopped. On restart the node loads the same directory normally. It then reports a wrong state root, produces wrong proofs (a zero `target_hash` for RAM pages), and keeps computing wrong roots after further steps. An honest player could commit to or defend a wrong state and lose a dispute. Nothing errors, so the problem is not noticed. A node that always loads with `clear_hash_tree=true` repairs this on restart. The `prt.lua` node in this branch never calls `clear_hash_tree`.

**Possible solution**: In `hash_tree::clear`, call `get_dirty_page_tree().mark_dirty_pages_and_up(0, bit_ceil(len))` for a range before zeroing or punching its `.dht`. For power-loss safety, also msync the `.dpt` first. Alternatively, persist a durable "needs rebuild" flag before zeroing anything and clear it only after the operation finishes. With the order swapped, the same test exits 0: the dpt is already fully dirty at the kill point, so the reload rebuilds the tree.

**Severity**: Medium. Both reviewers agree. The impact is high: a stored machine silently reports a wrong state root and wrong proofs. Reaching it is unlikely, though. It needs an explicit, non-routine clear on a shared directory, a process death inside a window of a few to tens of milliseconds, and then a normal reload without a clear. The power-loss variant is not specific to this function: the README already says `sharing:all` directories need `sync` to survive a host crash.

**Risks**: Bug: a validator that keeps using the directory commits to or proves wrong states, with no error raised. `verify_hash_tree` (which normal load does not run) or another clear is the only thing that detects or repairs it. Fix: low risk. Marking the dpt dirty first only means a kill can leave extra dirty pages, which costs a rebuild and is always safe. An extra msync of the `.dpt` adds some latency to `clear_hash_tree`.

**Proof of concept**: `bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`, `test.lua` and `killshim.c`. `run.sh` builds the shim into a temporary directory and runs `test.lua`. Run it from the repo root with `eval $(make -s env); sh bugs/ht-04-clear-hash-tree-zeroes-before-marking-dirty/run.sh`. It needs `gcc` and `lua5.4`, exits 1 with `BUG:` lines while the defect is present, and exits 0 once it is fixed.

**ID**: `ht-04-clear-hash-tree-zeroes-before-marking-dirty`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-11-clear-hash-tree-crash-order`: run with `eval $(make -s env); sh bugs/rpc-11-clear-hash-tree-crash-order/run.sh`.
- `api-07-clear-hash-tree-zeroes-before-marking-dirty`: run with `eval $(make -s env); sh bugs/api-07-clear-hash-tree-zeroes-before-marking-dirty/run.sh`.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B05. cartesi.filesystem.write_file ignores close errors, CLI writes empty hash files

**Title**: `cartesi.filesystem.write_file` reports success when the final flush fails, so CLI hash and proof files can be left empty

**Problem:** `filesystem.write_file` opens the file as a to-be-closed variable (`local f <close> = ...`), calls `assert(f:write(data))`, and never closes the file explicitly. For small payloads (32-byte hashes, proofs, reports) `f:write` only fills the stdio buffer, so it succeeds. The real `write(2)` happens in `fclose`, which runs from the `<close>` handler. Lua 5.4's file `__close` (the same function as `__gc`) throws away `fclose`'s result. So ENOSPC, EFBIG, EIO or quota errors are lost: `write_file` returns normally and leaves an empty or truncated file. `write_temp_file` wraps `write_file` in `pcall`, so it cannot see the error either. The CLI then exits 0.

**Origin:** Pre-existing. `util.write_file` on `origin/main` has identical code (`src/cartesi/util.lua:344-347`). This branch moved it into the new `cartesi.filesystem` module.

**Area:** Lua library `cartesi.filesystem` (exported to other projects) / `cartesi-machine` CLI.

**Category:** Durability / silent error loss.

**Location:**
- `src/cartesi/filesystem.lua:91-94` (`write_file`)
- `src/cartesi/filesystem.lua:103-109` (`write_temp_file`, and `write_scope_temp_file` through it)
- CLI callers in `src/cartesi-machine.lua`: 3214, 3287 (per-advance state hash files), 3486 and 3500 (proofs), 3587, 3606 (memory-range dumps), 3669 (`--initial-hash`), 4365, 4715 (`--final-hash`)
- Not affected: `hash-tree.lua` has its own `write_file` (temp file, sync, rename) for stored hash trees.

**Evidence:** `test_write_file_close.lua` writes 32 bytes to `/dev/full`. An explicit `f:close()` reports the error, but `fs.write_file` returns success:
```
$ lua5.4 bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua
explicit f:close() on /dev/full ->	nil	No space left on device
fs.write_file(32 bytes, /dev/full) ->	true	nil
BUG: cartesi.filesystem.write_file reported success although the data could not be written (ENOSPC on fclose was swallowed)
```
`test_cli_final_hash.sh` runs `cartesi-machine.lua --final-hash=...` with `ulimit -f 0` and SIGXFSZ ignored, so the write fails with EFBIG:
```
$ sh bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh
Halted
Cycles: 56481123
cli_exit=0
final.bin size=0
BUG: cartesi-machine exited 0 although the --final-hash file was not written (size=0)
```

**Scenario:** A script, CI job or operator tool runs `cartesi-machine --final-hash=final.bin` (or `--initial-hash`, state-hash, proof or dump outputs) on a host whose disk is full, over quota or failing. The CLI exits successfully and leaves a 0-byte or truncated file. Downstream tooling reads an empty or wrong hash or proof and may compare it, submit it or reject it with nothing pointing at the real cause. Lua projects that use `cartesi.filesystem.write_file`, `write_temp_file` or `write_scope_temp_file` (for example to stage input files for a run) can silently feed empty data into a later step after a host I/O failure.

**Possible solution:** Close explicitly and check the result. For example, keep `<close>` and add `assert(f:close())` after the write; closing an already-closed file in `__close` is harmless. Or:
```lua
function filesystem.write_file(data, filename)
    local f = assert(io.open(filename, "wb"))
    local ok, err = f:write(data)
    if ok then ok, err = f:close() else f:close() end
    assert(ok, err)
end
```
Audit other `<close>`-only write paths for the same pattern.

**Severity:** Low. Both reviewers agree. It only triggers on host-side write failures. Machine state and the hashes and proofs computed in memory are correct, and neither the C API nor the PRT hash-tree storage path is involved. The harm is output files left empty or truncated while the CLI reports success.

**Risks:** Bug: downstream consumers of CLI output files, or Lua library users, can act on empty or truncated hashes, proofs or inputs with no error raised. Fix: minimal. Callers that used to "succeed" on a failing disk will now raise an error, which is the intended behavior. `write_temp_file` already removes the file when it fails.

**Proof of concept:** `bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua` (library-level, needs `/dev/full`) and `bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh` (end-to-end CLI, needs the default Cartesi images). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/ht-08-filesystem-write-file-swallows-close-errors/test_write_file_close.lua
eval $(make -s env); sh bugs/ht-08-filesystem-write-file-swallows-close-errors/test_cli_final_hash.sh
```
Both exit 1 while the bug is present and 0 once it is fixed.

**ID**: `ht-08-filesystem-write-file-swallows-close-errors`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-21-write-file-close-error-ignored`: run with `lua5.4 bugs/lua-21-write-file-close-error-ignored/test_write_file_close_error.lua`.

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files).

### B06. frontier_forest_store and fs.sync_file ignore write errors and commit truncated files

**Title**: hash-tree.lua `write_file` ignores `file:write` errors, so `frontier_forest_store` commits a truncated tree file that later stores never repair

**Problem:** The durable `write_file` helper in `cartesi.hash-tree` calls `temporary.file:write(contents)` and never checks the result. Lua's `file:write` does not raise on failure; it returns `nil, err`. When a large `fwrite` fails partway (ENOSPC, EFBIG, EDQUOT), glibc returns a short count and leaves nothing pending in the stdio buffer. The later `fs.sync_file` therefore succeeds (`fflush` returns 0 and `fsync` works): its C implementation, `filesystem_core_mod_sync_file`, checks only `fflush`'s return value and never the stream's sticky error flag (`ferror`). So every user of the public `cartesi.filesystem` durable-write pattern (`new_temporary_file`, `file:write`, `sync_file`, `rename`) that does not check `file:write` itself loses the error too, not just `hash-tree.lua`. The same path can also replace a previously good file with a truncated one. `temporary:rename` in `cartesi.filesystem` also ignores the result of `self.file:close()`, so the truncated temporary file is renamed into place. This breaks the helper's own guarantee that "the name never appears with incomplete contents". `store_tree` writes a tree file only `if not fs.exists(path)`, and files are named by the tree's hash, so no later store rewrites or checks the corrupt file, even in a fresh process with free space. The next `frontier_forest_store` then commits a new frontier file (the store's commit point) that references the unloadable tree.

**Origin:** Introduced by this branch. `src/cartesi/filesystem.lua` and the durable forest store in `src/cartesi/hash-tree.lua` do not exist on `main`.

**Area:** Lua library `cartesi.hash-tree` (frontier forest and frontier persistence) and `cartesi.filesystem`. The `cartesi-machine` CLI's `store_frontier` also goes through `write_file`.

**Category:** Durability / silent data corruption (an unchecked I/O error).

**Location:**
- `src/cartesi/hash-tree.lua:509-514`: `write_file`, where `temporary.file:write(contents)` is unchecked.
- `src/clua-cartesi-filesystem.cpp:111-125`: `filesystem_core_mod_sync_file` checks `fflush` only, never `ferror`.
- `src/cartesi/filesystem.lua:47-51`: `temporary_file_meta.__index:rename`, where `self.file:close()` is unchecked.
- `src/cartesi/hash-tree.lua:577-596`: `store_tree` skips any tree file that already exists.
- `src/cartesi/hash-tree.lua:967-990`: `frontier_forest_store` commits the frontier file over the corrupt tree.
- `src/cartesi/hash-tree.lua:935-938` (`frontier_store`) and `src/cartesi-machine.lua:3274-3277` (CLI `store_frontier`): other users of the same `write_file`.

**Evidence:** The test builds a 512-leaf keccak256 forest, whose single fixed-point tree file is about 35 KB. A child process stores it under `trap '' XFSZ; ulimit -f 8`, so `write(2)` fails with EFBIG at 8 KiB, which is the same short-write path ENOSPC takes on a full disk. The parent then stores again with no limit, reloads the forest, and queries a node hash. Run from the repo root: `eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`
```
child (limited store): STORE-OK
tree file 0x8782ecbf...6e6606a5.json size 8192
second (unlimited) store:	true	nil
tree file after second store 0x8782ecbf...6e6606a5.json size 8192
reload + query:	false	.../src/cartesi/hash-tree.lua:528: failed to parse JSON from a string: [json.exception.parse_error.101] parse error at line 1, column 8193: ... missing closing quote
BUG: frontier_forest_store reported success although writing the tree file failed (EFBIG)
BUG: the committed tree file is truncated and the forest cannot be reloaded/queried: ...
BUG: a later store over the same directory did not repair the truncated file (store_tree skips existing files)
exit=1
```
The prover patched a copy with `assert(temporary.file:write(contents))`. With that change, the limited store raises `hash-tree.lua:511: File too large` and commits nothing, the later store writes the full 35388-byte file, and the reload and query succeed.

**Scenario:** A long-running PRT validator, Rollups Node or Dave component persists its commitment or output forest snapshots with `frontier_forest_store`. Fixed-point tree files hold up to 2^k hashes of about 68 bytes each, so many are larger than the stdio buffer and take this path. If the disk fills or a quota is hit during a store, the store reports success and leaves a truncated tree file. After the operator frees space, later stores succeed but keep the corrupt file and commit frontiers that point at it. `frontier_forest_load` still succeeds because trees load lazily. After a restart, or when a dispute first needs that subtree for bisection or proof siblings, `frontier_forest_get_node_hash` and the related calls raise an error, and the node cannot take part in the dispute from that snapshot until an operator finds and deletes the bad file or rebuilds the forest from the machine. If that takes longer than the tournament's time budget, an honest player can lose on timeout. The CLI's `store_frontier` and `frontier_store` payloads are small and usually fit in the stdio buffer, so for them the failure normally shows up at `fflush` and is caught. Their exposure is lower but not zero.

**Possible solution:**
- In `write_file`, use `assert(temporary.file:write(contents))`.
- In `filesystem_core_mod_sync_file`, raise if `ferror(stream->f)` is set before or after `fflush`, so `sync_file` never reports success for a stream whose writes failed.
- In `filesystem.lua`'s `rename`, use `assert(self.file:close())` before renaming, so a deferred write error cannot be lost either.
- Optionally make `store_tree` stronger: check an existing file (parse it and compare its hash) before trusting it, or rewrite trees that the forest has not recorded as durable, so a corrupt file left by earlier code or by external damage is repaired instead of committed.

**Severity:** High. This entry's own reviewers rated it medium, because a truncated file always fails JSON parsing or the hash check and so never yields a wrong hash or proof. Two independent reproductions (`lua-01` and `rpc-05`, listed below) were each rated high by both of their reviewers. That rating is used here. A realistic operating event, a disk full or quota hit during a store, is reported as success. It leaves committed state permanently unreadable, later stores never repair it, and the validator cannot reload its trees or build bisection proofs until an operator intervenes. It can therefore lose a dispute by timeout. That matches the high level of the scale (stored validator state corrupted in realistic use).

**Risks:**
- *Of the bug:* Nodes that once hit a full disk carry corrupt snapshots that look committed. They then hit query failures at the worst time: after a restart or deep in a bisection. Dispute deadlines can be missed while operators diagnose a JSON parse error in a hash-named file.
- *Of the fix:* Checking the write and close results is low risk. Stores that used to "succeed" on a full disk will now raise, so callers must handle that error, for example by retrying after freeing space. The temporary file is still removed by its `<close>` handler. Validating or rewriting existing files in `store_tree` costs extra reads and hashing per store, and must keep the rule that the frontier file is written only after every tree it reaches is durable.

**Proof of concept:** `bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/ht-07-hashtree-lua-write-file-ignores-write-error/test_write_file_short_write.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 with `OK:` once it is fixed. It needs `bash` and `ulimit -f` (RLIMIT_FSIZE) and uses a `mktemp -d` work directory that it removes afterwards.

**ID**: `ht-07-hashtree-lua-write-file-ignores-write-error`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-01-tempfile-write-error-silently-committed`: run with `eval $(make -s env); lua5.4 bugs/lua-01-tempfile-write-error-silently-committed/test_tempfile_write_error.lua`. It also identified the missing `ferror` check in `fs.sync_file` and showed that a previously good file can be replaced by a truncated one.
- `rpc-05-hash-tree-write-file-ignores-write-error`: run with `eval $(make -s env); lua5.4 bugs/rpc-05-hash-tree-write-file-ignores-write-error/test_forest_store_short_write.lua`.

**Related**: [B05](#b05-cartesifilesystemwrite_file-ignores-close-errors-cli-writes-empty-hash-files).

### B07. Interrupted remove_stored leaves a directory that blocks the name forever

**Title**: `remove_stored` is not idempotent: after an interrupted removal it cannot remove the leftover directory, and that directory blocks `store`/`clone_stored`/`rename_stored` to the same name

**Problem:** `machine::remove_stored` calls `for_each_stored_filename(dir, os::remove_file)`, then `os::remove_directory(dir)`. `for_each_stored_filename` first runs `machine_config::load(dir)`, which needs `config.json`. It then unlinks a fixed list of files: the data, dht and dpt files of every backing store, then the sht and phtc files, and `config.json` last. `os::remove_file` throws on any `unlink` error, including `ENOENT`. If the process dies partway through (SIGKILL, OOM kill, power loss), the next `remove_stored` call fails one of two ways:
- if `config.json` is still there, it throws on the first file that is already gone;
- if `config.json` was already unlinked (the directory is empty or nearly empty), it throws because it cannot read the config.

Either way the directory never gets removed. `clone_stored` and `store` create the target with `mkdir`, so they fail with `EEXIST`. `rename_stored` uses `RENAME_NOREPLACE`, so it fails with "destination exists". No emulator API can recover the name. A `clone_stored` or `store` killed partway through leaves the same kind of partial directory, because its scope cleanup never runs, and `remove_stored` cannot clean that up either.

**Origin:** Pre-existing. `remove_stored` and `for_each_stored_filename` are the same on `origin/main`. The CLI's stored revert mode and the branch's PRT recipe use them.

**Area:** Stored machine API (`cm_remove_stored`, `cm_clone_stored`, `cm_rename_stored`, `cm_store`), Lua bindings, and `cartesi-machine --revert-mode=stored`.

**Category:** Durability / crash recovery (liveness).

**Location:**
- `src/machine.cpp:576-609` (`for_each_stored_filename`: loads `config.json` first and removes it last)
- `src/machine.cpp:611-619` (`machine::remove_stored`)
- `src/os-filesystem.cpp:193-197` (`os::remove_file` throws on `ENOENT`)
- `src/cm.h:603` (documents only that "some files or the directory may remain"; it gives no way to recover)
- Callers that hit it: `src/cartesi-machine.lua:3739` (`revert_stored:commit`), `src/cartesi-machine.lua:3748-3749` (`revert_stored:revert`: `remove_stored` then `rename_stored`)
- Workaround in this branch: `doc/recipes/prt.lua:1119` (`remove_leftover_stored_machine` falls back to listing the directory and unlinking each entry)

**Evidence:** The test stores a real machine through the public Lua API. It simulates two crash points by deleting files with `os.remove`, then calls the real `remove_stored`, `clone_stored` and `rename_stored`:
```
$ eval $(make -s env); lua5.4 bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua
stored files:	27
A: retry remove_stored:	false	unable to remove file '/tmp/tmp.../victim/0000000000000000-8000.bin': No such file or directory
A: directory still exists:	true	files left:	26
BUG: remove_stored cannot finish a partially removed stored machine (aborts on first missing file: ...)
A: clone_stored to same name:	false	unable to create directory '/tmp/tmp.../victim': File exists
A: rename_stored to same name:	false	... unable to rename directory from '/tmp/tmp.../other' to '/tmp/tmp.../victim': destination exists: File exists
BUG: name stays blocked for clone_stored and rename_stored
B: retry remove_stored on empty leftover dir:	false	unable to read file '/tmp/tmp.../victim/config.json': open() failed: No such file or directory	exists:	true
BUG: remove_stored cannot remove the empty directory left after config.json was unlinked (...)
exit=1
```

**Scenario:** A validator node (Rollups Node, Dave, or a custom PRT node) keeps a revert snapshot or scratch stored machine under a fixed name. It discards the snapshot with `cm_remove_stored`, or replaces the machine with `cm_remove_stored` followed by `cm_rename_stored`. The node is killed during the roughly 27 unlinks. After restart, the leftover can never be removed: `cm_remove_stored` fails with `ENOENT`, and `cm_clone_stored`/`cm_rename_stored`/`cm_store` to that name fail with `EEXIST`. The node stays stuck until custom code or an operator deletes the directory by hand. An honest PRT player stuck this way can miss tournament deadlines. The `cartesi-machine` CLI with `--revert-mode=stored` gets stuck the same way: a stale `<dir>.revert` makes the next snapshot's `clone_stored` fail, and an interrupted revert leaves `<dir>` unremovable. Hashes and proofs are never affected.

**Possible solution:** Make removal idempotent and crash-safe:
- Ignore `ENOENT` in the remover used by `remove_stored`.
- If `config.json` is missing, don't fail. Fall back to removing the known file patterns, or every regular file in the directory, and then the directory itself.
- Better still, first rename the directory atomically to a unique tombstone name, such as `<dir>.removing.<pid>`, and sync the parent directory. Then delete the tombstone's contents. The original name is then free right after one atomic step, and leftovers are easy to find and remove.

**Severity:** Medium. Both reviewers rated it medium, at the low end. Crashes are expected over a long-running validator's life, and this one can leave a node or CLI stuck with no API path to recover. On the other hand, it never produces wrong or nondeterministic hashes or proofs, recovery outside the API is trivial (`rm -rf`), and `cm.h` already warns that files may remain after a failure.

**Risks:**
- Of the bug: lost liveness after a crash. Unattended validators stay down until someone cleans up by hand, which can mean missed dispute deadlines. Integrators may write ad-hoc recursive deletes, which can remove the wrong directory if a path is wrong.
- Of the fix: a fallback that deletes every entry when `config.json` is missing must not run on a directory that is not a stored machine, for example a user path passed by mistake. Limit it to known file-name patterns, or to the tombstone created by the API itself. Ignoring `ENOENT` must not hide real errors such as `EACCES` or `EIO`. The tombstone approach adds a rename and a sync and needs a unique-name scheme.

**Proof of concept:** `bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua`. It works in a fresh `mktemp -d` directory, or in `$WORKDIR` if that is set. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/ht-09-remove-stored-not-idempotent/test_remove_stored_idempotent.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: remove_stored is idempotent` once fixed.

**ID**: `ht-09-remove-stored-not-idempotent`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `api-13-remove-stored-fails-on-incomplete-dir`: run with `eval $(make -s env); lua5.4 bugs/api-13-remove-stored-fails-on-incomplete-dir/test_remove_stored_incomplete_dir.lua`.

### B08. clone_stored fails with EMLINK instead of falling back to a copy

**Title**: `clone_stored` fails with EMLINK ("Too many links") instead of copying once about 65000 stored clones share one hard-linked read-only file

**Problem:** `os::clone_file` handles a source with no write bits by hard-linking it with a plain `link()`. It falls back to `copy_file` only when the error is `ENOTSUP`, `EXDEV` or `EPERM`, and rethrows every other errno. `machine::store` always writes the PMAs backing file (`0000000000010000-1000.bin`) read-only, and it does the same for read-only flash drives and NVRAM. As a result, `machine::clone_stored` (`cm_clone_stored`) hard-links that file on every clone, and the template, its clones and their clones all share one inode. ext4 allows at most 65000 links per inode. At that point `link()` returns `EMLINK`, the error is rethrown as `std::system_error("Too many links")`, and `clone_stored` fails. A plain copy would have worked. The failure then hits every clone from the template or from any of its descendants, not just one source, for as long as that many links exist. The Lua `cartesi.filesystem.clone_file` binding calls the same function and fails the same way.

**Origin:** Pre-existing. `origin/main` (v0.22.0) has the same `clone_file` with the same fallback list. This branch makes the defect easier to reach by exposing `clone_file` in the new `cartesi.filesystem` Lua module.

**Area:** Stored machine API (`cm_clone_stored` / `machine:clone_stored`), `os::clone_file`, and the Lua `cartesi.filesystem.clone_file`.

**Category:** Availability / unhandled recoverable error. Hashes are not affected.

**Location:**
- `src/os-filesystem.cpp:598-614`: `os::clone_file` uses `hardlink_file` for read-only sources, and its fallback list does not include `EMLINK`.
- `src/machine.cpp:454-460`: `store` marks the PMAs backing store, plus read-only flash drives and NVRAM, read-only.
- `src/machine.cpp:493-541`: `clone_stored` runs every backing file through `os::clone_file`.
- `src/clua-cartesi-filesystem.cpp:70`: `filesystem.clone_file`.

**Evidence:** The test stores a machine with 4 KiB of RAM and confirms that a clone shares the PMAs file's inode with the template. It then adds hard links to that inode with `os.link` until the ext4 limit is reached, which stands in for about 65000 live stored descendants. Finally it calls `clone_stored` from both the template and a descendant. Run on ext4 (`/dev/vda`), in about 1.5 s:
```
$ eval $(make -s env); lua5.4 bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua
read-only files in stored dir: 0000000000010000-1000.bin
inode template=936448 clone=936448 (shared=true)
hit EMLINK after 64998 extra links; st_nlink= 65000
clone_stored(c1) failed: unable to create hard link from '.../c1/0000000000010000-1000.bin' to '.../c-from-c1/0000000000010000-1000.bin': Too many links
clone_stored(template) failed: unable to create hard link from '.../template/0000000000010000-1000.bin' to '.../c-from-template/0000000000010000-1000.bin': Too many links
BUG: clone_stored fails with EMLINK once the shared read-only inode reaches the filesystem link limit; no fallback to copy
```
The exit status is 1. Once fixed, the test exits 0 and also checks that each clone's root hash matches the template's.

**Scenario:** A validator (a Rollups Node, Dave, or a PRT node such as `doc/recipes/prt.lua`, which calls `clone_stored` from templates and snapshot caches) keeps stored snapshots, for example one per input or checkpoint, all cloned from one stored template or from each other. The shared inode spreads only through `clone_stored` chains: a machine that is loaded, run and then stored gets fresh files. If the node does not prune, the live directories from one lineage reach about 65000. From then on every `clone_stored` from that lineage throws, so the node can no longer snapshot, fork or revert, and it can stall during a dispute until an operator deletes old clones. Filesystems with lower per-inode link limits hit this sooner. XFS and btrfs allow far more links.

**Possible solution:** In `os::clone_file`, also fall back to `copy_file` on `EMLINK`, and arguably on `EACCES` and `EOPNOTSUPP` (the same value as `ENOTSUP` on Linux, but not on every platform). Check that the copied file keeps the source's read-only mode, so that later clones of it are still hard-linked.

**Severity:** Low. Both reviewers agreed. It is an availability failure that needs about 65000 unpruned live clones of one stored lineage on ext4. It produces no wrong hashes or proofs and no corrupted state. The error is clean and catchable, `scope_remove` cleans up the partial target, and deleting old clones lowers the link count again.

**Risks:** Bug: when the limit is reached, a long-running validator that depends on `clone_stored` loses the ability to snapshot or revert, which could delay its dispute moves. Fix: very low risk. Falling back to a copy only costs disk space and time for the affected file (the PMAs file is 4 KiB). If `EACCES` is added, the fallback must not hide real permission errors on the destination directory. `copy_file` would surface those itself.

**Proof of concept:** `bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua`. It needs `python3`, and the `bugs/` directory must be on ext4 or another filesystem with a per-inode link limit. Its temporary files go in a subdirectory next to the test and are removed afterwards. Run from the repo root:
`eval $(make -s env); lua5.4 bugs/ht-10-clone-stored-emlink-no-fallback/test_clone_stored_emlink.lua`

**ID**: `ht-10-clone-stored-emlink-no-fallback`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-08-clone-file-emlink-no-fallback`: run with `eval $(make -s env); lua5.4 bugs/lua-08-clone-file-emlink-no-fallback/test.lua`. It reaches the same failure through `cartesi.filesystem.clone_file`.

### B09. JSON-RPC server exits when an error message contains invalid UTF-8

**Title**: JSON-RPC server process exits when a response error message contains invalid UTF-8 (2-byte POST body, or `load()` of a non-UTF-8 `config.json`)

**Problem:** `jsonrpc_http_reply` serializes every response with `j.dump()`. That uses nlohmann's default `strict` error handler, which throws `type_error.316` when any string in the response holds a byte that is not valid UTF-8. Error messages are copied into responses verbatim, so they can carry such bytes:
- (a) For a malformed request body, `handle_request` passes the nlohmann `parse_error.101` text to `jsonrpc_response_parse_error`. That text echoes the raw bytes it last read ("last read: '...<0xFF>'").
- (b) For an exception raised by machine code, `jsonrpc_response_from_exception` copies the exception message, which can embed file contents. One example is the parse error `machine::load` raises for a `config.json` that contains non-UTF-8 bytes.

Nothing catches the `type_error` thrown by `dump()`. Neither `handle_request` nor `http_session::on_read_request` has a try/catch, and the Asio handler does not either. The exception leaves `ioc.run()`, `main()` logs `fatal ... caught exception` and returns 1, and the whole server process exits along with the machine it holds. Forked snapshot/backup children run the same code and die the same way. A local (in-process) machine given the same input just returns a normal error.

**Origin:** Pre-existing. `j.dump()` in `jsonrpc_http_reply` and `jsonrpc_response_parse_error(x.what())` are unchanged on `main`. This branch did not introduce them, but they sit in the remote-machine server that PRT validator nodes use.

**Area:** JSON-RPC remote machine server (`cartesi-jsonrpc-machine`, `src/jsonrpc-remote-machine.cpp`) and its Lua/C clients (`cartesi.jsonrpc`, `cm_jsonrpc_*`).

**Category:** Crash (an untrapped exception kills the server process).

**Location:**
- `src/jsonrpc-remote-machine.cpp:1791`: `std::string body = j.dump();` in `jsonrpc_http_reply`, which uses the strict UTF-8 handler.
- `src/jsonrpc-remote-machine.cpp:1946-1950`: the parse-error path, `jsonrpc_response_parse_error(x.what())`.
- `src/jsonrpc-remote-machine.cpp:499-505` and `1896-1897`: `jsonrpc_response_from_exception` copies machine exception text into the response.
- `src/jsonrpc-remote-machine.cpp:217-246`: `http_session::on_read_request` calls `handle_request` and `send_response` with no try/catch.
- `src/jsonrpc-remote-machine.cpp:2188` and `2192-2194`: the exception escapes `ioc.run()` into `main`'s catch, which returns 1.

**Evidence:** The test spawns servers with `jsonrpc.spawn_server()`.
- Scenario 1 sends a raw HTTP POST whose body is the 2 bytes `\xff\xfe`.
- Scenario 2 calls `m:load(dir)`, where `dir/config.json` is `{"a":\xff}`. For comparison, it first loads the same directory into a local machine.

After each scenario the test checks whether the server is still alive. Both scenarios kill the server; the local load just raises a Lua error:
```
scenario 1 response: "" err=closed
... fatal cartesi-jsonrpc-machine pid:3893 ... caught exception: [json.exception.type_error.316] invalid UTF-8 byte at index 130: 0xFF
BUG: scenario 1: server at 127.0.0.1:36537 died after POST body \xff\xfe: jsonrpc error: post error contacting 127.0.0.1:36537 (Connection refused ...)
local load: ok=false err="...[json.exception.parse_error.101] parse error at line 1, column 6: syntax error while parsing value - invalid literal; last read: '\"a\":<0xFF>'"
... fatal cartesi-jsonrpc-machine pid:3897 ... caught exception: [json.exception.type_error.316] invalid UTF-8 byte at index 134: 0xFF
remote load: ok=false err="...jsonrpc error: post error contacting 127.0.0.1:37023 (end of stream ...)"
BUG: scenario 2: server at 127.0.0.1:37023 died after load() of corrupted config.json: ... (Connection refused ...)
exit=1
```
Run command: `eval $(make -s env); timeout 60 lua5.4 bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`

**Scenario:**
- A validator (Rollups Node, Dave, or the PRT Lua node) runs its working or backup machine in a remote `cartesi-jsonrpc-machine` and calls `load()` on a stored snapshot whose `config.json` was corrupted on disk (bit flip, partial write) into non-UTF-8 bytes. The same can happen with any error message that embeds non-UTF-8 bytes, such as a file path.
  - Locally this is a recoverable error. Remotely the server process dies: the client sees "end of stream", then "Connection refused".
  - The load fails either way, and `load` only runs on an empty machine, so no machine state is lost. But any retry or fallback over the same connection (for example, loading an older snapshot) now fails. That defeats the node's error handling and can stall it until a supervisor respawns the server.
- Anything that can reach the port can kill the server with `curl -X POST --data-binary $'\xff\xfe' http://HOST:PORT/`. The server is unauthenticated and binds to 127.0.0.1 by default, and such a party can already call `shutdown`. This trigger therefore adds no new attack capability; it only shows that malformed input becomes a crash instead of an error.
- Hashes, proofs and step logs are not affected.

**Possible solution:**
- In `jsonrpc_http_reply`, serialize with `j.dump(-1, ' ', false, json::error_handler_t::replace)`. Alternatively, sanitize error messages to valid UTF-8 (or escape non-ASCII bytes) when building error responses in `jsonrpc_response_parse_error` and `jsonrpc_response_machine_error`.
- As defense in depth, wrap `handle_request` and `send_response` in `on_read_request` in a try/catch that returns a 500 or JSON-RPC internal error and keeps the server running.

**Severity:** Medium. The server crashes and exits, where it should return a recoverable error. Both reviewers rated it medium rather than the suspected high, for three reasons:
- The legitimate trigger, a corrupted snapshot `config.json` or a non-UTF-8 string in an error message, is uncommon.
- The network trigger gives no capability beyond the existing unauthenticated `shutdown` method.
- Hashes, proofs and dispute outcomes are not affected directly.

**Risks:**
- Of the bug: a remote working or backup machine disappears on a recoverable error, which breaks retry or fallback logic in validator nodes. A malformed request from a buggy client or a stray local process takes down the server and the machine it holds.
- Of the fix: with `replace`, error messages a client receives will contain U+FFFD in place of the raw bytes, so clients matching on exact error text may see different strings. A catch-all in `on_read_request` must not hide failures that leave the server in an inconsistent state, such as exceptions thrown around `fork` or snapshot handling; it should log them and reply with an error, not swallow them silently.

**Proof of concept:** `bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`. It needs LuaSocket (`socket`) for the raw POST, and creates its temporary directory with `os.tmpname()`. Run it from the repo root with `eval $(make -s env); timeout 60 lua5.4 bugs/rpc-01-jsonrpc-server-crash-invalid-utf8-error-message/test_jsonrpc_invalid_utf8_crash.lua`. While the bug is present it prints `BUG:` lines and exits 1. Once fixed it prints `OK: server survived both scenarios` and exits 0.

**ID**: `rpc-01-jsonrpc-server-crash-invalid-utf8-error-message`

### B10. Spawned JSON-RPC servers inherit client sockets, so concurrent spawns fail

**Title**: `cm_jsonrpc_spawn_server` leaks client sockets into spawned servers: concurrent spawns on fixed addresses fail with EADDRINUSE, and closed connections stay in CLOSE_WAIT

**Problem.** The spawn constructor binds a listening acceptor on the requested address and calls `posix_spawnp(&child_pid, bin, nullptr, nullptr, args, environ)`. It passes no `posix_spawn_file_actions`. Boost.Asio opens sockets without `SOCK_CLOEXEC` (only its epoll fd and timerfd get CLOEXEC), and nothing in `src/` sets `FD_CLOEXEC` on sockets or calls `close_range`/`closefrom`. So every socket open in the client process at spawn time is inherited by `cartesi-jsonrpc-machine`. That includes keep-alive connections to other remote machines and, in a multi-threaded host, acceptors other threads have just bound for their own spawns. The server never closes fds it does not know about. Its `fork` handler keeps them in the grandchild, and the grandchild is the long-lived server whose pid is returned. This has two effects:
1. **Concurrent spawns fail.** Thread A's acceptor stays LISTENing inside thread B's server tree. A's later `rebind` to that address (or A's next acceptor bind) then fails with `bind: Address already in use`. It keeps failing for as long as B's servers live.
2. **Closed connections leak.** When the client closes a connection (`shutdown_and_close_socket`: receive shutdown plus linger-0 close), the close only drops one reference while another server holds a copy. No RST or FIN is sent, so the remote session never sees EOF. The socket stays in CLOSE_WAIT for the whole lifetime of the inheriting server and its fork descendants.

**Origin.** Pre-existing.

**Area.** JSON-RPC client library (`libcartesi_jsonrpc`, `cm_jsonrpc_spawn_server`) and the `cartesi-jsonrpc-machine` server.

**Category.** Resource leak / file-descriptor inheritance, causing spawn failures (denial of service).

**Location.**
- `src/jsonrpc-machine.cpp:473-494`: the acceptor is bound, then `posix_spawnp` runs with no file actions.
- `src/jsonrpc-machine.cpp:180-198`: `json_post` keep-alive sockets, opened with `async_connect` and no CLOEXEC.
- `src/jsonrpc-machine.cpp:549-551`: the parent closes the acceptor only after the spawn, which leaves a window in which other threads' spawns inherit it.
- `src/jsonrpc-machine.cpp:581-584` and `src/jsonrpc-remote-machine.cpp:894-907`: `rebind` to the requested address, where the EADDRINUSE shows up.
- `src/jsonrpc-remote-machine.cpp:830-886`: the `fork` handler, which carries the inherited fds into the grandchild.
- `src/jsonrpc-remote-machine.cpp:2121-2166`: `--server-fd` handling, which never closes other inherited fds.

**Evidence.** The PoC uses only the public C API.
- **Part A, single thread.** It spawns m1, makes one request (which opens a keep-alive socket), then spawns m2. It then inspects `/proc/<pid2>/fd` and `/proc/net/tcp`.
- **Part B, concurrency.** 4 threads x 8 rounds. Each thread spawns on its own fixed port, outside the ephemeral range. A sequential control run uses one fixed port.

Re-run output (`eval $(make -s env); sh bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/run.sh`):
```
[A] client sockets before spawning m2: 1, of which held by server2 (pid 4645): 1
    leaked socket:[143122]  tcp: 01 local=0100007F:DC26 remote=0100007F:81B1
    after cm_delete(m1): server2 still holds socket:[143122]  tcp: 08 local=0100007F:DC26 remote=0100007F:81B1
BUG: spawned server2 inherited 1 client socket(s) (keep-alive connection to server1); 1 still held after server1 was deleted
    [B] thread 0 round 0 spawn on 127.0.0.1:23461 failed: bind: Address already in use [system:98
        LISTEN holders of port 23461 now: pid=4652(cartesi-jsonrpc) pid=4653(cartesi-jsonrpc) pid=4655(cartesi-jsonrpc)
[B] concurrent spawns: 23/32 failed (23 with 'Address already in use')
[B] sequential control on one fixed port: 0/32 failed
```
State 08 is CLOSE_WAIT. The prover and two independent reviewers saw between 12/32 and 24/32 concurrent failures across runs. The sequential control always failed 0/32. When a spawn fails, the LISTEN socket for the failing port is held by other threads' `cartesi-jsonrpc-machine` processes.

**Scenario.** A validator node (Cartesi Rollups Node, Dave, or another PRT node written in Go or Rust) hosts several applications or tournaments. It calls `cm_jsonrpc_spawn_server` from several threads, each with its own machine object. With cgo this is the normal case, because cgo calls run on separate OS threads. If each machine is configured on a fixed address, a large share of spawns fail with EADDRINUSE. Retries on the same address keep failing while the servers holding the inherited acceptor are alive, so the node can fail to start or restart machines, for example when it needs a fresh machine to compute a commitment or a step proof during a dispute deadline. Even single-threaded, a long-running node that spawns many servers piles up stale fds and CLOSE_WAIT sockets in them. Remote sessions also never see the client's EOF, so the server holds those connections open. CLI users and Lua scripts that spawn several servers are affected the same way, though less severely.

**Possible solution.**
- In the client, pass `posix_spawn_file_actions` that keep only the acceptor fd. Alternatively, have `cartesi-jsonrpc-machine` close every inherited fd except `--server-fd` and stdio on startup (`close_range(3, ~0U, 0)` around the server fd, or iterate `/proc/self/fd`).
- Also open all client sockets and acceptors with CLOEXEC, for example by setting `FD_CLOEXEC` right after open, and clear it only on the acceptor passed to the child (with `posix_spawn_file_actions_adddup2`, or by clearing the flag just before the spawn). This narrows the window but does not remove it unless spawns are serialized, so the server-side close is the robust fix.
- Optionally serialize the acceptor-bind-to-spawn section with a process-wide mutex as defence in depth.

**Severity.** Medium. Both reviewers agree. It causes a denial of service for nodes that spawn concurrently on fixed addresses, plus a bounded fd and socket leak in long-running nodes. It cannot produce wrong or nondeterministic hashes or proofs, and the common `127.0.0.1:0` (ephemeral port) configuration avoids the bind failure.

**Risks.**
- Of the bug: a validator can fail to start or restart machines at a critical moment, such as a dispute deadline. A failure that looks transient tends to persist, because the leaked listeners live as long as unrelated servers. Stale CLOSE_WAIT sockets and missed EOFs slowly use up fds and kernel memory, and they keep remote sessions open.
- Of the fix: closing fds in the server must keep `--server-fd` and stdio, or spawning breaks. Setting CLOEXEC on asio sockets needs care so the acceptor is still inherited. Embedders that deliberately pass extra fds to spawned servers through `CARTESI_JSONRPC_MACHINE` wrappers (unlikely) would lose them.

**Proof of concept.** Files are in `bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/`:
- `test_spawn_fd_leak.cpp`: the C++ test.
- `run.sh`: compiles the test against `src/` into a temp dir and runs it.

Run from the repo root (Linux, needs `/proc`):
```
eval $(make -s env); sh bugs/rpc-02-jsonrpc-client-fds-leak-into-spawned-servers/run.sh > rpc-02.log 2>&1; cat rpc-02.log
```
Redirect the output to a file as shown: while the bug is present, leftover spawned servers inherit the shell's stdout, so piping the output (for example into `grep`) never reaches end of file. Exit status 1 and `BUG:` lines mean the bug reproduced. Exit status 0 means it is fixed.

**ID**: `rpc-02-jsonrpc-client-fds-leak-into-spawned-servers`

### B11. JSON-RPC request with an invalid id is rejected but still executed

**Title**: JSON-RPC server rejects a request with an invalid `id` but still executes it, and answers it twice in a batch

**Problem**: `handle_request` in the JSON-RPC remote-machine server checks each request and replies `-32600 invalid request` if the request is malformed. For the `jsonrpc` and `method` fields, the code pushes the error and then `continue`s. For an `id` that is not a string, number or null (for example `true`, `{}` or `[]`), it pushes the error but has no `continue`. Control falls through to `jsonrpc_dispatch_method`, so the method runs and changes machine state. Then, because `ji.contains("id")` is true, the method's result is pushed as a second response. A single request returns only `jr[0]`, which is the error, so the client is told the call was rejected when it actually ran. A batch returns both responses for one request. JSON-RPC 2.0 forbids both behaviours: an invalid request must not be executed, and each request gets exactly one response.

**Origin**: pre-existing. `origin/main` has the same code, and the branch's changes to this file do not touch this check.

**Area**: jsonrpc-remote-machine server (`cartesi-jsonrpc-machine`), request validation.

**Category**: api-contract.

**Location**:
- `src/jsonrpc-remote-machine.cpp:1984-1991`: the invalid-`id` check pushes the error with no `continue`.
- `src/jsonrpc-remote-machine.cpp:1997`: `jsonrpc_dispatch_method(ji, session)` still runs.
- `src/jsonrpc-remote-machine.cpp:2003-2005`: the result is pushed as a second response.
- `src/jsonrpc-remote-machine.cpp:2012`: a single (non-array) request returns only `jr[0]`, the error.

**Evidence**: The test spawns a real `cartesi-jsonrpc-machine` server using the Lua `cartesi.jsonrpc` client and creates a 1 MiB machine. It then sends raw HTTP POSTs with curl. Run with `eval $(make -s env); lua5.4 bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`:
```
single response: {"error":{"code":-32600,"message":"invalid field \"id\" (expected string, number, or null)"},"id":true,"jsonrpc":"2.0"}
x1 after rejected request: 77
BUG: request rejected as invalid (bad id) but write_reg was executed anyway (x1=77)
batch response: [{"error":{"code":-32600,...},"id":{},"jsonrpc":"2.0"},{"id":{},"jsonrpc":"2.0","result":true}]
responses in batch for 1 request: 2, x2=55
BUG: batch with one invalid-id request produced 2 responses
BUG: batch request with invalid id executed (x2=55)
exit=1
```

**Scenario**: A third-party or hand-written client talks to `cartesi-jsonrpc-machine` directly over HTTP, for example a validator written in another language or a debugging script. It sends a request whose `id` is not a scalar, such as `{"method":"machine.write_reg","id":true,"params":["x1",77]}`. It receives "invalid field id", treats the call as having no effect, and may retry or carry on. Meanwhile `write_reg`, `run`, `write_memory`, `send_cmio_response` or `store` has already run, so the client's view of the machine no longer matches the real state. A batch-aware client that pairs responses with requests is also confused by the extra response. The official `libcartesi_jsonrpc` C/C++ client, which the Lua bindings, the `cartesi-machine` CLI, Rollups Node, Dave and the PRT node all use, always sends numeric ids. Honest validators using the shipped clients cannot trigger this, and hashes and proofs are not affected.

**Possible solution**: Add `continue;` after `jr.push_back(jsonrpc_response_invalid_request(ji, "invalid field \"id\" ..."))` at line 1990. The invalid-`id` check then behaves like the `jsonrpc` and `method` checks: one error response, and no dispatch.

**Severity**: low. Both reviewers agreed with the prover. Only clients that send a malformed, non-scalar `id` can reach this, and the official C/Lua clients never do. There is no crash, hang, memory corruption, or wrong hash or proof. The harm is that the server tells non-conforming clients a request was rejected when it actually ran.

**Risks**: The bug itself can make a non-conforming client misjudge machine state after a state-changing call it believes was rejected, and can break response pairing in batches. The fix is a one-line change with minimal risk. Any client that currently sends non-scalar ids and depends, by accident, on the method running will now see the request genuinely rejected, which is the behaviour JSON-RPC 2.0 requires.

**Proof of concept**: `bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/rpc-03-jsonrpc-invalid-id-still-executes/test.lua`. It needs `curl` and `cartesi-jsonrpc-machine` in `PATH`. It exits with 1 and prints `BUG:` lines while the bug is present, and exits with 0 once the bug is fixed.

**ID**: `rpc-03-jsonrpc-invalid-id-still-executes`

### B12. frontier_forest_store drops expansions under single-value fixed-point trees

**Title**: `frontier_forest_store` and `store_expansion` silently drop expansions placed under single-value fixed-point trees, so a reloaded forest is opaque where it answered before

**Problem:** In `store_tree`, any `fixed_point` tree with `base_height == height` returns at once, before `store_children` is called. The code assumes such a single-value wrapper only holds a raw hash. That assumption is wrong:
- `forest_flush` creates these wrappers whenever it flushes a raw value alone. This happens on a height change, a pad or value change, or an aligned single-entry chunk, such as the odd value in a 4 + 1 flush.
- `frontier_forest_expand_leaf` walks into fixed-point trees, including these wrappers. When it reaches the opaque value, it sets `values[index] = replacement`.

Suppose the forest had no directory when the expansion ran, so `store_expansion` was skipped. The next `frontier_forest_store` never reaches the replacement. The parent's file records only the raw hash (`get_value_hash`), and no file is written for the replacement. After `frontier_forest_load`, `load_tree(hash)` finds nothing, and the subtree is opaque again.

`store_expansion` has the same blind spot. It calls `store_children` and `store_tree` on the replacement root, so an expanded single-value wrapper nested inside a replacement forest is skipped too.

The in-memory forest keeps answering correctly, so the persisted state silently differs from memory. This breaks the documented contract that a stored forest "keeps its trees" and that "an expansion also stores its new trees there".

**Origin:** Introduced by this branch. `src/cartesi/hash-tree.lua` does not exist on `main`.

**Area:** Lua library `cartesi.hash-tree`, frontier forest persistence (`frontier_forest_store`, `frontier_forest_load`, `frontier_forest_expand_leaf`).

**Category:** Correctness / persistence (silent data loss).

**Location:**
- `src/cartesi/hash-tree.lua:578` (`store_tree` early return for `fixed_point` with `base_height == height`)
- `src/cartesi/hash-tree.lua:720-755` (`forest_flush` wraps a lone raw value in a single-value fixed-point tree)
- `src/cartesi/hash-tree.lua:886-896` (`frontier_forest_expand_leaf` replaces `values[index]` inside such a wrapper, and calls `store_expansion` only when `forest.directory` is set)
- `src/cartesi/hash-tree.lua:606-613` (`store_expansion`, which inherits the blind spot for nested expansions)
- Real caller: `doc/recipes/prt.lua:1748` (`open_bundle` calls `frontier_forest_expand_leaf` on claim trees), `doc/recipes/prt.lua:2535` and `2804` (`frontier_forest_store`/`frontier_forest_load` of claim trees)

**Evidence:** The test uses only the public `cartesi.hash-tree` API: `push_back`, `pad_back`, `append`, `expand_leaf`, `store`, `load`, `get_node_hash` and `get_siblings`.
- Control: a 2-value tree survives store and load, which shows the test setup is valid.
- Case A: a bundle root flushed alone is expanded in memory, then stored and loaded.
- Case B: the expansion is nested inside a replacement forest and goes through `store_expansion`.
- Case C: a claim-tree-like layout (per-input bundles plus pad bundles, flushed as 4 + 1) has its lone pad bundle opened, then stored and loaded.

Cases A, B and C all lose the expansion:
```
$ eval $(make -s env); lua5.4 bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua
control (2-value tree) after reload ok:	true
  reload error: the node is below an opaque hash
BUG: A: expand_leaf then store (no directory at expand time): node answerable before store is opaque after frontier_forest_load
  get_siblings after reload: the node is below an opaque hash
BUG: A: get_siblings after reload: node answerable before store is opaque after frontier_forest_load
BUG: B: nested expansion inside replacement (store_expansion): node answerable before store is opaque after frontier_forest_load
BUG: C: claim-like layout, pad bundle opened then stored: node answerable before store is opaque after frontier_forest_load
BUG: 4 check(s) failed: store_tree drops expansions under single-value fixed-point trees
exit=1
```
With the fix below applied to a copy of `hash-tree.lua`, all cases pass and the test prints `OK: expansions survive store/load` (exit 0).

**Scenario:** A validator node keeps claim trees as frontier forests. During a dispute it opens a bundle with `frontier_forest_expand_leaf`, as the PRT recipe's `open_bundle` does, and snapshots the tree with `frontier_forest_store`. If that bundle's root was flushed alone (for example, the odd pad bundle after a per-input block), the expansion is not persisted. After a restart, `frontier_forest_load` returns a tree where the bundle is opaque again. `get_node_hash` and `get_siblings` return `nil, "the node is below an opaque hash"` for nodes that answered before the restart. The node must re-run the machine to re-collect the bundle. If the machine snapshot is gone, or there is not enough time before a tournament deadline, it cannot produce the proof. Whether a given claim hits this depends on its layout: aligned per-input blocks often avoid lone wrappers. Hashes, roots and proofs are never wrong.

**Possible solution:** In `store_tree`, recurse into a single-value wrapper but write no file for it, because the parent already records the raw hash and `load_tree(hash)` then finds the expansion's own file:
```lua
if forest.durable[tree] then return end
if tree.kind == "fixed_point" and tree.base_height == tree.height then
    store_children(forest, tree, written)
    return
end
```
This also fixes `store_expansion`, since it goes through `store_tree`/`store_children`. Verified with the PoC.

**Severity:** Medium. Both reviewers rated it medium. The bug silently loses persisted proof data, contrary to the documented store/load contract, and the PRT recipe's claim-tree usage can reach it. It never yields wrong hashes or proofs, and it never crashes or hangs. Callers get a recoverable `nil` result and can recompute by re-running the machine, so an honest player loses a dispute only when that recomputation is impossible or too slow.

**Risks:**
- Of the bug: after a restart, a validator that relies on stored forests to answer proofs without the machine cannot produce siblings or node hashes. This costs availability and time during disputes. Re-expanding after a reload works, because the parent holds a raw hash.
- Of the fix: low. Single-value wrappers still write no file and are not added to `written`, so the stored format does not change. Wrappers are never marked durable, so every store walks into them again. The walk is cheap, because durable children return at once. Existing stores that already lost expansions are not repaired; callers must expand again.

**Proof of concept:** `bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua`. It works under `$WORKDIR` (or `$TMPDIR`, or `/tmp`, or a directory given as the first argument) and removes its files at the end. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-02-store-skips-expanded-single-value-tree/test_store_single_value_expansion.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: expansions survive store/load` once fixed.

**ID**: `lua-02-store-skips-expanded-single-value-tree`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `rpc-06-forest-store-drops-expansion-in-raw-fixed-point`: run with `eval $(make -s env); lua5.4 bugs/rpc-06-forest-store-drops-expansion-in-raw-fixed-point/test_store_drops_expansion.lua`.

### B13. Lazily loaded forest used as a value loses its unloaded subtrees

**Title**: A lazily loaded forest used as a value (push_back/pad_back/expand_leaf) loses its unloaded subtrees in the destination, and storing the destination leaves dangling tree files

**Problem:** `frontier_forest_load` returns trees whose fixed-point values stay raw hashes until a query reaches them. Those hashes resolve only through `load_tree(forest, hash, height)`, and `load_tree` looks only in `forest.directory` of the forest passed to it. Suppose that loaded forest is passed as a value to `frontier_forest_push_back`/`frontier_forest_pad_back`, or as the subtree of `frontier_forest_expand_leaf`. `normalize_forest_value` hands the destination the source's root tree, and the source directory is lost. The destination's later queries call `load_tree` with the destination forest, which has no directory or a different one. So `get_node_hash`/`get_siblings` return `nil, "the node is below an opaque hash"` for positions the source forest answers. Storing the destination into its own directory makes it worse. `store_tree` writes the file of the inner root, but `store_children` only recurses into values that are already trees, so the files behind the raw-hash values are never copied. The new directory ends up holding a tree file whose child files exist only in the source directory, and those leaves stay unreachable after a reload. No error is raised at any point.

**Origin:** introduced by this branch. Durable store and lazy load arrived with commit fcf6819 ("feat: store frontier forests durably in hash-tree"); `main` has no `load_tree` or `frontier_forest_load`.

**Area:** Lua library `cartesi.hash-tree` (frontier forests: durable store/load and composition of forests as values).

**Category:** correctness (data availability / persistence integrity).

**Location:**
- `src/cartesi/hash-tree.lua:525-527`: `load_tree` resolves only against `forest.directory` of the querying forest
- `src/cartesi/hash-tree.lua:690-701`: `normalize_forest_value` returns `value[value.height + 1]` and drops the source forest's directory
- `src/cartesi/hash-tree.lua:642-649`: `descend_tree` calls `load_tree` on the destination forest and returns "opaque"
- `src/cartesi/hash-tree.lua:866-904`: `frontier_forest_expand_leaf` takes the same path (`load_tree` at line 890)
- `src/cartesi/hash-tree.lua:563-572`: `store_children` skips raw-hash values, so files from a foreign directory are never copied
- `src/cartesi/hash-tree.lua:577-596`: `store_tree` writes a parent file that references the missing files

**Evidence:** The test builds `inner` (height 3), which is a height-1 forest `{a, b}` padded 4 times. It stores `inner` in directory A and loads it back, then uses the loaded forest as a value. The controls pass: the loaded forest queried directly, and the same composition done with an in-memory `inner`. All four compositions of the loaded forest fail. Root hashes stay correct.
```
$ eval $(make -s env); lua5.4 bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua
ok:   loaded inner answers leaf 1 itself
ok:   outer with in-memory inner, leaf 1
BUG: pad_back(loaded inner) into in-memory outer: leaf 1: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
ok:   root hash still matches
BUG: outer stored in B and reloaded: leaf 9: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
BUG: push_back(loaded inner) into outer with directory C: leaf 3: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
ok:   leaf 0 opaque before expansion
BUG: expand_leaf(loaded inner): leaf 1: expected 0xb5553d...5510, got nil (the node is below an opaque hash)
4 failure(s)
```
After the store, directory B holds the inner root's file `0x0c96...json`, a fixed-point tree whose value is `0x805b...`. It does not hold `0x805b...json`, which exists only in A.

**Scenario:** A validator built on the shipped Lua library persists bundle or claim forests and, after a restart, reloads them with `frontier_forest_load`. It then composes one into another forest: it pads it into an in-memory or differently stored outer forest, or passes it to `frontier_forest_expand_leaf` to reveal a leaf. Commitments still match, so nothing looks wrong. But when a dispute step needs siblings or a node hash at those positions, `get_siblings`/`get_node_hash` return nil/opaque. The validator then cannot produce the proof and can miss the dispute deadline. Its persisted state also carries dangling references, so restarting does not fix it. The experimental node in `doc/recipes/prt.lua` does not hit this today: it keeps all forests in one shared directory and composes only raw hashes or freshly built in-memory forests.

**Possible solution:** Pick one:
- Bind each lazily loaded tree to the directory it came from, for example by storing the source directory, or a loader closure, on the tree or on its raw-value container. `load_tree` and `descend_tree` would then resolve against that directory rather than the destination's.
- Have `normalize_forest_value` (and `expand_leaf`) reject, or fully materialize, a forest value whose `directory` differs from the destination's.

In either case, `store_tree`/`store_children` should copy (or hard-link) the files behind raw values that are reachable from a foreign directory. Failing that, they should refuse the store instead of writing files that reference missing children.

**Severity:** medium. Hashes and proofs are never wrong (root hashes are preserved). The failure is clean and avoidable, because it occurs only when a reloaded forest is composed into a forest with no directory or a different one. The reference node does not do this. Both reviewers rated it medium. A validator relying on this pattern could still fail to produce dispute proofs and persist incomplete state with no error, so it is more than low.

**Risks:** The bug's risk is lost availability of proof data. A validator cannot answer a step for positions it believes it holds, and a store reports success while leaving dangling references, so the problem shows up only later, during a dispute. On the fix side:
- Tying trees to their source directory keeps a reference to that directory alive and makes lifetime and removal (`remove_stored`) harder to reason about.
- Materializing a forest eagerly can be expensive for large forests.
- Copying files across directories changes store cost and needs the same crash-safe ordering (children first, then sync) that the current store uses.
- Rejecting such values is the simplest option, but it breaks callers that currently work by accident because they share one directory.

**Proof of concept:** `bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `all ok` once it is fixed. It writes into a unique scratch directory under the first argument, `$WORKDIR` or `$TMPDIR` (default `/tmp`). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-03-loaded-forest-as-value-loses-lazy-subtrees/test_loaded_forest_as_value.lua
```

**ID**: `lua-03-loaded-forest-as-value-loses-lazy-subtrees`

### B14. Forest tree files keyed only by hash collide across heights and representations

**Title**: Frontier-forest tree files are keyed only by hash: the same hash at another height makes `frontier_forest_load` raise, and a coarser tree stored first permanently hides a finer tree's leaves

**Problem:** `frontier_forest_store` writes each tree to `<directory>/<hash>.json`, and the file name holds nothing but the tree hash. Three things combine:
- `get_tree_path` names the file by `tree.hash` only.
- `store_tree` writes the file only when no file with that name exists, so the first tree stored under a hash owns the file.
- `load_tree` asserts `stored.height == height`, so a file for the same hash at another height raises an error. It does not treat the hash as opaque.

Raw values carry a height the caller declares (`append`, `pad_back` and `push_back` take a `value_height`). So one 32-byte hash can stand for different subtrees. The two hashes need not collide: the subtrees are equal as hash trees but described differently.
- **Different height.** Take the pristine chain `z0 = H(zero word)`, `z[i+1] = H(z[i], z[i])`. Four leaves `z1` form a height-2 node with hash `z3`. Eight leaves `z0` form a height-3 node with the same hash `z3`.
- **Same height, different representation.** Two opaque height-1 values `R = H(a,b)` (fixed_point, base 1) and the four leaves `{a,b,a,b}` (base 0) give the same height-2 hash.

Consequences:
- (a) Whichever tree is stored second under a hash makes later loads raise `stored tree height mismatch`. A mixed tree loads its children eagerly, and frontier levels load at open time, so a single collision aborts the whole `frontier_forest_load`. If the collision is reached lazily through `descend_tree`, `get_node_hash` and `get_siblings` raise instead of returning `nil, "the node is below an opaque hash"`. That defeats a caller's open-the-bundle fallback.
- (b) If the coarse representation is stored first, the finer tree's store skips the file. After reload, the fine forest's leaves are opaque. `get_node_hash` and `get_siblings` return `nil` for nodes they answered before the store.

A shared directory is not needed. A single forest stored alone into an empty directory shows both failures. The documented contract fails: a stored forest is meant to reopen and keep its trees, and the directory is meant to be shared ("successive snapshots of a growing forest share them").

**Origin:** Introduced by this branch. `src/cartesi/hash-tree.lua` was added in commit fcf6819 ("store frontier forests durably") and does not exist on `main`. It ships as the `cartesi.hash-tree` Lua module.

**Area:** Lua library `cartesi.hash-tree`, frontier forest persistence (`frontier_forest_store`, `frontier_forest_load`, lazy loads in `descend_tree`).

**Category:** Correctness / persistence (load failure, silent loss of stored data).

**Location:**
- `src/cartesi/hash-tree.lua:503`: `get_tree_path` names files by hash only.
- `src/cartesi/hash-tree.lua:529`: `load_tree` asserts `stored.height == height`.
- `src/cartesi/hash-tree.lua:548-551`: mixed trees load their children eagerly, so one mismatch aborts the whole load.
- `src/cartesi/hash-tree.lua:581`: `store_tree` skips a file that already exists.
- `src/cartesi/hash-tree.lua:645`: lazy `load_tree` in `descend_tree`, reached from `get_node_hash` and `get_siblings`.
- `src/cartesi/hash-tree.lua:1010`: `frontier_forest_load` loads every frontier level.
- Shared-directory use: `doc/recipes/prt.lua:2511`, `2523`, `2535` (store) and `2786`, `2799`, `2804` (load). The epoch builder, the mcycle forest and every uarch claim forest all use `<epoch>/forests`.

**Evidence:** The PoC uses only the public `cartesi.hash-tree` API. Every case asserts that the in-memory forest answers correctly before the store.
- (a) and (a'): two forests share one directory. They hold the same hash `z3` at heights 2 and 3. The forest stored second fails to reload, whichever order is used.
- (b): coarse `pad_back(R,2,1)` is stored first, then fine `append{a,b,a,b}`. The reloaded fine forest has lost its leaves.
- (c): a single height-5 forest stored alone holds `z3` at (0,2) and at (8,3). It cannot be reloaded.
- (d): a single height-3 forest stored alone holds `pad_back(R,2,1)` and then `{a,b,a,b}`. It loses leaf 4 after reload.
```
$ eval $(make -s env); lua5.4 bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua
BUG (a): reloading forest Y raises because forest X stored the same hash at another height: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (a'): reloading forest X raises because forest Y stored the same hash at another height: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (b): reloaded fine forest lost its leaves: get_node_hash(0,0) -> nil (the node is below an opaque hash); get_siblings(1,0) -> nil (the node is below an opaque hash)
BUG (c): a single forest stored alone cannot be reloaded: .../src/cartesi/hash-tree.lua:529: stored tree height mismatch
BUG (d): single forest stored alone lost leaf 4 after reload: the node is below an opaque hash
5 check(s) failed: tree files are keyed only by hash
exit=1
```

**Scenario:**
- **Affected users.** A validator or tool built on `cartesi.hash-tree` keeps forests on disk across restarts, in one directory or in a directory shared between forests, as the PRT recipe does. Its leaves mix declared heights or granularities. Examples are leaves that are roots of memory regions of different sizes (pristine or repeated content gives equal hashes at different heights), or forests with different bundle heights over the same values.
- **(a) Crash on startup.** After a restart, `frontier_forest_load` raises, so the node cannot reopen its stored state and must rebuild it by re-running the machine.
- **(b) Lost answers.** The reloaded forest silently becomes opaque below the shared hash. The node can no longer answer node-hash or sibling queries it answered before, and so cannot produce those proofs without recomputation. Under a tournament deadline, this can cost an honest player the dispute.
- **PRT recipe.** Neither the prover nor the reviewers found a trigger in the recipe's own forests. Those forests put state hashes at height 0 and bundle roots at one bundle height per forest. State hashes include `mcycle`, so values repeat only in the halted region, which is represented the same way everywhere. A cross-height match there would need a Keccak collision. An honest node stores only forests it computed itself, so an adversary cannot inject colliding trees.
- **Not affected.** The CLI does not use these functions. Wrong hashes are never accepted: `load_tree` verifies the hash, so failures are loud (an error) or show up as opacity, never as a wrong proof.

**Possible solution:**
- Make the file name identify the representation, not just the hash. For example, `<hex>-h<height>.json`, and ideally also the kind and base height, or a digest of the stored contents. Then `load_tree(hash, height)` looks up only a file of the right height.
- Also make `load_tree` treat a height or representation mismatch as "no file" (return `nil`, so the hash stays opaque) instead of raising. This keeps the opaque-hash fallback working.
- To keep the finest representation, `store_tree` could overwrite an existing file when its representation is coarser (higher `base_height`, or a fixed-point file where the new tree is mixed). Writing under a representation-specific name also does this.
- A simpler mitigation for callers is one directory per forest. That fixes only the cross-forest cases (a, a', b), not the single-forest cases (c, d).

**Severity:** Medium. One reviewer rated it low: there is no PRT trigger, and it never yields wrong proofs. The other rated it medium, after showing it fires inside a single forest stored alone. Medium is the reconciled rating. A shipped persistence API can produce a store that cannot be loaded, or that silently loses leaf-level data, on legitimate input. It is not high, because the PRT recipe's forests do not reach it and an adversary cannot force it.

**Risks:**
- **Of the bug.** A validator restart can fail outright, or come back unable to answer queries and proofs that worked before. Recovery means re-running the machine, which costs time during disputes and fails if the snapshot is gone. Stores already written in the hash-only layout keep the ambiguity.
- **Of the fix.** Changing the file name changes the on-disk format. Existing stores written with hash-only names would become unreadable unless `load_tree` falls back to the old name, checking the height. Overwriting files in place must stay crash-safe (temporary file and rename, as `write_file` already does). It must also not break the store's commit-point guarantee, because another frontier file may reference the old file. Representation-specific names avoid in-place rewrites. Including the height in the name grows the directory only when the same hash is used at several heights.

**Proof of concept:** `bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua`. It works under `$WORKDIR` (or `$TMPDIR`, `/tmp`, or a directory given as the first argument) and removes its files at the end. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-04-content-addressing-ignores-height-and-representation/test_tree_files_keyed_by_hash_only.lua`. It exits 1 and prints `BUG` lines while the bug is present. It prints `PASS` once fixed.

**ID**: `lua-04-content-addressing-ignores-height-and-representation`

### B15. frontier(last_proof) hangs on the last leaf of a 64-bit tree and does not validate the proof

**Title**: `hash_tree.frontier(last_proof)` loops forever on `target_address = 2^64-1` (so `cartesi-machine` hangs on `last_output_proof`) and accepts out-of-range or inconsistent proofs without checking them

**Problem**

`frontier(proof)` rebuilds an outputs frontier from the last leaf's proof. It sets `leaf_count = proof.target_address + 1` and then runs `while (leaf_count & (1 << (lowest_complete_level - 1))) == 0 do ... end`, a loop with no upper bound. Take a proof with `target_address = 0xFFFFFFFFFFFFFFFF`:

- `cartesi.fromjson(..., "Proof")` accepts `18446744073709551615` for a `log2_root_size` 63 proof and returns Lua integer `-1`.
- `leaf_count` wraps to 0.
- In Lua 5.4, `1 << n` is 0 for `n >= 64`, so the mask stays 0 and the loop never ends (100% CPU).

The function also never validates the proof. Nothing checks any of these:

- `0 <= target_address < 2^log2_root_size`
- `log2_target_size == 0`
- `#sibling_hashes == log2_root_size`
- that the target hash rolled up through the siblings equals `root_hash`

As a result, an out-of-range `target_address` silently produces a frontier for a different leaf count. For example, address 16 in a height-4 tree gives `leaf_count` 1. A proof whose `root_hash` does not match its target and siblings is also accepted, and the frontier built from it has a different root.

**Origin**

Pre-existing. `frontier(proof)` and its loop are identical on `origin/main`. This branch changes code around them, and the new PRT recipe node calls the same API.

**Area**

Lua hash-tree library (`cartesi.hash-tree` frontier) and the `cartesi-machine` CLI (`--cmio-advance-state ... last_output_proof:`). The C++ JSON `Proof` parser is also involved: it does not range-check `target_address` against `log2_root_size`.

**Category**

Hang (infinite loop) and missing input validation, which leads to a silently wrong frontier.

**Location**

- `src/cartesi/hash-tree.lua:389-421`: `frontier()`. The unbounded loop is at 397-399; there is no proof validation, and bits at or above `log2_max_leaves` are ignored at 402-405.
- `src/cartesi-machine.lua:3392-3401`: `initialize_cmio_outputs` only asserts `log2_root_size == 63` and `log2_target_size == 0`, then calls `hash_tree.frontier(proof, "keccak256")`.
- `src/cartesi-machine.lua:3305-3309`: `read_proof` uses `cartesi.fromjson(contents, "Proof")`, which accepts out-of-range `target_address`.
- `doc/recipes/vg.lua:715`: the PRT recipe node calls the same API on a stored `last_output_proof`.

**Evidence**

`eval $(make -s env); lua5.4 bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua` (about 26 s, mostly the two timeouts):

```
BUG: hash_tree.frontier(proof) with target_address=2^64-1 (log2_root_size 63) did not return within 5s (infinite loop)
ok: control CLI run with genuine last_output_proof exited 0
BUG: cartesi-machine --cmio-advance-state last_output_proof:<target_address 18446744073709551615> hung (killed by 20s timeout)
BUG: frontier(proof) accepted target_address=16 in a 2^4-leaf tree; frontier leaf_count=1 (expected error; true count would be 17)
BUG: frontier(proof) accepted a proof whose root_hash does not match its target/siblings (frontier root differs from proof.root_hash)
ok: sanity genuine proof rebuilds frontier with leaf_count 6 and matching root
exit=1
```

The test runs `cartesi-machine.lua --revert-mode=none --cmio-advance-state=...,last_output_proof:hang-proof.json,format:json -- true`, which hangs before any input is processed. The same command with a genuine last-output proof exits 0 in about 1.4 s, so the hang comes from the proof. The test also shows that the JSON parser turns `18446744073709551615` into `-1` without complaint.

**Scenario**

- **CLI hang.** An operator or script runs `cartesi-machine --cmio-advance-state=...,last_output_proof:<file>,format:json` with a corrupted, hand-edited or externally received Proof JSON that has `target_address` 18446744073709551615. The process spins forever instead of failing.
- **Validator hang.** A validator node built on the Lua library rebuilds the previous epoch's outputs frontier from a stored or received proof in the same way (the recipe node does this). It hangs, which is a liveness failure.
- **Wrong outputs.** Any `target_address` in `[2^63, 2^64-2]` (for the CLI), or `>= 2^L` in general, or a proof whose root does not match, is silently accepted. Outputs are then numbered from the wrong index and appended to the wrong frontier, so the node produces wrong outputs roots and output proofs instead of rejecting the input.
- **Why this is not a normal-flow bug.** Proofs the emulator itself produces are always in range and consistent, so honest flows that use the node's own previous-epoch proof are not affected. The Rollups Node and Dave, which use the C API, do not go through this Lua function.

**Possible solution**

In `frontier(proof)`, before using the proof:

- Require `math.type(proof.target_address) == "integer"`.
- Require `0 < log2_root_size < 64` and `0 <= target_address < (1 << log2_root_size)`, using an unsigned comparison such as `math.ult`.
- Require `log2_target_size == 0` and `#sibling_hashes == log2_root_size`.
- Check that rolling `target_hash` up through `sibling_hashes` (or `verify_slice`) reproduces `proof.root_hash`.
- Cap the loop at `log2_max_leaves + 1` as defense in depth.

Optionally, make the C++ JSON `Proof` parser reject `target_address` values that are out of range for `log2_root_size`.

**Severity**

Low. Both reviewers rated it low, and the prover rated it low to medium. The bug really hangs a library function and the CLI forever, and it silently builds wrong frontiers. But it is reached only with malformed, corrupted or untrusted proof files that the emulator never produces. It cannot make an honest player who uses genuine proofs lose a dispute, and the C API used by the Rollups Node and Dave is not involved.

**Risks**

- **Of the bug:** a validator or CLI hangs at 100% CPU on bad input instead of failing fast. A wrong frontier, wrong output numbering, and wrong outputs roots or proofs can follow from out-of-range or inconsistent input with no error raised.
- **Of the fix:** the root-hash consistency check costs `log2_root_size` hashes, which is negligible. Strict checks could reject callers that today pass proofs with extra fields or a non-zero `log2_target_size` on purpose, but none are known in this repo. The unsigned range check must handle `log2_root_size` 63 correctly, where `1 << 63` is negative in Lua.

**Proof of concept**

`bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua`. Run it from the repo root:

```
eval $(make -s env); lua5.4 bugs/lua-05-frontier-from-proof-hang-and-no-validation/test_frontier_from_proof.lua
```

It exits 1 and prints `BUG:` lines while the defect is present, and prints `PASS` once it is fixed. It writes `hang-proof.json`, `ok-proof.json`, `child_hang.lua` and `cli*.log` next to itself, and needs `cartesi-machine.lua` in `PATH`, which the env provides, plus the default kernel and rootfs images.

**ID**: `lua-05-frontier-from-proof-hang-and-no-validation`

### B16. verify_slice and verify_splice accept malformed proofs

**Title**: Lua `verify_slice`/`verify_splice` accept malformed proofs (address beyond root, unaligned address, extra siblings, target size above root size), and `frontier_next_proofs` on a full tree returns one

**Problem:** `roll_hash_up_tree` loops only over `log2_size = log2_target_size .. log2_root_size - 1`. It reads only those bits of `target_address` and only the first `log2_root_size - log2_target_size` entries of `sibling_hashes`. `verify_slice` and `verify_splice` only compare the rolled-up hash with `root_hash`, and check nothing about the shape of the proof. As a result, a valid proof also verifies when:
- (a) `k * 2^log2_root_size` is added to `target_address`, which puts it outside the tree;
- (b) address bits below `log2_target_size` are set, so the address is unaligned;
- (c) extra trailing siblings are appended;
- (d) `log2_target_size > log2_root_size`. The loop then never runs, so any proof with `target_hash == root_hash` "verifies" at any address.

The C++ `hash_tree_proof` (`src/hash-tree-proof.hpp:43-55`) rejects non-positive root sizes and a target size above the root size, and it sizes the sibling vector exactly. The Lua verifier enforces none of this.

Separately, `frontier_next_proofs` has no capacity check, unlike `frontier_push_back` and `frontier_append`, which assert "too many leaves". On a full frontier it returns a proof with `target_address == 2^height`, a leaf that cannot exist. Bit `height` is ignored, so the proof verifies as index 0.

**Origin:** Pre-existing. `roll_hash_up_tree`, `verify_slice`, `verify_splice` and `frontier_next_proofs` are identical on `origin/main` (v0.22.0, the merge base).

**Area:** Lua hash-tree library (`cartesi.hash-tree`): proof verification and output-frontier proofs.

**Category:** API contract / input validation.

**Location:**
- `src/cartesi/hash-tree.lua:9-23` (`roll_hash_up_tree`)
- `src/cartesi/hash-tree.lua:27-29` (`verify_slice`)
- `src/cartesi/hash-tree.lua:33-36` (`verify_splice`)
- `src/cartesi/hash-tree.lua:310-359` (`frontier_next_proofs`, no `leaf_count + #next_output_hashes <= 2^log2_max_leaves` check)

**Evidence:** The test builds proofs that are valid at first: a height-63 outputs-tree proof from `frontier_next_proofs`, and a 32-byte word proof from `machine:get_proof`. It then mutates each proof into a non-canonical form and calls `verify_slice`/`verify_splice`. It also calls `frontier_next_proofs` on a full height-2 frontier. All 6 non-canonical cases are accepted. The one rejected case (address bit 63 with `log2_root_size` 64) is rejected only because that bit falls inside the range the verifier reads.
```
$ eval $(make -s env); lua5.4 bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua
baseline: index	2	verifies
BUG: verify_slice accepted target_address beyond tree (0x8000000000000002 >= 2^63)
BUG: verify_slice accepted proof with 2 extra trailing siblings (65 vs 63)
BUG: verify_slice accepted log2_target_size > log2_root_size with target_hash == root_hash (arbitrary address 12345)
BUG: verify_slice accepted unaligned memory proof target_address 0x80000007 (log2_target_size 5)
ok: rejected memory proof target_address 0x8000000080000000 beyond 2^64 address space root (log2_root_size 64)
BUG: verify_slice accepted verify_splice with unaligned target_address
BUG: verify_slice accepted frontier_next_proofs(full height-2 frontier) proof at target_address 4 (tree has 4 leaves)
BUG: 6 non-canonical proofs accepted
```
The test exits with status 1 while the bug is present.

**Scenario:** A third-party Lua validator, or any tool built on `cartesi.hash-tree`, receives an output proof or state proof from an untrusted party. It calls `verify_slice(proof)`, then records the claim at `proof.target_address`, or derives the depth from `#proof.sibling_hashes`. An adversary can make it accept a claim at an index that does not exist (beyond the outputs tree, which has 2^63 leaves, or unaligned), or accept a degenerate "proof" in which the target is the root.

The bits that are actually read stay bound by the hashes. An attacker therefore cannot prove a false hash at a different valid, in-range, aligned position. The address only aliases the true position.

The reference `doc/recipes/prt.lua` is not affected, because it checks `target_address` exactly before calling `verify_slice` (lines 207-212 and 318-324). The Rollups Node and Dave are not affected either: they use the C API, which does not expose proof verification.

The `frontier_next_proofs` overflow cannot be reached with the real outputs tree (height 63). It occurs only with small custom heights that are deliberately filled.

**Possible solution:**
- In `verify_slice` and `verify_splice` (or in `roll_hash_up_tree`), require all of the following:
  - integer sizes with `0 <= log2_target_size <= log2_root_size <= 64`;
  - `#sibling_hashes == log2_root_size - log2_target_size`;
  - `target_address & ((1 << log2_target_size) - 1) == 0`;
  - `target_address >> log2_root_size == 0` when `log2_root_size < 64`.
- In `frontier_next_proofs`, assert `leaf_count + #next_output_hashes <= 1 << log2_max_leaves`, with the message "too many leaves".

**Severity:** Low. Both reviewers rated it low; the original suspicion was medium. The emulator never produces a wrong or nondeterministic hash, root or proof for valid inputs. The PRT reference node and the C API consumers are not affected. Harm requires a Lua caller that skips its own shape checks and trusts the free address bits or the sibling count. Even then it cannot prove a false hash at a real position.

**Risks:**
- *Of the bug:* Lua validators built on this API may silently accept claims at fabricated indices, out of range or unaligned. This can mislead bookkeeping, for example output indexes or leaf positions, or a decision to dispute. A full-frontier misuse yields a "valid" proof for a leaf that does not exist.
- *Of the fix:* Stricter checks could reject proofs that callers build by hand with non-canonical fields. Examples are `log2_root_size` 64 with `target_address` near 2^64, which needs care because Lua integers are signed, and callers that pad `sibling_hashes`. The new assertions must not break the proofs from `machine:get_proof` or the uarch/mcycle proofs that `prt.lua` builds. Both are canonical today.

**Proof of concept:** `bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua`. It needs no machine images: it builds a RAM-only machine. Run it from the repo root:
`eval $(make -s env); lua5.4 bugs/lua-06-verify-slice-noncanonical-address/test_verify_slice_noncanonical.lua`
Exit status 1 with `BUG:` lines means the bug reproduces. Exit status 0 with "all non-canonical proofs rejected" means it is fixed.

**ID**: `lua-06-verify-slice-noncanonical-address`

**Related**: [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity).

### B17. ABI decoder rejects canonical empty arrays of dynamic types

**Title**: evmu `decode_array` returns a nil end offset for an empty `T[]` with dynamic `T`, so `decode_abi`/`decode_calldata` reject canonical data

**Problem:** In `decode_array`, when the element type is dynamic (`bytes`, `string`, `T[]`, or a tuple with dynamic members), the end offset `last_offset` is declared nil and assigned only inside `for i = 1, size`. For an empty array (`size == 0`), the function returns `result, nil` when it should return the offset just past the length word. `decode_tuple` copies that nil into its `new_offset`. If no later dynamic component overwrites it, the tuple returns nil as its end offset, and the final length checks fail on valid, canonical ABI data. The nil also passes up through enclosing arrays and tuples, so `bytes[][]` holding one empty inner array fails too. Because the encoder is correct, `encode_abi` followed by `decode_abi` is not a round trip.

**Origin:** Pre-existing. The `decode_array`/`decode_tuple` code is the same on `main`, where `decode_calldata` already had the bug. This branch adds the public `decode_abi`, which reuses the same helper for event log data and `eth_call` return values. That gives callers a new way to hit the bug.

**Area:** Lua library `cartesi.evmu`, the ABI decoder (`src/cartesi/evmu.lua`).

**Category:** Correctness (canonical input rejected; robustness/DoS).

**Location:**
- `src/cartesi/evmu.lua:742-750`: `decode_array`, dynamic-element branch (`local last_offset` is set only inside the loop; `return result, last_offset`)
- `src/cartesi/evmu.lua:776`: `decode_tuple` copies the nil into `new_offset`
- `src/cartesi/evmu.lua:831`: `decode_calldata` `assert(offset == #calldata_raw, "calldata too long")`
- `src/cartesi/evmu.lua:846`: `decode_abi` `assert(offset == #data, "ABI data too long")`

**Evidence:** The test encodes values with `evmu.encode_abi`/`encode_calldata` and decodes them back. `encode_abi("(bytes[])", {{}})` produces the canonical 64 bytes (offset `0x20`, length `0`), which is the same as Solidity's `abi.encode(new bytes[](0))`. The non-empty control case passes, and every empty case fails:
```
$ eval $(make -s env); lua5.4 bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua
ok:  abi (bytes[])
BUG: abi (bytes[]) round trip with empty dynamic-element array fails: .../src/cartesi/evmu.lua:846: ABI data too long
BUG: abi (string[]) ... :846: ABI data too long
BUG: abi (uint256,string[]) ... :846: ABI data too long
BUG: abi ((uint256,bytes)[]) ... :846: ABI data too long
BUG: abi (bytes[][]) ... :846: ABI data too long
BUG: calldata f(bytes[]) ... :831: calldata too long
BUG: calldata f(string[],uint256) ... :831: calldata too long
exit=1
```
Reviewers also found that `(bytes[],uint256)` fails, while `(bytes[],bytes)` decodes because the later dynamic component overwrites the nil. This matches the code path described above.

**Scenario:** A Lua validator or tool built on `cartesi.evmu` decodes something that carries an empty `bytes[]`, `string[]` or tuple-with-dynamic `[]` array: a contract event, an `eth_call` return value, or an input or calldata payload. A real-world example is an empty batch. `decode_abi`/`decode_calldata` raise an error on this legitimate data. If the caller does not wrap the call in `pcall`, its event-processing loop stops, and a PRT validator could miss dispute deadlines. The in-tree experimental PRT node does not use such types today, so it is not affected. The Rollups Node and Dave use the C API, not this Lua library. Hashes, proofs and machine state are not involved.

**Possible solution:** In the dynamic-element branch, initialize the end offset to the end of the offsets head: `local last_offset = new_offset + size * 32`. Equivalently, return `size == 0 and new_offset or last_offset`. A more robust fix tracks the maximum end offset over all elements, instead of assuming the last element's data comes last. The same reasoning applies to `decode_tuple`: it should use the maximum end over its dynamic components.

**Severity:** Medium. A shipped public Lua API deterministically errors on valid, canonical ABI data, and encode followed by decode does not round-trip. The error is loud and catchable with `pcall`, never yields wrong decoded values, does not affect hashes or proofs, and does not hit the in-tree PRT node. Both reviewers rated it medium (arguably low).

**Risks:** Bug: a Lua consumer of `decode_abi`/`decode_calldata` (validator, indexer or tool) can stall or crash on legitimate events or inputs containing empty dynamic-element arrays. Fix: low risk, a local change to the end-offset calculation. Switching to "maximum end" semantics would also change the "too long" check for non-canonical but valid layouts (for example, out-of-order element data), so add round-trip tests for nested and mixed types.

**Proof of concept:** `bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/lua-09-evmu-decode-empty-dynamic-element-array/test_decode_empty_dynamic_array.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 once it is fixed.

**ID**: `lua-09-evmu-decode-empty-dynamic-element-array`

**Related**: [B43](#b43-abi-decoders-trailing-data-check-uses-only-the-last-dynamic-tail).

### B18. ABI decoder bounds checks overflow and accept out-of-bounds offsets

**Title**: evmu ABI decoder: integer overflow in offset/length bounds checks lets out-of-bounds dynamic offsets and lengths decode silently as empty or zero values (`decode_abi`, `decode_calldata`)

**Problem:** `check_lua_uint` only rejects values of 2^63 or more. Offsets and lengths up to `0x7fffffffffffffff` therefore become Lua integers, and the decoder adds them with no overflow check:
- `tuple_start + offset` in `decode_tuple`
- `array_data_start + offset` in `decode_array`
- `offset + 32` in `read_word`
- `n + 31` in `ceil32`
- `new_offset + padded_len` in `decode_string` and `decode_bytes`

Lua integer arithmetic wraps, so a sum can become negative. The guard `x > #calldata` is then false and decoding carries on: `calldata:sub(...)` with a start past the end, or a negative end, returns `""`, and `bint.frombe(word_padding .. "")` gives 0. A length of 0 then decodes as an empty value, with a negative "next offset".

The only end-of-data check (`offset == #data` in `decode_abi` and `decode_calldata`) never sees the corrupted component. `decode_tuple` overwrites `new_offset` with each dynamic component's end, so the check only covers the last dynamic component. An earlier `bytes`/`string`/array component with an out-of-bounds offset or length is accepted silently and comes back as `"0x"` or `""`. Solidity's `abi.decode` reverts on all of these inputs. The overflow is the whole defect: offsets that are too large but do not wrap are correctly rejected with "insufficient calldata".

**Origin:** Pre-existing. The decoder logic predates this branch and is reachable through `decode_calldata`. This branch adds a new public entry point, `decode_abi`, that uses the same decoder, and the PRT recipes call it on chain return data.

**Area:** Lua library `cartesi.evmu` (ABI decoder: `decode_abi`, `decode_calldata`, `decode_calldata_hex`).

**Category:** Correctness: input validation, integer overflow in bounds checks.

**Location:**
- `src/cartesi/evmu.lua:45`: `ceil32` (`(n + 31) // 32` wraps)
- `src/cartesi/evmu.lua:48-53`: `check_lua_uint` (limit 2^63, not `#calldata`)
- `src/cartesi/evmu.lua:643`: `read_word` bounds check `offset + 32 > #calldata`
- `src/cartesi/evmu.lua:693-699`: `decode_string`
- `src/cartesi/evmu.lua:716-721`: `decode_bytes` (dynamic)
- `src/cartesi/evmu.lua:747`: `decode_array` element offset
- `src/cartesi/evmu.lua:775-776`: `decode_tuple` dynamic offset and the `new_offset` overwrite
- `src/cartesi/evmu.lua:831, 846`: end checks in `decode_calldata` and `decode_abi`, which only see the last component's end

**Evidence:** The test builds five malformed encodings and passes them to the public `evmu.decode_abi` / `evmu.decode_calldata`. It first checks that a valid encoding round-trips. All five malformed encodings decode without error:
```
BUG: (bytes,bytes) offset 0x7ffffffffffffff0: decode accepted malformed data, returned {0x, 0xcd}
BUG: (bytes,bytes) length 0x7fffffffffffffff: decode accepted malformed data, returned {0x, 0xcd}
BUG: (string,string) offset 0x7ffffffffffffff0: decode accepted malformed data, returned {, x}
BUG: decode_calldata f(bytes[],bytes) element offset overflow: decode accepted malformed data, returned {table: 0x..., 0xcd}
BUG: (address,uint256,bytes,bytes) payload offset overflow: decode accepted malformed data, returned {0x1111111111111111111111111111111111111111, 5, 0x, 0x}
BUG: 5 malformed encodings decoded without error (Solidity abi.decode reverts)
exit=1
```
Run: `eval $(make -s env); lua5.4 bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua`

**Scenario:** An off-chain Lua tool, indexer or alternative validator uses `evmu.decode_calldata` to interpret machine outputs, as `vgu.lua`, `cartesi-rollup-data.lua` and the rolling-calculator recipes do with `Notice`/`Voucher`. It may also use `decode_abi` on chain data, as `prt-bridge.lua` and `prt-deploy.lua` do. An application, buggy or malicious, emits a `Voucher(address,uint256,bytes)`-style output whose payload offset or length is near 2^63. The Lua decoder accepts it and reports an empty payload (or an empty string, or a zero-length array element). On chain, `abi.decode` on the same bytes reverts. So off-chain interpretation differs from on-chain behaviour: a tool may show or act on a "valid, empty" voucher or notice that can never be executed, or skip validation logic that assumes malformed data raises.

None of this touches machine state hashes, Merkle proofs, step logs or PRT commitments. In the PRT flow the decoded chain data is produced by Solidity contracts and is always well-formed.

**Possible solution:** Bounds-check every offset and length against `#calldata` before any arithmetic, for example in a helper `check_offset(value, base, calldata)` that rejects `value > #calldata - base`. Cap `check_lua_uint` results used as offsets or lengths at `#calldata` instead of 2^63. In `ceil32`, check the length against `#calldata` before rounding. In `read_word`, test `offset < 0 or offset > #calldata - 32`. Optionally, make `decode_tuple` track the maximum end over all dynamic components (or check that each one lies inside the data), so the end-of-data check is meaningful for every component and not just the last.

**Severity:** Low. It is a real correctness defect in a shipped Lua library: it silently accepts out-of-bounds ABI data where Solidity reverts. However:
- It needs deliberately crafted offsets or lengths near 2^63.
- It cannot change hashes, proofs or step logs, so it cannot make an honest PRT player lose a dispute.
- It causes no crash or hang.
- The PRT callers decode contract-produced data.

The prover suggested medium/low and both reviewers rated it low. Low-medium is at most justified for third-party indexers that rely on `evmu` to validate untrusted application outputs.

**Risks:**
- Of the bug: off-chain consumers misread malformed outputs or inputs as valid with empty or zero fields, so off-chain views (indexers, explorers, tooling that decides whether to submit a voucher) diverge from on-chain execution.
- Of the fix: stricter checks may start rejecting encodings that were previously, and wrongly, accepted. That is the desired behaviour, but callers that do not wrap decode in `pcall` would now raise. Tracking the maximum dynamic end must not reject valid encodings whose dynamic tails are out of order or overlap (Solidity accepts those), so the fix should check per-component bounds rather than demand a contiguous layout.

**Proof of concept:** `bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-10-evmu-offset-length-overflow-accepts-oob/test_abi_offset_overflow.lua
```
It exits 1 and prints `BUG:` lines while the defect is present, and exits 0 with `PASS` once every malformed encoding is rejected.

**ID**: `lua-10-evmu-offset-length-overflow-accepts-oob`

### B19. ABI type parser mangles parameter names starting with memory, storage or calldata

**Title**: evmu type parser splits parameter names that start with `memory`/`storage`/`calldata`, so named encode/decode uses the wrong field

**Problem:** In the `cartesi.evmu` type-spec grammar, the `data_location` rule is `P("memory") + P("calldata") + P("storage")`. It has no identifier-boundary check (`idnot`), and the int/bytes size rules in the same file do have one. `type_spec` matches `C(V("data_location")^-1) * opsp * C(identifier^-1)`, and `opsp` allows zero spaces. As a result, a parameter name that begins with one of these keywords gets split in two. `uint256 storageRoot` parses as data_location `storage` with name `Root`. `memoryIndex` becomes `Index`, `calldataHash` becomes `Hash`, and `storage_x` becomes `_x`. Every named spec gets these wrong names:
- `parse_type_spec` and `parse_func_sig` return the wrong `name`.
- `decode_abi`, `decode_calldata` and `decode_calldata_hex` return the value under the mangled key, so `v.storageRoot` is `nil`.
- `encode_abi`, `encode_calldata` and `encode_calldata_hex` reject a correctly named argument table with `unexpected tuple component with name "storageRoot"`.

**Origin:** Pre-existing. The grammar line is the same on `main`. This branch adds `encode_abi` and `decode_abi`, which are used for event data and return values. Those specs are usually built from ABI JSON with names, so the new functions make the bug easier to hit.

**Area:** Lua library `cartesi.evmu` (`src/cartesi/evmu.lua`), the EVM ABI helper that ships in the emulator package.

**Category:** Correctness (parser / ABI encoding and decoding).

**Location:**
- `src/cartesi/evmu.lua:127`: the `data_location` rule, missing `* idnot`
- `src/cartesi/evmu.lua:129-141`: `type_spec` uses that rule and assigns `name` and `data_location`
- `src/cartesi/evmu.lua:100`: `idnot`, already defined and not applied here
- Affected entry points:
  - `parse_func_sig` (`:280`) and `parse_type_spec` (`:299`)
  - `encode_calldata` and `encode_calldata_hex` (`:611`, `:623`)
  - `encode_abi` (`:627`)
  - `decode_calldata` and `decode_calldata_hex` (`:820`, `:836`)
  - `decode_abi` (`:842`)

**Evidence:** The test parses, decodes and encodes specs whose parameter names start with each keyword. Run it with `eval $(make -s env); lua5.4 bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua`. Output:
```
BUG: parameter "storageRoot" parsed as name=Root data_location=storage
BUG: parameter "memoryIndex" parsed as name=Index data_location=memory
BUG: parameter "calldataHash" parsed as name=Hash data_location=calldata
BUG: parameter "storage_x" parsed as name=_x data_location=storage
BUG: decode_abi named fields missing: storageRoot=nil memoryIndex=nil; keys present: 1,2,Index,Root
BUG: encode_abi with {storageRoot=7} failed: .../src/cartesi/evmu.lua:39: unexpected tuple component with name "storageRoot"
BUG: encode_calldata with {calldataHash=...} failed: .../src/cartesi/evmu.lua:39: unexpected tuple component with name "calldataHash"
exit=1
```
With the one-line fix below, the same test prints `OK: ...` and exits 0. It also checks that `(bytes memory payload)` still parses as data_location `memory` with name `payload`.

**Scenario:** A validator node or tool builds encode/decode specs from a contract's ABI JSON, keeping the parameter names. Examples are event arguments or function return values decoded with `decode_abi`, or calls built with `encode_calldata`. Names such as `storageRoot`, `memoryHash` and `calldataSize` are legal in Solidity and appear in real contracts.
- Decoding puts the field under `Root`, `Hash` or `Size`, so the caller reads `nil` and fails, or may misread the data.
- Encoding a named argument table throws.

The PRT node in this branch uses only unnamed specs such as `(uint64)` (`prt-bridge.lua`), so it does not hit the bug. Third-party validators and tools that use names would.

**Possible solution:** Add an identifier boundary to the keyword rule:
```lua
data_location = (P("memory") + P("calldata") + P("storage")) * idnot,
```
This fix was verified in a patched copy. Separately, `idfirst`/`idrest` reject `$`, which Solidity allows in identifiers. That is a different grammar limitation and is not covered by this test.

**Severity:** Low. Both reviewers confirmed the bug and rated it low; the prover's medium was not adopted. It is a real bug in a shipped Lua helper, but the impact is narrow:
- Nothing touches state hashes, proofs, step logs or the C API.
- The decoded value is correct and only its key is wrong.
- Failures are usually loud: a nil field or an encode error.
- The trigger is uncommon: a named spec whose name starts with one of the three keywords.

**Risks:**
- Bug: a caller may misread data or fail when decoding events or return values under the expected field name. An encode error may also stop a transaction or query from being built. This can disrupt tools or nodes that rely on names taken from ABI JSON.
- Fix: minimal. Real data locations are always followed by whitespace or the end of the input, and `idnot` accepts both, so `bytes memory payload` and `string calldata` still parse. The only change in behaviour is that names starting with these keywords are now kept whole.

**Proof of concept:** `bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-11-evmu-param-name-data-location-prefix-mangled/test.lua
```
It exits 1 and prints `BUG: ...` lines while the bug is present. It exits 0 and prints `OK: ...` once fixed.

**ID**: `lua-11-evmu-param-name-data-location-prefix-mangled`

### B20. frontier_next_proofs does not check tree capacity

**Title**: `frontier_next_proofs` does not check tree capacity, so on overflow or a full frontier it returns out-of-tree proofs against a wrong root, while `push_back` and `append` reject the same input

**Problem:** `frontier_next_proofs(frontier, next_output_hashes)` reads `leaf_count` and builds one proof per new hash. It never checks two things:
- that `leaf_count + #next_output_hashes <= 2^log2_max_leaves`;
- that the frontier is not already full (its top entry is unset).

The sibling functions do check both. `frontier_push_back` asserts `not frontier[#frontier]`, and `frontier_append` and `frontier_pad_back` assert `frontier_padding_fits(...)`. When the check is missing, `frontier_next_proofs` returns well-formed proofs instead of raising "too many leaves":
- **Partial overflow.** Proofs get `target_address` values outside the tree, and `root_hash` is whatever ends up in `active[1]`.
- **Full frontier.** `frontier_get_leaf_count` wraps to 0, and `frontier[1..L]` are all `false`, because only the top entry is set. The function therefore treats the tree as empty and returns a proof whose root is the root of `{new, pristine, ...}`. The existing leaves are ignored.

`verify_slice` only rolls the hash up `log2_root_size` levels and ignores the higher address bits. So some of these bogus proofs verify, including the full-frontier proof, which verifies against an unrelated root.

**Origin:** Pre-existing. The function is identical on `main` (`src/cartesi/hash-tree.lua:309`).

**Area:** Lua library `cartesi.hash-tree`, the frontier and output-proof API (`frontier_next_proofs`, with `verify_slice` aliasing the address).

**Category:** Correctness / missing precondition check (API inconsistency).

**Location:**
- `src/cartesi/hash-tree.lua:310-360` (`frontier_next_proofs`: no capacity or full check)
- `src/cartesi/hash-tree.lua:144` (`frontier_padding_fits`), `:169` (`frontier_push_back`), `:191` (`frontier_append`), `:262` (`frontier_pad_back`): the checks that the sibling functions do perform
- `src/cartesi/hash-tree.lua:28-30` (`verify_slice`: does not reject `target_address >= 2^log2_root_size`)
- Callers: `src/cartesi-machine.lua:3474` (`save_cmio_output_proofs`), `doc/recipes/prt.lua:2302`, `doc/recipes/vg-test.lua:779`

**Evidence:** The test builds a height-2 (4-leaf) keccak256 frontier using only the public API.
- Case 1: with 3 leaves present, `frontier_append` rejects 3 more hashes, but `frontier_next_proofs` accepts them.
- Case 2: on a full 4-leaf frontier, `frontier_next_proofs` is asked for 1 more proof.
```
$ eval $(make -s env); lua5.4 bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua
BUG: overflow: next_proofs accepted 3 outputs into a 4-leaf tree holding 3 leaves (frontier_append rejects); target addresses {3,4,5} (tree has 4 leaves), 1 of 3 proofs pass verify_slice
BUG: full: next_proofs on a full frontier returned target_address=4 (out of tree), root differs from the real root, verify_slice=true
     (proof root == root of a tree holding only the new leaf; existing 4 leaves ignored)
exit=1
```
In the partial-overflow case, only the first proof (address 3) passes `verify_slice`. The other two have inconsistent roots.

**Scenario:** A library user, such as a validator node or tooling that serves output proofs, builds a small custom-height frontier, or by mistake feeds more leaves than fit. They get silently wrong proofs instead of an error, and a caller that does not compare `root_hash` against an independently computed root publishes them. In the full-frontier case, the proof even passes `verify_slice`.

The realistic PRT and Rollups paths are not exposed:
- Rollups outputs trees use `ROLLUP_LOG2_MAX_OUTPUT_COUNT = 63`, so an overflow would need about 2^63 outputs.
- The CLI's `save_cmio_output_proofs` grows the live frontier with `frontier_push_back`, which rejects overflow first. It also asserts `proofs[1].root_hash == frontier_get_root_hash(outputs_frontier)`.

**Possible solution:** At the top of `frontier_next_proofs`, after the empty-input early return, add `assert(frontier_padding_fits(frontier, next_output_count, 1), "too many leaves")`, mirroring `frontier_append`. This also covers the full-frontier case, because `frontier_padding_fits` fails when the top entry is set. As separate hardening, make `verify_slice` reject `target_address >= 2^log2_root_size` (and misaligned addresses), so that aliased out-of-tree proofs cannot verify.

**Severity:** Low. Both reviewers confirmed the defect and rated it low. It is a real silent-garbage API inconsistency, but height-63 rollup trees make overflow infeasible, and the shipped CLI rejects overflow earlier and checks the root. Only misuse with a small tree, combined with a missing root check, reaches it, so it does not threaten realistic PRT disputes.

**Risks:**
- Of the bug: callers with small trees, or callers that skip the root check, may emit or accept invalid output proofs. The `verify_slice` address aliasing means verification alone does not catch the full-frontier case.
- Of the fix: low. Callers that relied on the lenient behavior now get a "too many leaves" error. A `verify_slice` range check would also reject any existing proof that uses aliased high address bits. No legitimate in-tree caller produces such proofs.

**Proof of concept:** `bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-12-next-proofs-no-capacity-check/test-next-proofs-capacity.lua`. It exits with 1 and prints `BUG:` lines while the bug is present, and prints `OK: next_proofs rejects overflow` once it is fixed.

**ID**: `lua-12-next-proofs-no-capacity-check`

**Related**: [B16](#b16-verify_slice-and-verify_splice-accept-malformed-proofs).

### B21. frontier_next_proofs is wrong on trees of height 64 or more

**Title**: `frontier_next_proofs` returns wrong roots and proofs on trees of height >= 64 when the new leaves cross leaf index 2^63

**Problem:** `frontier_node` decides whether a node index belongs to the frontier, the active region or the pristine region. It does this with signed comparisons, `index < lo` and `index > hi`. `frontier_next_proofs` passes it global node indices: `(leaf_count + i - 1) >> bit`, `node ~ 1`, `2*p` and `2*p + 1`.

On a tree of height 64 or more, those indices can reach 2^63 and above. Lua then reads them as negative integers. Once the active range crosses the sign boundary (`lo` positive, `hi` or the index negative), the node is put in the wrong region. The function returns the frontier entry or the pristine hash where it should return the active node. Every resulting sibling and root is silently wrong.

The rest of the module treats indices as unsigned:
- right shifts are logical;
- `frontier_pad_back` uses `math.ult`;
- `frontier_get_leaf_count` accepts bit 63;
- `frontier_padding_fits` is documented as supporting "trees taller than a Lua integer".

**Origin:** pre-existing. The same `frontier_node` code is on `origin/main` (line 97).

**Area:** Lua hash-tree frontier library (`cartesi.hash-tree`), which ships as part of the emulator's Lua API.

**Category:** correctness (silent wrong result, integer signedness).

**Location:**
- `src/cartesi/hash-tree.lua:96-106` (`frontier_node`: `if index < lo` / `elseif index > hi`)
- `src/cartesi/hash-tree.lua:332` (sibling lookup in `frontier_next_proofs`)
- `src/cartesi/hash-tree.lua:336-340` (parent loop in `frontier_next_proofs`)

**Evidence:** The test builds a height-64 frontier whose levels 1..63 are filled, so the leaf count is 2^63-1. It then calls `frontier_next_proofs` with 3 leaf hashes. Each proof is compared with the root from `frontier_push_back` + `frontier_get_root_hash`, and each is checked with `verify_slice` and `roll_hash_up_tree`. A control case also runs: height 64 with leaf count 1023, where nothing crosses 2^63. The control passes, while all 3 proofs of the crossing case are wrong:
```
$ eval $(make -s env); lua5.4 bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua
control (leaf count 1023, height 64): OK
proof 1 target_address=0x7fffffffffffffff root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
proof 2 target_address=0x8000000000000000 root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
proof 3 target_address=0x8000000000000001 root_matches_push_back=false verify_slice=false rolled_matches_push_back=false
BUG: frontier_next_proofs produced 3/3 wrong proofs for height-64 tree when range crosses 2^63
```
(exit 1). The prover patched the two comparisons to `math.ult(index, lo)` / `math.ult(hi, index)`. With that change the same test prints all `true` and `OK`, and exits 0.

**Scenario:** A tool or validator uses the exported generic frontier API on a tree of height >= 64, for example:
- a custom accumulator;
- a frontier rebuilt from a stored proof using the `frontier(last_proof)` constructor with `target_address` near 2^63;
- a frontier built with `frontier_push_back` on large subtrees.

It then asks `frontier_next_proofs` for proofs of leaves whose range crosses index 2^63. It gets proofs that fail verification, with roots that differ from `frontier_get_root_hash`, and no error is raised.

The PRT/CMIO outputs tree used by `cartesi-machine.lua`, `prt.lua`, the Rollups Node and Dave has height 63. Its leaf indices stay below 2^63, so the honest PRT path is not affected. `frontier_forest` also rejects heights >= 63.

**Possible solution:** Make the region test unsigned in `frontier_node`:
```lua
if math.ult(index, lo) then return frontier_entry
elseif math.ult(hi, index) then return pristine_entry
else return active[index - lo + 1] end
```
`active[index - lo + 1]` is already correct under two's-complement wrap-around. The `for p = parents_base, (base + #active - 1) >> 1` loop also runs correctly, because both bounds come from logical shifts and so are below 2^63. If supporting heights above 64 is not intended, `frontier_next_proofs` should instead assert `log2_max_leaves < 64`, or `leaf_count + next_output_count - 1` must not wrap.

**Severity:** low. All reviewers agree. The API silently returns a wrong result, but only for trees of height >= 64 holding about 2^63 leaves. No CLI, PRT, Rollups or Dave path can reach that, because the outputs tree has height 63. Getting there in practice also needs a hand-built or reconstructed frontier.

**Risks:**
- Of the bug: a third-party tool using the generic frontier API on a tall tree gets unverifiable proofs or a wrong root without any error. If such a root were committed, it would not match an independently computed root.
- Of the fix: minimal. For indices below 2^63, `math.ult` behaves exactly like the signed comparison, so results for the height-63 outputs tree and for every existing caller stay the same.

**Proof of concept:** `bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-13-next-proofs-signed-compare-ge64/test_next_proofs_ge64.lua`. It needs no machine images. It exits 1 and prints `BUG:` while the bug is present, and prints `OK` (exit 0) once fixed.

**ID**: `lua-13-next-proofs-signed-compare-ge64`

**Related**: [B22](#b22-frontier_pad_back-rejects-valid-counts-and-corrupts-very-tall-frontiers).

### B22. frontier_pad_back rejects valid counts and corrupts very tall frontiers

**Title**: frontier_pad_back rejects valid counts >= 2^63 and corrupts the frontier when the tree is more than 64 levels above the pad height

**Problem:** `frontier_pad_back` treats `count` as an unsigned 64-bit integer. `frontier_padding_fits` uses logical shifts and scans up to `max(height, 63)`, and phase 1 compares with `math.ult`. Phase 1 also computes `local size = 1 << (level - first_level)`. In Lua a shift of 64 or more gives 0, so once the cursor is 64 or more levels above `first_level`, `math.ult(count, 0)` is false and the loop does not stop. At the next occupied level it folds `pad_hashes[level]` in, subtracts 0 from `count`, and leaves the result on the same level. The next pass sees that level occupied and folds again, so the carry runs to the top, where `assert(level < top, "too many leaves")` fires. `frontier_padding_fits` had already accepted the count, and the call has already rewritten the low levels of the frontier in place. This breaks the documented rule that a failing call changes nothing. Any remaining count >= 2^63 triggers it once the cursor reaches offset 64 and some level at offset 64 or above is occupied. That includes exactly 2^63 when the offset-63 level is empty. The call always fails with an assert. No case was found where it returns a wrong root hash.

**Origin:** pre-existing. `origin/main` has the same phase-1 code.

**Area:** Lua hash-tree frontier (`cartesi.hash-tree` module, exported as `frontier_pad_back`).

**Category:** correctness / error-path state corruption.

**Location:**
- `src/cartesi/hash-tree.lua:274`: `local size = 1 << (level - first_level)`, which is 0 for offsets of 64 or more
- `src/cartesi/hash-tree.lua:275`: `if math.ult(count, size) then break end`, which never breaks when `size == 0`
- `src/cartesi/hash-tree.lua:279`: `assert(level < top, "too many leaves")`, the assert that fires after the frontier has been mutated
- `src/cartesi/hash-tree.lua:144` (`frontier_padding_fits`) and `:262`: the fits check that accepts the count

**Evidence:** The test builds `frontier(66)` holding one height-65 subtree and pads it with `count = -1` (2^64-1 unsigned; 2^65 + 2^64 - 1 < 2^66, so it fits). It then builds `frontier(70)` holding one height-65 subtree and pads it with `1 << 63`. Each case is compared with the same padding done as two smaller calls, which succeed.
```
$ eval $(make -s env); lua5.4 bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua
single-call pad_back(2^64-1):	false	.../src/cartesi/hash-tree.lua:279: too many leaves
BUG: frontier_pad_back rejected a fitting count 2^64-1 in a height-66 tree: ...:279: too many leaves
BUG: the failing frontier_pad_back call mutated the frontier
height-70 pad_back(2^63):	false	.../src/cartesi/hash-tree.lua:279: too many leaves
BUG: height-70 frontier_pad_back rejected fitting count 2^63: ...:279: too many leaves
BUG: the failing call mutated the height-70 frontier
exit=1
```
With the fix below applied to a copy of `hash-tree.lua`, both cases succeed and match the split-call roots (`OK`, exit 0).

**Scenario:** A validator other than the shipped node uses the public `cartesi.hash-tree` API to build a tall frontier, for example over the PRT computation tree, which is 24+48+20 = 92 levels. It pads in one call with a large unsigned-wrapped count (>= 2^63, a negative Lua integer). It gets a spurious "too many leaves" error. If it catches the error with `pcall` and keeps the frontier, it continues from a partly rewritten frontier, and later roots or proofs built from that frontier are wrong. Shipped callers are not affected. The PRT node uses `frontier_forest_pad_back`, which rejects negative counts. The `cartesi-machine` CLI calls `frontier_pad_back` (`src/cartesi-machine.lua` around lines 4036, 4104, 4159, 4198) only with small per-input, per-bundle or per-period counts. Output trees are 63 levels or shorter, where this path cannot run. Padding to the root uses `count = nil`, which takes a separate path that works.

**Possible solution:** In phase 1, break out of the loop when `level - first_level >= 64`. A count below 2^64 can never need a pad subtree of 2^64 or more entries. Phase 2 already handles `size == 0` correctly, because `count & 0 == 0`. A more general option is to validate everything first, or to work on a copy and commit only on success, so that no failing path leaves the frontier changed.

**Severity:** low. Both reviewers and the prover agree. Triggering it takes a frontier more than 64 levels above the pad height and a single pad count of 2^63 or more passed as a wrapped negative integer. No shipped caller does this. The failure is always loud and never yields a wrong or nondeterministic hash. The only lasting harm is a frontier mutated by a rejected call.

**Risks:** Bug: a caller that recovers from the error and keeps using the frontier works from corrupted state, which could produce wrong roots. Fix: very low. The early break only affects offsets of 64 or more, where `size` was already meaningless, and phase 2 places the remaining bits as before. Results for counts below 2^63 or for frontiers of height 64 or less do not change.

**Proof of concept:** `bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua`. It exits 1 while the bug is present and prints `OK` once fixed. Run from the repo root:
`eval $(make -s env); lua5.4 bugs/lua-14-pad-back-tall-tree-size-wrap/test-pad-back-tall-tree.lua`

**ID**: `lua-14-pad-back-tall-tree-size-wrap`

**Related**: [B21](#b21-frontier_next_proofs-is-wrong-on-trees-of-height-64-or-more).

### B23. JSON-RPC protocol version not bumped for the new clear_hash_tree API

**Title**: JSON-RPC protocol version left at 0.8 although the branch adds `machine.clear_hash_tree` and `runtime_config.clear_hash_tree`

**Problem:** The branch adds a new RPC method, `machine.clear_hash_tree`, and a new runtime-config field, `clear_hash_tree`, to the JSON-RPC protocol. It does not bump the protocol version, which stays at 0.8.0, the value shipped in v0.22.0.

The client's handshake only requires the server to have the same major.minor. So a branch client accepts an older (main / v0.22.0) `cartesi-jsonrpc-machine`. That server parses `machine_runtime_config` by reading only the fields it knows, so it drops `clear_hash_tree=true` without an error. As a result:
- `create`/`load` with `{clear_hash_tree=true}` succeeds, but the cached hash tree is never cleared;
- `get_runtime_config().clear_hash_tree` returns `false`;
- an explicit `clear_hash_tree()` fails only later, with a method-not-found error.

The version handshake exists to catch exactly this kind of mismatch, and here it does not.

**Origin:** Introduced by this branch. The new method and field were added, but `src/jsonrpc-version.hpp` is unchanged from `origin/main`.

**Area:** JSON-RPC client/server version handshake (`cartesi.jsonrpc` Lua module, C API `cm_jsonrpc_*`, `cartesi-jsonrpc-machine`).

**Category:** API contract / version compatibility.

**Location:**
- `src/jsonrpc-version.hpp:24-26`: `JSONRPC_VERSION_MAJOR/MINOR/PATCH = 0/8/0`, not bumped.
- `src/jsonrpc-machine.cpp:407-414`: `check_server_version` compares only major/minor; called at lines 430 and 559.
- `src/json-util.cpp:1130-1140`: `ju_get_opt_field(..., machine_runtime_config&)` reads only known keys and ignores unknown ones. This is how the older server drops the field.
- `src/jsonrpc-remote-machine.cpp:1285-1294,1856`: the new `machine.clear_hash_tree` handler. Client side: `src/jsonrpc-machine.cpp:908-911`.
- `src/json-util.cpp:1139,2583`, `src/machine-runtime-config.hpp:88`, `src/machine.cpp:316`: the new runtime field.

**Evidence:** `run.sh` builds `cartesi-jsonrpc-machine` from `git archive origin/main`, then runs the branch Lua client against it. Run from the repo root with `eval $(make -s env); bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh`:
```
client library version:	0.22.0
handshake accepted, server protocol version 0.8.0
create({...}, {clear_hash_tree=true}) succeeded; get_runtime_config().clear_hash_tree =	false
BUG: runtime option clear_hash_tree=true silently ignored by a server that passed the version handshake
clear_hash_tree() failed only now: .../test.lua:55: machine.clear_hash_tree
BUG: client accepted a server (same protocol 0.8) that does not implement machine.clear_hash_tree
exit=1
```
Control run against the branch server (`CARTESI_JSONRPC_MACHINE=src/cartesi-jsonrpc-machine`): `clear_hash_tree = true`, exit 0.

**Scenario:** An operator of a PRT validator (Rollups Node, Dave or a custom node) upgrades the emulator library or Lua client but keeps an older `cartesi-jsonrpc-machine` binary or container image, for example in a split client/server deployment. The node spawns or connects to the server and passes `clear_hash_tree=true` on `create`/`load` to throw away a possibly stale or untrusted cached hash tree. The handshake succeeds and the option is silently skipped, so the node keeps working from the cached tree. If the node only calls `clear_hash_tree()` later, it gets a "method not found" error in the middle of a run instead of a clear incompatibility error at connect time.

Two things limit the impact:
- an older server cannot load machines stored by the branch (config archive version 8 vs 9), so the silent skip mostly affects `create`, or machines stored by the older server itself;
- skipping the clear only gives a wrong hash if the on-disk cache is actually stale or corrupted.

**Possible solution:** Bump `JSONRPC_VERSION_MINOR` to 9 in `src/jsonrpc-version.hpp`, with a CHANGELOG line ("Bumped JSON-RPC protocol version to 0.9.0"), as v0.21.0 and v0.22.0 did, so the handshake rejects older servers. As defence in depth, the server could also reject unknown keys in `runtime_config` (and other config objects) rather than ignoring them.

**Severity:** Low. Both reviewers agree. It needs a newer client paired with an older server, and its only direct effect is a skipped defensive hash-tree clear plus a late method-not-found error. No hash or proof is computed incorrectly unless the cached tree is already bad. The fix is a one-line version bump, which may already be planned for release, since the library version is also still 0.22.0 and the branch is "Unreleased".

**Risks:**
- Bug: in a mixed-version deployment, a validator that relies on `clear_hash_tree=true` to distrust a cached tree silently keeps using it. A corrupted cache could then produce wrong root hashes or proofs, and the honest player could lose a dispute.
- Bug: it also hides version skew that could break other new behaviour later.
- Fix: bumping the minor version makes 0.22.x servers and newer clients refuse each other at connect time. That is the intended outcome, but deployments that mix versions must upgrade both sides together.
- Fix: strict rejection of unknown config keys would break clients that send extra or forward-compatible fields.

**Proof of concept:** `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/test.lua` (Lua client test, which needs `CARTESI_JSONRPC_MACHINE` to point at an old server) and `bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh` (the driver). The driver builds the old server once from `origin/main` into `${OLD_BUILD_DIR:-${TMPDIR:-/tmp}/rpc-04-old-server}`, which takes a few minutes; set `CARTESI_JSONRPC_MACHINE` to reuse an existing old binary and skip the build. Run from the repo root:
```
eval $(make -s env); bugs/rpc-04-jsonrpc-protocol-version-not-bumped/run.sh
```
Exit code 1 means the bug reproduced. Exit code 0 means it is fixed: the handshake rejects the old server, or the option is honoured.

**ID**: `rpc-04-jsonrpc-protocol-version-not-bumped`

**Related**: [B26](#b26---clear-hash-tree-is-silently-ignored-for-existing-remote-machines).

### B24. Temporary and frontier files are created with mode 0600 and without atomic O_CLOEXEC

**Title**: Frontier files from `hash_tree.frontier_store` and `frontier_forest_store`, including the CLI's `outputs_frontier` and computation `frontier` files, are created 0600 and ignore umask

**Problem:** `cartesi.hash-tree` writes its files through a local `write_file` helper. The helper creates a temporary file with `fs.new_temporary_file`, then syncs it and renames it over the target. `fs.new_temporary_file` calls `os::create_temporary_file`, which creates the file with `mkstemp` on POSIX (always 0600) or with `S_IRUSR|S_IWUSR` on Windows. `open_temporary_file` never calls `fchmod`, so every file this path writes is owner-only, whatever the umask is. Because the temporary file is renamed over the target, an existing 0644 file is also replaced by a 0600 one, and its mode is lost. On `main`, the CLI's `store_frontier` used `util.write_file` (`io.open`, mode 0666 & ~umask). It now calls `hash_tree.frontier_store`. As a result the CLI's `outputs_frontier` and `--mcycle-computation-hash=...,frontier:` files are 0600, while `state_hash`, `output_hashes` and the other epoch files written next to them stay 0644. Elsewhere `os-filesystem.cpp` creates files with `S_CREATE_FILE` (0644 before umask), so 0600 here is inconsistent with the rest of the code. It looks like an accidental side effect of switching to atomic writes, not a chosen contract.

**Origin:** Introduced by this branch. `os::create_temporary_file`, `fs.new_temporary_file`, `hash_tree.frontier_store`, `frontier_forest_store` and the hash-tree `write_file` are all new. The CLI change from `util.write_file` to `hash_tree.frontier_store` is in the branch diff.

**Area:** The `cartesi-machine` CLI's resumable epoch files, and the Lua library `cartesi.hash-tree` (`frontier_store`, `frontier_forest_store` and stored-tree files). The underlying `os::create_temporary_file` / `cartesi.filesystem.new_temporary_file` is also affected.

**Category:** API contract / file permissions (operational regression).

**Location:**
- `src/os-filesystem.cpp:647-663` (`open_temporary_file`: no `fchmod`)
- `src/os-filesystem.cpp:665-692` (`create_temporary_file`: `mkstemp` at 687, `S_IRUSR | S_IWUSR` at 676 on Windows)
- `src/cartesi/filesystem.lua:66-67` (`new_temporary_file`)
- `src/cartesi/hash-tree.lua:509-514` (`write_file`), callers at 592 (stored trees), 935-936 (`frontier_store`) and 967-988 (`frontier_forest_store`)
- `src/cartesi-machine.lua:3274-3277` (`store_frontier`), called at 3283 (`outputs_frontier`) and 4109 (computation `frontier`)

**Evidence:** `test_frontier_file_mode.lua` runs itself under `umask 022`. It writes a baseline file with `fs.write_file` and checks the mode of files written by `hash_tree.frontier_store` (to a new file and over an existing 0644 file) and by `frontier_forest_store`. It also runs the real CLI with `resumable:true` epoch files and a computation-hash `frontier`:
```
$ eval $(make -s env); lua5.4 bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua
fs.write_file (baseline)                                     mode 644 (expected 644)
hash_tree.frontier_store, new file                           mode 600 (expected 644)
hash_tree.frontier_store, overwriting existing 0644 file     mode 600 (expected 644)
hash_tree.frontier_forest_store, frontier file               mode 600 (expected 644)
hash_tree.frontier_forest_store, tree file 0x0aa7d3e8df...   mode 600 (expected 644)
CLI state_hash file                                          mode 644 (expected 644)
CLI output_hashes file                                       mode 644 (expected 644)
CLI outputs_frontier file                                    mode 600 (expected 644)
CLI computation frontier file                                mode 600 (expected 644)
...
BUG: frontier files are created mode 0600 (mkstemp) instead of honoring umask like other output files
```
The test exits 1 while the bug is present.

**Scenario:** A deployment runs `cartesi-machine` with resumable epoch files (`--cmio-advance-state=...,resumable:true,outputs_frontier:...` and/or `--mcycle-computation-hash=...,frontier:...`) as one uid. Another process reads them as a different uid, for example a sidecar container, a monitoring or verification tool, or a later run under a different service account on a shared volume. After the upgrade, the reader gets `EACCES` on the frontier files but can still read `state_hash`, so resuming or verifying the epoch fails. Lua tools that persist `hash_tree` frontiers or forests for a separate reader hit the same failure. An existing file that an operator deliberately made group- or world-readable silently becomes 0600 on its next rewrite. Hashes, proofs and determinism are not affected. The Rollups Node and Dave use the C API, which does not go through this path.

**Possible solution:** Give the temporary file the permissions a normal create would have before it is renamed. In `os::create_temporary_file` (or `open_temporary_file`), call `fchmod(fd, S_CREATE_FILE & ~current_umask)` or `0666 & ~umask`. The umask can be read with `m = umask(0); umask(m)` (not thread-safe, so read it once or under a lock) or from `/proc/self/status`. Alternatively, when the destination already exists, copy its mode with `fstat` + `fchmod`, so the rename keeps the original permissions. Fixing it in the C++ helper covers every caller (`frontier_store`, forest store, stored trees and any user of `fs.new_temporary_file`). If some caller does need private temporary files, add an explicit mode parameter instead of relying on mkstemp's default.

**Severity:** Low. Both reviewers agree. It is a real regression new on this branch, but it only affects operations. It needs a multi-uid deployment, fails loudly with `EACCES` rather than corrupting data, can be worked around with `chmod`/umask/uid changes, and cannot change any hash or proof or make an honest player lose a dispute.

**Risks:** Of the bug: resumable-epoch workflows split across users or containers break after the upgrade, and operator-set permissions on existing frontier files are silently narrowed. Of the fix: reading the umask with `umask()` is process-global and racy in multithreaded hosts, so it should be read once or replaced by a mode taken from the destination. Making the files readable again (0644) is the old behaviour and exposes only public hash data. Any caller that relies on `new_temporary_file` for private scratch files would need an opt-in private mode.

**Proof of concept:** `bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua` (self-contained; it re-executes itself under `umask 022`, creates its own temporary directory and small machine, and needs `cartesi-machine.lua` on `PATH`). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/rpc-07-frontier-files-mode-0600/test_frontier_file_mode.lua
```
Exit code 1 means the bug is present; it prints `OK: all files honor umask` and exits 0 once fixed.

**ID**: `rpc-07-frontier-files-mode-0600`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `lua-23-temp-file-cloexec-race-and-mode`: run with `eval $(make -s env); sh bugs/lua-23-temp-file-cloexec-race-and-mode/run.sh`. It also shows that `os::create_temporary_file` gets its fd from `mkstemp` without `O_CLOEXEC` and sets `FD_CLOEXEC` with a later `fcntl`, so a fork and exec on another thread in between inherits the fd. Use `mkostemp(..., O_CLOEXEC)` and `fchmod` to `0666 & ~umask`.

### B25. --clear-hash-tree is reapplied on every stored-mode revert

**Title**: `--clear-hash-tree` is reapplied on every `--revert-mode=stored` snapshot/revert reload, forcing a full-machine rehash per input

**Problem:** The help text says `--clear-hash-tree` clears cached hash-tree data once, "after creating or loading the machine". In practice the CLI puts the flag into the single shared `runtime_config` table (`clear_hash_tree = cmdline.clear_hash_tree`), and that same table goes to `new_revert_stored(machine, dir, runtime_config)`, which keeps it as `self.runtime_config`. Both `revert_stored:snapshot()` and `revert_stored:revert()` reload the machine with `m:load(self.machine_directory, self.runtime_config, cartesi.SHARING_ALL)`. The machine constructor calls `clear_hash_tree()` whenever `m_r.clear_hash_tree` is set. The result is that the tree is cleared at create/load, again in the setup snapshot inside `new_revert_stored`, and again at every per-input snapshot (advance and inspect) and every revert. Each of those clears throws away a hash tree the CLI has just synced to disk and marks every page dirty, so the next `get_root_hash` rehashes all of RAM and the flash drives.

**Origin:** Introduced by this branch. `--clear-hash-tree` and the `clear_hash_tree` runtime-config field do not exist on `origin/main`.

**Area:** `cartesi-machine` CLI (stored revert mode).

**Category:** Correctness (option applied far more often than specified), with a performance impact. Hashes stay correct.

**Location:**
- `src/cartesi-machine.lua:2809`: `runtime_config = { ..., clear_hash_tree = cmdline.clear_hash_tree }` (one shared table)
- `src/cartesi-machine.lua:3723-3732`: `revert_stored:snapshot()` reloads with `self.runtime_config`
- `src/cartesi-machine.lua:3744-3751`: `revert_stored:revert()` reloads with `self.runtime_config`
- `src/cartesi-machine.lua:3762-3770`: `new_revert_stored` keeps the table and takes a setup snapshot
- `src/cartesi-machine.lua:3779`: `new_revert_stored(machine, ..., runtime_config)` gets the shared table
- `src/cartesi-machine.lua:4476`, `4514`: per-input `backup:snapshot()`, advance and inspect
- `src/machine.cpp:316-318`: the constructor clears the tree whenever `m_r.clear_hash_tree` is set

**Evidence:** `wrapper.lua` patches the shared machine metatable to count `create`/`load` calls whose runtime config has `clear_hash_tree=true`. It does not change their behavior. After each `get_root_hash` it adds up `get_hash_tree_stats(true).phtc.page_changes`. It then runs the real CLI with `--ram-length=64Mi --create=DIR --revert-mode=stored --cmio-advance-state=...` and 3 inputs (`ioctl-echo-loop`), once with and once without `--clear-hash-tree`. Run with `eval $(make -s env); lua5.4 bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua`:
```
no-clear:        creates=1(clearing 0) loads=4(clearing 0) get_root_hash=4 pages_rehashed=107791 time=10s
--clear-hash-tree: creates=1(clearing 1) loads=4(clearing 4) get_root_hash=4 pages_rehashed=323269 time=16s
hash-tree clears: 5 (expected 1); extra pages rehashed vs no-clear: 215478
BUG: --clear-hash-tree cleared the hash tree 5 times (4 stored-revert reloads with clear_hash_tree=true for 3 inputs), rehashing 215478 extra pages (3.0x the no-clear run)
```
The test exits 1. The extra cost grows linearly with the number of inputs and with machine size.

**Scenario:** An operator suspects a corrupted cached tree and runs a rollup epoch through the CLI with `cartesi-machine --load=m,sharing:all --revert-mode=stored --clear-hash-tree --cmio-advance-state=...` on a GiB-sized machine. Instead of one rebuild, every input (and every rejected-input revert) pays a full-machine rehash. A long epoch can then take far longer than expected and miss tooling or operational deadlines. Validator nodes that use the C/Lua API directly (Rollups Node, Dave, the PRT node) set `clear_hash_tree` in their own runtime config, so they control when it applies. Hashes, proofs and stored state stay correct.

**Possible solution:** Give `new_revert_stored` a copy of `runtime_config` with `clear_hash_tree = false`, or clear the field in the shared table right after the initial create/load. Snapshot and revert reloads should never re-apply a one-shot recovery action. The same pattern is worth keeping in mind for any future one-shot runtime flag.

**Severity:** Low. Both reviewers agree: it only happens in the CLI, only when the user opts into `--clear-hash-tree` together with `--revert-mode=stored`, and the only effect is wasted rehashing. Results stay correct and deterministic, nothing crashes, and C API validator nodes are not affected.

**Risks:** Bug: large slowdowns per input on big machines, and avoidable disk and CPU load during long epochs. Fix: minimal. Removing the flag from reload configs keeps the documented single clear. Any code that relies on the field still being set in `runtime_config` after setup would need to read `cmdline.clear_hash_tree` instead.

**Proof of concept:** `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua` (driver) and `bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/wrapper.lua` (instrumented CLI launcher, used by the driver). Run from the repo root: `eval $(make -s env); lua5.4 bugs/rpc-08-clear-hash-tree-reapplied-every-stored-revert/test_clear_hash_tree_stored_revert.lua`. It needs the default kernel/rootfs images (`CARTESI_IMAGES_PATH`) and takes about 30 s. It finds the CLI via `$CARTESI_MACHINE_CLI` or `cartesi-machine.lua` on `LUA_PATH`. Exit 1 with `BUG:` means the bug is present; exit 0 means it is fixed.

**ID**: `rpc-08-clear-hash-tree-reapplied-every-stored-revert`

### B26. --clear-hash-tree is silently ignored for existing remote machines

**Title**: `cartesi-machine` silently ignores `--clear-hash-tree` (and other runtime options) with `--remote-address --no-remote-create` and no `--load`

**Problem**: The CLI applies `runtime_config` only by passing it to `main_machine:load(...)` or `main_machine:create(...)`. That includes `clear_hash_tree`, which this branch adds. When the CLI attaches to an existing remote machine (`--remote-address=X --no-remote-create`, with no `--load`), it calls neither one. As a result `--clear-hash-tree` is accepted with no error or warning and does nothing. The machine already has an API that would do the job (`machine:clear_hash_tree()` in Lua, C and JSON-RPC), but the CLI never calls it. The CLI already rejects a similar meaningless combination, `--create` with `--no-remote-create`, but not this one. The other runtime options (`--concurrency=update_hash_tree:N`, console options, `--skip-version-check`, `--no-reserve`) are dropped the same way on this path. That part predates the branch.

**Origin**: Introduced by this branch (the `--clear-hash-tree` option and the `clear_hash_tree` runtime field). The underlying pattern of dropping runtime options on this path already existed.

**Area**: `cartesi-machine` CLI

**Category**: api-contract (option silently ignored)

**Location**:
- `src/cartesi-machine.lua:2802-2810`: `runtime_config` is built, including `clear_hash_tree = cmdline.clear_hash_tree`
- `src/cartesi-machine.lua:2978-2982`: only `load` receives it, and the `elseif not (cmdline.remote_address and not cmdline.remote_create)` branch skips the existing-remote case
- `src/cartesi-machine.lua:3111`: only `create` receives it
- `src/cartesi-machine.lua:2819-2823`: the assert that rejects `--create` with `--no-remote-create` (there is no equivalent check for runtime-only options)
- `src/cartesi-machine.lua:715, 2127-2129`: option help and parsing
- `src/machine.cpp:316`: `clear_hash_tree` is honoured only while the machine is being constructed

**Evidence**: The test spawns a JSON-RPC server, creates a 1 MiB machine on it, fills the hash tree and resets `get_hash_tree_stats`. It then runs the CLI against that machine with `--remote-address=X --no-remote-create --no-remote-destroy --clear-hash-tree --max-mcycle=0 --final-hash`. The CLI exits 0, yet the remote machine shows 0 page rehashes both during the CLI run and on the next `get_root_hash`. An explicit `clear_hash_tree()` causes 2058 page rehashes. Run command: `eval $(make -s env); lua5.4 bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`
```
running: timeout 60 cartesi-machine.lua --remote-address=127.0.0.1:34253 --no-remote-create --no-remote-destroy --clear-hash-tree --max-mcycle=0 --final-hash 2>&1
Connected to JSONRPC remote cartesi machine at '127.0.0.1:34253'
0: 0xebef64772f7de7c9adf654590cc6e7dbc055380b6f786700465cc753710f27ad
Left alive JSONRPC remote cartesi machine at '127.0.0.1:34253'
CLI exit:	true	exit	0
page_misses during CLI run:	0	sparse_node_hashes:	0
page_misses on next root hash:	0
reference page_misses after explicit clear_hash_tree():	2058
BUG: CLI accepted --clear-hash-tree with --no-remote-create and exited successfully, but the remote machine's hash tree was never cleared (0 page rehashes vs 2058 after a real clear)
```

**Scenario**: An operator suspects that the cached hash tree of a long-running remote machine is corrupted, for example after a crash or after some other hash-tree bug. They run `cartesi-machine --remote-address=X --no-remote-create --clear-hash-tree --final-hash` to get a hash computed from scratch. The CLI succeeds and prints the hash from the same cache they distrust, so they wrongly conclude that the cached state is sound. Validator nodes (Rollups Node, Dave, the PRT node) that use the C/Lua/JSON-RPC APIs directly are not affected, because they call `clear_hash_tree()` or pass the runtime config themselves.

**Possible solution**: On the existing-remote path (`cmdline.remote_address and not cmdline.remote_create and not cmdline.load_dir`), call `main_machine:clear_hash_tree()` when `cmdline.clear_hash_tree` is set. For the runtime options that cannot be applied to an already constructed machine (console, `no_reserve`, `skip_version_check`, concurrency), either assert or print a warning, in the same way `--create` with `--no-remote-create` is already rejected.

**Severity**: Low. Both reviewers agree. The defect is limited to the CLI on a narrow path. No C, Lua or JSON-RPC API is affected, honest-machine hashes and proofs do not change, and nothing crashes or hangs. The only harm is false confidence in exactly the situation where an operator suspects a corrupted cache. The help text ("after creating or loading the machine") arguably limits the scope already, but the CLI still accepts the flag without telling the user.

**Risks**: *Bug*: an operator gets an unverified hash, or skips a recovery step, while believing the cache was rebuilt, and other runtime flags are silently dropped on the same path. *Fix*: calling `clear_hash_tree()` on a large remote machine makes the next root-hash computation expensive, but that is the requested behaviour. Asserting on runtime-only options could break existing scripts that pass them by habit together with `--no-remote-create`, so a warning is the safer choice for the options other than `--clear-hash-tree`.

**Proof of concept**: `bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/rpc-09-clear-hash-tree-ignored-existing-remote/test_clear_hash_tree_existing_remote.lua`. It exits 1 and prints `BUG:` while the bug is present. It exits 0 if the CLI clears the tree or rejects the combination. It needs `cartesi-machine.lua` on `PATH`, which `make -s env` sets up.

**ID**: `rpc-09-clear-hash-tree-ignored-existing-remote`

**Related**: [B23](#b23-json-rpc-protocol-version-not-bumped-for-the-new-clear_hash_tree-api).

### B27. --dump-memory-ranges runs mkdir through the shell with an unquoted path

**Title**: `--dump-memory-ranges` passes the directory name unquoted to a shell `mkdir` (word splitting crashes the CLI, shell metacharacters run commands)

**Problem:** `dump_memory_ranges` in the `cartesi-machine` CLI creates the output directory with `os.execute("mkdir " .. dir)`. Here `dir` is the user-supplied value of `--dump-memory-ranges=<dir>`, and it is passed to `/bin/sh` without quoting. A name that contains spaces is split into several words: `mkdir` creates several unrelated directories and reports success. The next `fs.write_file("<dir>/<start>--<length>.bin")` then fails, and the CLI aborts with a Lua traceback before it dumps anything. Shell metacharacters in the name (`;`, `$(...)`, backticks, `&&`) are executed as commands. Separately, an existing directory makes `mkdir` fail, and the `assertf` aborts the run.

**Origin:** Pre-existing. `origin/main` has the same `os.execute` line, at `src/cartesi-machine.lua:3596`. This branch touched the function only to replace `util.write_file` with `fs.write_file`.

**Area:** `cartesi-machine` CLI (`--dump-memory-ranges`).

**Category:** Correctness / shell command injection (local input).

**Location:**
- `src/cartesi-machine.lua:3599-3601` (`dump_memory_ranges`, `assertf(os.execute("mkdir " .. dir), ...)`)
- `src/cartesi-machine.lua:3606` (`fs.write_file` that then fails)
- `src/cartesi/filesystem.lua:28` (`filesystem.create_directory`, a safe alternative that is already available; `fs` is required at `src/cartesi-machine.lua:2677`)

**Evidence:** The test runs the real CLI twice (`--ram-length=32Mi --max-mcycle=0`), first with `--dump-memory-ranges=<tmp>/dm x` and then with `--dump-memory-ranges=<tmp>/d2;touch <tmp>/INJECTED`:
```
$ eval $(make -s env); lua5.4 bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua
BUG: --dump-memory-ranges='/tmp/tmp.zrloBehyMk/run/dm x' exit_ok=nil dumped=false stray_dirs(dm/x)=true
  lua5.4: /home/user/machine-emulator/src/cartesi/filesystem.lua:92: /tmp/tmp.zrloBehyMk/run/dm x/0000000000000000--0000000000008000.bin: No such file or directory
  stack traceback:
BUG: shell command injected through --dump-memory-ranges: file INJECTED was created by 'touch'
exit=1
```
After the run, the work directory contains the stray directories `dm`, `x` and `d2`, plus the injected file `INJECTED`.

**Scenario:** A developer or a CI script dumps memory ranges for debugging into a path with a space in it, such as a macOS-style `~/My Dumps` or a generated name. The run crashes after the machine has finished, leaves stray directories behind and produces no dump. A wrapper script or tool that builds the directory name from untrusted data, such as an application name, an input ID or a tournament label, and forwards it to `cartesi-machine` gives that data arbitrary shell command execution as the invoking user. Emulator C/Lua APIs, validator nodes, hashes and proofs are not affected.

**Possible solution:** Replace the shell call with the library function, e.g. `fs.create_directory(dir)` (`cartesi.filesystem.create_directory`). Optionally tolerate an already existing directory, or report a clear error for it. Do not build shell strings from user input. If a shell is unavoidable, single-quote `dir` and escape embedded single quotes.

**Severity:** Low. Both reviewers agreed: only a CLI debugging option is affected, and the input comes from the local user (injection matters only if a wrapper forwards untrusted names). Validators, emulator APIs, hashes, proofs and guest applications are not affected.

**Risks:** Bug: failed dumps and stray directories. Also local command execution if a script passes untrusted directory names through. Fix: minimal. `create_directory` fails on an existing directory just as `mkdir` does today, so behavior for valid names is unchanged. If the fix also makes existing directories acceptable, files with the same names would be overwritten.

**Proof of concept:** `bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/rpc-10-dump-memory-ranges-shell-mkdir/test_dump_memory_ranges_mkdir.lua
```
It uses a fresh `mktemp -d` work directory, or the directory given as the first argument. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK` once it is fixed.

**ID**: `rpc-10-dump-memory-ranges-shell-mkdir`

### B28. get_data_root_hash returns nil for empty data and rejects root sizes 63 and 64

**Title**: Lua `get_data_root_hash` returns nil for empty data, rejects `log2_root_size` 63/64 (shift overflow), and accepts sizes below a word

**Problem**: `cartesi.hash-tree.get_data_root_hash(data, log2_root_size)` has three defects:
1. **Empty data.** With `data == ""`, level 0 gets no entries, so the pairing loop `for i = 1, #level, 2` never runs. Every level stays `{}` and the function returns `level[1] == nil`. The function's own contract says "the data need not fill the tree" and that untouched nodes take the pristine hash, so it should return the pristine subtree root. That is the same value as `get_data_root_hash(zeros(2^n), n)` and the same value the machine reports for an untouched region.
2. **Shift overflow.** The guard `#data <= (1 << log2_root_size)` uses Lua's 64-bit integers. `1 << 63` is `math.mininteger` and `1 << 64` is `0`, so any non-empty data is rejected with "data does not fit in the tree" at log2 63 or 64. 64 is the machine's root size.
3. **No lower bound.** For `log2_root_size < WORD_LOG2_SIZE` (5, i.e. 32-byte words), the level loop does not run. The function silently returns the zero-padded full-word hash, for example `("a", 0)` and `("abcd", 2)`, instead of rejecting a size smaller than any proof target.

**Origin**: Pre-existing. The function body is the same on `origin/main`; the branch changes other parts of `hash-tree.lua` (the forest storage) but not this function.

**Area**: Lua hash-tree library (`cartesi.hash-tree`), used by off-chain verifiers of input/output regions.

**Category**: correctness (wrong result on an edge input, and integer overflow in a bounds check).

**Location**:
- `src/cartesi/hash-tree.lua:46-69` (`get_data_root_hash`)
- `src/cartesi/hash-tree.lua:48` (overflowing fit guard)
- `src/cartesi/hash-tree.lua:63-69` (level loop, with no lower bound and no empty-level handling; `return level[1]` gives nil)
- Caller example: `doc/recipes/slice-calculator-output.lua:26,36`

**Evidence**: The test computes `get_data_root_hash("", n)` and compares it with the all-zero root and with `machine:get_proof(flash_start, 12).target_hash` for an untouched 4 KiB flash drive. It also calls the function with 1-byte data at log2 63 and 64, and with sub-word sizes. Run: `eval $(make -s env); lua5.4 bugs/lua-16-get-data-root-hash-empty-nil/test.lua`
```
BUG: empty data, log2=12 returned nil, expected pristine 0x292c23a9aa1d8bea7e2435e555a4a60e379a5a35f3f452bae60121073fb6eead
BUG: verifier comparing get_data_root_hash('',12) against machine proof target fails (got nil)
BUG: 1-byte data, log2=63 rejected: .../src/cartesi/hash-tree.lua:48: data does not fit in the tree
BUG: 1-byte data, log2=64 rejected: .../src/cartesi/hash-tree.lua:48: data does not fit in the tree
BUG: log2_root_size=0 (< word) silently returns the full-word hash instead of rejecting
BUG: log2_root_size=2 (< word) silently returns the full-word hash
9 bug(s)
```
(The test exits with status 1 while the bug is present.)

**Scenario**: An application writes an empty result, or a result that starts with a NUL byte, to its output NVRAM. A Lua verifier that follows the documented recipe `doc/recipes/slice-calculator-output.lua` does `result = string.unpack("z", read_memory(output_nvram))` and gets `""`. It then calls `get_data_root_hash(result, log2_size)` and gets nil. The next step, `verify_splice` / `roll_hash_up_tree`, either fails its assertion or raises an error on `keccak256(nil, sibling)`, so an honest, correct proof is rejected or the verifier crashes. The machine's own target hash for that region is the all-zero root. A caller that hashes small data as a whole-machine root (log2 64) is wrongly rejected. The PRT C API paths are not affected: `get_root_hash`, `get_proof`, step and uarch logs, and the frontier/forest code. No on-chain hash or dispute outcome changes.

**Possible solution**: Add `assert(log2_root_size >= WORD_LOG2_SIZE and log2_root_size <= 64)`. Replace the guard with an overflow-safe form, such as `log2_root_size >= 63 or #data <= (1 << log2_root_size)`. Seed level 0 with the pristine word hash when `data` is empty (or return the pristine hash for that height), so the result is always a hash.

**Severity**: low. Both reviewers agree. This is a Lua convenience helper that is not on the PRT/C-API path. Its main failure, on empty data, fails loudly (nil, then an error) and never produces a wrong hash that would be accepted. Callers can work around it with zero-padded data, and the 63/64 and sub-word cases are rarely reached in practice.

**Risks**: Bug: Lua-based output/input verifiers reject valid proofs, or crash, for empty results. Code that hashes at the full machine size breaks. Sub-word sizes quietly give a hash that matches no proof target. Fix: low risk. Callers that relied on `nil` as an "empty" sentinel will now receive the pristine hash, and callers that passed sub-word sizes will get an error instead of a hash.

**Proof of concept**: `bugs/lua-16-get-data-root-hash-empty-nil/test.lua`. Run from the repo root: `eval $(make -s env); lua5.4 bugs/lua-16-get-data-root-hash-empty-nil/test.lua`. It needs no machine images: it builds a RAM-only machine with a flash drive.

**ID**: `lua-16-get-data-root-hash-empty-nil`

### B29. Frontier API accepts heights above the tree height and silently grows the frontier

**Title**: Lua frontier API accepts subtree and pad heights above the tree height, and non-hash `hash_type` values, then silently grows the frontier or returns the pad as the root

**Problem:** No function in the `cartesi.hash-tree` frontier API checks that a subtree or pad height is at most `log2_max_leaves` (`#frontier - 1`):
- `frontier_push_back(f, hash, height)` sets `level = height + 1`. Its only capacity check, `assert(not frontier[#frontier])`, looks at the current top level. When `height + 1 > #frontier`, the final `frontier[level] = right` writes past the end of the array. The tree silently gets taller: on a height-3 frontier, `push_back(f, x, 5)` makes `#f == 6`. After that, `frontier_get_root_hash` returns `x` and `frontier_get_leaf_count` returns 32 for a tree that holds at most 8 leaves.
- `frontier_append(..., height)` relies on `frontier_padding_fits`. When `first_level > #frontier`, the local `height = #frontier - first_level` is negative, so the capacity bits are never checked and the function returns true. `append` then calls `push_back` past the end, giving `#g == 5`.
- `frontier_get_root_hash(f, pad, pad_height)` with `pad_height >= #f - 1` runs its level loop zero times and returns `pad` itself as the root. `frontier_pad_back` has the same gap.
- `frontier_genesis` and `frontier_load` use `assert(cartesi[hash_type])`, so they accept any truthy field of the `cartesi` module, such as `"tohex"`, as a hash function.

These functions' own comments promise the opposite: "Appending past the tree capacity fails" and "Appending past the tree capacity fails before anything changes". `frontier_store` writes a frontier corrupted this way without error, but `frontier_load(path, L)` then rejects it with "frontier height does not match the expected height".

**Origin:** Pre-existing. `origin/main` has the same `frontier_push_back`, `frontier_append`, `frontier_get_root_hash` and `cartesi[hash_type]` lookups, one line earlier.

**Area:** Lua library `cartesi.hash-tree` (frontier functions).

**Category:** API contract / input validation.

**Location:**
- `src/cartesi/hash-tree.lua:144-158`: `frontier_padding_fits`, which mishandles a negative `height`
- `src/cartesi/hash-tree.lua:165-177`: `frontier_push_back`
- `src/cartesi/hash-tree.lua:186-213`: `frontier_append`
- `src/cartesi/hash-tree.lua:219-236`: `frontier_get_root_hash`
- `src/cartesi/hash-tree.lua:248-254`: `frontier_pad_back`
- `src/cartesi/hash-tree.lua:363-364`: `frontier_genesis`, the `hash_type` lookup
- `src/cartesi/hash-tree.lua:942-946`: `frontier_load`, the `hash_type` lookup and height check

**Evidence:** The test uses only the public `cartesi.hash-tree` API. Every out-of-range call succeeds, and each one corrupts the tree or returns a wrong root instead of raising an error:
```
$ eval $(make -s env); lua5.4 bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua
push_back(f,x,5) ok=	true	nil	#f=	6
BUG: frontier_push_back with height 5 > log2_max_leaves 3 grew frontier from 4 to 6 levels
BUG: after that, frontier_get_root_hash returns the pushed hash x as the root of the height-3 tree
leaf count after:	true	32
append({x},1,2,4) ok=	true	nil	#g=	5
BUG: frontier_append with height 4 > log2_max_leaves 3 grew frontier to 5 levels
BUG: frontier_get_root_hash with pad_height 6 > 3 returns the pad itself as the height-3 root
BUG: frontier accepts hash_type 'tohex' (not a hash function)
load corrupted with L=3:	false	.../hash-tree.lua:946: frontier height does not match the expected height
BUG: stored frontier cannot be reloaded with its original height (...)
exit=1
```

**Scenario:** An external validator, such as a Rollups Node or Dave component written in Lua, builds commitment or output trees with `cartesi.hash-tree`. A unit mix-up passes a height in the wrong unit, for example log2 of the bundle size in leaves where the tree counts bundles. Instead of an assertion, the node computes a silently wrong root (or the pad as the root) and a tree whose leaf count is wrong. If it persists that frontier, it cannot reload it after a restart. In-tree callers cannot reach this, because every height is bounded by construction. That covers `src/cartesi-machine.lua` (around lines 3535, 4033, 4158, 4160 and 4198) and the PRT recipes. An honest node that uses the API correctly gets correct roots.

**Possible solution:** Validate the height in `push_back`, `append`, `get_root_hash` and `pad_back`, before anything is mutated:
```lua
local h = height or 0
assert(math.type(h) == "integer" and h >= 0 and h <= #frontier - 1, "subtree height exceeds the tree height")
```
`height == #frontier - 1` must stay legal, because one subtree can fill the whole tree. In `frontier_genesis`, `frontier_load` and `frontier_forest`, accept only the supported hash types (`"keccak256"`, `"sha256"`).

**Severity:** Low. Both reviewers rated it low. It can only be triggered by a caller that breaks the precondition with an out-of-range height or a non-hash `hash_type`. No in-tree CLI or PRT path can do that, and correct use always gives correct hashes. The real cost is that such a programming error in an external validator produces silently wrong roots, or a persisted frontier that cannot be reloaded, where the documented behaviour is a clean failure.

**Risks:**
- Of the bug: a caller's mistake becomes a wrong commitment or root, or a node that cannot restart from its stored frontier, instead of an immediate error. In a fraud-proof setting, that can surface late, during a dispute.
- Of the fix: low. Valid calls are unchanged. Code that passed `height == log2_max_leaves` stays legal. Callers that relied on the silent growth were already producing wrong trees, and they will now fail loudly.

**Proof of concept:** `bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-17-frontier-height-args-unvalidated/test_frontier_height_args.lua`. It uses a temporary file from `os.tmpname()` and removes it at the end. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: frontier rejects out-of-range heights and hash types` once the bug is fixed.

**ID**: `lua-17-frontier-height-args-unvalidated`

**Related**: [B20](#b20-frontier_next_proofs-does-not-check-tree-capacity).

### B30. verify_hash_tree returns true when inner nodes or the root are corrupted

**Title**: verify_hash_tree returns true when dense inner nodes, the dense root or sparse nodes are corrupted

- **Problem**: `hash_tree::verify` is the implementation behind `cm_verify_hash_tree`, Lua `m:verify_hash_tree()` and JSON-RPC `machine.verify_hash_tree`. It checks only three things for each address range:
  1. It compares each page's recomputed Merkle hash with the dense-tree node at page level.
  2. It checks that a page or range that is actually dirty is also marked dirty.
  3. It compares the range's sparse node with its dense root.

  It never recomputes dense inner nodes from their children, and it never recomputes sparse inner nodes or the sparse root. The third check only prints `dense hash tree root does not match sparse node hash` to stderr and never sets `ret = false`. A tree whose inner nodes are stale or corrupted therefore passes, even though `get_root_hash`, `get_node_hash` and `get_proof` return wrong values. This breaks the documented contract ("True if tree is self-consistent").
- **Origin**: pre-existing. The branch only changed the cache-payload accessors inside the diagnostic branch. The print-only dense/sparse check is the same on `main`.
- **Area**: hash-tree integrity check API (`cm_verify_hash_tree`, Lua `verify_hash_tree`, JSON-RPC `machine.verify_hash_tree`).
- **Category**: correctness (false positive in an integrity check).
- **Location**:
  - `src/hash-tree.cpp:650-714`: `hash_tree::verify`. Only page-level dense nodes are recomputed (lines 662-666). The dense-root vs sparse-node mismatch at lines 707-710 prints but does not fail.
  - `src/machine.cpp:1620`: `machine::verify_hash_tree` calls `m_ht.verify` directly.
  - `src/cm.cpp:1036-1041`: `cm_verify_hash_tree`. Also `src/clua-i-machine.cpp:993` and `src/jsonrpc-remote-machine.cpp:1311`.
- **Evidence**: The test stores a machine with 1 MiB of RAM, with data written in both halves. It patches the stored hash-tree files and loads them with `sharing = "none"`. For each value it compares the result before and after `clear_hash_tree()`, which forces a full re-hash. The four patches are:
  - (A) the RAM `.dht` root node (heap index 1, byte 32);
  - (B) a dense inner node (heap index 2, byte 64), read with `get_node_hash(RAM, 19)` and also seen as the sibling in `get_proof` for the right half;
  - (C) the sparse root hash inside `hash_tree.sht`.

  In every case `verify_hash_tree()` returns true while the reported value is wrong:
  ```
  $ eval $(make -s env); timeout 120 lua5.4 bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua
  [A dense root] verify_hash_tree=true  value_before=4d05a7c1d6c16b50  recomputed=27323628b3e7e58f
  [B dense inner node hash] verify_hash_tree=true  value_before=0202020202020202  recomputed=27e1bd4ef3afd672
  [B proof sibling] verify_hash_tree=true  value_before=0202020202020202  recomputed=27e1bd4ef3afd672
  [C sparse root] verify_hash_tree=true  value_before=0303030303030303  recomputed=27323628b3e7e58f
  BUG: verify_hash_tree accepted 4 corrupted hash trees
  ```
- **Scenario**: A validator node (Rollups Node, Dave, or another PRT node) keeps a machine on disk and loads it after a crash or restart. It calls `verify_hash_tree` as a health or recovery check before it trusts the hash tree. The stored `.dht`/`.sht` files may be stale or damaged, either from disk corruption or from the crash-during-update states reported separately (ht-01, ht-03, rpc-12, rpc-14: stale dense inner nodes or a stuck sparse root). The check reports a healthy tree, so the node skips `clear_hash_tree` and then publishes wrong root hashes, proofs or step logs. Without that fix, an honest player could commit to or defend a wrong state. Applications inside the machine are not affected.
- **Possible solution**: After the leaf checks in `verify`, recompute every dense inner node from its children and compare. Then recompute the sparse inner nodes up to the root, using pristine hashes for pristine children, and compare each one with the stored value. Set `ret = false` on any mismatch. For the existing dense-root vs sparse-node branch, also set `ret = false`, but only when the range is not marked dirty, because a range that is marked dirty and not yet updated can legitimately differ. Alternatively, compare against a simulated update.
- **Severity**: low. Both reviewers rated it low (one said possibly low-to-medium), and the prover suggested medium. It is a real false positive in a public C, Lua and JSON-RPC API. But it does not produce wrong hashes by itself. The API is documented as "used only for emulator internal tests", and neither the CLI nor the in-branch PRT node calls it. It matters only to a node that relies on it after one of the separately reported corruption bugs.
- **Risks**: Bug: an operator or node that trusts the check gets a false "OK" on a corrupted tree, and wrong roots or proofs get published. That hides the corruption bugs reported separately. Fix: a full inner-node recomputation is O(size of the dense trees). That is acceptable for a diagnostic but slower than today on large machines. Failing on a dense/sparse mismatch without the dirty-range exception would give false negatives on trees that are healthy but not yet updated.
- **Proof of concept**: `bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua` patches stored hash-tree files and checks the result with the public Lua API. It uses a temporary directory, or `$WORKDIR` if that is set. It exits 1 when the bug reproduces. Run from the repo root:
  `eval $(make -s env); timeout 120 lua5.4 bugs/api-03-verify-hash-tree-misses-inner-nodes/test.lua`

**ID**: `api-03-verify-hash-tree-misses-inner-nodes`

**Reviewer note**: A separate review panel (`ht-05-verify-hash-tree-misses-inner-nodes`) reproduced the same behavior but rejected it 2 to 1, arguing that `verify_hash_tree` is meant to check dirty-page tracking rather than the whole tree. This panel confirmed it. It is listed as low so that readers can weigh both views.

**Related**: [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong), [B02](#b02-crash-in-sparse-tree-update-freezes-the-root-hash-of-a-shared-hash-tree).

### B31. A failed expansion store is never retried by later frontier_forest_store calls

**Title**: After a failed expansion store, `frontier_forest_expand_leaf` leaves the expansion only in memory, and no later `frontier_forest_store` writes it

**Problem:** `frontier_forest_expand_leaf` puts the replacement subtree in the in-memory forest (`values[index] = replacement`) before it calls `store_expansion`. If `store_expansion` raises, for example when `write_file` hits a `sync_file`, write or rename failure such as ENOSPC or EIO, the forest stays expanded in memory but the replacement's `<hash>.json` file is never written. An earlier store already put the fixed-point tree that holds the leaf, and every tree above it, in `forest.durable`. That map is keyed by the tree object, and changing the tree in place does not remove it. So on the next `frontier_forest_store`, `store_tree` returns at once at each durable top tree, and the walk never reaches the replacement. That store reports success and commits the frontier file, but the directory still lacks the expansion. This breaks the documented contract that "later expansions are stored there as well". After a reload, the leaf is opaque again.

**Origin:** introduced by this branch (new `src/cartesi/hash-tree.lua` frontier-forest persistence).

**Area:** Lua library `cartesi.hash-tree`: frontier forest persistence (`frontier_forest_expand_leaf`, `store_expansion`, `store_tree`, `frontier_forest_store`).

**Category:** durability / consistency between the in-memory and stored state after an error.

**Location:**
- `src/cartesi/hash-tree.lua:894-895`: `frontier_forest_expand_leaf` assigns `values[index] = replacement` and then calls `store_expansion(forest, replacement)`, with no rollback if that call fails.
- `src/cartesi/hash-tree.lua:578`: `store_tree` returns early with `if forest.durable[tree] ... then return end`, which hides trees below a durable tree that were never stored.
- `src/cartesi/hash-tree.lua:606-613`: `store_expansion`.
- `src/cartesi/hash-tree.lua:960-966`: the `frontier_forest_store` contract.

**Evidence:** The test builds an outer forest of height 4 from four bundle roots at height 2 and stores it. It then makes `fs.sync_file` fail once while bundle 1 (leaves 4..7) is expanded at position 4, and catches that error with `pcall`. Next it stores again, reloads the forest and queries `(5,0)`. A control run does the same steps with no injected failure.
```
$ eval $(make -s env); lua5.4 bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua
expand_leaf with injected failure:	false	...test_failed_expansion_store.lua:35: injected transient I/O error
in-memory node hash at (5,0):	0xb4f6c549a55037ee98548e37dbf8ee91322007c4a901157138bb753027104cb1
bundle tree file exists after snapshot 2:	false
reloaded node hash at (5,0):	nil	the node is below an opaque hash
control (no failure) reloaded node hash at (5,0):	0xb4f6c549a55037ee98548e37dbf8ee91322007c4a901157138bb753027104cb1
BUG: frontier_forest_store after a failed expansion store did not persist the in-memory expansion; ...
```
Exit status 1 means the bug reproduced; 0 means it is fixed. The I/O error is simulated by stubbing `fs.sync_file`, which `write_file` looks up through the shared module table on each call. Every other step uses only the public API.

**Scenario:** A validator built on `cartesi.hash-tree` (a Rollups Node, a Dave-style node or another PRT player) opens a bundle during a dispute by calling `frontier_forest_expand_leaf` on a stored forest, and hits a transient disk error such as a full disk. If the node catches the error and keeps going, as a retrying event loop would, every later snapshot succeeds. After a restart, though, the reloaded forest is opaque below that bundle, and queries and proofs there fail with "the node is below an opaque hash". The node must recompute the bundle; a node with no recompute path cannot produce the proof in time. The reference node `doc/recipes/prt.lua:1748` does not catch the error, so it crashes and on restart reopens the bundle by recomputing it, which means it is not affected. Only the second variant of the claim, where a second forest changes a durable tree through a shared reference, was not shown.

**Possible solution:** Make the expansion atomic with its store. If `store_expansion` fails, restore `values[index]` to the previous hash before re-raising (`local ok, err = pcall(store_expansion, ...); if not ok then values[index] = old; error(err, 0) end`). Another option is to store the replacement before assigning it to the tree. Or keep a list of pending expansions that the next `frontier_forest_store` retries, or mark the trees on the path as not durable so that `store_tree` descends again.

**Severity:** low. Both reviewers agreed: hashes and proofs are never wrong, `load_tree` checks every file against its hash, and nothing is corrupted. The bug needs both a transient I/O error during an expansion and a caller that swallows it, and the worst effect is that the bundle has to be recomputed after a restart.

**Risks:** Of the bug, the stored snapshot says less than the in-memory forest and nothing reports it, so a node that trusts its snapshots can lose an opened bundle across a restart and then fail to answer a dispute step if it cannot recompute it. If `sync_directory` is the call that fails, the files exist but their directory entries are never synced by a later store, which leaves a power-loss window (not tested). Of the fix, rolling back must restore the exact previous value (the raw hash), and the change must not make `store_tree` rewalk the whole durable forest on every store, which would cost time on large forests.

**Proof of concept:** `bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-20-failed-expansion-store-never-retried/test_failed_expansion_store.lua`. It uses scratch directories under `$WORKDIR`, then `$TMPDIR`, then `/tmp`, and removes them when done.

**ID**: `lua-20-failed-expansion-store-never-retried`

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files), [B12](#b12-frontier_forest_store-drops-expansions-under-single-value-fixed-point-trees).

### B32. Interrupted store or clone_stored leaves a torn page cache that loads silently and gives wrong hashes

**Title**: Interrupted store or clone_stored leaves a torn hash_tree.phtc that loads silently and gives wrong hashes

**Problem**: If `store()` or `clone_stored()` is killed while it writes `hash_tree.phtc`, the file is left full-size with a valid header and metadata but zeroed page payloads. A later load accepts it without error. The page hash-tree cache then treats the zeroed payloads as valid cached pages, and the machine silently computes wrong root hashes. Proofs and uarch cycle hashes that read the same payloads are also wrong.

Why this happens:
- `hash_tree.phtc` is the last file written (store) or copied (clone_stored). Every other file is already complete at that point.
- `os::create_file` and `os::copy_file` first `ftruncate` the file to its full length, then `pwrite` 4 KiB blocks in order. `clone_file` falls back to `copy_file` when reflink is not available, as on ext4.
- The initialized tag, the LRU and the entry metadata sit at the front of the file, so they are written first. A kill partway through leaves them valid, followed by zeros.
- At load, the `page_hash_tree_cache` constructor checks only the tag and `check_metadata()`. It never checks the payloads.
- `enqueue_hash_entry` rehashes only words that differ from the cached page. Zero words in RAM match the zeroed payload, so their leaves keep a zero hash instead of keccak(0). On an LRU eviction, a torn payload is also reused as the diff base for the page newly assigned to that entry, so the corruption spreads beyond the original hits.

A torn phtc is the only partial state that loads silently. An interruption at any earlier point leaves later files missing, and the load fails.

**Origin**: pre-existing. The write order and payload trust are in code this branch touches (store, clone_stored, page hash-tree cache).

**Area**: Hash tree persistence (page hash-tree cache, `store` / `clone_stored`, `os-filesystem`).

**Category**: Correctness / crash consistency (silent wrong state hash and proofs).

**Location**:
- `src/machine.cpp:475-482`: `store()` writes `hash_tree.sht`, then `hash_tree.phtc`, last.
- `src/machine.cpp:535-538`: `clone_stored()` clones the sht, then the phtc, last.
- `src/os-filesystem.cpp:348-390`: `create_file` (`ftruncate` to full size, then sequential `pwrite`).
- `src/os-filesystem.cpp:397-490`: `copy_file`.
- `src/os-filesystem.cpp:575+`: `clone_file`, which falls back to `copy_file` without reflink.
- `src/page-hash-tree-cache.hpp:414-455`: the constructor validates only the initialized tag and `check_metadata()`.
- `src/page-hash-tree-cache.hpp:340-375`: `enqueue_hash_entry` diffs against the untrusted cached page.

**Evidence**: The test makes no hand edits to any file. A child `lua5.4` process runs `machine:store(dir, SHARING_ALL)` or `cartesi.machine:clone_stored(src, dst)` under an `LD_PRELOAD` shim, which sends a real SIGKILL after N `pwrite()` calls to `hash_tree.phtc`. The machine has 16 MiB of RAM and the default `phtc_size` of 4096, which makes a phtc of about 50 MB. The parent then:
1. loads the directory, which succeeds;
2. writes one word per RAM page;
3. compares the root with an in-memory reference machine and with the same directory loaded with `clear_hash_tree = true`.

Output of `eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh` (default kill point 4000):
```
child store exited: nil exit 137
[store] load accepted; root on load matches reference: false
[store] root after touching pages: b2117719d1c48798bf6237ce4eaf64b6a2680eea9dd26b7fb105862d35b90269
[store] reference root           : c3b78b028e6361ae065e47902f6c753a06d8fabe221bb47a84f7f91c0767c41e
[store] same dir, clear_hash_tree: c3b78b028e6361ae065e47902f6c753a06d8fabe221bb47a84f7f91c0767c41e
BUG: [store] torn hash_tree.phtc accepted at load; machine computes a wrong root hash (clear_hash_tree rebuild matches reference)
[intact-source] root after touching pages: c3b78b028e63...c41e   (control: complete store is correct)
child clone_stored exited: nil exit 137
[clone_stored] root after touching pages: b2117719d1c4...0269
BUG: [clone_stored] torn hash_tree.phtc accepted at load; machine computes a wrong root hash (clear_hash_tree rebuild matches reference)
```
Exit status is 1.

With `KILL_AFTER_PHTC=12000`, the output starts with `[store] load accepted; root on load matches reference: true`. The root after touching pages is still wrong (`60289b49...` vs `c3b78b02...`). So the usual "load, then assert root == expected" check does not catch it.

With `VERIFY=1`, `verify_hash_tree()` returns false, but nothing calls it at load.

**Scenario**: A Rollups Node, Dave or other validator snapshots with `cm_store`, or with `cm_clone_stored` on ext4, straight into its final snapshot directory. The process is killed (OOM killer, container stop timeout, crash) during the roughly 50 MB phtc write. On restart, the node loads that directory with no error, and the root may even match the expected state hash. Then it processes inputs or bisects a dispute, and commits wrong state hashes and proofs. An honest player can lose the dispute this way, with no error anywhere.

The reference PRT node (`doc/recipes/prt.lua`) is not affected. It stores or clones into a temporary directory, then calls `sync_stored` and `rename_stored`, and deletes leftover temporary directories. However, nothing in the `cm_store` / `cm_clone_stored` API says they are not crash-atomic.

**Possible solution**: Make the phtc write all-or-nothing. Either option works:
- Write the payloads and metadata first and the initialized tag last, with an fsync before the tag write when durability is needed. A torn file then fails the tag check, or is reinitialized as empty.
- Or write and copy to a temporary name and rename it into place.

As defense in depth:
- validate the active entries' payloads at load (re-hash each page and compare with its stored page root, dropping mismatched entries), or add per-entry checksums;
- document that `store` / `clone_stored` are not atomic and that the temp-dir, `sync_stored`, `rename_stored` protocol is required.

**Severity**: high. Both reviewers agree. The impact is silent wrong state hashes and proofs, which can lose a PRT dispute, and some kill points pass the post-load root check. It is not critical because it needs both a process kill inside the phtc write window and an integrator that does not use the documented temp-dir, sync and rename protocol.

**Risks**:
- Bug: silent divergence of a validator's state hash and proofs after a realistic process kill. The only signal is `verify_hash_tree()`, which nobody calls at load and which is very noisy on stderr.
- Fix: writing the tag last only changes write order. Note that a reinitialized (empty) cache must still be consistent with the stored sht, or the sht must be rebuilt. Otherwise dropping the cache could expose other stale-hash issues. Payload validation at load costs about one page hash per active entry (4096 by default), which adds to load time. A temp-file-plus-rename approach needs care with `SHARING_ALL` mappings and with cleaning up leftover temporary files.

**Proof of concept**: `bugs/api-05-torn-phtc-silent-wrong-hash/run.sh`, `test_torn_phtc.lua` and `killshim.c`. `run.sh` builds the `LD_PRELOAD` shim into a `mktemp -d` directory and runs `test_torn_phtc.lua` with its work directory there. It needs `gcc` and `lua5.4`, and creates two phtc files of about 50 MB. The `clone_stored` case needs the temp dir on a filesystem without reflink, such as ext4, and is skipped otherwise. Optional settings: `KILL_AFTER_PHTC=<n>` sets the kill point, and `VERIFY=1` also runs `verify_hash_tree()`. Run from the repo root:
```
eval $(make -s env); sh bugs/api-05-torn-phtc-silent-wrong-hash/run.sh
```
While the bug is present it prints `BUG:` lines and exits 1. Once fixed it prints `OK: no wrong hash` and exits 0.

**ID**: `api-05-torn-phtc-silent-wrong-hash`

**Related**: [B01](#b01-persisted-page-cache-is-not-checked-against-memory-so-a-reload-yields-wrong-proofs), [B03](#b03-crash-during-hash-tree-update-makes-a-sharing_all-machine-unloadable-or-silently-wrong).

### B33. Lua bindings call luaL_error inside C++ catch handlers and leak the exception

**Title**: Lua bindings call `luaL_error` inside C++ `catch` handlers, so every failed call leaks the exception object (about 200-500 B each)

**Problem:** Many Lua bindings are function-try-blocks with this handler:
```cpp
} catch (const std::exception &e) {
    luaL_error(L, "%s", e.what());
    return 1;
}
```
Lua is built as C, so `luaL_error` raises the error with `longjmp`. Calling it inside the handler jumps straight out of the handler, which means `__cxa_end_catch` never runs. The exception object from `__cxa_allocate_exception` is never freed, and neither is anything it owns, such as the message string of a nlohmann `parse_error` or a `std::system_error`. The entry also stays on the thread's `caughtExceptions` chain. Formally this is undefined behaviour: a `longjmp` out of a handler, across frames with non-trivial destructors. Each failed call leaks memory that `collectgarbage` cannot reclaim. Most `machine` methods are not affected, because they call `cm_*`, check the returned error code and call `luaL_error` outside any handler.

**Origin:** Mixed.
- Introduced by this branch: the new `cartesi.filesystem` core module (`src/clua-cartesi-filesystem.cpp`, which is not on `origin/main`) repeats the pattern in all 8 of its functions.
- Pre-existing: the sites in `src/clua-cartesi.cpp` (the same 7 handlers exist on `origin/main`) and in `src/clua-i-machine.cpp`.

**Area:** Lua bindings. These are `cartesi.filesystem`; `cartesi.tobase64`, `frombase64`, `tohex`, `fromhex`, `tojson`, `fromjson` and `new`; and the `clua-i-machine` helpers (register-name conversion, schema dictionary, `clua_tojson`, `clua_fromjson`).

**Category:** Resource leak (unbounded native memory growth on error paths) and undefined behaviour.

**Location:**
- `src/clua-cartesi-filesystem.cpp:41-43, 49-51, 63-65, 73-75, 84-86, 105-107, 125-127, 133-135`
- `src/clua-cartesi.cpp:123-125, 135-137, 147-149, 159-161, 171-173, 181-183, 192-194` (tobase64, frombase64, tohex, fromhex, tojson, fromjson, new)
- `src/clua-i-machine.cpp:228-229` (register conversion), `605-606` (schema dictionary), `634-635` (`clua_tojson`), `650-651` (`clua_fromjson`), `1188`

**Evidence:** The test runs 200,000 failing `pcall`s per case. It measures `VmRSS` after two full GC cycles and compares against a control case that fails through `luaL_argerror`, with no C++ exception involved. The control grows by 0 KiB. The three exception paths grow linearly:
```
$ eval $(make -s env); timeout 300 lua5.4 bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua
control: cartesi.fromhex(non-string)     RSS 14432 KiB -> 14432 KiB (+0 KiB, 0.0 bytes/failed call)
cartesi.fromjson('{bad')                 RSS 15180 KiB -> 99900 KiB (+84720 KiB, 433.8 bytes/failed call)
cartesi.fromhex('zz')                    RSS 100092 KiB -> 138756 KiB (+38664 KiB, 198.0 bytes/failed call)
filesystem.create_directory(bad)         RSS 139552 KiB -> 240096 KiB (+100544 KiB, 514.8 bytes/failed call)
BUG: cartesi.fromjson('{bad') leaks ~434 bytes per failed call (...)
BUG: filesystem.create_directory(bad) leaks ~515 bytes per failed call (...)
exit=1
```
`/usr/bin/lua5.4` imports `_setjmp` and `__longjmp_chk` and does not link libstdc++, which confirms it is a C build that raises errors with `longjmp`.

**Scenario:** The leak hits a long-running Lua process that handles expected failures with `pcall`. Examples:
- a Lua PRT validator, or a JSON-RPC client script, that parses JSON or hex from counterparties that may be malformed or adversarial;
- a process that probes filesystem paths through `cartesi.filesystem`.

Such a process loses a few hundred bytes for every handled failure, and memory grows without bound. An attacker who can make a Lua validator parse many bad inputs can drive memory up slowly, at roughly 2-5 million failures per GB. Hashes, proofs and machine state are not affected. The C API that the Rollups Node and Dave use does not have this pattern, so only Lua-hosted processes are affected. The `cartesi-machine` CLI usually exits on the first error, so in practice it is not affected.

**Possible solution:** Never raise a Lua error while a C++ exception is still being handled. Two ways to do that:
- Inside the `catch`, push the message onto the Lua stack with `lua_pushstring(L, e.what())`, or copy it into a buffer the function owns. Let the handler finish normally, then call `lua_error(L)` after the `try`/`catch`.
- Factor this into a shared helper that wraps the body (for example `clua_protect(L, [&]{ ... })`), which returns a flag and calls `lua_error` after the handler.

The `cm_*` wrappers already raise errors outside any handler. Also check that no C++ object with a non-trivial destructor is still alive in the frame when `lua_error` is called. Temporaries should stay owned by Lua through `clua_push_new_managed_toclose_ptr`.

**Severity:** Low. Both reviewers rated it low. The leak is real and unbounded, but it happens only on error paths in the Lua bindings and it does not corrupt anything. Results stay correct, and memory becomes a problem only after millions of handled failures in one long-running Lua process.

**Risks:**
- Of the bug: slow memory growth, which could end in an OOM kill of a long-running Lua validator or tool fed many malformed inputs. In theory, stale `caughtExceptions` entries could also change what `std::current_exception()` or a bare `throw;` sees later.
- Of the fix: low. The change is mechanical, but it touches many bindings. The fix must keep the same error messages, which callers and tests may match on. It must also keep the message alive until `lua_error` runs (push it before leaving the handler), and it must keep the existing `catch (...)` fallbacks.

**Proof of concept:** `bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua`. Run it from the repo root:
```
eval $(make -s env); timeout 300 lua5.4 bugs/lua-22-lual-error-in-catch-leaks-exceptions/test.lua
```
It exits with 1 and prints `BUG:` lines while the leak is present. It exits with 0 and prints `OK: no per-call leak detected` once the leak is fixed.

**ID**: `lua-22-lual-error-in-catch-leaks-exceptions`

### B34. Frontier stores fail for files directly under the filesystem root

**Title**: hash-tree `frontier_store` / `frontier_forest_store` raise "unable to sync directory ''" for a file directly under `/`, after the file has already been replaced

**Problem**: `get_parent_directory(path)` is `path:match("^(.*)/[^/]*$") or "."`. For a path directly under the root, such as `/frontier.json`, the capture is `""`, not `"/"`. In Lua `""` is truthy, so the `"."` fallback never applies.
- `write_file` calls `fs.new_temporary_file("", ...)`. That still works, because the template becomes `/<prefix>.XXXXXX`. The temporary file is synced and renamed onto the target, so the new frontier is committed.
- `frontier_store` and `frontier_forest_store` then call `fs.sync_directory("")`. `open("", O_DIRECTORY)` fails with ENOENT, so the store raises.

Result: the public store APIs report failure even though the new file is already in place, and the rename is never made durable by a directory fsync. The C++ counterpart (`parent_directory` in machine.cpp, which uses `std::filesystem::path::parent_path()`) correctly returns `/`. Paths with repeated leading slashes, such as `//x`, behave the same way.

**Origin**: introduced by this branch. `get_parent_directory`, `write_file` and the `sync_directory` calls do not exist in `main`'s hash-tree.lua.

**Area**: Lua library `cartesi.hash-tree` (frontier and frontier-forest persistence); `cartesi-machine` CLI (`frontier:<filename>` / `outputs_frontier:<filename>` options).

**Category**: correctness / durability (wrong error reporting after a commit; missing fsync).

**Location**:
- `src/cartesi/hash-tree.lua:505`: `get_parent_directory`
- `src/cartesi/hash-tree.lua:510`: `write_file` (temporary file directory)
- `src/cartesi/hash-tree.lua:937`: `frontier_store` → `fs.sync_directory(get_parent_directory(path))`
- `src/cartesi/hash-tree.lua:989`: `frontier_forest_store` → `fs.sync_directory(get_parent_directory(frontier_path))`
- `src/cartesi-machine.lua:3276`: the CLI's `store_frontier` passes the user-given filename to `hash_tree.frontier_store`

**Evidence**: the test runs as root. It re-executes itself in a private mount namespace, chrooted into a tmpfs-backed overlay of `/`, so the real root is never written. Inside, it stores a frontier at `/frontier-<t>.json` and a forest frontier at `/forest-frontier-<t>.json`. Both calls raise, yet both files exist with the new contents. `sync_directory("/")` succeeds and `sync_directory("")` fails. Run command: `eval $(make -s env); lua5.4 bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua`
```
frontier_store(/frontier-1792962320.json): ok=false err=.../hash-tree.lua:937: unable to sync directory '': open() failed: No such file or directory file_exists=true
frontier_forest_store(/forest-trees-1792962320, /forest-frontier-1792962320.json): ok=false err=.../hash-tree.lua:989: unable to sync directory '': open() failed: No such file or directory file_exists=true
sync_directory('/') ok=true
sync_directory('')  -> unable to sync directory '': open() failed: No such file or directory
rc=1
```

**Scenario**:
- A validator node or tool running in a container keeps its frontier at a root-level path such as `/state.json` or `/frontier.json`. Every `frontier_store` / `frontier_forest_store` raises, and every `cartesi-machine ... frontier:/frontier.json` run fails the same way.
- A caller that treats the error as "store failed, old state still current" is wrong: the frontier has already been replaced. With `frontier_forest_store`, the trees are already written and `forest.directory` is already updated.
- Because the directory is never fsynced, a crash shortly afterwards can lose the rename.
- Hashes, proofs and dispute outcomes are not affected.

**Possible solution**: map an empty capture to `/`, matching `std::filesystem::path::parent_path()`. For example:
```lua
local function get_parent_directory(path)
    local d = path:match("^(.*)/[^/]*$")
    if d == nil then return "." end
    if d:match("^/*$") then return "/" end
    return d
end
```

**Severity**: low. Both reviewers rated it low, and the prover agrees. It only triggers for frontier files stored directly in the filesystem root, which is rare outside containers. When it triggers it fails reliably and visibly: there is a spurious error after a successful commit, plus one skipped directory fsync. It never corrupts stored data, hashes or proofs, and it does not hang.

**Risks**:
- Of the bug: callers may misjudge whether the persisted state changed, or abort at a store boundary. In root-level layouts the rename is not durable after a crash.
- Of the fix: minimal. The helper is local to hash-tree.lua and only used for the temporary-file directory and the directory sync. Returning `/` for root-level paths gives the same temporary-file location and makes the sync succeed. Relative paths and deeper absolute paths are unchanged.

**Proof of concept**: `bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua`. It must run as root and needs `unshare`, overlayfs and `chroot`. It sandboxes itself in a private mount namespace over a throwaway overlay of `/`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-24-hash-tree-root-parent-directory/test-root-parent-directory.lua
```
Exit status 1 together with `BUG:` lines means the bug reproduced; exit status 0 means it is fixed.

**ID**: `lua-24-hash-tree-root-parent-directory`

### B35. collect_uarch_cycle_* reset shortcut diverges from reset_uarch when uarch RAM is not the built-in image

**Title**: collect_uarch_cycle_root_hashes / collect_uarch_cycle_bundle restore only dirty uarch RAM words on reset, so reset leaves (and all later leaves) differ from reset_uarch / verify_reset_uarch when uarch RAM is not the built-in image

**Problem**: After each mcycle, `machine::collect_uarch_cycle_root_hashes` does not call `reset_uarch()`. As an optimization it resets the uarch registers to `uarch_registers_state{}`, then copies the library's built-in `uarch_pristine_ram` (or zeros past its end) back only into the uarch RAM words written during that mcycle (`reset_dirty_words`). It then rehashes only those words with `m_ht.update_words`. The real reset is different. `reset_uarch()`, `log_reset_uarch`/`verify_reset_uarch` and the on-chain reset they model all write the whole built-in image over uarch RAM and zero-fill the rest. The shortcut is equivalent only when every word the uarch did not write already equals the built-in image, and nothing checks this: the only uarch precondition is `uarch_cycle == 0`. If the machine's uarch RAM differs from the built-in image anywhere, the collected reset leaf comes from a mixed state that no reset proof can produce. Every later leaf is then wrong as well, and the machine is left in that mixed state. `collect_uarch_cycle_bundle` calls `collect_uarch_cycle_root_hashes`, so it has the same defect.

**Origin**: pre-existing. The same shortcut is in `origin/main` (v0.22.0) at `src/machine.cpp:2794`.

**Area**: microarchitecture root-hash collection for PRT: `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (C API `cm_collect_uarch_cycle_root_hashes`/bundle, Lua bindings, JSON-RPC).

**Category**: correctness (wrong commitment hashes / state divergence).

**Location**:
- `src/machine.cpp:2797-2824`: shortcut reset in `machine::collect_uarch_cycle_root_hashes` (registers reset, dirty-word restore, `update_words`).
- `src/machine.cpp:2677-2679`: precondition checks only `uarch_cycle == 0`, not that uarch RAM is pristine.
- `src/machine.cpp:2051-2068`: `machine::reset_uarch`, the full reset (whole image plus zero fill) that `log_reset_uarch`/`verify_reset_uarch` replay.
- `src/machine.cpp:2894`: `collect_uarch_cycle_bundle` reuses `collect_uarch_cycle_root_hashes`.

**Evidence**: The test creates a uarch RAM backing file through config `uarch.ram.backing_store.data_filename`, the mechanism behind CLI `--uarch-ram-image`. The file equals the built-in image except its last 4 KiB page, which is filled with `0xaa` and which the uarch never touches. The test compares `collect_uarch_cycle_root_hashes(3, 0, tail)` against a reference loop: `run_uarch(UARCH_CYCLE_MAX)`, then `get_root_hash` (halt leaf), then `log_reset_uarch` + `verify_reset_uarch` (reset leaf). It also checks the machine root after `collect_uarch_cycle_bundle`. The control run with the built-in uarch RAM matches everywhere. With the custom image, the reset leaf of mcycle 1 differs from what `verify_reset_uarch` returns, and every later leaf diverges:
```
[built-in uarch ram] mcycle 1: halt leaf ok (64dcb7ade907f069 vs 64dcb7ade907f069), reset leaf ok (beafc583c3a41063 vs verify_reset_uarch beafc583c3a41063)
[custom uarch ram] mcycle 1: halt leaf ok (ca0120065f62a44c vs ca0120065f62a44c), reset leaf MISMATCH (370c69331539f6a7 vs verify_reset_uarch beafc583c3a41063)
[custom uarch ram] mcycle 2: halt leaf MISMATCH (ef9c969db160a639 vs 38f993e746476dad), reset leaf MISMATCH (4e87a0c3654bd578 vs verify_reset_uarch 5169efe4d5f24b00)
[custom uarch ram] machine root after collect == root after reference: false
[custom uarch ram] machine root after collect_uarch_cycle_bundle == reference reset of mcycle 1: false
BUG: collect_uarch_cycle_root_hashes/collect_uarch_cycle_bundle reset leaves differ from reset_uarch/verify_reset_uarch when uarch RAM is not the built-in pristine image
```
Run: `eval $(make -s env); lua5.4 bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua` (exit 1). On the custom machine, the reference reset hash after mcycle 1 equals the built-in machine's reset hash (`beafc5...`). This confirms that the real reset restores the built-in image.

**Scenario**: A template or snapshot holds uarch RAM that is not byte-identical to the built-in image of the libcartesi the validator links. Ways this happens:
- the machine was built with `--uarch-ram-image` or a `uarch.ram.backing_store`;
- the snapshot was stored by a different build;
- uarch RAM was changed through `write_memory`.

A PRT validator (Dave, the Rollups Node, or another node) that builds its uarch-level commitment with `collect_uarch_cycle_root_hashes` or `collect_uarch_cycle_bundle` then commits reset leaves that `verify_reset_uarch` and the on-chain reset step cannot reproduce. Every later leaf is wrong too. In a dispute that reaches the reset step or any later uarch step, the honest player cannot prove its leaf and loses to an opponent that commits the full-reset leaves. If the differing words were uarch code or data that is read, later mcycles would even run different uarch code than a real reset gives. With the default config (built-in uarch RAM), the shortcut is correct.

**Possible solution**: At the start of collection, or before each shortcut reset, check that the uarch state is pristine: compare the uarch RAM range hash or the uarch state hash with `get_uarch_pristine_hash()`. If it is not pristine, either fall back to a full `reset_uarch()` (full write plus full hash-tree update) for that mcycle, or throw a clear error that rejects the machine. A cheaper and stricter variant: do the full `reset_uarch()` once on the first mcycle, so every later state is pristine and the dirty-word shortcut becomes valid.

**Severity**: medium. When it triggers, the impact is critical: the committed reset leaf and every later leaf cannot be proven, so an honest player loses. Both reviewers rated it medium because it needs a uarch RAM that differs from the library's built-in image, which default templates from the same release never have. A validator whose built-in image differs from the on-chain one would also fail through other paths.

**Risks**: Bug: silent wrong commitments, with no error, for machines with a custom or stale uarch RAM image. The machine is also left in a mixed state, so any later `get_root_hash`, proof or snapshot of it is wrong. Fix: a pristine check adds one hash comparison per collection (cheap). A full-reset fallback costs a full uarch RAM write and rehash per mcycle, but only on the non-pristine path. Rejecting such machines could break existing users of `--uarch-ram-image`; this is acceptable, since their commitments are unprovable today. Whatever the fix, it must keep the leaves byte-identical to `log_reset_uarch`/`verify_reset_uarch` in the pristine case.

**Proof of concept**: `bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua`. The test needs no machine images. It writes a temporary uarch RAM image next to itself (or in the directory given as its first argument) and removes it afterwards. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram/test-collect-nonpristine-uarch-ram.lua
```
Exit 1 means the bug is present, 0 means fixed, and 2 means the built-in-image control unexpectedly failed.

**ID**: `api-08-uarch-collect-shortcut-reset-nonpristine-uarch-ram`

**Related**: [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset).

### B36. Temporary files from killed stores are never cleaned up

**Title**: Temporary files from stores killed mid-write are never cleaned up and pile up in forest/frontier directories

**Problem:** `write_file` in `cartesi.hash-tree` writes each tree or frontier file as `<name>.tmp.XXXXXX` in the target directory (`fs.new_temporary_file`). It then syncs the file and renames it into place. The temporary file is removed on failure only by the temporary object's `close`, which runs from `__close`/`__gc` (`cartesi.filesystem`). Neither runs when the process is SIGKILLed or OOM-killed, or when the machine loses power. No store or load path ever removes stale temporary files: `store_tree` and `load_tree` only test or open `<hash>.json` by its exact name, and `hash-tree.lua` never lists the directory. Every crash that lands between creating the temporary file and renaming it therefore leaves an orphaned file behind for good.

**Origin:** Introduced by this branch (`hash-tree.lua` and `filesystem.lua` are new).

**Area:** Lua library `cartesi.hash-tree` (`frontier_forest_store`, `frontier_store`), with `cartesi.filesystem` temporary files.

**Category:** Resource leak (disk).

**Location:**
- `src/cartesi/hash-tree.lua:509-514` (`write_file`: creates `<name>.tmp.` in the target directory)
- `src/cartesi/filesystem.lua:52-68` (cleanup only through `close`, `__close` and `__gc`)
- `src/cartesi/hash-tree.lua:525-527, 577-592` (`load_tree`/`store_tree` only check `<hash>.json` with `fs.exists`)
- `src/cartesi/hash-tree.lua:935-938` (`frontier_store`), `967-1018` (`frontier_forest_store`/`frontier_forest_load`): no cleanup

**Evidence:** `child.lua` builds a 1024-leaf keccak256 forest. It wraps `fs.sync_file` so that the process SIGKILLs itself after the temporary file is written and synced, but before the rename. It then calls `frontier_forest_store`. `test.lua` runs this 5 times with different leaves. It then runs one healthy store and `frontier_forest_load` in the same directory, and counts the `*.tmp.*` entries.
```
$ eval $(make -s env); lua5.4 bugs/lua-25-leftover-temp-files/test.lua
crash 1: ok=nil how=exit code=137 tmp files now=1
...
crash 5: ok=nil how=exit code=137 tmp files now=5
after healthy store+load: 5 leftover .tmp. files (353585 bytes)
  0x45f40119...df47f.json.tmp.9SwUWg
  ...
BUG: 5 orphaned temporary files from 5 interrupted stores remain after a later store/load; nothing cleans them
```

**Scenario:** A validator node (an experimental PRT node, or any Rollups Node or Dave component using these Lua APIs) persists its commitment forests with `frontier_forest_store`. It gets OOM-killed, restarted by its supervisor, or loses power from time to time while storing. Each such crash leaves one tree-sized file, roughly 70 KB per 1024 base hashes, in the forests directory or in the frontier's parent directory. Over a long run on a node that crashes often, these files take up more and more disk space. That moves the node closer to disk-full (ENOSPC) conditions, which feed the separate truncated-write issue in `write_file`.

**Possible solution:** Clean up stale temporary files when a directory is used. For example, in `frontier_forest_load`/`frontier_forest_store` (or in a dedicated `cleanup` helper), remove entries matching `*.json.tmp.*` from the forests directory and from the frontier's parent directory. Only do this when the caller owns the directory, so that a live writer's file is never removed. Another option is to create temporary files in a dedicated subdirectory (on the same filesystem, so rename stays atomic) that is wiped at startup. Document that a forests directory has a single writer.

**Severity:** Low. Both reviewers and the prover agree. Hashes, proofs, stored-state correctness and dispute outcomes are not affected, because loads never read `*.tmp.*` files and the rename commit keeps every committed name consistent. Nothing crashes or hangs. The leak is at most one tree-sized file per crash that lands mid-write, so it matters only for nodes that crash repeatedly over a long time.

**Risks:**
- Of the bug: slow, unbounded disk growth on unstable nodes, which adds to the chance of ENOSPC and the failures that follow it (failed or truncated stores, a node that stops).
- Of the fix: removing temporary files without regard to other processes could delete a file that a concurrent writer is about to rename, making that store fail. So cleanup has to assume or enforce a single owner per directory. A glob that is too broad could also delete user files that share the directory. Match only the exact `<64-hex>.json.tmp.XXXXXX` and `<frontier-name>.tmp.XXXXXX` patterns.

**Proof of concept:** `bugs/lua-25-leftover-temp-files/test.lua` (driver) and `bugs/lua-25-leftover-temp-files/child.lua` (store that is killed mid-write). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-25-leftover-temp-files/test.lua
```
It exits with 1 and prints `BUG: ...` while the leak is present, and prints `OK: no leftover temporary files` once it is fixed.

**ID**: `lua-25-leftover-temp-files`

**Related**: [B06](#b06-frontier_forest_store-and-fssync_file-ignore-write-errors-and-commit-truncated-files).

### B37. filesystem.temp_pathname returns a deleted /tmp name that another user can claim

**Title**: `cartesi.filesystem.temp_pathname` returns a `/tmp` name it has just deleted, so another local user can claim it (TOCTOU)

**Problem**: `filesystem.temp_pathname()` calls `os.tmpname()`, which uses `mkstemp` to create `/tmp/lua_XXXXXX`. It then deletes that file and returns the name. This is the insecure `tmpnam` / `mktemp -u` pattern. Between the return and the caller's use of the name, any local user can create a symlink or a directory at that path in the world-writable `/tmp`. Callers use the returned name as the place to create a store, a checkpoint or a status directory.

**Origin**: Introduced by this branch. On `main` the same helper existed only in `tests/lua/cartesi/filesystem.lua`. This branch moves it into `src/cartesi/filesystem.lua`, which the Makefile installs through `EMU_TO_LUA_PATH`, so it is now part of the public `cartesi.filesystem` module.

**Area**: Lua library `cartesi.filesystem` (`temp_pathname`)

**Category**: Security (local TOCTOU / insecure temporary file)

**Location**:
- `src/cartesi/filesystem.lua:78-82` (`filesystem.temp_pathname`)
- `Makefile:80` (`EMU_TO_LUA_PATH` installs `src/cartesi/filesystem.lua`)
- Example callers (recipes, not shipped code): `doc/recipes/prt-demo.lua:99`, and `doc/recipes/prt-test.lua:170, 823, 2008, 2217, 2314`

**Evidence**: The test runs the victim as root. Right after `temp_pathname()` returns, it runs the attacker's steps as uid 65534 (`nobody`) through `setpriv`, which stands in for an attacker who has won the race.
(1) The attacker plants a symlink at the returned path that points to a file inside the victim's private 0700 directory. The victim's `fs.write_file` follows the symlink and overwrites that file. This host has `fs.protected_symlinks=0`.
(2) The attacker runs `mkdir` on the returned path first. The victim's `fs.create_directory` then fails with EEXIST.
Run command: `eval $(make -s env); lua5.4 bugs/lua-27-temp-pathname-toctou/test.lua`
```
running as root: true, fs.protected_symlinks=0
temp_pathname() -> /tmp/lua_wXY1oK (exists: false)
victim write_file to temp path: ok=true
BUG: write to fs.temp_pathname() path followed attacker's symlink and overwrote /tmp/tmp.shPbRLvdjK/precious
victim create_directory(temp_pathname()): ok=false err=unable to create directory '/tmp/lua_e39RDd': File exists
BUG: attacker pre-created directory at fs.temp_pathname() path; victim's create_directory fails (DoS)
exit=1
```

**Scenario**: A validator node or tool built on the shipped Lua library runs on a shared host and uses `fs.temp_pathname()` as the location for its store, checkpoint or status directory, the way the PRT recipes do. A local attacker watches `/tmp` (for example with inotify) and creates the name first.
- On every kernel: a pre-created directory or file makes the node's directory creation or store fail at startup. This is a denial of service.
- On hosts with `fs.protected_symlinks=0`: the node's writes follow a planted symlink, so it can overwrite files the attacker chose, with the node's privileges.

No shipped emulator code path (the `cartesi-machine` CLI, the C API or the other Lua modules) calls this helper. Hashes, proofs and step logs are not affected.

**Possible solution**: Remove `temp_pathname` from the shipped module, or make it safe. One option is to create a private directory with `mkdtemp` (mode 0700) and return a path inside it, so no other user can create that path. Another is to provide `create_temporary_directory()` built on `mkdtemp` and move the callers to it. A `mkdtemp` binding in the C filesystem core would make either option straightforward. With either fix the PoC exits 0.

**Severity**: Low. Both reviewers and the prover agree. An attacker needs a local account on a shared host and must win a race against a random name. On default kernels (`protected_symlinks=1`) the impact is limited to making the node fail at startup. No shipped emulator code uses the helper, and consensus data (hashes and proofs) is not affected.

**Risks**:
- Of the bug: other node implementations may copy the recipe pattern and get startup DoS on shared hosts, or symlink-redirected writes where `protected_symlinks` is off.
- Of the fix: removing or renaming the function breaks callers (the recipes and the tests). Returning a path inside a private directory changes cleanup semantics, because the caller must also remove the parent directory, so temporary directories may leak if callers are not updated.

**Proof of concept**: `bugs/lua-27-temp-pathname-toctou/test.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-27-temp-pathname-toctou/test.lua`. It exits 1 when the bug reproduces and 0 when the returned path cannot be claimed. Run it as root (with `setpriv` available) so the attacker steps run as `nobody`. As a non-root user it only gives a weaker same-user demonstration.

**ID**: `lua-27-temp-pathname-toctou`

### B38. ABI decoder accepts dirty address bits and non-zero padding

**Title**: evmu ABI decoder accepts dirty upper bits in `address` and dirty padding in `bytesN`, which Solidity rejects, and non-zero padding in `bytes`/`string`

**Problem**: The ABI decoder in `cartesi.evmu` does not check bits that a canonical encoding requires to be zero:
- `decode_address` keeps the last 20 bytes of the word (`tobe(word):sub(-20)`) and ignores the upper 12 bytes.
- `decode_bytes_sized` (`bytesN`) reads `N` bytes and skips the other `32-N` padding bytes without checking them.
- `decode_string` and the dynamic branch of `decode_bytes` skip the padding up to `ceil32(len)` without checking it.

The same file is strict elsewhere: `decode_uint` and `decode_int` check range, and `decode_bool` rejects anything other than 0 or 1. Solidity's ABI coder v2 reverts on an `address` or `bytesN` with dirty bits, so for those two types evmu accepts data that the on-chain `abi.decode` rejects. Solidity does not check trailing padding of dynamic `bytes`/`string`, so for those two types the issue is only malleability: several distinct byte strings decode to the same value.

**Origin**: Pre-existing. The branch added the selectorless wrappers `encode_abi`/`decode_abi` (commit 44f37ea). `decode_abi` sends data to the same lenient decoders, which makes them reachable from one more public entry point.

**Area**: `src/cartesi/evmu.lua`, the ABI decoder in the shipped Lua library (installed through `EMU_TO_LUA_PATH` in the top-level Makefile).

**Category**: Correctness. The decoder is non-canonical and inconsistent with on-chain decoding.

**Location**:
- `src/cartesi/evmu.lua:670-676` (`decode_address`)
- `src/cartesi/evmu.lua:702-709` (`decode_bytes_sized`)
- `src/cartesi/evmu.lua:691-700` (`decode_string`)
- `src/cartesi/evmu.lua:712-722` (`decode_bytes`, dynamic branch)
- Reached through `_M.decode_calldata` (`:820`), `_M.decode_calldata_hex` (`:836`) and `_M.decode_abi` (`:842`).

**Evidence**: The test first runs two control cases, which are rejected. It then feeds six non-canonical encodings, and all six are accepted:
```
$ eval $(make -s env); lua5.4 bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua
ok: (bool) value 2 [control] rejected: .../evmu.lua:686: invalid bool value in calldata (must be 0 or 1)
ok: (uint8) value 256 [control] rejected: .../evmu.lua:652: integer value does not fit in target type
BUG: (address) with 0xff upper 12 bytes accepted (decoded "0x1111111111111111111111111111111111111111")
BUG: (bytes4) with non-zero padding accepted (decoded "0xdeadbeef")
BUG: (string) with non-zero padding accepted (decoded "a")
BUG: (bytes) with non-zero padding accepted (decoded "0x61")
BUG: decode_calldata Notice(bytes) dirty padding accepted (decoded "a")
BUG: two distinct encodings decode to the same bytes value "a"
BUG: decoder accepted 6 non-canonical encodings
```
The test exits with status 1.

**Scenario**: The decoder is used by a Lua validator, indexer or tool that decodes untrusted ABI data with evmu, such as `decode_calldata` on Notice/Voucher outputs or `decode_abi` on `eth_call` results. Two things can go wrong:
- An `address` or `bytesN` with dirty bits is treated as valid, even though a contract's `abi.decode` of the same bytes would revert. For example, a voucher destination or payload field shows as well formed off-chain but fails on-chain.
- Distinct encodings collapse to the same decoded value. Code that deduplicates or keys on decoded values can then disagree with code that works on the raw bytes.

None of the following uses evmu: the C API, the JSON-RPC machine or the `cartesi-machine` CLI. Machine state hashes, output Merkle roots, proofs and step logs are all computed over raw bytes. So this bug cannot change a PRT commitment or make an honest player lose a dispute.

**Possible solution**:
- In `decode_address`, assert that the upper 12 bytes of the word are zero (`tobe(word):sub(1, 12) == ("\0"):rep(12)`).
- In `decode_bytes_sized`, assert that `calldata:sub(offset + size + 1, offset + padded_len)` is all zero.
- Optionally, for strict canonical decoding, check the same zero padding in `decode_string` and `decode_bytes`. Also optionally reject non-canonical head offsets, since aliasing or overlapping offsets are also accepted today.

**Severity**: Low. Both reviewers agree. The defect is real and reachable through the public Lua API, but it is pre-existing and limited to a Lua helper library. It never affects machine hashes, proofs, step logs, the C API or the CLI, so it cannot crash a validator or decide a dispute.

**Risks**:
- Of the bug: off-chain Lua consumers may accept malformed or malleable ABI data that the on-chain decoder rejects, and so diverge from contract behaviour on what counts as a valid output or input.
- Of the fix: stricter checks may start rejecting inputs that callers currently accept, such as sloppy hand-built calldata in scripts or tests. Making the padding checks on `bytes`/`string` strict goes beyond what Solidity enforces, so it should be a deliberate choice, or be made optional.

**Proof of concept**: `bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-28-evmu-lenient-dirty-bits-padding/test.lua
```
The test exits 1 while the bug is present and prints `PASS` (exit 0) once it is fixed.

**ID**: `lua-28-evmu-lenient-dirty-bits-padding`

**Related**: [B18](#b18-abi-decoder-bounds-checks-overflow-and-accept-out-of-bounds-offsets).

### B39. collect_uarch_cycle_* aborts the process when the uarch is halted but not reset

**Title**: collect_uarch_cycle_root_hashes and collect_uarch_cycle_bundle abort the process (assert) when uarch_halt=1 and uarch_cycle=0, because the precondition checks only uarch_cycle

**Problem**: The only uarch precondition in `machine::collect_uarch_cycle_root_hashes` is `read_reg(reg::uarch_cycle) != 0` -> throw "microarchitecture is not reset". `uarch_halt` is not checked. With `uarch_halt == 1` and `uarch_cycle == 0`, the first `uarch_interpret` in the inner loop returns `uarch_halted` without executing anything, and the loop breaks. The halt and reset hashes are appended and the uarch registers are reset, but mcycle never advanced, so `assert(mcycle_reached == mcycle_target)` fails. In the default build (`relwithdebinfo`, used for packaging), `src/Makefile` adds `-DNDEBUG` only to `interpret.cpp`, so `machine.cpp` keeps its asserts. The call therefore sends SIGABRT to the host process (the validator, or `cartesi-jsonrpc-machine` for a remote machine) instead of raising a catchable error. In an NDEBUG build (`release=yes`) the call does not abort. It returns a halt+reset group for an mcycle that never ran, then continues from the reset uarch, so every later leaf is shifted. `collect_uarch_cycle_bundle` calls `collect_uarch_cycle_root_hashes`, so it has the same defect.

**Origin**: pre-existing. `origin/main` has the same precondition (`src/machine.cpp:2676`) and the same assert (`src/machine.cpp:2834`).

**Area**: microarchitecture root-hash collection for PRT: `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (C API `cm_collect_uarch_cycle_root_hashes` and the bundle call, Lua bindings, JSON-RPC server).

**Category**: crash (process abort through a reachable assert); wrong hashes in NDEBUG builds.

**Location**:
- `src/machine.cpp:2678`: uarch precondition checks only `uarch_cycle`.
- `src/machine.cpp:2780`: an already-halted uarch breaks out of the inner loop at once.
- `src/machine.cpp:2837`: `assert(mcycle_reached == mcycle_target)` aborts the process.
- `src/machine.cpp:2894`: `collect_uarch_cycle_bundle` reaches the same path.

**Evidence**: `test-uarch-halt-abort.lua` runs each local case in a child process and also drives a spawned `cartesi-jsonrpc-machine`. All four cases abort with SIGABRT (exit 134) instead of raising an error:
- (a) `write_reg("uarch_halt", 1)`, then `collect_uarch_cycle_root_hashes`.
- (b) A config with `uarch.processor.registers.halt = 1`, the same state a stored machine can carry.
- (c) `collect_uarch_cycle_bundle`.
- (d) A remote machine: the server process dies.

Run from the repo root with `eval $(make -s env); lua5.4 bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`:
```
lua5.4: machine.cpp:2837: ... collect_uarch_cycle_root_hashes(...): Assertion `mcycle_reached == mcycle_target' failed.
Aborted
BUG: local write_reg case: child terminated abnormally (exit 134) instead of raising an error
... (same for config and bundle cases)
cartesi-jsonrpc-machine: machine.cpp:2837: ... Assertion `mcycle_reached == mcycle_target' failed.
remote collect: ok=false err=jsonrpc error: post error contacting 127.0.0.1:45905 (end of stream ...)
BUG: remote case: cartesi-jsonrpc-machine server died after collect_uarch_cycle_root_hashes: ... (Connection refused ...)
rc=1
```

**Scenario**: A validator (Rollups Node, Dave, or the Lua PRT node) loads a template or snapshot whose uarch registers have `halt = 1` and `cycle = 0`. This can happen through a misconfigured config, a hand-edited or corrupted stored machine, or a tool that called `write_reg("uarch_halt", 1)` before storing. When the node computes uarch-level commitments or a bundle for a dispute, the whole process aborts instead of reporting an error it could handle. If such a template were deployed, every validator using it would crash at that point. With a remote machine, the `cartesi-jsonrpc-machine` server dies and the client sees "end of stream", then "connection refused". Normal API use cannot reach this state: after `run_uarch` to halt, `uarch_cycle` is non-zero and the existing check rejects the call, and `reset_uarch` clears both registers.

**Possible solution**: Also throw `std::runtime_error{"microarchitecture is not reset"}` when `read_reg(reg::uarch_halt) != 0`, or require fully pristine uarch registers. Replace the post-loop sanity `assert`s (`uarch_halt != 0`, `mcycle_reached == mcycle_target`) with runtime checks that throw, so an unexpected state cannot abort the host process or produce silently wrong leaves in NDEBUG builds. Apply the same check to every other uarch entry point that assumes a reset uarch.

**Severity**: low. Both reviewers agree on this. The abort is real and kills the validator or the JSON-RPC server, but it needs a non-canonical uarch state that honest operation never produces, and an adversary cannot inject that state into an honest node's dispute. The wrong-hash variant exists only in non-default NDEBUG builds, from the same state.

**Risks**: Bug: a hard process abort (DoS) of a long-running validator or a shared JSON-RPC server, triggered by a bad template or snapshot. In NDEBUG builds, a silently wrong uarch commitment (a shifted leaf sequence) that would lose a dispute. Fix: low risk. The new check only rejects a state that is already invalid for this API. Turning the asserts into exceptions changes nothing on valid inputs.

**Proof of concept**: `bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/api-09-collect-uarch-halted-uarch-assert-abort/test-uarch-halt-abort.lua`. It exits 1 and prints `BUG:` lines while the defect is present, and prints `PASS` once every case raises a catchable error and the remote server survives.

**ID**: `api-09-collect-uarch-halted-uarch-assert-abort`

**Related**: [B35](#b35-collect_uarch_cycle_-reset-shortcut-diverges-from-reset_uarch-when-uarch-ram-is-not-the-built-in-image), [B40](#b40-over-long-revert_uarch_tail-aborts-on-an-assert-or-yields-an-invalid-mcycle-subtree).

### B40. Over-long revert_uarch_tail aborts on an assert or yields an invalid mcycle subtree

**Title**: Over-long `revert_uarch_tail` (more than 2^20 entries) is accepted: with `log2_bundle > 0` it aborts the process (local or JSON-RPC server) on an assert, otherwise it returns an mcycle group with more than 2^20 leaves

**Problem**: The caller supplies `revert_uarch_tail` to `collect_uarch_cycle_root_hashes` and `collect_uarch_cycle_bundle` (in `cm_*`, as a JSON array; over JSON-RPC it comes from the client). `machine::collect_uarch_cycle_root_hashes` checks three things only: the tail is non-empty, has `size() >= 2`, and has `back() == read_revert_root_hash()`. Nothing bounds its length by `2^ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE` (2^20). `append_revert_uarch_tail_period` pushes `tail[0..n-3]` as leaves, then calls `append_uarch_reset_root_hash`. The outcome depends on bundling and build type:
- `log2_bundle > 0`: `append_uarch_reset_root_hash` executes `assert(execution_bundle_count < bundle_capacity)`. The default `relwithdebinfo` build leaves asserts on outside `interpret.cpp`, so the process aborts with SIGABRT.
- `log2_bundle > 0` in a `release` build (NDEBUG): the assert is compiled out, and the call silently emits more than `2^(20-log2)` bundles for that mcycle.
- `log2_bundle == 0`: the call returns one mcycle group with more than 2^20 leaves, which is not a valid mcycle subtree.

So a bad argument produces either an abort or malformed output, never the `runtime_error` that the other tail checks raise.

**Origin**: pre-existing. The same validation and assert are on `origin/main`. The branch only changes `clear_hash_tree` in `machine.cpp`. The experimental PRT node does use this API, so it is in scope.

**Area**: microarchitecture root-hash collection for PRT, specifically the revert-tail handling of `collect_uarch_cycle_root_hashes` / `collect_uarch_cycle_bundle`. Exposed through the C API (`cm_collect_uarch_cycle_root_hashes`), the Lua bindings and JSON-RPC (`cartesi-jsonrpc-machine`).

**Category**: crash (assert abort, remote DoS of the JSON-RPC server) / input validation (malformed output).

**Location**:
- `src/machine.cpp:2700-2709`: tail validation in `machine::collect_uarch_cycle_root_hashes`, with no upper bound on the length.
- `src/machine.cpp:2645-2655`: `append_revert_uarch_tail_period` pushes every entry except the last two as leaves.
- `src/machine.cpp:2606`: `assert(execution_bundle_count < bundle_capacity)` in `append_uarch_reset_root_hash`.
- `src/machine.cpp:2718` (machine already at an rx-rejected yield, `start_rejected`) and `src/machine.cpp:2849` (machine reaches that state during collection): the two call sites.
- `src/Makefile:211`: the default `relwithdebinfo` build sets `-DNDEBUG` only for `interpret.cpp`, so the assert is live in `machine.cpp`.

**Evidence**: The test sets `iflags_Y=1` and an rx-rejected manual-yield `htif_tohost`, then passes a tail of 2^20+8 entries whose last entry is `read_revert_root_hash()`. It runs three cases:
- Case A: in-process, `log2_bundle=0`.
- Case B: child process, `log2_bundle=4`.
- Case C: `cartesi-jsonrpc-machine` server, `log2_bundle=4`.
```
case A (log2_bundle=0): accepted tail of 1048584 entries, group has 1048584 leaves (max 1048576)
BUG: over-long revert_uarch_tail accepted; mcycle group has more than 2^20 leaves
lua5.4: machine.cpp:2606: void cartesi::append_uarch_reset_root_hash(...): Assertion `execution_bundle_count < bundle_capacity' failed.
case B (local, log2_bundle=4): child exit code 134
cartesi-jsonrpc-machine: machine.cpp:2606: ... Assertion `execution_bundle_count < bundle_capacity' failed.
child-jsonrpc: call returned	false	jsonrpc error: post error contacting 127.0.0.1:44027 (end of stream ...)
child-jsonrpc: server alive after call:	false
BUG: case C (jsonrpc server, log2_bundle=4): process aborted on assert(execution_bundle_count < bundle_capacity)
```
Run: `eval $(make -s env); lua5.4 bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua` (exit 1, about 18 s).

**Scenario**: A validator or tooling built on the C/Lua/JSON-RPC API passes a wrong tail, for example:
- groups from several mcycles concatenated together;
- a tail taken from a machine that is not at the manual-yield fixed point.

The machine is at, or reaches, an rx-rejected manual yield, and the caller uses `log2_bundle > 0`. The node process aborts instead of getting an error. If the machine is remote, the shared `cartesi-jsonrpc-machine` server aborts, so one bad request from any client kills that server and every machine it hosts. Without bundling, or in a release build, the caller instead silently receives an invalid commitment group. A correct caller builds the tail with `collect_uarch_cycle_root_hashes(MCYCLE_MAX, 0)` on the reverted machine, as `prt.lua` does. That returns exactly one mcycle group of at most 2^20 entries, so honest validators that use the API correctly are not affected.

**Possible solution**: In `machine::collect_uarch_cycle_root_hashes`, next to the existing tail checks and before anything executes, add `if (revert_uarch_tail.size() > (UINT64_C(1) << ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE)) throw std::runtime_error{"revert uarch tail is too long"};`. Optionally also require the size to be a valid one-mcycle period. Replace the `assert` at line 2606 (and the related `assert(!back_tree.full())`) with runtime checks, so that internal invariants guarding caller-controlled sizes cannot abort the process or be silently skipped under NDEBUG.

**Severity**: low. Both reviewers agree. Only a buggy or malicious caller can trigger it: correctly built tails never exceed 2^20 entries, so an honest player cannot lose a dispute and no correct node crashes. The impact is a process abort (including a remote JSON-RPC server DoS) or malformed output from bad input instead of a clean error.

**Risks**: Bug: abort of the node or of a shared JSON-RPC server on one malformed request; in release builds, silently malformed bundles that a caller might commit. Fix: very low risk. The new bound rejects only tails that can never be valid, and changing asserts into runtime errors does not change behaviour for valid inputs.

**Proof of concept**: `bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua`. The test needs no machine images. It spawns itself as child processes for the abort cases and spawns a local `cartesi-jsonrpc-machine` for case C. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/api-10-collect-uarch-revert-tail-length-unvalidated/test-tail-length.lua
```
Exit 1 means the bug is present. Exit 0 means all three cases reject the over-long tail with a normal error.

**ID**: `api-10-collect-uarch-revert-tail-length-unvalidated`

**Related**: [B39](#b39-collect_uarch_cycle_-aborts-the-process-when-the-uarch-is-halted-but-not-reset).

### B41. collect_uarch_cycle_root_hashes accepts bundle sizes above 2^20 and shifts by a negative amount

**Title**: `collect_uarch_cycle_root_hashes` accepts `log2_bundle_uarch_cycle_count` 21..63, hits a negative shift (UB) and returns a malformed layout

**Problem:** `machine::collect_uarch_cycle_root_hashes` never checks that `log2_bundle_uarch_cycle_count` is in `0..ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE` (0..20). The only bound comes from the `back_merkle_tree` constructor, which accepts 0..63. For values from 21 to 63, `append_uarch_reset_root_hash` computes `UINT64_C(1) << (20 - log2_bundle_uarch_cycle_count)`. That is a shift by a negative amount, which is undefined behavior, and the `assert` after it is compiled out in release builds. Instead of an argument error, the call returns 3 entries per mcycle (a padded execution bundle, the halt pad hash and the reset bundle), and each entry claims to cover 2^log2 > 2^20 leaves. The sibling API `collect_uarch_cycle_bundle` rejects the same values with `log2_bundle_uarch_cycle_count must be in {0, ..., 20}`.

**Origin:** pre-existing. `origin/main` has the same unguarded shift and no range check.

**Area:** `collect_uarch_cycle_root_hashes` in the C++ machine, used by the C API (`cm_collect_uarch_cycle_root_hashes`), the Lua binding and the JSON-RPC server/client.

**Category:** api-contract / input validation (undefined behavior)

**Location:**
- `src/machine.cpp:2657-2713`: `machine::collect_uarch_cycle_root_hashes` has no range check, and the `back_merkle_tree` is built at line 2713
- `src/machine.cpp:2604-2606`: the negative shift in `append_uarch_reset_root_hash`
- `src/back-merkle-tree.hpp:47-52`: the only check, which allows 0..63
- `src/machine.cpp:2878-2881`: the check in `collect_uarch_cycle_bundle`, for comparison
- `src/cm.cpp:789`, `src/clua-i-machine.cpp:1300`, `src/jsonrpc-remote-machine.cpp:1014`: these pass the value through unchanged

**Evidence:** The test makes a fresh machine (local, then remote through JSON-RPC). On each one it calls `collect_uarch_cycle_root_hashes(2, L, tail)` with L = 20 as a control, then with L = 21, 32, 40 and 63. It also calls `collect_uarch_cycle_bundle(0, 21, tail)`.
```
local	log2=20 ok:	4	entries, offsets	1,3,5
local	collect_uarch_cycle_bundle(0,21):	rejected: log2_bundle_uarch_cycle_count must be in {0, ..., 20}
BUG: local collect_uarch_cycle_root_hashes accepted log2_bundle_uarch_cycle_count=21 (valid range 0..20): 6 entries, offsets 1,4,7 ...
BUG: local collect_uarch_cycle_root_hashes accepted log2_bundle_uarch_cycle_count=63 (valid range 0..20): 6 entries, offsets 1,4,7 ...
jsonrpc	collect_uarch_cycle_bundle(0,21):	rejected: log2_bundle_uarch_cycle_count must be in {0, ..., 20}
BUG: jsonrpc collect_uarch_cycle_root_hashes accepted log2_bundle_uarch_cycle_count=21 (valid range 0..20): 6 entries, offsets 1,4,7 ...
BUG: 8 out-of-range log2_bundle_uarch_cycle_count values accepted
```
To run it: `eval $(make -s env); lua5.4 bugs/api-11-collect-uarch-log2-bundle-unbounded/test-uarch-log2-bound.lua`. The exit status is 1 while the bug is present. L = 64 is rejected, but only by the back tree's `log2_max_leaves is too large` check.

**Scenario:** A validator node, a remote JSON-RPC client or a tool built on the C/Lua API passes the height of a different tree level, for example 21 or a whole-mcycle level, or reads a misconfigured constant. It does not get a clear argument error. The call succeeds with a malformed layout, so the caller builds a wrong uarch commitment or computation hash and may store or publish it. Because the shift is undefined behavior, the result could also differ across compilers, optimization levels or architectures. Correct PRT callers only use levels 0..20 and are not affected. A malformed commitment cannot match a valid on-chain one, so the most likely outcome is a mismatch or a wasted dispute, not an honest player being silently misled.

**Possible solution:** At the top of `machine::collect_uarch_cycle_root_hashes`, before any work, add the same check that `collect_uarch_cycle_bundle` uses: `if (log2 < 0 || static_cast<uint64_t>(log2) > ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE) throw std::runtime_error{"log2_bundle_uarch_cycle_count must be in {0, ..., 20}"};`. Once that check exists, the redundant check in `collect_uarch_cycle_bundle` can stay or be removed.

**Severity:** low. Both reviewers agree. Only callers that pass invalid arguments (21..63) are affected. The outcome is UB and a meaningless result rather than a crash, a hang or memory corruption (the back tree stays within its own bounds). Correct PRT nodes never pass values above 20.

**Risks:** The bug lets a misconfigured validator produce commitments that look plausible but are invalid and that depend on the platform, with no error. The fix carries almost no risk. It only rejects inputs that never had a defined meaning. A caller that relied on values above 20 being accepted, which none should, would now get an error.

**Proof of concept:** `bugs/api-11-collect-uarch-log2-bundle-unbounded/test-uarch-log2-bound.lua` (uses the local machine and a spawned JSON-RPC server, and takes about 2 s). From the repo root: `eval $(make -s env); lua5.4 bugs/api-11-collect-uarch-log2-bundle-unbounded/test-uarch-log2-bound.lua`. Exit status 1 with `BUG:` lines means the bug reproduced. Exit status 0 with `OK:` means it is fixed.

**ID**: `api-11-collect-uarch-log2-bundle-unbounded`

**Related**: [B40](#b40-over-long-revert_uarch_tail-aborts-on-an-assert-or-yields-an-invalid-mcycle-subtree).

### B42. filesystem.rename_file does not replace existing files on Windows

**Title**: `cartesi.filesystem.rename_file` does not replace an existing destination on Windows, so every hash-tree durable rewrite after the first fails (`frontier_store`, `frontier_forest_store`, StoredTree)

**Problem**: `filesystem.rename_file(from, to)` says it renames "atomically replacing the destination if it exists", but its body is just `assert(os.rename(from, to))`. Lua's `os.rename` is plain ISO C `rename()`. POSIX `rename()` replaces the destination. The Windows CRT `rename()` (msvcrt/UCRT, and so MinGW builds too) fails with `EEXIST`/`EACCES` when the destination exists. `temporary_file:rename` calls `rename_file`. `hash-tree.lua`'s `write_file` uses `temporary_file:rename` for every durable write, and its callers rewrite a fixed path on each commit:
- StoredTree persistence
- `frontier_store`
- `frontier_forest_store`

On Windows, the first write of each file succeeds and every later write raises. The destination keeps its stale contents. Nothing removes the destination first or falls back to another way of replacing it, and the C core has no Windows-aware rename helper.

**Origin**: Introduced by this branch. `src/cartesi/filesystem.lua` and the hash-tree persistence code do not exist on `main`.

**Area**: Lua library `cartesi.filesystem` (`src/cartesi/filesystem.lua`) and its users in `cartesi.hash-tree` (`src/cartesi/hash-tree.lua`). Validator nodes use these to persist output and epoch frontiers and stored trees.

**Category**: API contract / portability. Availability: persisting state raises an error.

**Location**:
- `src/cartesi/filesystem.lua:127`: `function filesystem.rename_file(from, to) assert(os.rename(from, to)) end`
- `src/cartesi/filesystem.lua:45-49`: `temporary_file:rename` calls `filesystem.rename_file`
- `src/cartesi/hash-tree.lua:509-514`: local `write_file` (temporary file, sync, then rename)
- `src/cartesi/hash-tree.lua:592` (StoredTree), `:936` (`frontier_store`), `:988` (`frontier_forest_store`): callers that rewrite a fixed path
- Windows is an intended target. `src/os-filesystem.cpp` has new `_WIN32` branches (for example `create_temporary_file` at :667, plus `sync_file` and `sync_directory`), and `README.md:45` lists Windows support.

**Evidence**: `test.lua` loads the repo's unmodified `src/cartesi/filesystem.lua`. It stubs only the C core functions `create_temporary_file`, `sync_file` and `sync_directory`, because the native core is not built for Windows here and the rename path does not use them. It then runs the same temporary-file, sync and rename sequence as `hash-tree.lua` `write_file` twice on one path. `run.sh` runs the test once with native Linux Lua and once with a Windows `lua.exe` (Lua 5.4.6, cross-built with mingw-w64) under Wine. Run it with `eval $(make -s env); sh bugs/lua-26-rename-not-replacing-on-windows/run.sh`. It exits 1:
```
== native lua5.4 (Linux) ==
second store:	true	nil
destination contents:	commit-2
OK: destination replaced
== Windows lua.exe under wine ==
first store:	true	nil
second store:	false	Z:/home/user/machine-emulator/src/cartesi\filesystem.lua:127: File exists
destination contents:	commit-1
BUG: rename_file did not replace existing destination (second frontier store failed): ...filesystem.lua:127: File exists
```

**Scenario**: A validator node built for Windows (or any tool using `cartesi.hash-tree` persistence there) persists the outputs frontier or the epoch-builder forest after each input or epoch. The first commit creates the file. The second commit raises `File exists`, and the node stops persisting state or crashes. After a restart it reloads the stale commit-1 frontier, if it reloads at all. Re-persisting a StoredTree to the same path fails the same way. Hashes and proofs are never silently wrong, because the failure is loud. Rollups Node and Dave do not deploy on Windows today, and the repo has no Windows build or CI, so the realistic reach is limited to people porting a node or tools to Windows.

**Possible solution**: Implement the rename in the C core and expose it as `core.rename_file`. Use `rename()` on POSIX. On Windows, use `MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)` (or `ReplaceFileW`), or use `std::filesystem::rename`, which replaces on both. Make `filesystem.rename_file` use it. Do not "remove the destination, then rename" in Lua: that breaks atomicity, because a crash between the two steps loses the file.

**Severity**: Low. Both reviewers agree. The failure is loud, affects availability only, and occurs only on Windows builds, which have no build or CI support in the repo and are not used by Rollups Node or Dave. No data is corrupted, and no hashes or proofs come out wrong.

**Risks**:
- **Of the bug**: a Windows-hosted node cannot persist state after its first commit. A recovery path that writes the same file twice also fails.
- **Of the fix**: a careless fallback (remove, then rename) opens a crash window in which neither the old file nor the new one exists. `MoveFileExW` can still fail with sharing violations while another handle holds the destination open, for example a concurrent reader or an antivirus scanner, so callers should expect it to fail occasionally.

**Proof of concept**: `bugs/lua-26-rename-not-replacing-on-windows/test.lua` and `bugs/lua-26-rename-not-replacing-on-windows/run.sh`. From the repo root, run `eval $(make -s env); sh bugs/lua-26-rename-not-replacing-on-windows/run.sh`.

It needs `lua5.4` and `wine` (or `wine64`). It also needs either `WIN_LUA=<path to a Windows lua.exe>`, or `x86_64-w64-mingw32-gcc` so the script can cross-build Lua 5.4.6. The script builds it from `LUA_TARBALL`, or downloads it from lua.org, and caches it in `${TMPDIR:-/tmp}/bugs-lua-26-winlua`. Exit status 1 together with a `BUG:` line means the bug reproduced.

**ID**: `lua-26-rename-not-replacing-on-windows`

### B43. ABI decoder's trailing-data check uses only the last dynamic tail

**Title**: evmu ABI decoder's "no trailing data" check uses only the end of the last-decoded dynamic tail, so it rejects valid data (out-of-order tails, empty dynamic-element arrays) and accepts aliased tails and gaps

**Problem:** `decode_abi` and `decode_calldata` assert that the end offset returned by the top-level `decode_value` equals `#data`, which is meant to check that no data is left over. That end offset does not measure how much data was used:
- `decode_tuple` starts `new_offset` at `tuple_start + static_size` and then replaces it with the end of *each* dynamic component it decodes. It returns the end of the **last** component in declaration order, not the furthest byte read.
- For dynamic element types, `decode_array` returns `last_offset`, the end of the last element only. That value is `nil` when `size == 0`. This nil case is reported on its own as `lua-09`; this entry covers the general root cause.

As a result:
1. **Valid encodings are rejected.** The ABI spec lets tails appear in any order, and Solidity's decoder accepts such layouts. When tails are not in component order (for example `(bytes,bytes)` with the second tail stored first), the last component's end falls before `#data`, and the decoder raises `ABI data too long` / `calldata too long`.
2. **The decoder's own canonical output is rejected** whenever an empty `bytes[]`, `string[]` or dynamic-tuple `[]` is the last dynamic component (the `lua-09` case).
3. **Non-canonical data is accepted.** Two heads can point at one tail (aliasing), and garbage can sit between the head and the first tail, so the assert never actually checks that all data was consumed. The values returned are still the ones the offsets point to, and Solidity is just as lenient, so this part is a strictness gap rather than a wrong-value bug.

**Origin:** Pre-existing. On `origin/main`, `decode_calldata` already rejects reversed tails (`evmu.lua:821: calldata too long`) and accepts aliased tails. This branch (commit `44f37ea`) adds the public `decode_abi`, which reuses the same `decode_tuple`/`decode_array` logic for `eth_call` return data and event log data, giving callers a new way to hit the bug.

**Area:** Lua library `cartesi.evmu` (ABI decoder: `decode_abi`, `decode_calldata`, `decode_calldata_hex`).

**Category:** Correctness (ABI decoding: wrong end-offset / trailing-data check).

**Location:**
- `src/cartesi/evmu.lua:726-755`: `decode_array`, which returns `last_offset` (end of the last element; `nil` for `size == 0`).
- `src/cartesi/evmu.lua:757-783`: `decode_tuple`, where `new_offset` is replaced by each dynamic component's end (lines 767-773).
- `src/cartesi/evmu.lua:831`: `decode_calldata`, `assert(offset == #calldata_raw, "calldata too long")`.
- `src/cartesi/evmu.lua:846`: `decode_abi`, `assert(offset == #data, "ABI data too long")`.

**Evidence:** The test builds raw ABI words by hand (`w(n)` is a 32-byte big-endian word, and `bytes(s)` is a length word followed by padded data) and checks six cases. Run from the repo root with `eval $(make -s env); lua5.4 bugs/lua-29-evmu-end-offset-last-dynamic-only/test_end_offset_last_dynamic.lua`:
```
BUG: aliased tails accepted: {0xcd,0xcd} (128 bytes, only one tail)
BUG: 32-byte garbage gap before tail accepted: 0xcd
BUG: valid out-of-order tails rejected: .../src/cartesi/evmu.lua:846: ABI data too long
BUG: canonical empty string[] rejected: .../src/cartesi/evmu.lua:846: ABI data too long
BUG: decode_calldata rejects its own encode_calldata output for empty bytes[]: .../src/cartesi/evmu.lua:831: calldata too long
BUG: decode_abi rejects encode_abi output for empty string[]: .../src/cartesi/evmu.lua:846: ABI data too long
exit=1
```
The inputs were:
- Aliased: `w(0x40)..w(0x40)..bytes("\xcd")` as `(bytes,bytes)`.
- Gap: `w(0x40)..<32 x 0xff>..bytes("\xcd")` as `(bytes)`.
- Reversed: `w(0x80)..w(0x40)..bytes("\xef")..bytes("\xcd")` as `(bytes,bytes)`, which decodes to `{0xcd,0xef}` under the ABI spec.

Running the same reversed and aliased inputs through `origin/main`'s `decode_calldata` gives `false  evmu.lua:821: calldata too long` and `true` respectively.

**Scenario:**
- A validator or Rollups/Dave component written in Lua uses `cartesi.evmu.decode_abi` to decode an `eth_call` result or event log. If a contract getter returns, or an event emits, an empty `string[]`/`bytes[]`/dynamic-tuple array as its last dynamic field, the call throws on legitimate chain data. The node cannot process that response or event until the code is patched. The same happens with any producer (a hand-written or non-Solidity encoder, or a precompile or proxy) that lays tails out in a different order.
- An application inside the machine that decodes input calldata with `decode_calldata` (for example `bytes[]` batches) rejects valid inputs, such as an empty batch, and may reject or revert legitimate user transactions.
- Code that relies on `decode_abi`/`decode_calldata` to reject non-canonical encodings (for example, for replay or uniqueness, or for hashing the raw bytes it accepted) gets two different byte strings that decode to the same value.
- The in-tree PRT node's current ABI types (uint, `bytes32[]`, static tuples, `bytes`) do not include arrays of dynamic elements as the last dynamic field, so the PRT path is unlikely to hit this in practice. No machine hash, proof or step log is involved.

**Possible solution:**
- Track the furthest extent read instead of the last-decoded tail. In `decode_tuple`, start with `end = tuple_start + static_size` and set `end = max(end, tail_end)` for each dynamic component. In `decode_array`, start with `end = array_data_start + 32*size` for dynamic elements, which also fixes the `size == 0` nil, and take the max over elements.
- For a strict decoder, also check that the tails cover `[head_end, end)` exactly with no overlap or gap: sort the tails by offset and require each one to start where the previous one ended. This rejects aliasing and gaps while still accepting any order. Alternatively, keep lenient Solidity-like behaviour and use the max-extent check only.

**Severity:** Low. Both reviewers rated it low. The decoder only *throws* on some valid inputs (out-of-order tails, empty dynamic-element arrays in the last dynamic position), never returns wrong values for canonical data, and does not affect hashes, proofs or the C API. The PRT contract types in use do not trigger it. Accepting aliased or gapped data matches Solidity's own leniency. One could argue for medium because the library fails to round-trip its own encoder's output; that case is rated medium on its own as `lua-09`.

**Risks:**
- *Of the bug:* Throwing on valid chain data can stall a Lua-based validator or indexer on one response or event until someone patches it. In-machine apps may reject legitimate inputs. Users who assume the length assert makes the decoder strict get non-unique encodings accepted.
- *Of the fix:* The max-extent fix is local and low risk. It only changes which inputs raise, not the values decoded for accepted inputs. A strict no-overlap/no-gap check would newly reject non-canonical encodings that some producers (and Solidity's decoder) accept, so it should be optional or documented, and should not be applied to data that only needs to be interoperable.

**Proof of concept:** `bugs/lua-29-evmu-end-offset-last-dynamic-only/test_end_offset_last_dynamic.lua`. Run from the repo root with `eval $(make -s env); lua5.4 bugs/lua-29-evmu-end-offset-last-dynamic-only/test_end_offset_last_dynamic.lua`. It needs no machine images. It exits 1 with `BUG:` lines while the bug is present and prints `PASS` once it is fixed. Under a lenient (Solidity-like) fix, the first two checks (aliasing and gap) are expected to keep reporting and can be dropped.

**ID**: `lua-29-evmu-end-offset-last-dynamic-only`

**Related**: [B17](#b17-abi-decoder-rejects-canonical-empty-arrays-of-dynamic-types).

### B44. JSON parsers truncate 64-bit log2 sizes in access logs and proofs without range checks

**Title**: JSON parsing truncates a 64-bit access `log2_size` to `int` without a range check, and the proof parser's `log2_target_size` bound check tests `log2_root_size` instead

**Problem**: Two validation gaps in the JSON-to-C++ parsers in `src/json-util.cpp`:
1. Access-log parser (`ju_get_opt_field(..., access&)`). It reads `log2_size` as `uint64_t` and calls `access.set_log2_size(static_cast<int>(log2_size))` with no range check. `access::set_log2_size(int)` does not validate the value either. So `4294967299` (2^32+3) silently becomes `3`.
2. Proof parser (`ju_get_opt_field(..., not_default_constructible<hash_tree_proof>&)`). After reading `log2_target_size` it checks `if (log2_root_size > INT_MAX)` again. This is a copy-paste error: the error message names `log2_target_size`, but `log2_target_size` itself is never bounds-checked before `static_cast<int>`. An out-of-range target size wraps (2^32+5 becomes 5). An out-of-range root size is correctly rejected.

So the emulator accepts non-canonical JSON: a log or proof whose literal field values differ from the values the emulator actually uses.

**Origin**: Pre-existing. This branch changes only 2 unrelated lines of `src/json-util.cpp`.

**Area**: json-util access log / proof parsing (C API `cm_verify_step_uarch` / `cm_verify_*` JSON inputs, Lua `verify_*`, JSON-RPC client `get_proof`).

**Category**: api-contract (input validation).

**Location**:
- `src/json-util.cpp:1377-1379`: access `log2_size` read as `uint64_t`, then `static_cast<int>` with no range check
- `src/json-util.cpp:1214-1219`: second bound check tests `log2_root_size` instead of `log2_target_size`, followed by `static_cast<int>(log2_target_size)`
- `src/access-log.hpp:84`: `set_log2_size(int)` does no validation
- Reached via `cm_verify_step_uarch` and the other `cm_verify_*` functions (access logs), and via `jsonrpc_machine::do_get_proof` (`src/jsonrpc-machine.cpp:869`)

**Evidence**: `test.lua` records a real uarch step log and sets `accesses[1].log2_size = 2^32+3`. `verify_step_uarch` still accepts it and returns the correct post-state root. The test then runs a real `cartesi-jsonrpc-machine` behind `proxy.py`, which adds 2^32 to one field of the `machine.get_proof` result. The client rejects the out-of-range `log2_root_size` but accepts the out-of-range `log2_target_size` and wraps it to 5:
```
verify_step_uarch with accesses[1].log2_size=4294967299 ->	true	true
BUG: verify_step_uarch accepted access log2_size=4294967299 (truncated to int 3, no range check)
get_proof with server log2_root_size=64+2^32   ->	false	...test.lua:49: jsonrpc server error: "result/log2_root_size" is out of bounds
get_proof with server log2_target_size=5+2^32  ->	true	log2_target_size=5
BUG: JSON-RPC client accepted get_proof result with log2_target_size=4294967301 (wrapped to 5); bound check tests log2_root_size instead of log2_target_size
```
Run with `eval $(make -s env); lua5.4 bugs/api-12-access-log2-size-truncation/test.lua`. Exit code 1 means the bug is present.

**Scenario**: A tool (relay, archiver, dispute helper) receives a JSON access log, checks it with `cm_verify_step_uarch`, and forwards the same JSON to a downstream encoder or external verifier that reads `log2_size` as a 64-bit value. The emulator accepts the log, but the downstream consumer sees a different access size, so the two disagree on the same artifact. Separately, a buggy or malicious JSON-RPC server can return a `get_proof` result with a huge `log2_target_size`, and the client accepts it silently instead of rejecting it. The emulator itself stays internally consistent: it verifies against the truncated value, which matches the real access. So no wrong state transition is accepted and no honest transition is rejected. Honest PRT nodes (Dave, Rollups Node) produce their own logs and proofs locally, and on-chain step verification uses the Solidity step contract, so an honest player cannot lose a dispute because of this.

**Possible solution**:
- In the access parser, reject `log2_size > INT_MAX`, or better, anything outside the valid range (for example `[3, 63/64]`), before the cast.
- In the proof parser, change the second check to `if (log2_target_size > INT_MAX)`.
- Optionally, make `access::set_log2_size` assert or validate its argument.

**Severity**: Low. Both reviewers and the prover agree. No hash, proof or verification result changes, and nothing crashes or hangs. The only effect is that malformed JSON is accepted when it should be rejected, which matters only to 64-bit downstream consumers or to clients of an untrusted JSON-RPC server.

**Risks**:
- Of the bug: different tools can parse the same JSON log or proof differently. The parser does not do what its own error message says, and similar copy-paste gaps may hide elsewhere.
- Of the fix: minimal. Previously accepted malformed inputs with wrapped sizes will now be rejected, which is the intended behavior. No well-formed log or proof is affected.

**Proof of concept**: `bugs/api-12-access-log2-size-truncation/test.lua` and its helper `bugs/api-12-access-log2-size-truncation/proxy.py` (a JSON-RPC proxy that tampers with `machine.get_proof` results; needs `python3` and `cartesi-jsonrpc-machine` on PATH). Run from the repo root with `eval $(make -s env); lua5.4 bugs/api-12-access-log2-size-truncation/test.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and prints `OK: no bug` once it is fixed.

**ID**: `api-12-access-log2-size-truncation`

### B45. ABI decoder amplifies memory use through aliased dynamic offsets

**Title**: evmu ABI decoder: aliased dynamic-element offsets cause quadratic (nested: exponential) memory/CPU amplification

**Problem**: `cartesi.evmu`'s ABI decoder follows each head offset of a dynamic element or component independently. It never checks that offsets increase, that element ranges do not overlap, or that the total decoded size stays bounded. Every element of a `bytes[]` / `string[]` (or any array/tuple of dynamic types) can point at the same large tail. `decode_bytes` / `decode_string` then make a fresh `calldata:sub(...)` copy for each element; Lua 5.4 does not intern long strings, so each copy is a separate L-byte allocation. With `prefer="hex"` (the default for `bytes`) every copy also goes through `tohex`, which doubles its size and adds CPU time. Memory grows as N*L for an input of about 32N+L bytes, and each nesting level multiplies it. The decoders return the end offset of the *last* element, so the trailing `offset == #data` / `offset == #calldata_raw` "too long" checks still pass on aliased input.

**Origin**: pre-existing. `decode_calldata` and `decode_array` / `decode_tuple` are the same on `main`. The branch's new `decode_abi` (commit 44f37ea) exposes the same path for data without a selector.

**Area**: `src/cartesi/evmu.lua` (Lua ABI encode/decode helper shipped in the emulator package).

**Category**: resource exhaustion (memory/CPU amplification, DoS).

**Location**:
- `src/cartesi/evmu.lua:741-750`: `decode_array` dynamic-element loop (offset read, then `decode_value` with no overlap or monotonicity check)
- `src/cartesi/evmu.lua:761-785`: `decode_tuple`, same pattern for dynamic components
- `src/cartesi/evmu.lua:691-724`: `decode_string` / `decode_bytes` make one `sub` copy (and `tohex`) per aliased element
- `src/cartesi/evmu.lua:831`, `:846`: end-offset checks in `decode_calldata` / `decode_abi` that aliased payloads still pass

**Evidence**: `test.lua` builds well-formed but non-canonical ABI payloads whose element offsets all alias one tail, then measures the Lua heap retained after decoding.
```
$ eval $(make -s env); lua5.4 bugs/lua-30-evmu-aliased-offsets-quadratic-memory/test.lua
flat (bytes[]): input=129632 bytes, retained Lua memory=125.1 MiB, ratio=1012x, time=0.18s
BUG: decode_abi('(bytes[])') of 129632-byte input retains 125.1 MiB (1012x amplification) because all 2000 element offsets alias one 65536-byte tail
decode_calldata f(bytes[]): input=129636, retained=125.1 MiB (1012x)
BUG: decode_calldata('f(bytes[])') has the same aliased-offset amplification
nested (bytes[][][]): input=18080 bytes, retained=64.2 MiB, ratio=3722x, time=0.17s
BUG: nested decode_abi('(bytes[][][])') of 18080-byte input retains 64.2 MiB (16^3 aliased copies)
```
(exit status 1 = bug present). The prover also ran the nested case with `prefer="hex"` and a 16 KiB tail: an 18 KB input retained 128 MiB and took 21 s of CPU.

**Scenario**: A Lua validator, indexer or tool built on `cartesi.evmu` decodes attacker-influenced ABI data containing arrays of dynamic types. Examples are inputs, vouchers or notices from an untrusted app whose schema has `bytes[]`, `string[]` or nested dynamic arrays. A payload of a few KB to a few hundred KB makes the decoder allocate hundreds of MiB to GiB and burn CPU, so the process runs out of memory or stalls. Hashes, proofs, step logs and the C API are not involved. The PRT recipe node in this branch only decodes `Notice(bytes)` and the EvmAdvance input, which have no arrays of dynamic types, so it cannot hit this path. Solidity's decoder also accepts aliased offsets, but it pays gas for each copy; this decoder has no limit at all.

**Possible solution**: Pick one or more:
- Enforce canonical layout: each dynamic element/component offset must be at least the end of the previous one, and must start inside the region after the head.
- Track the total number of decoded bytes and fail once it exceeds a small multiple of `#data` (a "max inflation" guard, like the one ethers.js v6 has).
- Memoize decoded values by `(absolute offset, type)` so aliased elements share one Lua value instead of getting new copies.

**Severity**: low. Both reviewers and the prover agree. This is a real DoS amplification, but it is limited to an optional Lua helper. It cannot change hashes, proofs or dispute outcomes, and the shipped PRT node's decode paths cannot reach it. It matters only to third-party Lua tooling that decodes untrusted arrays of dynamic types.

**Risks**:
- Bug: an out-of-memory crash or CPU stall in any Lua process that decodes untrusted dynamic-array ABI data. If that process is a validator or monitor, it goes down; it does not produce a wrong result.
- Fix: strict canonical-offset enforcement would reject some valid but non-canonical encodings that Solidity accepts. That could break interoperability for callers who decode hand-crafted or third-party data. A size cap needs a generous bound so legitimate large payloads still decode. Memoization makes aliased elements share one Lua value, which is only visible if callers mutate the decoded tables.

**Proof of concept**: `bugs/lua-30-evmu-aliased-offsets-quadratic-memory/test.lua`. From the repo root:
```
eval $(make -s env); lua5.4 bugs/lua-30-evmu-aliased-offsets-quadratic-memory/test.lua
```
It exits 1 and prints `BUG:` lines while the amplification is present, and exits 0 once fixed (the amplification ratio stays at or below 64x). It needs about 300 MiB of free memory.

**ID**: `lua-30-evmu-aliased-offsets-quadratic-memory`

**Related**: [B43](#b43-abi-decoders-trailing-data-check-uses-only-the-last-dynamic-tail).

### B46. ABI integer encoders wrap values of 2^512 or more instead of rejecting them

**Title**: evmu integer encoders (encode_calldata / encode_abi) silently wrap values >= 2^512 given as strings instead of rejecting them

**Problem**: `cartesi.evmu` uses a 512-bit bint (256 bits of headroom). `encoded_uint` and `append_encoded_int` call `bint.new(value)`. For a string or bint input, `bint.new` reduces the value modulo 2^512 and raises no error, and the range check then runs on the wrapped value. So the guard rejects values in [2^256, 2^512) but accepts any value >= 2^512 that is congruent mod 2^512 to an in-range value, and encodes that smaller value. Examples: 2^512 encodes as `0`, 2^512+5 encodes as `5` (also for `uint8`), and `int256` given `0x` followed by 128 `f`s encodes as `-1`.

**Origin**: Pre-existing. The encoders behind `encode_calldata` / `encode_calldata_hex` predate this branch. This branch adds `_M.encode_abi`, which reuses the same encoders and inherits the defect.

**Area**: `src/cartesi/evmu.lua` ABI/calldata encoder. This is a shipped Lua library, installed through `EMU_TO_LUA_PATH` in the Makefile.

**Category**: correctness (silent truncation / missing input validation)

**Location**:
- `src/cartesi/evmu.lua:18-19`: `bint_extra = 256`; `bint(256 + bint_extra)`
- `src/cartesi/evmu.lua:405-410`: `encoded_uint`, `bint.new(value)` followed by the `value >> size == 0` check
- `src/cartesi/evmu.lua:416-423`: `append_encoded_int`, `bint.new(value)` followed by the intmin/intmax check
- `src/cartesi/evmu.lua:627-633`: `_M.encode_abi` (new), plus `_M.encode_calldata` (pre-existing), both reach these encoders

**Evidence**: The test passes the out-of-range values above through the public `encode_abi` and `encode_calldata_hex`. Every call is accepted and returns the wrapped value instead of raising "integer value does not fit in target type":
```
BUG: uint256 2^512+5 (hex string), encode_abi was accepted and encoded as 0x0000000000000000000000000000000000000000000000000000000000000005
BUG: uint256 2^512+5 (hex string), encode_calldata was accepted and encoded as 0xb3de648b0000000000000000000000000000000000000000000000000000000000000005
BUG: uint256 2^512 (decimal string) was accepted and encoded as 0x0000000000000000000000000000000000000000000000000000000000000000
BUG: uint8 2^512+5 was accepted and encoded as 0x0000000000000000000000000000000000000000000000000000000000000005
BUG: int256 2^512-1 (hex string) was accepted and encoded as 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
bint.new(2^512+5) =	5
```
Run: `eval $(make -s env); lua5.4 bugs/lua-31-evmu-encode-int-wraps-mod-2-512/test.lua` (exits 1 while the bug is present). For comparison, values in [2^256, 2^512) are correctly rejected.

**Scenario**: A node or tool built on `cartesi.evmu` (for example, one that builds Rollups or Dave calldata, or event/return data with `encode_abi`) forwards a numeric string from untrusted input, such as a JSON-RPC parameter, a user-supplied amount or a CLI argument, without validating it. If the string is at least 155 decimal digits or 129 significant hex nibbles long, it is encoded as a small, different number and no error is raised. A transaction or input carrying the wrong argument is then signed and submitted. Lua integers can never reach the wrap. Machine hashes, proofs and step logs never pass through this path, so it cannot by itself make an honest PRT player lose a dispute. Applications running inside the machine are unaffected.

**Possible solution**: Reject over-wide inputs before or after parsing. Options:
- (a) For strings, strip the sign, the `0x` prefix and leading zeros, then reject more than 64 hex nibbles or more than 78 decimal digits before calling `bint.new` (the range check then handles the rest).
- (b) Parse with a wider bint that has a guard, or check that `tostring`/`tobase` of the parsed value round-trips to the normalized input.
- (c) Teach the bundled bint's `frombase`/`fromstring` to report overflow instead of wrapping.

**Severity**: low. Both reviewers agree. This is a real silent truncation in a shipped helper library, but it fires only on absurdly large string inputs (>= 2^512) that well-behaved callers never produce. It touches no hashing, proof or step-verification path, and it cannot crash or hang a validator.

**Risks**: Bug: wrong values are encoded into calldata or ABI data without any error when callers forward unvalidated, huge numeric strings, which may cause unintended on-chain actions. Fix: low risk. Stricter parsing could reject inputs that callers currently pass with redundant leading zeros or unusual formatting, so normalize (strip leading zeros) before applying the length check. A fix inside bint itself would affect every other user of the third-party bint module.

**Proof of concept**: `bugs/lua-31-evmu-encode-int-wraps-mod-2-512/test.lua`. Run from the repo root: `eval $(make -s env); lua5.4 bugs/lua-31-evmu-encode-int-wraps-mod-2-512/test.lua`. It prints `BUG:` lines and exits 1 while the bug is present, and prints `PASS` once it is fixed.

**ID**: `lua-31-evmu-encode-int-wraps-mod-2-512`

### B47. ABI encoder emits malformed data for arrays with nil holes

**Title**: evmu ABI encoder silently emits malformed ABI for arrays with nil holes (length/offsets from `#values`, elements from `ipairs`)

**Problem:** `append_encoded_array` takes its counts from `#values`: the fixed-size `T[k]` count check, the dynamic-array length word, and the base offset of the dynamic-element offsets table (`#values * 32`). It writes the elements with `ipairs(values)`, which stops at the first `nil`. If the array table has a hole, such as `{1, nil, 3}`, `#values` may be 3 while only one element is written. `encode_abi`, `encode_calldata` and `encode_calldata_hex` then return malformed ABI data and raise no error. For `T[k]`, the static head is short, so every field after it moves into the wrong slot. Lua's `#` on a table with holes may return any border. A caller can therefore also get a smaller count, such as 1, which yields well-formed ABI with the trailing elements silently dropped.

**Origin:** Pre-existing. `append_encoded_array` is identical on `origin/main`. The branch adds the selectorless `encode_abi`/`decode_abi` entry points, which reach the same code, and the PRT bridge uses them for `bytes32[]` proof arrays.

**Area:** Lua library `cartesi.evmu`, the ABI encoder that ships in the emulator package.

**Category:** Correctness / input validation.

**Location:**
- `src/cartesi/evmu.lua:474-501` (`append_encoded_array`)
- `src/cartesi/evmu.lua:477-478`: `T[k]` count check uses `#values`
- `src/cartesi/evmu.lua:481`: dynamic length word uses `#values`
- `src/cartesi/evmu.lua:484`: static elements written with `ipairs`
- `src/cartesi/evmu.lua:490-492`: offsets base uses `#values * 32`, elements written with `ipairs`
- Reached from `src/cartesi/evmu.lua:611` (`encode_calldata`) and `src/cartesi/evmu.lua:627` (`encode_abi`)

**Evidence:** The test encodes arrays with holes and decodes the result with the module's own `decode_abi`. Every case encodes without an error, and in every case `decode_abi` rejects the output:
```
#vals =	3
uint8[] {1,nil,3} ->	0x..20 ..03 ..01	(96 bytes)
BUG: uint8[] {1,nil,3}: encoded length word says 3 elements but only 1 element words emitted (96 bytes, expected 160)
BUG: encode_abi output for uint8[] cannot be decoded by decode_abi: evmu.lua:39: insufficient calldata for 256-bit word at offset 96
(uint8[3],uint256) ->	0x..01 ..42	(64 bytes)
BUG: (uint8[3],uint256) with {1,nil,3}: static head is 64 bytes, expected 128; following field shifted
BUG: string[] with hole: encoded data is malformed (decode_abi fails: ... insufficient calldata for 256-bit word at offset 160)
BUG: bytes32[] with hole silently encoded into malformed data (decode fails: ... insufficient calldata for bytes32)
exit=1
```
Run: `eval $(make -s env); lua5.4 bugs/lua-32-evmu-encode-array-holes-malformed/test.lua`

**Scenario:** A validator node, or any Lua tool built on `cartesi.evmu`, builds a sibling/proof array (`bytes32[]`) or a fixed-size argument indexed by tree level, and a bug leaves a `nil` at one level. The node does not get an encoding error. It submits malformed calldata, which most likely makes the transaction revert. That turns a simple caller bug into a hard-to-diagnose failed submission (a missed move or a timeout in a dispute). Two rarer cases produce ABI that looks valid but carries the wrong data:
- With `T[k]` followed by more fields, the fields shift into the wrong slots.
- If `#` returns a smaller border, elements are silently truncated.

**Possible solution:** Compute `n = #values` once and loop `for i = 1, n do local v = values[i]; if v == nil then errorf("missing array element at index %u", i) end ... end` for both static and dynamic elements. Optionally, reject tables that have non-sequence keys or integer keys greater than `n` (checked with `pairs`), so that a truncating border is also caught.

**Severity:** Low. Both reviewers agree. The bug fires only when the caller already has a bug (a nil inside an array). The usual result is calldata that contracts and `decode_abi` reject, not accepted wrong values. It does not affect emulator hashes or proofs, and it cannot make an honest player who builds proofs correctly lose a dispute.

**Risks:**
- Of the bug: silent malformed or shifted calldata instead of a clear error. In rare cases, a different border from `#` can give well-formed ABI with wrong or truncated arguments, and the behaviour can depend on how the table was built.
- Of the fix: minimal. Callers that currently pass tables with holes and rely on the output (already malformed) will get an error instead. The added checks are O(n) and negligible.

**Proof of concept:** `bugs/lua-32-evmu-encode-array-holes-malformed/test.lua`. From the repo root: `eval $(make -s env); lua5.4 bugs/lua-32-evmu-encode-array-holes-malformed/test.lua`. It prints `BUG:` lines and exits 1 while the bug is present, and prints `OK` and exits 0 once fixed.

**ID**: `lua-32-evmu-encode-array-holes-malformed`

### B48. evmu hex decoding accepts sign characters

**Title**: evmu `fromhex`/`decode_hex` accepts `+`/`-` sign characters: malformed hex is silently decoded, or raises instead of returning `nil, err`

**Problem**: `fromhex` checks only for whitespace, the `0x` prefix and even length. It then decodes each 2-character group with `tonumber(c, 16)` and treats only a `nil` result as invalid. In Lua 5.4, `tonumber` with a base accepts a leading sign, so `"+f"` gives 15, `"-0"` gives 0 and `"-1"` gives -1. This has three effects:
- `"0x+f"` decodes to `"\x0f"` and `"0x-0"` decodes to `"\0"`. Both are malformed and should be rejected.
- `"0x-1"` through `"0x-f"` pass a negative value to `string.char`. That raises `bad argument #1 to 'char' (value out of range)` instead of returning the documented `nil, err`.
- The function feeds every hex-typed argument of the encoders. As a result, a malformed address such as `"0x" .. ("+f"):rep(20)` is silently encoded as `0x0f0f…0f`.

**Origin**: pre-existing. `origin/main` has the same `tonumber(c, 16)` line, and the branch's evmu change (selectorless ABI encode/decode) does not touch `fromhex`.

**Area**: `cartesi.evmu` Lua library, hex helpers. The library ships: `evmu.lua` is in `EMU_TO_LUA_PATH`.

**Category**: api-contract / input validation

**Location**:
- `src/cartesi/evmu.lua:56-76`: `fromhex`. The `tonumber(c, 16)` call is at line 64 and the `string.char(n)` that raises is at line 69.
- `src/cartesi/evmu.lua:636`: `_M.decode_hex = fromhex`.
- `src/cartesi/evmu.lua:389-402`: `get_raw_expect_hex` and `get_raw_expect_raw`, used by the address, `bytesN` and `bytes` encoders in `encode_calldata`/`encode_abi`. `decode_calldata_hex` also calls `fromhex`.

**Evidence**: running the test from the repo root with `eval $(make -s env); lua5.4 bugs/lua-33-evmu-fromhex-sign-chars/test-fromhex-sign-chars.lua` prints:
```
decode_hex('0x+f') ->	true	"\15"	nil
BUG: decode_hex accepted '0x+f' as "\15" (should return nil,err)
decode_hex('0x-0') ->	true	"\0"	nil
decode_hex('0x-1') ->	false	.../src/cartesi/evmu.lua:69: bad argument #1 to 'char' (value out of range)
encode_calldata_hex('f(address)', {0x+f+f+…+f}) ->	true	0xfc68521a0000000000000000000000000f0f0f…0f
exit=1
```

**Scenario**: a Lua caller (for example a validator node, a Rollups tooling script or a CLI wrapper) uses `evmu.decode_hex` to validate hex from an external source such as a JSON-RPC provider, a config file or user input, and expects `nil, err` on bad input. Two things can go wrong:
- A string with `-X` groups raises an error. Without a `pcall`, that error propagates and can crash the caller.
- A string with `+X` or `-0` groups is accepted as valid, with content different from what was apparently intended.

The same happens when such a string is passed as an `address` or `bytes` argument to `encode_calldata`/`encode_abi`. Well-formed hex is always decoded correctly. Machine hashes, proofs and step logs do not depend on evmu. Within the package, no CLI or C API path feeds untrusted hex to it.

**Possible solution**: reject any non-hex-digit character before decoding, for example `local bad = hex:find("[^%x]", 3); if bad then return nil, string.format("hex string cannot contain %q", hex:sub(bad, bad)) end`. Alternatively, validate each group with `c:match("^%x%x$")` before calling `tonumber`.

**Severity**: low. Both reviewers rated it low. The bug cannot affect machine state, hashes, proofs or dispute outcomes, and it needs malformed external hex containing sign characters. Its effects are limited to two: malformed input is accepted, or an exception is raised (catchable with `pcall`) where `nil, err` was expected. The assert-based encoder paths raise on bad hex anyway.

**Risks**:
- Bug: hex that should be rejected is accepted with different content, which could matter for a caller that uses `decode_hex` as a validator. Callers that rely on the `nil, err` contract can also hit an unexpected error.
- Fix: minimal. It makes only already-malformed input fail, so any caller that currently depends on `"+f"`-style strings being accepted would start getting errors. That is the intended behaviour.

**Proof of concept**: `bugs/lua-33-evmu-fromhex-sign-chars/test-fromhex-sign-chars.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/lua-33-evmu-fromhex-sign-chars/test-fromhex-sign-chars.lua`. It exits 1 and prints `BUG:` lines while the bug is present, and exits 0 once it is fixed.

**ID**: `lua-33-evmu-fromhex-sign-chars`

### B49. Lua hash functions ignore an empty second argument and frontier functions accept non-32-byte hashes

**Title**: `cartesi.keccak256`/`sha256(h, "")` and `(h, nil)` return `hash(h)` instead of raising an error; in-memory hash-tree frontier and proof functions accept entries that are not 32 bytes

**Problem**: `cartesi_mod_hasher` reads its second argument with `luaL_optlstring(L, 2, "", &len2)` and takes the two-hash concat path only `if (len2 > 0)`. So `keccak256(h, "")` and `keccak256(h, nil)` (and the same calls to `sha256`) look exactly like the one-argument call. They return `hash(h)` with no error, although the two-argument form is documented as the hash of two 32-byte hashes. The check is also asymmetric: `("", h)` and `(h, 31-byte)` raise an error, but `(h, "")` does not. The in-memory functions in `cartesi.hash-tree` pass caller entries straight to `hash_function(left, right)` without checking that they are 32-byte hashes. These are `frontier_push_back`, `frontier_append`, the pad of `frontier_get_root_hash`, `frontier_pad_back`, `frontier_next_proofs`, and `roll_hash_up_tree`/`verify_slice`. When an empty right-hand entry reaches them, they build a wrong node or root and report nothing. Only `frontier_load` and `load_tree` check sizes with `is_raw_hash`. A 31-byte entry is accepted on insertion and fails only later, inside a root or proof computation, with a confusing error.

**Origin**: Pre-existing. `cartesi_mod_hasher` is the same as on `origin/main`. The frontier functions already exist on `main`; this branch extends them, and the PRT node uses them.

**Area**: The Lua bindings (`src/clua-cartesi.cpp`) and the shipped Lua module `cartesi.hash-tree` (`src/cartesi/hash-tree.lua`), which validators use to build output and computation commitments and their proofs.

**Category**: Correctness / input validation (fail-open).

**Location**:
- `src/clua-cartesi.cpp:64-101` (`cartesi_mod_hasher`: `luaL_optlstring(L, 2, "", ...)` at line 77, `if (len2 > 0)` at line 81)
- `src/cartesi/hash-tree.lua:9-23` (`roll_hash_up_tree`, used by `verify_slice`)
- `src/cartesi/hash-tree.lua:165-178` (`frontier_push_back`)
- `src/cartesi/hash-tree.lua:186-214` (`frontier_append`)
- `src/cartesi/hash-tree.lua:219-238` (`frontier_get_root_hash`, `pad` argument)
- `src/cartesi/hash-tree.lua:248` (`frontier_pad_back`)
- `src/cartesi/hash-tree.lua:310-359` (`frontier_next_proofs`)
- For contrast: `src/cartesi/hash-tree.lua:516` (`is_raw_hash`, used only by the load paths at lines 543, 548, 949 and 1008)

**Evidence**: The test runs each case under `pcall`. The only cases that raise an error are the ones where the empty value is the left operand. Excerpt:
```
BUG: keccak256(a, "") returned keccak256(a) instead of raising an error
BUG: keccak256(a, nil) returned keccak256(a) instead of raising an error
ok: keccak256("", a) raises: true (bad argument #1 to 'cartesi.keccak256' (concatenate hash is only supported for inputs with size of hash))
BUG: sha256(a, "") returned sha256(a) instead of raising an error
BUG: frontier_push_back(f, "") accepted; f[2] == keccak256(a) (single-input hash of left sibling)
BUG: frontier_push_back(f, 31-byte entry) accepted; later root computation fails late with: .../hash-tree.lua:229: bad argument #1 to 'hash_function' (...)
BUG: frontier_get_root_hash(f, "") accepted empty pad, returned 0x9de88bce...334270e
BUG: frontier_next_proofs(f, {a, ""}) accepted; root 0xb839c4dc...4634a8f1, target_hash[2] length 0
   proof[1] verifies against that root: true
BUG: verify_slice accepted a proof with an empty sibling hash (root = keccak256(target))
9 defect(s) observed
```
Run: `eval $(make -s env); timeout 30 lua5.4 bugs/lua-15-concat-hash-empty-second-arg/test.lua` (exit status 1 while the bug is present).

**Scenario**: A Lua validator (the PRT node, or another node built on the same `cartesi` / `cartesi.hash-tree` APIs) builds its outputs or computation commitment with `frontier_push_back`, `frontier_append` or `frontier_next_proofs`. A bug in the caller can feed it `""` or `nil` instead of a hash, for example an off-by-one index into a table of hashes, a missing field, or a truncated read. Lua code hits these mistakes easily. The library does not fail loudly. It computes a commitment that looks valid but is wrong, and the node posts it, so an honest player can end up defending a wrong claim. Code that calls `keccak256(left, right)` directly, with `right` coming from a sparse table, makes the same silent mistake. An adversary cannot exploit this. A forged proof cannot be made to verify against an honest root, because the bogus parent `keccak256(child)` would have to match a node built from 64 bytes, which needs a preimage. Every hash the C API returns is exactly 32 bytes.

**Possible solution**: In `cartesi_mod_hasher`, choose the concat path with `nargs == 2` (or `!lua_isnoneornil(L, 2)`) instead of `len2 > 0`, and require both inputs to be `CM_HASH_SIZE`. Decide whether an explicit `nil` second argument is an error or the one-argument form, and document the choice. Optionally, assert `is_raw_hash` on the entries, pads and siblings that `frontier_push_back`, `frontier_append`, `frontier_pad_back`, `frontier_get_root_hash`, `frontier_next_proofs` and `roll_hash_up_tree` receive, so that bad input is rejected when it enters, not deep inside a later computation.

**Severity**: Low. All three reviewers rated it low, and one of them argued it is not a defect. With well-formed 32-byte inputs every hash and proof is correct and deterministic, verification cannot be fooled, and there is no crash or hang. The impact is fail-open behaviour that turns a separate caller bug into a silently wrong commitment instead of an error.

**Risks**: Of the bug: a caller-side mistake goes unnoticed and leads to a wrong on-chain commitment or proof, which in the worst case makes an honest validator lose a dispute. It also makes such bugs harder to diagnose, because the error, if any, appears far from its cause. Of the fix: code that today calls `keccak256(x, nil)` or `keccak256(x, "")` on purpose to mean "hash x" would start raising an error. A search of in-tree callers is needed. Size asserts in the frontier functions cost a little time on hot paths, which matters little next to the hashing itself.

**Proof of concept**: `bugs/lua-15-concat-hash-empty-second-arg/test.lua`. Run it from the repo root with `eval $(make -s env); timeout 30 lua5.4 bugs/lua-15-concat-hash-empty-second-arg/test.lua`. It prints one `BUG:` line per accepted malformed input and exits with 1 while the bug is present, and with 0 once it is fixed.

**ID**: `lua-15-concat-hash-empty-second-arg`

### B50. rename_stored and remove_stored with a trailing slash succeed, then fail and skip the parent fsync

**Title**: rename_stored/remove_stored with a trailing-slash path complete the operation, then fail with ENOENT and never fsync the real parent

**Problem:** `parent_directory()` returns `std::filesystem::path(dir).parent_path()`. For a path with a trailing slash such as `"st/a/"`, the final path element is empty, so it returns `"st/a"`, the directory itself, instead of `"st"`. As a result:
- `rename_stored("st/a/", "st/b/")` renames the directory (Linux accepts trailing slashes on directory renames). It then fsyncs `"st/b"`, the renamed directory rather than its parent. Because `"st/a"` differs from `"st/b"`, it then calls `sync_directory("st/a")`, which no longer exists, so it throws ENOENT.
- `remove_stored("st/c/")` deletes every file and the directory, then calls `sync_directory("st/c")` on the directory it just removed, which throws ENOENT.

In both cases the caller gets an error for an operation that has already happened, and the real parent directory `"st"` is never fsynced. That breaks the durability contract in `cm.h`, which says the affected or removed parent directory entries are durable on success. `sync_stored` builds the parent as `dir + "/.."`, so it is not affected, and the path-handling helpers disagree with each other.

**Origin:** Pre-existing. `origin/main` has the same `parent_directory`, `rename_stored` and `remove_stored` code (around `src/machine.cpp:545-616`), and this branch does not change it.

**Area:** Stored machine management (`machine.cpp`), reachable through the C API (`cm_rename_stored`, `cm_remove_stored`), the Lua bindings, JSON-RPC and the CLI.

**Category:** Durability / error reporting.

**Location:**
- `src/machine.cpp:548-554`: `parent_directory()`
- `src/machine.cpp:562-569`: `rename_stored` (syncs `to_parent`, then the vanished `from_parent`)
- `src/machine.cpp:619`: `remove_stored` (syncs the removed directory)
- `src/cm.h:586-602`: the durability contract it breaks

**Evidence:** The Lua test stores a machine at `st/a`, then calls `rename_stored('st/a/', 'st/b/')`. The call raises an error even though `st/a` is gone and `st/b/config.json` exists. It then stores `st/c` and calls `remove_stored('st/c/')`, which raises an error even though `st/c` is gone. Run with `eval $(make -s env); lua5.4 bugs/w2b-03-rename-remove-stored-trailing-slash/test.lua`:
```
rename_stored('a/','b/'): ok=false err=unable to sync directory '/tmp/w2b-03-rename-remove-stored-trailing-slash-st/a': open() failed: No such file or directory; a exists=false b exists=true
BUG: rename_stored with trailing slash renamed the directory on disk but reported failure: ...
remove_stored('c/'): ok=false err=unable to sync directory '/tmp/w2b-03-rename-remove-stored-trailing-slash-st/c': open() failed: No such file or directory; c exists=false
BUG: remove_stored with trailing slash removed the directory on disk but reported failure: ...
exit=1
```

**Scenario:** A PRT validator, Dave or Rollups Node deployment takes its snapshot directory from a config value such as `"snapshots/"`, or from a shell-completed path, and builds machine paths with a trailing slash. Snapshot rotation calls `rename_stored("snapshots/next/", "snapshots/current/")`, gets an error, and treats the rotation as failed. A retry then also fails, because the source no longer exists. Revert logic that calls `remove_stored` and then `rename_stored` stops after the first step, leaving neither the old state nor the backup in place. The parent directory entry is also never fsynced, so after a power loss the rename or removal can be undone. The CLI's `revert_stored` passes the user's `--load-dir`/`--create-dir` value straight to these calls, so a trailing slash there has the same effect. Hashes, proofs and step logs are not affected.

**Possible solution:** Normalise the path before taking its parent. For example, strip trailing separators (`path p(dir); if (p.filename().empty()) p = p.parent_path(); parent = p.parent_path();`, keeping the `"."` fallback). Another option is to use the same `dir + "/.."` approach as `sync_stored`, computed before the rename or removal. Add regression tests for rename and remove with trailing-slash paths, and for root-relative and `"./"` forms.

**Severity:** medium. Both reviewers agreed. The API reports failure for an operation that has already taken effect and skips the parent fsync it promises, which can derail a caller's rotation or revert logic and lose the change after a crash. It only occurs with trailing-slash paths, which are legitimate but uncommon for nodes that build paths in code, and it never affects hashes, proofs or dispute outcomes.

**Risks:**
- *Of the bug:* Callers get a misleading error and may take the wrong recovery action, such as retrying or rolling back based on wrong state. A crash after the call can lose the rename or removal, because the parent directory entry was never made durable.
- *Of the fix:* Very low. It only changes which directory gets fsynced. Edge cases to check are `"/"`, `"a//"`, `"./a/"` and bare names (which should still map to `"."`), and that `from_parent`/`to_parent` still compare equal when they refer to the same directory, so it is not synced twice needlessly.

**Proof of concept:** `bugs/w2b-03-rename-remove-stored-trailing-slash/test.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/w2b-03-rename-remove-stored-trailing-slash/test.lua
```
It exits with status 1 and prints `BUG:` lines while the bug is present, and prints `OK` once it is fixed. It works in `$WORKDIR` if set, otherwise in `${TMPDIR:-/tmp}/w2b-03-rename-remove-stored-trailing-slash-st`.

**ID**: `w2b-03-rename-remove-stored-trailing-slash`

**Related**: [B07](#b07-interrupted-remove_stored-leaves-a-directory-that-blocks-the-name-forever).

### B51. log_step on an empty or destroyed local machine dereferences a null pointer

**Title**: `local_machine::do_log_step` skips the `get_machine()` null check, so `cm_log_step` / `machine:log_step` on an empty or destroyed local machine segfaults instead of returning "no machine"

**Problem**: `local_machine::do_log_step` calls `m_machine->log_step(mcycle_count, filename)` directly. Every other `do_*` method in `src/local-machine.cpp` calls `get_machine()`, which throws `std::runtime_error{"no machine"}` when `m_machine` is null, and this is the only bare `m_machine->` dereference in the file. `m_machine` is null on a handle from `cm_new()` / `cartesi.new()` that was never created or loaded, and after `cm_destroy()` / `machine:destroy()` (`do_destroy` deletes the machine and sets the pointer to null). In that state `cm_log_step` dereferences a null pointer. Its `try`/`catch(...)` cannot catch a SIGSEGV, so the host process crashes. Every sibling API (`cm_run`, `cm_get_root_hash`, `cm_log_step_uarch`, `cm_get_proof`, ...) returns `CM_ERROR_RUNTIME_ERROR` "no machine" on the same handle. The Lua binding has the same defect because `machine_obj_index_log_step` passes the handle straight to `cm_log_step`, and `pcall` cannot recover from the crash.

**Origin**: pre-existing. `origin/main` has the same line (`src/local-machine.cpp:112-113`). This branch adds only 4 unrelated lines to the file.

**Area**: libcartesi C API / `local_machine` (local machines only). The JSON-RPC server is not affected: `jsonrpc_machine_log_step_handler` (`src/jsonrpc-remote-machine.cpp:1168`) checks `if (!session->handler->machine)` and returns "no machine" before it calls `log_step`.

**Category**: crash (null-pointer dereference / SIGSEGV)

**Location**:
- `src/local-machine.cpp:112-114`: `do_log_step` uses `m_machine->` instead of `get_machine()->`
- `src/local-machine.cpp:62-74`: the `get_machine()` guard that this method skips
- `src/local-machine.cpp:212-215`: `do_destroy` nulls `m_machine`
- `src/i-machine.hpp:139-140`: `i_machine::log_step` forwards to `do_log_step` without a check
- `src/cm.cpp:865-881`: `cm_log_step` validates only `log_filename`, then forwards
- `src/clua-i-machine.cpp:850-853`: `machine_obj_index_log_step` calls `cm_log_step`

**Evidence**: Each call runs in a child process. As a control, `cm_run` on an empty `cm_new()` handle returns -6 "no machine", but `cm_log_step` on the same handle dies with signal 11. In Lua, `get_root_hash` on a destroyed machine raises "no machine", while `log_step` on a `cartesi.new()` machine or on a destroyed machine segfaults, even inside `pcall`. Run: `eval $(make -s env); sh bugs/w2b-02-log-step-empty-machine-null-deref/run.sh`
```
== C API ==
  cm_run (control) returned -6: no machine
OK: cm_run (control) on empty machine returned an error
BUG: cm_log_step on empty machine killed process with signal 11 (Segmentation fault) instead of returning an error
== Lua ==
  ok=false err=no machine
OK: control: get_root_hash on destroyed machine raised an error
Segmentation fault
BUG: log_step on cartesi.new() machine crashed the process (exit 139) instead of raising an error
Segmentation fault
BUG: log_step on destroyed machine crashed the process (exit 139) instead of raising an error
```

**Scenario**: A PRT validator or Dave node uses `cm_log_step` to produce big-machine step proofs, and it runs the machine in process. Two cases hit the bug:
- An error path calls `cm_destroy()`, and a later retry or cleanup step still calls `cm_log_step` on that handle.
- A `cm_create`/`cm_load` failure leaves the `cm_new()` handle empty, and the code does not check the return value before calling `cm_log_step`.

In both cases the node process crashes with SIGSEGV. Every other call on that handle would have returned a recoverable "no machine" error that the node could log and handle. Lua tooling built on `cartesi.new()` / `machine:destroy()`, such as test harnesses and CLI scripts, fails the same way, and `pcall` cannot catch it. Rollups Node and other users of `cartesi-jsonrpc-machine` are not affected, because the server checks for a missing machine.

**Possible solution**: In `local_machine::do_log_step`, replace `return m_machine->log_step(mcycle_count, filename);` with `return get_machine()->log_step(mcycle_count, filename);`. Optionally, add a regression test that calls every `cm_*` machine method on an empty and on a destroyed handle and expects "no machine". That would catch this omission and any future one.

**Severity**: low. The bug only triggers when a caller misuses a handle (never created or loaded, or already destroyed). Correct validators that check return codes never reach it. Hashes, proofs, step logs and dispute outcomes are never affected. The only effect is a process crash where every other API returns a recoverable error. The prover suggested medium, but both reviewers rated it low (at most borderline medium) because it needs a caller bug and has no integrity impact. This entry uses their rating.

**Risks**:
- Of the bug: a caller bug becomes a crash of the whole host process (validator / node / Lua script) instead of a recoverable error. The crash also loses any in-memory state and leaves a partial or empty step-log file behind. The API also behaves inconsistently, because only `log_step` lacks the guard.
- Of the fix: minimal. It is a one-line change that matches every sibling method. Behavior on valid handles does not change. On an empty handle the call now returns `CM_ERROR_RUNTIME_ERROR` "no machine" and sets `break_reason` to `CM_BREAK_REASON_FAILED`.

**Proof of concept**: `bugs/w2b-02-log-step-empty-machine-null-deref/run.sh` (driver), `test_log_step_empty.cpp` (C API test, compiled against `src/libcartesi`), and `test_log_step_empty.lua` (Lua test: one control case plus a `cartesi.new()` case and a destroyed-machine case). Run from the repo root with libcartesi built: `eval $(make -s env); sh bugs/w2b-02-log-step-empty-machine-null-deref/run.sh`. The script exits non-zero while the bug is present and prints `OK` for every case once it is fixed.

**ID**: `w2b-02-log-step-empty-machine-null-deref`

### B52. A full disk kills a SHARING_ALL machine with SIGBUS on writes to sparse pages

**Title**: A full disk kills the process with SIGBUS when a SHARING_ALL machine writes to a sparse page

**Problem**: When a machine is loaded or created with `SHARING_ALL` (or with shared backing stores), its RAM, flash drive and phtc payload files are mapped `MAP_SHARED` straight from the stored directory, and those files stay sparse. The first write to a page that is still a hole makes the kernel allocate a disk block during the page fault. If the filesystem is full at that point, the kernel raises SIGBUS. The writer can be the guest during `run` or the host through `write_memory` and similar calls. Nothing reserves space when the machine loads: `mapped_memory` only checks that `st_size` equals the expected length, which a sparse file passes, and it never calls `fallocate`/`posix_fallocate`. libcartesi also installs no SIGBUS handler. So the process dies in the middle of an instruction or an API call, and no error ever reaches the caller (no C error code, no Lua error). The `cartesi-jsonrpc-machine` server dies the same way, because it deliberately leaves SIGBUS out of its Asio signal set. The SHARING_ALL directory is left part-written.

**Origin**: Pre-existing. `origin/main` (v0.22.0) has the same `MAP_SHARED` mapping and also reserves no space. The branch makes the failure a little more likely: its new `mapped_memory::clear()` punches holes (`FALLOC_FL_PUNCH_HOLE`) across the shared backing file, so pages written after a clear need disk space again when they fault. Commit ff9ac85 on the branch ("fix: let SIGBUS terminate the JSON-RPC server") deliberately keeps the current kill-on-SIGBUS behaviour and leaves graceful recovery for later.

**Area**: os-mapped-memory / machine load with `SHARING_ALL`, both in-process (C API, Lua, CLI) and in the JSON-RPC server.

**Category**: Crash / robustness: an uncontrolled process kill on ENOSPC instead of a returned error.

**Location**:
- `src/os-mapped-memory.cpp:161-182`: the backing file is checked only by `st_size` against the expected length. Sparse files pass, and no space is reserved.
- `src/os-mapped-memory.cpp:187`, `:227`, `:253`: `MAP_SHARED` mmap of the backing file.
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear()` (added on the branch) punches holes in the shared backing file.
- `src/machine.cpp:1730-1775`: `machine::write_memory` does a plain `memcpy` into the shared mapping, which faults with SIGBUS on ENOSPC.
- `src/jsonrpc-remote-machine.cpp:328`: SIGBUS is deliberately not handled, so the server process dies.

**Evidence**: `test.lua` runs `child.lua` inside `unshare -m`, on a private 60 MiB tmpfs. The child stores a machine with 64 MiB of RAM there; the directory takes about 33 MiB because the RAM file is sparse. It then reloads the machine with `cartesi.SHARING_ALL` and calls `write_memory` one 4 KiB page at a time, wrapping each call in `pcall`. After about 6-7k pages the tmpfs is full and the child is killed by SIGBUS. `pcall` never sees an error. Run with `eval $(make -s env); lua5.4 bugs/w2b-04-sharing-all-enospc-sigbus/test.lua` as root; it takes about 0.2 s and exits 1:
```
stored; df:
tmpfs              61440 33676     27764  55% .../mnt
pages written: 2048
pages written: 4096
pages written: 6144
Bus error
EXIT=135
BUG: process killed by SIGBUS (exit 135) on write_memory to SHARING_ALL machine when disk fills; no error returned
```

**Scenario**: A PRT validator, a Dave node, or anything following `doc/recipes/prt.lua` (lines 1021, 1113, 1172) loads its epoch machine in-process with `SHARING_ALL`. If the host disk fills up while the guest touches fresh RAM or flash pages during `run`, or while the node calls `write_memory` / `send_cmio_response`, the node process is killed with a bare "Bus error". There is no log line and no error to handle. The working directory is left torn in the middle of a step. A Rollups Node or app using a `cartesi-jsonrpc-machine` with shared stores sees the connection drop and gets no reason for it. CLI users running `cartesi-machine` with shared stores see the same crash.

**Possible solution**: Choose one or combine:
- Optionally reserve the backing file's blocks for shared-writable mappings on load and after `clear()`: `posix_fallocate`/`fallocate(mode=0)`, enabled by a runtime flag such as `preallocate`. This turns ENOSPC into a load-time `std::system_error`, at the cost of giving up sparseness.
- Before load or `run`, check free space with `statvfs` against the number of hole blocks (`SEEK_HOLE`/`SEEK_DATA`), and warn or fail early.
- At minimum, document that `SHARING_ALL` needs headroom of up to the full RAM and flash sizes, and have the JSON-RPC server log a clear "SIGBUS on mapped memory (disk full?)" message before it dies, using a `sigaction` handler that only writes and calls `_exit`.

Recovering from SIGBUS inside the library (`siglongjmp`) is fragile and is not recommended.

**Severity**: Low. Both reviewers rated it low and the prover rated it medium. It needs a full host disk, which stops the node in any case. Hashes, proofs and step logs are never wrong. The torn directory is the same outcome as any other crash during a `SHARING_ALL` run, which nodes already have to recover from via snapshots. The practical cost is a sudden kill that is hard to diagnose, instead of a clean error.

**Risks**: Of the bug: an operator whose disk fills sees validators die with no explanation, and the shared working directory is left inconsistent, so recovery depends on a good snapshot or clone existing. Of the fix: preallocating removes the disk savings of sparse RAM and flash images, which can be several GiB per machine and per snapshot. Calling `fallocate` after `clear()` undoes the point of punching holes. A SIGBUS handler that tries to resume execution can corrupt state or loop on the faulting instruction.

**Proof of concept**: `bugs/w2b-04-sharing-all-enospc-sigbus/test.lua` (driver: makes a private mount namespace and a 60 MiB tmpfs; needs root) and `bugs/w2b-04-sharing-all-enospc-sigbus/child.lua` (stores, reloads with `SHARING_ALL`, and writes pages). Run from the repo root: `eval $(make -s env); lua5.4 bugs/w2b-04-sharing-all-enospc-sigbus/test.lua`. Exit 1 means the bug reproduced (SIGBUS); exit 0 means it is fixed (`write_memory` raised an error, or every page was written); exit 2 means `unshare`/`mount` were unavailable.

**ID**: `w2b-04-sharing-all-enospc-sigbus`

**Related**: [B64](#b64-clear_hash_tree-punches-holes-in-shared-hash-files-so-a-full-disk-later-kills-the-process-with-sigbus).

### B53. run aborts when a non-blocking console output descriptor is briefly full

**Title**: `machine:run` aborts with "console output flush failed: Resource temporarily unavailable" when the console output fd is non-blocking and briefly full (EAGAIN is not retried)

**Problem**: When console output goes to stdout, stderr or a `to_fd` descriptor, `machine::run` flushes the guest's console output with one `write()` call. That call is retried only on `EINTR`. If the descriptor is `O_NONBLOCK` and its pipe is momentarily full, `write()` fails with `EAGAIN`/`EWOULDBLOCK`. `machine_console::flush_output` treats every error other than `EPIPE` as fatal and throws `machine_console_exception`. Nothing in `interpret_with_console` catches it, so the exception leaves `machine::run`, and from there `cm_run`, Lua `machine:run`, the JSON-RPC server's run handler and the CLI.

`O_NONBLOCK` is stored on the shared open file description, so a parent that made its own stdout non-blocking (the usual case is Node.js/libuv) passes the flag to an emulator it spawns with inherited stdio. A transient condition (the host is slow to drain console output for a few seconds) then aborts an input-processing run partway through.

The codebase already treats console I/O errors as non-fatal elsewhere: the `collect_*` paths catch `machine_console_exception` and clear the output. Plain `run()` does not.

**Origin**: Pre-existing. `src/machine-console.cpp` and `src/os.cpp` are the same on `origin/main` and on this branch.

**Area**: Machine console / run loop (`src/machine-console.cpp`, `src/os.cpp`, `src/machine.cpp`). Reached through the C API (`cm_run`), the Lua API, `cartesi-jsonrpc-machine` and the `cartesi-machine` CLI.

**Category**: API contract / robustness. Transient host backpressure is reported as a fatal I/O error.

**Location**:
- `src/machine-console.cpp:298-306`: `flush_output` handles only `EPIPE` and throws `machine_console_exception{errno, "console output flush failed"}` for anything else, `EAGAIN` included.
- `src/os.cpp:523-529`: `os::putchars` (HAVE_TTY path, `to_stdout`/`to_stderr`) makes one `write()`, retries only `EINTR`, and never polls.
- `src/os.cpp:570-575`: `os::write_fd` (`to_fd` destination) has the same flaw.
- `src/machine.cpp:2162-2183`: `interpret_with_console` calls `console.flush_output()` without a handler, so the exception leaves `machine::run`.
- For contrast, the `collect_*` paths (`src/machine.cpp` ~2404-2418 and ~2536-2542) catch the exception and keep running.

**Evidence**: `test_nonblock_stdout.py` creates a pipe and sets `O_NONBLOCK` on the write end, as a libuv parent would. It then spawns `cartesi-machine.lua --ram-length=64Mi -- "head -c 300000 /dev/zero | tr '\0' x; echo; echo GUEST-DONE"` with stdout on that pipe. The reader waits 4 s before draining, which simulates brief backpressure. The emulator dies after only 61440 of the 300000 bytes are delivered. Run with `eval $(make -s env); python3 -I bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py`; it exits 1:
```
exit code: 1 | bytes of guest 'x' received: 61440 | GUEST-DONE seen: False
lua5.4: .../src/cartesi-machine.lua:4003: console output flush failed: Resource temporarily unavailable
stack traceback:
	[C]: in method 'run'
	.../src/cartesi-machine.lua:4003: in method 'run'
	.../src/cartesi-machine.lua:4376: in local 'run_to_stop'
BUG: machine:run aborted with a console flush EAGAIN error on a non-blocking stdout (transient host backpressure killed the emulation run)
```
The control run uses the same pipe and the same 4 s delay but a blocking fd (`CONTROL_BLOCKING=1`). It completes with `Halted`, all 300000 bytes and exit 0. So the unhandled `EAGAIN` is the cause, not the workload or the pipe size.

**Scenario**: A Node.js-based node, app harness or developer tool sets its stdio non-blocking (libuv does this) and spawns `cartesi-jsonrpc-machine` or `cartesi-machine` with inherited stdout/stderr. Or a caller configures console output `to_fd` on a non-blocking pipe or socket. A guest app prints a large burst of logs, more than the 64 KiB pipe capacity, while the log consumer is briefly slow. `run()` then throws, the CLI exits with an error, and a JSON-RPC client gets an RPC error in the middle of processing an input. A node that treats any `run` error as fatal stops processing that input.

Some setups are probably not affected. Rollups Node (Go) and Dave (Rust) normally hand children blocking fds, and PRT hash collection goes through the `collect_*` functions, which already tolerate console errors.

**Possible solution**: Treat `EAGAIN`/`EWOULDBLOCK` in `flush_output` as "nothing consumed" and do not throw. Then either:
- wait for the fd to become writable with `poll(POLLOUT)` and retry, inside `os::putchars`/`os::write_fd` or in `flush_output`, or
- return to the interpreter with the bytes still buffered and retry the flush on the next console-output break, so a full buffer applies backpressure to the guest.

Optionally, match the `collect_*` behaviour and never let host console I/O errors abort `run()`. In that case, drop the output and record or log the error.

**Severity**: Medium. Reviewers rated it low and medium. It is not high: no hash, proof, step log or stored state is corrupted, the machine stays at a consistent `mcycle` with the unflushed bytes still buffered (a retry of `run()` recovers), and buffered output or a blocking fd avoids it. It is not low: the trigger is a legitimate, reachable deployment (a non-blocking stdio inherited from a Node/libuv parent, or a non-blocking `to_fd`), the defect breaks the `run()` contract under transient backpressure, and typical callers, the CLI included, do not retry.

**Risks**:
- Of the bug: CLI or validator runs abort partway through under log bursts. Failures are intermittent and depend on load, so they are hard to diagnose. Callers that do not retry may mark an input as failed.
- Of the fix: blocking in `poll` stalls emulation for as long as the consumer stalls. A fix that waits forever turns a crash into a hang, so a timeout or the "leave buffered and resume" approach may be preferable. Silently dropping output on `EAGAIN` would lose guest logs. Any change must not alter emulation semantics, cycle counts or hashes, which is the case because console output is host-side only.

**Proof of concept**: `bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py`. Run from the repo root:
```
eval $(make -s env); python3 -I bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py
```
It exits 1 and prints `BUG:` while the defect is present, and exits 0 when it is fixed. It takes about 5 s and needs the default Linux/rootfs images under `CARTESI_IMAGES_PATH`. Control (expected to pass): `CONTROL_BLOCKING=1 python3 -I bugs/w2b-05-console-eagain-fails-run/test_nonblock_stdout.py`.

**ID**: `w2b-05-console-eagain-fails-run`

### B54. A transient accept error closes the JSON-RPC server's listening socket for good

**Title**: One transient `accept()` error (EMFILE) permanently closes the JSON-RPC server's listening socket; the process stays alive but its machine can no longer be reached

**Problem**: `http_handler::on_accept` in `cartesi-jsonrpc-machine` handles every accept error other than `operation_aborted` the same way. It logs `accept error: ...`, calls `close_acceptor()` (cancel and close the listening socket) and returns without calling `next_accept()`. The comment says this is expected when the open-file limit is reached. But EMFILE is transient, and so are ENFILE, ENOBUFS and ENOMEM, the other errors that reach this handler. Boost.Asio already retries ECONNABORTED and EPROTO internally, so those never get here. Once the burst of connections ends, fds are free again, but the acceptor stays closed for good. Nothing reopens it. The only other code that installs an acceptor is `rebind()`, reached through the fork/rebind RPCs, and those need a connection that is already open.

The process does not exit either. The SIGINT/SIGTERM `signal_set::async_wait` is still pending, so `ioc.run()` never returns. This contradicts the comment in `main` ("run until ... the handler is not accepting new connections"). The result is a live, orphaned server that holds the machine in memory with no listening socket. No client can read its state, `store` or snapshot it, or even send `shutdown`. Only SIGTERM/SIGKILL ends it, and any unsaved in-memory machine state is lost. The process and its memory also leak until someone kills it.

**Origin**: Pre-existing. `on_accept` is byte-identical on `origin/main`. The branch's 14-line change to `src/jsonrpc-remote-machine.cpp` does not touch it.

**Area**: `cartesi-jsonrpc-machine` (the JSON-RPC remote machine server), `src/jsonrpc-remote-machine.cpp`.

**Category**: Crash / availability. Denial of service: the server becomes permanently unreachable.

**Location**:
- `src/jsonrpc-remote-machine.cpp:387-399`: in `http_handler::on_accept`, the `if (ec)` branch (391-398) calls `close_acceptor()` and returns without re-arming accept.
- `src/jsonrpc-remote-machine.cpp:357-361`: `close_acceptor()` cancels and closes the acceptor.
- `src/jsonrpc-remote-machine.cpp:345-354`: `rebind()` is the only other place an acceptor is reinstalled, and it is reachable only over an existing connection.
- `src/jsonrpc-remote-machine.cpp:325-331, 2182-2188`: the termination `signal_set` async_wait keeps `ioc.run()` alive after the acceptor is gone.

**Evidence**: `test.lua` starts `cartesi-jsonrpc-machine` under `prlimit --nofile=32:32` on a free port. Over JSON-RPC it creates a 1 MiB machine with `x10=0x1234`. It then opens 60 TCP connections at once, so `accept()` hits EMFILE. It closes them all, waits 1 s for the server to release the fds, and connects as a normal client to call `read_reg("x10")`. Only 24 of the 60 connects succeed, because the server closes its acceptor at the first EMFILE. The later client gets ECONNREFUSED while the server process is still alive. It reproduced on every run (4/4 for the prover, plus two independent reviewer runs and the recorder re-run). Run with `eval $(make -s env); lua5.4 bugs/w2b-06-jsonrpc-accept-error-kills-server/test.lua`; it exits 1:
```
created remote machine, root hash ok:	true
opened	24	client connections
... info cartesi-jsonrpc-machine ... remote machine server bound to 127.0.0.1:43993
... error cartesi-jsonrpc-machine ... 127.0.0.1:43993 accept error: Too many open files
server process still alive:	yes
BUG: after transient accept() EMFILE the JSON-RPC server stopped listening; machine unreachable: ...test.lua:64: jsonrpc error: post error contacting 127.0.0.1:43993 (Connection refused [system:111 ...])
```

**Scenario**: A node (Rollups Node, Dave or a PRT validator) runs `cartesi-jsonrpc-machine` and holds a machine with advanced, unstored state. A momentary fd exhaustion in the server process happens: a burst of parallel clients or forked children, a port scanner or connection flood against a reachable bind address, or a low `ulimit -n` in a container. ENFILE (system-wide) or ENOBUFS/ENOMEM under memory pressure have the same effect. A single failed accept closes the listener for good. Clients that already hold a keep-alive connection keep working until they reconnect, after a timeout, an error, a new client instance or a new `connect_server`. From then on every call gets "connection refused". The node cannot store or snapshot the machine or shut it down cleanly. It must kill the process and re-execute from the last stored state, and it leaks a lingering server process until it does. CLI users driving a remote machine (`cartesi-machine --remote-address=...`) see the same thing. Hashes, proofs and dispute outcomes are not affected.

**Possible solution**: Treat transient accept errors as recoverable. On EMFILE, ENFILE, ENOBUFS and ENOMEM (and as a safe default, anything except EBADF/EINVAL/ENOTSOCK), log the error and arm a short `asio::steady_timer` backoff (for example 10-100 ms, possibly growing). When it fires, call `next_accept()` again. Do not retry straight away: the pending connection keeps the listening fd readable in epoll, so an immediate retry spins at 100% CPU. Close the acceptor only on unrecoverable errors. If the acceptor does have to be closed for good, make the server exit or shut down cleanly, for example by uninstalling the signal handlers so `ioc.run()` can return, rather than lingering unreachable. Optionally reserve a spare fd that is released and re-acquired to drain the pending connection (the classic "idle fd" trick), so clients get a clean close instead of a hang.

**Severity**: Low. Both reviewers rated it low, against the candidate's medium. The failure mode is bad: a live but unreachable server, and loss of unsaved in-memory state. But it needs fd exhaustion in the server process, which is unusual when validators use one connection per server and default limits are 1024 or more. Existing keep-alive connections keep working. Anyone who can flood the port can already call `shutdown` on the unauthenticated API, so an attacker gains nothing new. It cannot affect hashes, proofs or dispute outcomes.

**Risks**:
- Bug: the server is permanently unreachable after one transient error. Unsaved machine state is lost when the operator kills it. A zombie server process leaks memory and possibly large machine mappings. A node that monitors liveness by PID will not notice anything wrong.
- Fix: retrying without a backoff turns EMFILE into a busy loop at 100% CPU. A backoff that is too long delays legitimate clients. Retrying on genuinely unrecoverable errors (EBADF/EINVAL after `rebind`/`close_acceptor`) must still be avoided; the existing `operation_aborted` / `!acceptor.is_open()` guard covers the close paths. The backoff timer must be cancelled on rebind, on signal-triggered shutdown and on the `shutdown` RPC, or it will keep `ioc.run()` alive or re-arm accept on a closed or replaced acceptor.

**Proof of concept**: `bugs/w2b-06-jsonrpc-accept-error-kills-server/test.lua`. It needs `prlimit` (util-linux) and lua-socket, and takes about 3 s. Run from the repo root with `eval $(make -s env); lua5.4 bugs/w2b-06-jsonrpc-accept-error-kills-server/test.lua`. It exits 1 while the bug is present and 0 once the server is still reachable after EMFILE. The spawned server is killed at the end and its log goes to a temporary file that is deleted.

**ID**: `w2b-06-jsonrpc-accept-error-kills-server`

**Related**: [B09](#b09-json-rpc-server-exits-when-an-error-message-contains-invalid-utf-8).

### B55. spawn_server hangs on its error path when the caller has SIGTERM blocked

**Title**: cm_jsonrpc_spawn_server hangs forever on its error path when the caller has SIGTERM blocked

**Problem:** `jsonrpc_machine` starts the server with `posix_spawnp(&child_pid, bin, nullptr, nullptr, args, environ)`. It passes no `posix_spawnattr_t`, so `POSIX_SPAWN_SETSIGMASK` is not set and the child inherits the calling thread's signal mask. The server's `install_signal_handlers()` resets the SIGINT/SIGTERM dispositions to `SIG_DFL` and later adds them to an asio `signal_set`. Nothing in the server calls `sigprocmask` or `pthread_sigmask`, so a SIGTERM that was blocked in the caller stays blocked in the server. If anything fails after the spawn, the `child_waiter` scope-exit sends `kill(child_pid, SIGTERM)` once and then loops on `waitpid(child_pid, nullptr, 0)` with no time limit. It escalates to SIGILL only on `EINTR`, which never happens here. The SIGTERM stays pending, the server never exits, and `cm_jsonrpc_spawn_server` never returns its error. The server process also leaks. Failures that lead here: version check failure or timeout, and failure of the `fork`, `shutdown` or `rebind` requests. On the success path the direct child exits through the `shutdown` RPC, so the call returns. Servers spawned that way still ignore SIGTERM/SIGINT for their whole life, but this was not tested. A secondary claim was also not tested: the waiter always SIGTERMs `child_pid`, even after the child may have been auto-reaped under `SIGCHLD=SIG_IGN`, so a narrow race could signal a reused pid.

**Origin:** pre-existing. The spawn and waiter logic is the same before this branch.

**Area:** libcartesi_jsonrpc spawn (`jsonrpc-machine.cpp`) / server signal setup (`jsonrpc-remote-machine.cpp`).

**Category:** hang

**Location:**
- `src/jsonrpc-machine.cpp:491`: `posix_spawnp` with null file actions and null attrs, so the signal mask is inherited.
- `src/jsonrpc-machine.cpp:505-545`: `child_waiter` sends `kill(child_pid, SIGTERM)`, then `waitpid` with no bound; SIGILL is sent only on `EINTR`.
- `src/jsonrpc-machine.cpp:559-586`: post-spawn steps that can throw (`check_server_version`, `fork`, `shutdown`, `rebind`).
- `src/jsonrpc-remote-machine.cpp:170-182`: `install_signal_handlers()` resets dispositions only and never unblocks the signals.
- `src/jsonrpc-remote-machine.cpp:325-327`: `signals.add(SIGINT/SIGTERM)` cannot fire while the signals are blocked.

**Evidence:** The test forks a helper into its own process group. The helper calls the public C API `cm_jsonrpc_spawn_server("127.0.0.1:0", 0, ...)`. A timeout of 0 forces the version check to time out, which takes the error path.
- Baseline, SIGTERM unblocked: the call returns -6 at once.
- After `pthread_sigmask(SIG_BLOCK, {SIGTERM})`: the call does not return within 5s. `/proc` shows the caller sleeping in `waitpid`. The spawned `cartesi-jsonrpc-machine` has `SigBlk=0x4000` (SIGTERM inherited as blocked) and `ShdPnd=0x4000` (the waiter's SIGTERM is stuck pending). The test then SIGKILLs the group.

Run command:
```
eval $(make -s env); sh bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh
```
Output excerpt:
```
pid 24806 test_spawn_sigt: State:	S (sleeping) ShdPnd:	0000000000000000 SigBlk:	0000000000004000
pid 24807 cartesi-jsonrpc: State:	S (sleeping) ShdPnd:	0000000000004000 SigBlk:	0000000000004000
baseline (SIGTERM unblocked): spawn returned -6 (error, as expected for timeout 0)
BUG: cm_jsonrpc_spawn_server did not return within 5s when caller has SIGTERM blocked (spawned server inherited mask, ignores SIGTERM, waitpid blocks forever)
```
(exit status 1)

**Scenario:** A C/C++ host such as a PRT validator, a custom node or an app harness follows the common daemon pattern: it blocks SIGTERM/SIGINT in `main` and handles them in a dedicated `sigwait`/`signalfd` thread. Every thread created afterwards inherits that mask, including the one that calls `cm_jsonrpc_spawn_server`. When a spawn fails, the worker thread freezes forever instead of getting an error code, and an orphaned `cartesi-jsonrpc-machine` stays alive holding its listening socket. Typical failures are a version mismatch between libcartesi_jsonrpc and the installed server binary, a server that starts too slowly under load and exceeds `spawn_timeout_ms`, or a failed fork, shutdown or rebind. The validator cannot retry or report the failure. Rust/Go hosts such as the Rollups Node and Dave usually do not block these signals, so they are less likely to be affected.

**Possible solution:**
- In `jsonrpc-machine.cpp`, pass a `posix_spawnattr_t` with `POSIX_SPAWN_SETSIGMASK` (empty mask) and `POSIX_SPAWN_SETSIGDEF` (at least SIGINT, SIGTERM and SIGCHLD reset to default). Rust's `std::process::Command` resets the child's mask the same way.
- As defense in depth, make the server unblock SIGINT/SIGTERM at startup (`pthread_sigmask(SIG_UNBLOCK, ...)` in `install_signal_handlers`).
- Optionally bound the waiter: after SIGTERM, poll `waitpid(..., WNOHANG)` for a short grace period, then escalate to SIGKILL.
- Skip the unconditional SIGTERM once the child has acknowledged `shutdown`, to avoid signalling a possibly reused pid.

**Severity:** low. Both reviewers rated it low, at most borderline medium. Two uncommon conditions must hold at once: the caller has SIGTERM blocked, and a spawn fails after `posix_spawnp`. When they do, the result is a permanent hang plus a leaked server process instead of an error code. Hashes, proofs and stored state are never affected, and successful spawns work.

**Risks:**
- Of the bug: a host thread deadlocks forever on a spawn failure. Servers accumulate as leaked processes holding ports, and supervisors cannot terminate spawned servers with SIGTERM/SIGINT.
- Of the fix: resetting the mask and dispositions in the child is standard and low-risk. A hard SIGKILL escalation must keep the coverage-build rule of not signalling a child that is already flushing gcov counters after `shutdown`. Callers that relied on spawned servers ignoring SIGTERM (unlikely, and undocumented) would see different behaviour.

**Proof of concept:** `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/test_spawn_sigterm_blocked.cpp`, built and run by `bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh`. From the repo root:
```
eval $(make -s env); sh bugs/w2b-07-spawn-server-hangs-when-sigterm-blocked/run.sh
```
The test exits 1 and prints a `BUG:` line while the defect is present, and exits 0 once it is fixed.

**ID**: `w2b-07-spawn-server-hangs-when-sigterm-blocked`

**Related**: [B10](#b10-spawned-json-rpc-servers-inherit-client-sockets-so-concurrent-spawns-fail).

### B56. Out-of-range concurrency.update_hash_tree makes every hash-tree update throw

**Title**: concurrency.update_hash_tree values that truncate to a negative int (e.g. -1, 0xFFFFFFFF) make every hash-tree update throw "vector::reserve"

**Problem:** The hash tree narrows the uint64 runtime setting `concurrency.update_hash_tree` to an `int` with `static_cast<int>`. Any value whose low 32 bits read as a small negative int, such as `-1` (given through Lua or JSON) or `4294967295` (UINT32_MAX), becomes `-1`. `get_concurrency` replaces only `0` with `omp_get_max_threads()` and then takes `std::min` with that thread count, so the negative value is kept. `update_dense_trees` then computes `std::min(m_concurrency << 10, 16384)`, which is `-1024`. Stored in a `size_t`, that is about 2^64, so `batch.reserve` throws `std::length_error("vector::reserve")`. The machine constructor accepts the config, and no interface validates the value. The failure only appears later, on the first operation that updates the hash tree: `get_root_hash`, `get_proof`, `collect_*` logs, `verify_*`, and so on. From then on, every one of those calls fails.

**Origin:** pre-existing. origin/main has the same code, a few lines off.

**Area:** hash tree (`src/hash-tree.cpp`) / runtime config (`concurrency.update_hash_tree`)

**Category:** crash (an exception is thrown; there is no memory corruption) / missing input validation

**Location:**
- `src/hash-tree.cpp:956`: `m_concurrency{get_concurrency(static_cast<int>(concurrency))}` narrows uint64 to int.
- `src/hash-tree.cpp:939-946`: `get_concurrency` keeps negative values.
- `src/hash-tree.cpp:468-470`: `std::min(m_concurrency << 10, 16384)` turns into a huge `size_t`, and `batch.reserve(batch_size)` throws.
- `src/machine.cpp:303`: the runtime value is passed to the hash tree without any check.
- `src/machine.cpp:1556, 1614, 1627, 2361, 2675`: callers of `update_hash_tree()` that fail as a result.
- `src/cartesi-machine.lua:2113`: the CLI `--concurrency=update_hash_tree:<number>` only checks that the value is a number.

**Evidence:** The test builds a 1 MiB-RAM machine for each value and calls `get_root_hash` and `get_proof`. The values -1 and 4294967295 are accepted at construction, and then every hash call fails:
```
$ eval $(make -s env); timeout 60 lua5.4 bugs/w2b-08-concurrency-update-hash-tree-int-truncation/test.lua
update_hash_tree=1: get_root_hash OK
update_hash_tree=0: get_root_hash OK
update_hash_tree=1000000: get_root_hash OK
BUG: update_hash_tree=-1 accepted by constructor but get_root_hash fails: vector::reserve
BUG: update_hash_tree=4294967295 accepted by constructor but get_root_hash fails: vector::reserve
update_hash_tree=2147483648: get_root_hash OK
exit=1
```
A reviewer reproduced the same failure through the C API. `cm_create_new` with the runtime config `{"concurrency":{"update_hash_tree":4294967295}}` succeeds, and then `cm_get_root_hash` returns -3 with "vector::reserve". The JSON parser also accepts `-1` for this uint64 field.

Note: 0x80000000 (INT_MIN) does not fail. In practice `INT_MIN << 10` gives 0, `reserve(0)` succeeds, and the code runs single-threaded. The build uses `-std=c++20`, where left-shifting a negative value is defined, so the "signed-shift UB" in the original claim does not apply. The failure that matters is the `reserve` exception.

**Scenario:** An operator of a PRT validator, Rollups Node or Dave node, or a CLI user, sets `concurrency.update_hash_tree` to an "unlimited" value such as `-1` or `UINT32_MAX`, or passes `--concurrency=update_hash_tree:4294967295`. The machine is created and runs without complaint. Then the first root hash, proof, step log or state comparison fails with the unhelpful message "vector::reserve", and the node can never compute a hash. The config is set by the operator, so neither an attacker nor guest code can trigger this.

**Possible solution:** Validate and clamp the value where it enters, and do the arithmetic in `size_t`. In `get_concurrency`, take a `uint64_t`. Treat `0` as auto (`omp_get_max_threads()`) and clamp any other value to `[1, omp_get_max_threads()]` before converting to `int`; alternatively, reject values above `INT_MAX` with a clear `std::invalid_argument` in the machine constructor or the runtime-config parser. Compute the batch size as `std::min<size_t>(static_cast<size_t>(m_concurrency) << 10, 16384)`.

**Severity:** low. Both reviewers and the prover agree. It needs an out-of-range value that the operator chose. It fails loudly and deterministically on the first hash call. It never produces wrong or nondeterministic hashes or proofs, corrupts no state, and is easy to work around by using `0` (auto).

**Risks:** Of the bug: a node configured with an "unlimited" sentinel cannot compute any hash or proof, and the delayed failure with an unclear message makes it harder to diagnose. Of the fix: very low. Clamping changes no hashes, because concurrency affects only scheduling and not results. If the fix rejects bad values instead of clamping them, configs that "work" today with odd values may start failing at machine creation. For example, 0x80000000 currently runs single-threaded by accident.

**Proof of concept:** `bugs/w2b-08-concurrency-update-hash-tree-int-truncation/test.lua`. To run it from the repo root after building:
```
eval $(make -s env); timeout 60 lua5.4 bugs/w2b-08-concurrency-update-hash-tree-int-truncation/test.lua
```
It exits with 1 and prints `BUG:` lines while the bug is present, and exits with 0 once the value is validated or clamped. Rejecting the value in the constructor also counts as a pass.

**ID**: `w2b-08-concurrency-update-hash-tree-int-truncation`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `w2a-04-concurrency-update-hash-tree-int-truncation`: run with `eval $(make -s env); lua5.4 bugs/w2a-04-concurrency-update-hash-tree-int-truncation/test.lua`.

### B57. read/write_virtual_memory silently do nothing for ranges that reach 2^64

**Title**: `read/write_virtual_memory` report success and do nothing when `vaddr + length` reaches or passes 2^64 (Lua read then returns uninitialized heap bytes)

**Problem:** `machine::read_virtual_memory` and `machine::write_virtual_memory` compute `vaddr_limit = vaddr_start + length` and `vaddr_page_limit = (vaddr_limit + AR_PAGE_SIZE - 1) & ~(AR_PAGE_SIZE - 1)` with no overflow check. There are two failing cases:
- **Range ends exactly at 2^64** (for example `0xfffffffffffff000`/4096, or `0xffffffffffffffff`/1): `vaddr_page_limit` wraps to 0.
- **Range crosses 2^64** (for example `0xfffffffffffff000`/8192): `vaddr_page_limit` becomes a small value below `vaddr_page_start`.

In both cases the page loop (`vaddr_page < vaddr_page_limit`) runs zero times. No translation, page-fault check, physical-range check or copy happens, and `cm_read_virtual_memory`/`cm_write_virtual_memory` return `CM_ERROR_OK`. So a read leaves the caller's buffer untouched, and a write reports success but writes nothing. The same write to the neighbouring page `0xffffffffffffe000` is correctly rejected.

The Lua binding allocates its result with an uninitialized `new unsigned char[length]` and returns it as a string, so `m:read_virtual_memory(-4096, 4096)` returns leftover host heap bytes. The JSON-RPC server zero-fills its buffer (`make_unique_calloc`), so a remote machine returns zeros for the same call. Local and remote results therefore differ.

**Origin:** pre-existing. This branch does not touch these functions.

**Area:** libcartesi C API (`cm_read_virtual_memory` / `cm_write_virtual_memory`), Lua binding, and the gdbstub as the in-tree caller.

**Category:** correctness, plus a minor uninitialized-memory disclosure to the in-process Lua caller.

**Location:**
- `src/machine.cpp:1811-1838` (`machine::read_virtual_memory`: unchecked `vaddr_limit` / `vaddr_page_limit` overflow)
- `src/machine.cpp:1840-1873` (`machine::write_virtual_memory`: same arithmetic)
- `src/cm.cpp:1142-1156` (passes the success through)
- `src/clua-i-machine.cpp:805-823` (uninitialized `new unsigned char[length]` returned to Lua)
- `src/jsonrpc-remote-machine.cpp:1449-1458` (calloc'd buffer, which is why remote and local results differ)
- Caller: `src/cartesi/gdbstub.lua:398,412`

**Evidence:** The C test pre-fills the output buffer with `0xAA` on a fresh bare-mode machine (1 MiB RAM). The Lua test checks the bytes returned for an unmapped range, which must be all zero (or the call must raise an error). Run from the repo root with `eval $(make -s env); sh bugs/w2b-09-virtual-memory-range-wraparound/run.sh`:
```
read  va=0xffffffffffffe000 len=4096 -> err=0 () buffer written
write va=0xffffffffffffe000 len=4096 -> rejected (attempted write is not entirely within single memory range)
read  va=0xfffffffffffff000 len=4096 -> err=0 () buffer UNTOUCHED (still 0xAA)
BUG: cm_read_virtual_memory(0xfffffffffffff000, 4096) returned success but never wrote the output buffer
BUG: cm_read_virtual_memory(0xffffffffffffffff, 1) returned success but never wrote the output buffer
BUG: cm_read_virtual_memory(0xfffffffffffff000, 8192) returned success but never wrote the output buffer
write va=0xfffffffffffff000 len=4096 -> err=0 ()
BUG: cm_write_virtual_memory(0xfffffffffffff000, 4096) reported success (wrote nothing) although the same write to the neighbouring page 0xffffffffffffe000 is rejected
6 defect(s) found
== Lua binding ==
read(-8192,4096) nonzero bytes:	no
read(-4096,4096) first nonzero byte at: 1
BUG: read_virtual_memory(-4096,4096) returned uninitialized host heap bytes
write(-8192) ok:	false	write(-4096) ok:	true
BUG: write_virtual_memory(-4096,4096) reports success but writes nothing
```
The C result is deterministic. Whether the Lua read leaks garbage depends on the allocator: the 4 KiB read leaked non-zero bytes in every run, while a 64 KiB read came from fresh zeroed mmap memory.

**Scenario:** Under Sv39/Sv48/Sv57, kernel addresses are sign-extended, so the top virtual page `0xfffffffffffff000` is a legal page. A developer debugging a guest kernel through `cartesi-machine --gdb` (gdbstub.lua forwards GDB-supplied addresses and lengths) can hit it in two ways:
- Reading memory there gets success with stale or garbage bytes instead of the real contents or an error.
- Writing memory there (for example a breakpoint or patch) is silently dropped.

Apps or CLI tools that call `cm_read_virtual_memory` directly with a range that touches the last page get an untouched buffer and `CM_ERROR_OK`. PRT validators, Rollups Node and Dave are not affected: these helpers take no part in hashing, proofs, step logs, or the uarch/PRT verification paths, and since nothing is written the root hash does not change.

**Possible solution:**
- Reject `length > UINT64_MAX - vaddr_start + 1`, that is, any range that wraps past 2^64. The cleaner option is to make the loop wrap-safe: iterate a page count, or loop while `remaining > 0` and advance by `chunklen`, so a range ending exactly at 2^64 is still translated and read or written normally, and a range that crosses 2^64 raises a "page fault" or `invalid_argument`.
- Apply the same fix to both functions, which could share one helper.
- In `clua-i-machine.cpp`, value-initialize the buffer (`new unsigned char[length]()`) as defense in depth.
- Add regression tests for `(-4096, 4096)`, `(-1, 1)` and `(-4096, 8192)`.

**Severity:** low. Both reviewers rated it low and agree on why: it is a real contract violation (silent success with no data, and uninitialized bytes in Lua), but it triggers only for ranges touching the very last page of the 64-bit address space, through debug and inspection APIs. It corrupts nothing, does not crash or hang, has no effect on PRT, hashes or proofs, and the leaked bytes stay in the caller's own process. The remote server zero-fills its buffer.

**Risks:**
- **Bug:** debugger users see wrong kernel memory, or have writes and breakpoints silently ignored at the top page, which can lead to wrong debugging conclusions. There is also a small in-process heap disclosure through Lua, and local and remote machines behave differently.
- **Fix:** low risk. The fix changes behavior only for ranges that currently do nothing. A range that ends exactly at 2^64 will start translating the top page and can now raise "page fault" where it used to "succeed". Callers that relied on the silent success (none known in-tree; the gdbstub uses `pcall`) would now see an error. Take care that the new loop does not itself overflow when `vaddr` advances past the last page.

**Proof of concept:** `bugs/w2b-09-virtual-memory-range-wraparound/test-vmem-wrap.cpp` (C API), `bugs/w2b-09-virtual-memory-range-wraparound/test-vmem-wrap.lua` (Lua binding), and `bugs/w2b-09-virtual-memory-range-wraparound/run.sh`, which builds the C test into a temporary directory against `src/libcartesi` and runs both tests. Run from the repo root (after building `src/`) with `eval $(make -s env); sh bugs/w2b-09-virtual-memory-range-wraparound/run.sh`. To run only the Lua test: `eval $(make -s env); lua5.4 bugs/w2b-09-virtual-memory-range-wraparound/test-vmem-wrap.lua`. Exit status 1 means the bug reproduced.

**ID**: `w2b-09-virtual-memory-range-wraparound`

### B58. Timed-out fork_server leaks an unreachable server, and a forked child can take over the parent's connection

**Title**: JSON-RPC timeouts do not cancel the server-side request: a timed-out `fork_server()` leaves an unknown machine server running after shutdown, and a forked child can take over the parent's pending connection

**Problem**: A JSON-RPC timeout (`cm_jsonrpc_set_timeout`, or the spawn/connect timeout) only stops the client from waiting. `json_post` throws `jsonrpc error: timeout` from the asio completion handler and closes the socket with an RST (`SO_LINGER` 0). The server is never told to stop. The server is single-threaded and calls `handle_request` synchronously, so the request in flight runs to completion. A request that is already queued in the backlog of the reset connection is also accepted and executed. Only `send_response` fails, with "Connection reset by peer". This has three effects:
1. A timed-out `run()` still advances the machine. This is normal RPC semantics, but it is not documented: the header says only "milliseconds to wait before returning".
2. A timed-out `fork` still forks a full copy of the machine. That copy listens on a port that nobody knows about. `fork_server()` never receives the child's pid or address, and the parent does not reap a child whose reply could not be delivered. Forked servers have no parent-death signal, so the child is orphaned (ppid 1) for good and keeps holding memory and file locks. The spawn constructor has the same flaw: its own `fork` request runs before `grand_child_killer` is armed, so a spawn timeout there orphans the grandchild.
3. A connection race in the forked child (found while reproducing). If `fork` is handled while another connection has already been `accept()`ed by the reactor but its `on_accept` completion has not run yet, that connection is not in `sessions`. The child's `close_sessions()` therefore misses it. The child then runs the queued `on_accept` against its freshly rebound, open acceptor and serves the connection. Parent and child now share one client TCP connection, and each request goes to whichever process reads it first. In 2 of 4 prover runs and in both reviewer runs, the child answered `shutdown_server()` and the original server was the process that leaked.

**Origin**: pre-existing.

**Area**: libcartesi_jsonrpc client (`src/jsonrpc-machine.cpp`) / `cartesi-jsonrpc-machine` server (`src/jsonrpc-remote-machine.cpp`).

**Category**: resource-leak, plus wrong machine instance serving a request (fork race).

**Location**:
- `src/jsonrpc-machine.cpp:120-129`: `shutdown_and_close_socket` closes with an RST.
- `src/jsonrpc-machine.cpp:172-290`: the `json_post` timeout path. It throws from the connect/write/read handlers and sends no cancellation.
- `src/jsonrpc-machine.cpp:743-747`: `fork_server()` gets no pid or address on timeout.
- `src/jsonrpc-machine.cpp:563-571`: the spawn constructor's `fork` runs before `grand_child_killer` is armed.
- `src/jsonrpc-remote-machine.cpp:217-246`: `handle_request` runs synchronously, so an in-flight request always completes.
- `src/jsonrpc-remote-machine.cpp:830-885`: `jsonrpc_fork_handler`. It never reaps a child whose reply failed. At 863, the child's `close_sessions()` misses connections that were accepted but not yet dispatched.
- `src/jsonrpc-remote-machine.cpp:364-372, 387-418`: `close_sessions` and `on_accept`. The `!acceptor.is_open()` guard passes in the child after `rebind`.

**Evidence**: The test runs a 1 MiB RAM machine whose program is `j .`. It sets a 300 ms timeout, calls `run(3e8)` (about 1.3 s of work), then calls `fork_server()`. Both calls report a timeout. Afterwards `mcycle` equals 3e8, the server has an unexpected child `cartesi-jsonrpc-machine --server-fd=6`, and one server process is still running with ppid 1 after `shutdown_server()`. The prover's 4 runs and the re-run all exit 1. Command: `eval $(make -s env); lua5.4 bugs/w2b-01-rpc-timeout-request-still-executes-fork-leaks-server/test.lua`
```
run(300000000) with 300ms timeout -> ok= false err= jsonrpc error: post error contacting 127.0.0.1:36997 (jsonrpc error: timeout)
fork_server() with 300ms timeout -> ok= false err= jsonrpc error: post error contacting 127.0.0.1:36997 (jsonrpc error: timeout)
... error cartesi-jsonrpc-machine pid:26845 ppid:1 ... send response error: Connection reset by peer   (x2)
mcycle after the timed-out run: 300000000
BUG: run() reported a timeout, but the server executed it to completion (mcycle=300000000)
unexpected child of server: 26846 cartesi-jsonrpc-machine --server-fd=6
BUG: fork_server() reported a timeout, but the server forked 1 machine server process(es) whose pid/address the client never received
process 26845 still running after shutdown_server(), ppid=    1
BUG: 1 cartesi-jsonrpc-machine process(es) leaked (orphaned, listening forever)
```
In this run the leaked process was the original server (26845), because the forked child served the client's later requests (effect 3).

**Scenario**: A PRT validator, Rollups Node, Dave or app backend sets per-call timeouts to detect stuck servers. It then calls `fork_server()` to snapshot or branch the machine (PRT's `doc/recipes/prt.lua` uses `fork_server` heavily, although it keeps the default timeout of -1). Each `fork` that times out leaks one full machine server (RAM plus flash backing, file locks) that never exits, and the leaks add up until the host runs out of memory or descriptors. A client that retries `run` or `collect` after a timeout works on a machine that has already advanced, so it gets timing-dependent results unless it discards the server. A server shared by several clients, or a client that reconnects during a `fork`, can have its requests answered by the forked copy instead of the original. State-changing calls then go to a machine instance nobody intended, and the original may survive `shutdown`.

**Possible solution**:
- In `jsonrpc_fork_handler`, the parent should check whether the reply was delivered. If `send_response` fails for a `fork` reply, `kill` and `waitpid` the child. Alternatively, have the child confirm through a handshake before it starts serving.
- In the child, call `close_sessions()` and also drop any pending accept completions before rebinding. For example, give each acceptor a generation counter and have `on_accept` ignore sockets accepted under an old generation. Another option is to `close()` the inherited listening acceptor and every socket fd except the new acceptor.
- In the spawn constructor, arm `grand_child_killer` (or kill the whole process group) on every failure path, including a timeout during the `fork` request.
- Optionally, set `PR_SET_PDEATHSIG` for forked servers, or provide a server-side "abort current request" mechanism.
- Document in `cm-jsonrpc.h` that after a timeout the remote state is unknown, and that the server should be treated as tainted (shut down or killed) rather than reused.

**Severity**: medium. One reviewer rated it medium and the other low. Both agree that "a timeout does not cancel the request" is standard RPC semantics and would rate low on its own. Both also agree that the defects with real impact are the unrecoverable process leak after a timed-out `fork` or spawn, and the fork-child connection race that sends requests to the wrong machine instance. These need non-default settings (timeouts) or overlapping connections, and they do not affect a single sequential client with default settings, so the rating is medium, not high.

**Risks**: Of the bug: each incident leaks a full machine process with no handle to kill it; retried calls can give timing-dependent results; and requests can be served by the wrong machine instance (forked copy and original sharing a connection). Of the fix: killing the child when the reply fails could kill a child the client did receive, if the send error is spurious, so a handshake is more robust than inferring delivery from `send_response`. Changing accept handling around `fork` touches the asio fork-notification sequence and must be tested with concurrent clients. `PDEATHSIG` would change the lifetime semantics of forked servers that callers may rely on, since today they deliberately outlive their parent after `rebind`/`shutdown`.

**Proof of concept**: `bugs/w2b-01-rpc-timeout-request-still-executes-fork-leaks-server/test.lua` (self-contained; it writes its 4-byte `j .` RAM image to `os.tmpname()` and kills every process it spawned before exiting). Run from the repo root:
`eval $(make -s env); lua5.4 bugs/w2b-01-rpc-timeout-request-still-executes-fork-leaks-server/test.lua`
It exits 1 and prints `BUG:` lines while the defect is present, and exits 0 once fixed. Part (A) (the `mcycle` check) shows the expected no-cancellation behaviour. It should be relaxed or removed if that behaviour is accepted and documented rather than changed.

**ID**: `w2b-01-rpc-timeout-request-still-executes-fork-leaks-server`

**Related**: [B10](#b10-spawned-json-rpc-servers-inherit-client-sockets-so-concurrent-spawns-fail).

### B59. replace_memory_range leaves the config stale, so store persists the old flash image

**Title**: `replace_memory_range` leaves `m_c.flash_drive`/`m_c.nvram` stale, so `store` with `SHARING_CONFIG`/`SHARING_NONE` persists the pre-replacement image

**Problem**: `machine::replace_memory_range` replaces the address range object (`m_ars.replace`), rebuilds the hot TLB and evicts clean pages. It never writes the new `backing_store` (data/dht/dpt filenames and the `shared` flag) into the matching `m_c.flash_drive[i]` or `m_c.nvram[i]` entry. `machine::store` decides what to do with each flash/nvram range from that stale `m_c` entry. As a result:
- **Shared replacement under `SHARING_CONFIG`.** If the original range was not shared (for example, any machine loaded with `SHARING_NONE`), `store` takes the "copy unshared backing store" branch. It runs `os::copy_file` on the ORIGINAL image and its `.dht`/`.dpt` files instead of writing current memory. This breaks the `cm.h` contract: "Store current machine state for shared backing stores".
- **Unshared replacement under `SHARING_CONFIG` or `SHARING_NONE`.** The range is rolled back to the image it had before the replacement, not to the replacement file.

The stored snapshot mixes the current processor/RAM state with the old flash contents, and its root hash is neither the live machine's hash nor the replacement image's hash. `get_initial_config()` also keeps reporting the old backing store (old `data_filename`, `shared=false`). That could be read as intended for an "initial" config, but `store` depends on it, so either way the snapshot is wrong.

**Origin**: Pre-existing. `origin/main` has the same `replace_memory_range` and `store` code.

**Area**: C API / Lua API `replace_memory_range` + `store` (stored machines, flash drives and NVRAM). Reached by the `cartesi-machine` CLI (`--replace-memory-range` plus `--store=...,sharing:config|none`).

**Category**: corrupted-state (a silently wrong persisted snapshot).

**Location**:
- `src/machine.cpp:633-681`: `machine::replace_memory_range` resolves start/length from `m_c` and calls `m_ars.replace(resolved)`, but never updates `m_c.flash_drive[i]`/`m_c.nvram[i]`.
- `src/machine-address-ranges.cpp:639-663`: `machine_address_ranges::replace` builds the new `memory_address_range` from `config.backing_store`. This is the only place the new backing store is recorded.
- `src/machine.cpp:418-459`: the `store_address_range` lambda picks "write current memory" vs "copy unshared backing store" (line 436) from the `backing_store_config` it is handed.
- `src/machine.cpp:467-472`: `store` passes the stale `f.backing_store`/`n.backing_store` from `m_c` for each flash drive and NVRAM range.
- `src/cm.h:569`: documented `CM_SHARING_CONFIG` store semantics, which the shared case violates.
- `src/cartesi-machine.lua:3141` (replacements applied) and `:4727` (store): the CLI path.

**Evidence**: `test.lua` stores a base machine whose flash drive (`0x0080000000000000`, length `0x2000`) holds `'A'`. It then runs three scenarios. In each, it loads the base with `SHARING_NONE`, replaces the drive with a `'B'` file (shared or unshared), writes `'Z'` at `+0x1000`, stores with `SHARING_CONFIG` or `SHARING_NONE`, and reloads. In every scenario the reloaded flash holds the pre-replacement `'A'` image. Run with `eval $(make -s env); lua5.4 bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It exits 1:
```
[shared-B_SHARING_CONFIG] get_initial_config flash backing_store: data_filename=/tmp/lua_G3S6gc-w2b-11/base/0080000000000000-2000.bin shared=false
[shared-B_SHARING_CONFIG] memory before store="BBBBBBBB" after reload="AAAAAAAA"
[shared-B_SHARING_CONFIG] root hash equal after store/reload: false
[shared-B_SHARING_CONFIG] byte at +0x1000 after reload="A" expected="Z"
BUG: [shared-B_SHARING_CONFIG] store after replace_memory_range persisted the PRE-replacement flash image ("AAAAAAAA", byte@+0x1000="A") instead of the replacement ("BBBBBBBB", byte@+0x1000="Z")
[unshared-B_SHARING_CONFIG] memory before store="BBBBBBBB" after reload="AAAAAAAA"
[unshared-B_SHARING_NONE]   memory before store="BBBBBBBB" after reload="AAAAAAAA"
```
In the shared scenario the processor did not run, so the flash range is the only source of the root hash mismatch. For the unshared scenarios a hash mismatch alone is expected, because those ranges roll back by design. The defect there is that they roll back to `A` instead of `B`.

**Scenario**: An app or CLI user, or a node, keeps a template machine and swaps in an app or input drive per run. For example: `cartesi-machine --load=template,sharing:none --replace-memory-range=label:app,filename:app-v2.ext2,shared --store=snap,sharing:config`, or the same sequence through `cm_replace_memory_range` + `cm_store`. The stored `snap` silently contains the template's old drive (and its old `.dht`/`.dpt`), so reloading it gives a different root hash and a machine that boots the wrong drive contents. Anyone who later loads that snapshot (an operator restoring a checkpoint, an app developer reproducing a run) works from state that matches neither the live machine nor the replacement image. The default `SHARING_ALL` always writes current memory and is not affected. No evidence was found that PRT validators, the Rollups Node or Dave combine `replace_memory_range` with `SHARING_CONFIG`/`SHARING_NONE` stores, and live-machine hashes, proofs and logs are unaffected.

**Possible solution**: In `machine::replace_memory_range`, after `m_ars.replace(resolved)` succeeds, find the `m_c.flash_drive`/`m_c.nvram` entry with the same start/length and update its `backing_store` (data/dht/dpt filenames, `shared`, `create`, `truncate`) from `config.backing_store`. Keep its `label`, `read_only`, start and length. Alternatively, have `store` take the per-range backing-store decision from the live `address_range` object instead of `m_c`. Add a regression test that stores after `replace_memory_range` under all three sharing modes and reloads.

**Severity**: medium. Both reviewers rated it medium and the prover low-to-medium. It silently corrupts a persisted snapshot (wrong flash image and root hash) in a legitimate, documented, CLI-reachable flow, which is more than low. It is not high because the default `SHARING_ALL` is unaffected, live-machine hashes/proofs are correct, and no validator path is known to use the combination.

**Risks**:
- Of the bug: snapshots that silently contain the wrong drive, which leads to unexpected root hashes, wrong program behaviour after reload, and hard-to-diagnose divergence when such a snapshot is used as a checkpoint or template.
- Of the fix: `get_initial_config()` would start reporting the replacement backing store. Callers that compare it with the originally loaded config, or that rely on it to find the original image, would see a change. The stored `config.json` would then reference the replaced drive's files, which is correct, but the semantics of "initial config" should be documented. `create`/`truncate` flags copied from the replacement must not cause files to be recreated or truncated on a later load. The update must stay exception-safe, so `m_c` is changed only after `m_ars.replace` succeeds.

**Proof of concept**: `bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It is self-contained and uses a temporary directory (override with `WORKDIR=...`). Run from the repo root with `eval $(make -s env); lua5.4 bugs/w2b-11-replace-memory-range-stale-config-store/test.lua`. It prints `BUG:` lines and exits 1 while the bug is present, and prints `OK` and exits 0 once it is fixed.

**ID**: `w2b-11-replace-memory-range-stale-config-store`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `w2a-01-store-after-replace-memory-range-uses-stale-config`: run with `eval $(make -s env); lua5.4 bugs/w2a-01-store-after-replace-memory-range-uses-stale-config/test.lua`.

**Related**: [B01](#b01-persisted-page-cache-is-not-checked-against-memory-so-a-reload-yields-wrong-proofs).

### B60. Full-shadow write_memory skips validation and never marks the TLB padding page dirty

**Title**: `write_memory` full-shadow snapshot path skips shadow validation and never marks the TLB padding page dirty

**Problem**: `machine::write_memory` has a special case for a write that covers the whole processor shadow (`paddr == AR_SHADOW_STATE_START && length == AR_SHADOW_STATE_LENGTH`, 32 KiB). This is the documented way to make manual snapshots with `read_memory`/`write_memory`. The path calls `mark_write_tlb_dirty_pages()`, memcpys the buffer over `m_s->shadow`, calls `init_hot_tlb_contents()` and returns. Two things are missing:
1. **No dirty marking.** `mark_always_dirty_pages` re-hashes only the registers page (`0x0-0x1000`) and the TLB (`0x1000-0x7000`). The last shadow page (`0x7000-0x8000`, `tlb_padding_`) is in the hash tree but is never marked dirty. A non-zero byte written there leaves `get_root_hash` stale: `verify_hash_tree` returns false, and a later `clear_hash_tree` gives a different root for the same state.
2. **No validation.** The path never calls `validate_processor_shadow()`, which the load path uses. It accepts a non-zero `x0`, an `iunrep` that does not match the config, and non-pristine padding. `store` then writes a directory that cannot be loaded.

Changes to the registers and TLB are re-hashed correctly because those pages are always dirty. Garbage TLB contents are not a safety issue, because hot TLB slots are checked lazily (`shadow_tlb_verify_slot`).

**Origin**: Pre-existing. `origin/main` has the same code.

**Area**: C API `cm_write_memory` (and the Lua/JSON-RPC bindings that call it): `src/machine.cpp`, `src/machine-address-ranges.cpp`.

**Category**: Correctness: the hash tree gets out of sync with memory, and invalid state is accepted.

**Location**:
- `src/machine.cpp:1748-1761`: the full-shadow special case in `machine::write_memory`. It has no `validate_processor_shadow()` call and marks no shadow pages dirty.
- `src/machine-address-ranges.cpp:128-133`: `mark_always_dirty_pages` marks only `AR_SHADOW_REGISTERS_*` and `AR_SHADOW_TLB_*`, not the `tlb_padding_` page at shadow offset `0x7000`.
- `src/machine.cpp:196-225`: `validate_processor_shadow`, the checks that run on load only (x0 at 211, iunrep at 215, padding at 223).

**Evidence**: `test.lua` builds a 1 MiB RAM machine and reads the 32 KiB shadow with `read_memory`. It then runs three cases:
- puts `'X'` at offset `0x7000` and writes the buffer back with `write_memory`, then checks the root hash, `verify_hash_tree`, `clear_hash_tree`, and `store` followed by a load;
- sets `x0 = 0x1234`;
- flips bit 0 of `iunrep`.

It exits 1. Run it with `eval $(make -s env); lua5.4 bugs/w2b-12-shadow-snapshot-write-unvalidated-not-dirty/test.lua`:
```
page 0x7000 (in shadow state) is not marked dirty but is dirty
root before: 0xebef6477...710f27ad
root after : 0xebef6477...710f27ad
verify_hash_tree: false
BUG: root hash unchanged after writing 'X' at shadow offset 0x7000 (page not marked dirty)
root after clear_hash_tree: 0x066ca414...ba4e7620
BUG: root hash changes after clear_hash_tree (stale hash tree)
BUG: stored machine cannot be loaded: shadow padding bytes are corrupt
BUG: x0 accepted by write_memory, stored machine unloadable: x0 register is corrupt
BUG: iunrep accepted by write_memory, stored machine unloadable: iunrep mismatch between shadow state and config
```

**Scenario**: An application or tool snapshots and restores machine state with the `read_memory`/`write_memory` shadow path, for example to share a layout between machines. It writes back a buffer that is corrupted, truncated and re-padded, or assembled by hand. `write_memory` succeeds. The machine reports a root hash that does not commit to its real state, `verify_hash_tree` fails, and the directory written by `store` fails to load. A buffer that came straight from `read_memory` is always clean, and none of the in-scope callers use this path (the PRT recipes, the Rollups Node, Dave, the `cartesi-machine` CLI). `tests/lua/pre-thrash-tlb.lua` writes only the TLB region. So an honest validator does not hit this.

**Possible solution**: In the full-shadow branch, check the incoming buffer before the memcpy: `x0 == 0`, `iunrep` matches the config, and both padding areas are pristine. Throw `std::invalid_argument` on a failure. One way is to factor the checks out of `validate_processor_shadow` into a function that takes a `processor_state` and leaves the old state untouched on error. Also mark the whole shadow range dirty after the copy (`mark_dirty_pages_and_up(0, AR_SHADOW_STATE_LENGTH)` on the shadow address range), or add the `tlb_padding_` page to `mark_always_dirty_pages`. Validation alone keeps the padding pristine, so the hash cannot go stale; explicit dirty marking adds a second line of defence.

**Severity**: Low. Both reviewers agree. Triggering it takes a malformed or crafted buffer passed to a niche public API path that no PRT, Rollups or CLI flow uses. An honest player cannot lose a dispute through it. The impact is a stale root hash, a failing `verify_hash_tree` and an unloadable store, all of which follow from bad input that should have been rejected. There is no memory corruption.

**Risks**:
- *Bug*: an API user gets a root hash and proofs that do not match the machine's memory, plus a stored snapshot that cannot be loaded. The problem shows up later and far from its cause.
- *Fix*: rejecting invalid buffers may break callers that relied on loose acceptance. A test or tool that deliberately writes non-zero `x0` or padding would now get an exception. Validating before the copy keeps the machine unchanged on failure. Marking the padding page dirty costs one extra page hash per snapshot write, which is negligible.

**Proof of concept**: `bugs/w2b-12-shadow-snapshot-write-unvalidated-not-dirty/test.lua`. It writes its temporary stored directories next to itself and removes them. Run from the repo root with `eval $(make -s env); lua5.4 bugs/w2b-12-shadow-snapshot-write-unvalidated-not-dirty/test.lua`. Exit 1 means the bug is present. Exit 0 with `OK: no defect`, or a "write_memory rejected ... (fixed?)" line, means it is fixed.

**ID**: `w2b-12-shadow-snapshot-write-unvalidated-not-dirty`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `w2a-03-write-memory-full-shadow-skips-padding-page-dirty`: run with `eval $(make -s env); lua5.4 bugs/w2a-03-write-memory-full-shadow-skips-padding-page-dirty/test.lua`.

### B61. cm_translate_virtual_address crashes on a NULL output pointer

**Title**: cm_translate_virtual_address(NULL paddr) segfaults instead of returning an error

**Problem**: `cm_translate_virtual_address` writes `*paddr = ...` without first checking `paddr` for null. When a caller passes `NULL`, the process segfaults. Its catch block does guard `paddr != nullptr`, so the author clearly meant NULL to be handled. Sibling functions such as `cm_read_console_output` and `cm_write_console_input` throw `std::invalid_argument("invalid ... output")` for NULL outputs (about 26 such checks in `cm.cpp`), so this one breaks the API's own "return an error, don't crash" convention. The crash happens on both local and JSON-RPC machines, because the write is in the client-side `cm.cpp` wrapper and happens after the translation succeeds. A related claim, that `cm_jsonrpc_rebind_server(m, NULL, ...)` crashes, does **not** reproduce. libstdc++ throws `std::logic_error` when a `std::string` is built from nullptr, and the call returns `CM_ERROR_LOGIC_ERROR` (-5). That is still UB per the standard, so it needs an explicit check for portability (hardening only).

**Origin**: pre-existing (the code is identical on `origin/main`).

**Area**: libcartesi C API.

**Category**: crash.

**Location**:
- `src/cm.cpp:1158-1160`: `cm_translate_virtual_address` dereferences `paddr` unchecked (the catch at 1163-1166 checks it, but only after the fact).
- `src/cm-jsonrpc.cpp:161-163`: `cm_jsonrpc_rebind_server` passes `address` into `rebind_server(const std::string&)` with no null check (hardening only, no crash under libstdc++).
- `src/cm.h:796`: documents `paddr` as a required "Receives" output.

**Evidence**: Each case runs in a forked child, so the test can observe the signal. Translating with `paddr=NULL` gets SIGSEGV on both a local machine and a spawned JSON-RPC machine. `rebind_server(NULL)` returns -5. Run with `eval $(make -s env); sh bugs/w2b-14-capi-null-output-crashes/run.sh`:
```
  rebind(NULL) -> -5: basic_string: construction from null is not valid
BUG: cm_translate_virtual_address(local, paddr=NULL) crashed with signal 11 (Segmentation fault) instead of returning an error
BUG: cm_translate_virtual_address(jsonrpc, paddr=NULL) crashed with signal 11 (Segmentation fault) instead of returning an error
OK: cm_jsonrpc_rebind_server(address=NULL) returned an error code
```
(exit 1)

**Scenario**: A third-party FFI binding (Rust, Go, Python ctypes) or a validator written directly against the C API calls `cm_translate_virtual_address(m, vaddr, NULL)`, for example to probe whether a page is mapped. The whole process segfaults instead of getting an error code. That process could be a node hosting several machines, or the JSON-RPC client. In-tree callers cannot trigger it: the Lua binding (`clua-i-machine.cpp:1056`) always passes `&paddr_value`, and the CLI, the JSON-RPC server and PRT-style nodes built on Lua never pass NULL.

**Possible solution**: At the top of the try body in `cm_translate_virtual_address`, add `if (paddr == nullptr) { throw std::invalid_argument("invalid paddr output"); }`, which matches the sibling functions. In `cm_jsonrpc_rebind_server`, add `if (address == nullptr) { throw std::invalid_argument("invalid address"); }` before building the string. A quick audit of other `const char *` → `std::string` conversions in `cm.cpp`/`cm-jsonrpc.cpp` would be worth doing too.

**Severity**: low. Both reviewers agree on low. The crash needs a C caller to pass NULL for a documented required output, which is API misuse. The segfault is client-side only, can't be triggered remotely, and doesn't touch hashes, proofs, step logs or stored state. The `rebind_server` half doesn't crash with libstdc++.

**Risks**: Bug: a misbehaving direct C/FFI caller takes down its own process. Under a non-checking standard library (for example libc++ without hardening), `rebind_server(NULL)` is UB and could also crash. Fix: very low risk. It only turns a crash into an error code (`CM_ERROR_INVALID_ARGUMENT`) for inputs that were never valid. It changes no successful paths.

**Proof of concept**: `bugs/w2b-14-capi-null-output-crashes/test_null_output.cpp` (forked-child C++ test) and `bugs/w2b-14-capi-null-output-crashes/run.sh` (builds it against `src/` and runs it). From the repo root: `eval $(make -s env); sh bugs/w2b-14-capi-null-output-crashes/run.sh`. It exits 1 while the bug is present and 0 once `cm_translate_virtual_address` returns an error for NULL `paddr`.

**ID**: `w2b-14-capi-null-output-crashes`

### B62. Lua-to-JSON conversion fails on numeric keys and expands sparse integer keys into huge arrays

**Title**: Lua-to-JSON conversion fails with "invalid key to 'next'" on numeric keys and expands sparse integer keys into huge null arrays

**Problem**: `clua_push_managed_toclose_json_ref`, which converts Lua values to JSON for `cartesi.tojson` and every Lua config path, has two defects in its table handling:
1. *Traversal corruption.* If a table is not classified as an array, the code walks it with `lua_next`. It accepts any key for which `lua_isstring` is true, and numbers pass that check. It then calls `lua_tostring(L, -2)` on the live key slot. For a numeric key this converts the slot to a string in place, which the Lua manual forbids during traversal. The next `lua_next` call raises `invalid key to 'next'`. So numeric keys can never be stringified as JSON object keys, which is what the code clearly means to do, and the error message gives the caller no hint of the cause. Affected tables include mixed keys (`{1, x=2}`), float keys (`{[1.5]=1}`), and zero or negative integer keys (`{[0]=1,[1]=2}`, `{[-1]=7,a=1}`).
2. *Sparse expansion.* `clua_get_array_table_len` classifies any table whose keys are all positive integers as an array of length `max(key)`. The array branch then calls `lua_geti` for every index from 1 to `len`, and each missing index becomes `null`. `{[1<<24]=1}` produces an 83,886,078-byte JSON string. `{[1<<40]=1}` hangs and eventually runs out of memory.

**Origin**: Pre-existing. The code is identical on `origin/main`, with `clua_get_array_table_len` at line 254 and `lua_tostring(L, -2)` at line 402. This branch only changed nearby schema code.

**Area**: Lua bindings, specifically Lua-to-JSON conversion in `src/clua-i-machine.cpp`. The converter backs `cartesi.tojson`, machine and runtime config conversion, range configs, and every other `clua_tojson` caller (e.g. lines 711, 1142 and 1252).

**Category**: crash (spurious Lua error; CPU and memory exhaustion / DoS)

**Location**:
- `src/clua-i-machine.cpp:254-276`: `clua_get_array_table_len` uses the largest key as the array length and never checks density.
- `src/clua-i-machine.cpp:381-393`: the array branch loops `lua_geti` from 1 to `len`, emitting a null for every hole.
- `src/clua-i-machine.cpp:395-405`: in the object branch, `lua_isstring(L, -2)` accepts numbers and `lua_tostring(L, -2)` at line 402 rewrites the `lua_next` key in place.

**Evidence**: The test calls `cartesi.tojson` on four tables with numeric keys that are not a valid sequence. It then runs the sparse cases in child processes, each limited by `ulimit -v 2000000` and `timeout 20`. Run with `eval $(make -s env); lua5.4 bugs/w2b-13-clua-json-numeric-keys-lua-next/test.lua`. Output:
```
{1, x=2}	false	invalid key to 'next'
BUG: cartesi.tojson({1, x=2}) failed with traversal corruption: invalid key to 'next'
BUG: cartesi.tojson({[1.5]=1, x=2}) failed with traversal corruption: invalid key to 'next'
BUG: cartesi.tojson({[0]=1, [1]=2, [2]=3}) failed with traversal corruption: invalid key to 'next'
BUG: cartesi.tojson({[-1]=7, a=1}) failed with traversal corruption: invalid key to 'next'
sparse {[1<<24]=1} -> json length / rc:	83886078 rc=0
BUG: cartesi.tojson({[1<<24]=1}) produced a 83886078-byte JSON array of nulls (2^24 entries)
sparse {[1<<40]=1} ->	 rc=124
BUG: cartesi.tojson({[1<<40]=1}) hangs or exhausts memory:  rc=124
```
The test exits with code 1. Reviewers saw the same behaviour independently: `{[1]=1,[3]=3}` gives `[1,null,3]`, `{[100000]=1}` gives a 499,998-byte string, and `{[1<<20]=1}` gives about 5 MB.

**Scenario**: Lua tooling, such as a Lua-based node, test harness, or CLI helper script, serializes its own integer-keyed bookkeeping with `cartesi.tojson`. Examples are `{[mcycle]=root_hash}` or `{[input_index]=status}`. With a few entries this fails with a puzzling `invalid key to 'next'` error. With a single large key such as an mcycle near 2^40, the process spins and runs out of memory instead of returning an error. The same can happen when a caller builds a machine or runtime config table and accidentally puts an integer key next to string keys. Emulator-produced configs, logs, proofs and hashes are pure arrays or string-keyed maps. C API and JSON-RPC users (PRT validators, Dave, Rollups Node) never take this path.

**Possible solution**:
- In the object branch, convert a copy of the key: `lua_pushvalue(L, -2); const char *field_name = lua_tostring(L, -1); ...; lua_pop(L, 1);`. Alternatively, accept only `lua_type(L, -2) == LUA_TSTRING` and give numeric keys a clear error such as "table maps cannot contain keys of type number". Pick deliberately between stringifying integer keys and rejecting them, and either way decide what happens to float keys.
- In `clua_get_array_table_len`, count the keys and treat the table as an array only if `count == max_key`. Equivalently, require `max_key == lua_rawlen` and allow no holes. Otherwise fall back to the object branch or raise an error. As a backstop, check `len` against `clua_check_array_schema_size` or a sane cap before the loop.

**Severity**: low. Both reviewers and the prover agree. Only Lua callers that pass their own non-sequence numeric-keyed tables to the JSON conversion are affected. The numeric-key case is a clean, catchable Lua error with no memory corruption. The sparse case can hang or OOM the process, but only on tables the caller builds itself. Emulator-produced data, hashes, proofs, step logs and the C/JSON-RPC APIs are unaffected.

**Risks**:
- *Of the bug:* Lua-side tools fail to serialize legitimate integer-keyed maps. A single large integer key in an untrusted or careless table can hang a Lua-based process or exhaust its memory (local DoS). Sparse arrays also round-trip silently as dense arrays full of nulls, which changes the data.
- *Of the fix:* Treating sparse tables as objects changes the output for tables like `{[1]=a,[3]=b}`, which go from `[a,null,b]` to `{"1":a,"3":b}` or to an error. Any caller that relies on holes becoming nulls would break. Stringifying numeric keys has its own catch: JSON-to-Lua conversion would bring those keys back as strings, so integer-keyed tables would not round-trip exactly. Config paths whose schemas expect arrays must keep accepting dense arrays unchanged.

**Proof of concept**: `bugs/w2b-13-clua-json-numeric-keys-lua-next/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/w2b-13-clua-json-numeric-keys-lua-next/test.lua
```
It needs the built `cartesi.so` and `lua5.4` on `PATH`, because the sparse cases run in `lua5.4` child processes. Expect about 30 s, mostly the 20 s timeout on the `1<<40` case. It prints `BUG:` lines and exits 1 while the bug is present, and prints `OK` and exits 0 once fixed.

**ID**: `w2b-13-clua-json-numeric-keys-lua-next`

### B63. cartesi/filesystem.lua collides with the v0.22 tests package, breaking upgrades

**Title**: Emulator 0.23 ships `cartesi/filesystem.lua` at the path the v0.22 tests package already owns: dpkg upgrade aborts, and a mixed install crashes `cartesi-machine` and `cartesi.hash-tree` at load time

**Problem**: This branch moves the `cartesi.filesystem` module out of the tests tree (`tests/lua/cartesi/filesystem.lua`) and into the emulator package (`src/cartesi/filesystem.lua`). Both versions install to `$(LUA_INSTALL_PATH)/cartesi/filesystem.lua`. The two modules have incompatible APIs. The v0.22 helper has `write_file(filename, data)` and does `require("cartesi.tests.util")`. The new module has `write_file(data, filename)` and adds `new_temporary_file`, `sync_file`, `sync_directory` and others. Neither Debian control template handles the move. `control.template` declares no `Breaks`/`Replaces`, and `tests-control.template` keeps `Depends: cartesi-machine-emulator (>= ARG_VERSION)`. That dependency means the published 0.22 tests deb still accepts emulator 0.23, so both packages claim the same file.
- With dpkg, upgrading the emulator to 0.23 is refused because of the file conflict.
- With a source or overlay install where the old helper is installed last, the old `filesystem.lua` requires `cartesi.tests.util`, which requires `cartesi.hash-tree`, which requires `cartesi.filesystem` again. This circular require overflows the C stack ("C stack overflow") while modules are loading. Every `cartesi-machine` invocation then dies at startup, even `--help`, and so does any program that loads `cartesi.hash-tree`.
- The candidate expected a garbage-named file from the swapped `write_file` arguments and nil `new_temporary_file`/`sync_directory` calls. Neither happens, because the crash comes before that code runs.

**Origin**: Introduced by this branch (commit 956a179). On v0.22.0 (f9e4f82) and origin/main, the file belongs only to the tests package.

**Area**: Lua libraries / packaging (`src/cartesi/filesystem.lua`, Makefile `install-lua-libs`/`install-tests`, Debian control templates).

**Category**: api-contract (packaging / install-path ownership).

**Location**:
- `Makefile:80`: `EMU_TO_LUA_PATH` now includes `src/cartesi/filesystem.lua`.
- v0.22 `Makefile:88` and `Makefile:435`: `TESTS_LUA_TO_LUA_PATH=tests/lua/cartesi` is copied into `$(LUA_INSTALL_PATH)`. That tree contains `cartesi/filesystem.lua`.
- `tools/template/control.template`: no `Breaks`/`Replaces: cartesi-machine-tests`.
- `tools/template/tests-control.template:8`: `Depends: cartesi-machine-emulator (>= ARG_VERSION)`.
- `src/cartesi/filesystem.lua:91`: `write_file(data, filename)`. The v0.22 helper's `tests/lua/cartesi/filesystem.lua:41` has `write_file(filename, data)`, and its line 17 has `require("cartesi.tests.util")`.
- `src/cartesi/hash-tree.lua:2` and `src/cartesi-machine.lua:2677`: `require("cartesi.filesystem")`.
- `.github/workflows/build.yml:933-935`: the tests debs are published as release assets.

**Evidence**: The test has two parts.
- Part A builds real debs from the real control templates and file lists: emulator 0.22, tests 0.22, and emulator 0.23 from this branch. It installs them with dpkg into a private root.
- Part B simulates a source install: this branch's `install-lua-libs`, then a v0.22 `install-tests` (`cp -RP`) over it. It then runs the shipped CLI and `hash-tree`.

Run from the repo root: `eval $(make -s env); lua5.4 bugs/w2a-05-filesystem-module-collides-with-v022-tests-package/test.lua`
```
[A] dpkg -i emulator 0.23 over emulator 0.22 + tests 0.22: rc=1
    dpkg: error processing archive /tmp/w2a-05-fs-collision.XXXX/emu-0.23.0.deb (--install):
     trying to overwrite '/usr/share/lua/5.4/cartesi/filesystem.lua', which is also in package cartesi-machine-tests 0.22.0
BUG: dpkg upgrade of cartesi-machine-emulator to 0.23 aborts: file conflict with installed cartesi-machine-tests 0.22 (no Replaces/Breaks declared)
[B1] cartesi-machine --final-hash rc=1 hash file exists=false size=nil
    lua5.4: error loading module 'cartesi.hash-tree' from file '.../cartesi/hash-tree.lua':
[B2] hash-tree frontier_store rc=1
3 defect(s) found
(cartesi-machine.lua --help: "C stack overflow ... cartesi/tests/util.lua:18 ... cartesi/filesystem.lua:17 ...")
```

**Scenario**: A host (CI runner, developer box, or validator/node image) has the published 0.22 `cartesi-machine-emulator` and `cartesi-machine-tests` debs installed and upgrades only the emulator to 0.23. `dpkg -i` aborts on the file conflict, and `apt` may fail too, depending on the order it unpacks the two packages. On a source-built host, an `install-tests` from an older checkout that runs after `make install` of 0.23 overwrites the new module. After that, `cartesi-machine` (used by PRT/Dave tooling and app developers' CLI workflows) and any Lua program that loads `cartesi.hash-tree` crash at load time.

**Possible solution**: Pick one or more of these:
- Add `Breaks: cartesi-machine-tests (<< 0.23.0)` and `Replaces: cartesi-machine-tests (<< 0.23.0)` to `tools/template/control.template`.
- Make the tests package depend on the exact emulator version (`Depends: cartesi-machine-emulator (= ARG_VERSION)`).
- Rename the new shipped module (for example `cartesi.fs`) so it does not share a path with the old helper.

**Severity**: low. Both reviewers rated it low, and the prover rated it low to medium. It is packaging and upgrade breakage only. dpkg refuses the upgrade loudly instead of leaving a corrupted install. Only hosts that have the 0.22 tests deb installed are affected, which production validators rarely have. No hash, proof or stored state is affected. The load-time crash needs a hand-mixed install.

**Risks**:
- Of the bug: upgrades are blocked, and CI or provisioning scripts fail. In a mixed source install, the CLI and `cartesi.hash-tree` are completely unusable until the stale file is removed.
- Of the fix: `Breaks`/`Replaces` are low risk. They make apt remove or upgrade the old tests package, and the version bounds must match the release that moves the file. An exact `=` dependency forces the two packages to upgrade in lockstep. Renaming the module changes the public Lua module name that new callers (`hash-tree.lua`, `cartesi-machine.lua`, tests) use, so all of them must be updated together.

**Proof of concept**: `bugs/w2a-05-filesystem-module-collides-with-v022-tests-package/test.lua`. It needs `git` with tag commit f9e4f82 (v0.22.0) reachable, plus `dpkg-deb`/`dpkg` and built `src/cartesi.so`. Run it from the repo root:
`eval $(make -s env); lua5.4 bugs/w2a-05-filesystem-module-collides-with-v022-tests-package/test.lua`
It exits 1 with `BUG:` lines while the defect is present and 0 once it is fixed. `REPO` and `WORK` environment variables can override the repo root and the scratch dir (a fresh `mktemp -d` by default).

**ID**: `w2a-05-filesystem-module-collides-with-v022-tests-package`

### B64. clear_hash_tree punches holes in shared hash files, so a full disk later kills the process with SIGBUS

**Title**: mapped_memory::clear punches holes in shared .dht backing files, so after cm_clear_hash_tree on a full filesystem the next get_root_hash dies with SIGBUS instead of returning an error

**Problem**: `mapped_memory::clear()` handles a shared writable mapping (`m_backing_sync_length > 0`) by calling `fallocate(FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE)` (`F_PUNCHHOLE` on macOS) over the whole backing file. Every allocated block of the file is freed. `dense_hash_tree::do_clear()` reaches this code, and `hash_tree::clear()` calls that and then marks every page dirty. The next `get_root_hash`, `get_proof` or `collect_*` call therefore rewrites every dense node through the `MAP_SHARED` mapping. Pristine-page hashes are nonzero, so every node really is written. Each first touch of a punched page has to allocate a block from inside a page fault. If the filesystem is full or the quota is used up, the fault cannot be served and the kernel sends SIGBUS. The process is killed and the C API returns no error. A plain zero-fill (`std::ranges::fill`) would write over blocks that are already allocated and would need no new space. The punch saves almost nothing, because the blocks are filled again right away. `clear_hash_tree` is a recovery path, so it is likely to run on a node that is already short on disk.

**Origin**: introduced by this branch. `mapped_memory::clear()`, `i_dense_hash_tree::clear` / `dense_hash_tree::do_clear` and the dense-tree part of `hash_tree::clear` are all new (`git diff origin/main...HEAD -- src/os-mapped-memory.cpp src/dense-hash-tree.hpp src/hash-tree.cpp`). On `origin/main`, `clear_hash_tree` never touched the dense trees. There is a related limitation that existed before the branch: stored RAM, flash and `.dht` files are sparse, so a `SHARING_ALL` machine loaded on a disk that is already full can SIGBUS on its first write to a hole. The branch makes this worse: a machine that was running fine on a full disk is turned into one that crashes as soon as someone else takes the freed space.

**Area**: OS memory mapping / hash tree (`src/os-mapped-memory.cpp` `clear()`, `hash_tree::clear`, `cm_clear_hash_tree`, runtime option `clear_hash_tree`).

**Category**: crash (SIGBUS, process kill with no error reported).

**Location**:
- `src/os-mapped-memory.cpp:536-566`: `mapped_memory::clear()`, the `fallocate(PUNCH_HOLE|KEEP_SIZE)` / `F_PUNCHHOLE` branch
- `src/dense-hash-tree.hpp:80-82`: `dense_hash_tree::do_clear()` calls `m_mapped_memory.clear()`
- `src/hash-tree.cpp:717-728`: `hash_tree::clear()` clears every dense tree and marks every page dirty
- `src/hash-tree.cpp:310-320`: `hash_tree::return_updated_dirty_pages`, where the fault fires (the `std::ranges::equal` / `copy` on the dense node in the punched `.dht` mapping)

**Evidence**: The test mounts a 96 MiB tmpfs. It stores a machine with 16 MiB of RAM there using `SHARING_ALL`, then runs a child process that does the following:
1. Loads the machine with `SHARING_ALL` and calls `get_root_hash`, which allocates every `.dht` block.
2. Fills the filesystem to ENOSPC.
3. Calls `get_root_hash` again. This still works.
4. Calls `clear_hash_tree()`. Free space goes from 0 to 376832 bytes, about the total size of the `.dht` files, which shows the punch really freed the blocks.
5. Fills the filesystem again, the way another process would.
6. Calls `get_root_hash`.

The child dies with SIGBUS. In the control run, which skips step 5, the child succeeds with the same root hash. A gdb backtrace places the fault in `std::__memcmp` under `cartesi::hash_tree::return_updated_dirty_pages(...)._omp_fn.0` at `hash-tree.cpp:317`.
```
$ eval $(make -s env); lua5.4 bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua
child: avail after clear:  376832 (blocks freed by PUNCH_HOLE)
child: get_root_hash after clear ok
control (no refill): true exit 0
...
child: avail after clear:  376832 (blocks freed by PUNCH_HOLE)
child: avail after refill: 0
Bus error
refill case: nil exit 135
BUG: get_root_hash after clear_hash_tree on a full filesystem killed the process with SIGBUS (...)
```
On tmpfs, a read fault on a hole also needs a page, so the fault comes at the `memcmp` read. On ext4 or xfs, a read of a hole maps the zero page and the SIGBUS comes at the first write, when `page_mkwrite` fails. The result is the same crash.

**Scenario**: A PRT/Dave validator or a Rollups Node keeps its machine stored with `SHARING_ALL` on a volume that is nearly full. It suspects a damaged hash tree and calls `cm_clear_hash_tree`, or reloads with runtime `clear_hash_tree=true`. While that runs, logs, snapshots or another machine use up the blocks the punch just freed. On the next `cm_get_root_hash` or `cm_get_proof`, the node is killed by SIGBUS in the middle of a dispute or epoch, and it gets no error it could handle. A CLI user running `cartesi-machine` on a shared stored machine on a full disk sees "Bus error" with no explanation.

**Possible solution**: Drop the punch for dense hash trees and zero the shared mapping in place (`std::ranges::fill(data, 0)`), so blocks that are already allocated are reused. If space reclamation is wanted, make the punch opt-in and call `fallocate(0, ...)` (plain allocate, without `PUNCH_HOLE`) right after it to reserve the blocks again. That turns ENOSPC into an `errno` that can be reported as an error from `clear()`. The function is currently `noexcept`/`void`, so it would need to be made able to fail. This touches the same code as B04/`api-07` (the dense tree is cleared before its pages are marked dirty). A fill through the shared mapping has the same ordering problem as the punch, so this change should go together with the mark-dirty-first fix described there. In general, a shared mapping on a full disk can SIGBUS on any hole. A broader fix would preallocate (`posix_fallocate`) shared backing files at load time, or handle SIGBUS, but that is outside the scope of this branch's regression.

**Severity**: low. Triggering it needs four things at once: `SHARING_ALL` storage, a full disk or used-up quota, a call to the rare `clear_hash_tree` recovery path, and another consumer taking the freed blocks before the next hash update. The result is a hard process kill with no wrong hash, wrong proof or corruption, and a restart after space is freed recovers. Both reviewers rated it low. The prover said low/medium, because it is a silent kill on a recovery path. The final rating is low: shared-mmap SIGBUS on a full disk already exists before the branch, and the branch only widens it slightly.

**Risks**: Bug: a validator or node can be killed without warning while computing a root hash or proof after a hash-tree reset, which can cost it time in a dispute. Disk pressure is common exactly when operators reach for recovery tools. Fix: replacing the punch with a fill means the cleared `.dht` files keep their full allocation. They are rewritten right away anyway, so space use does not change. A zero-fill of a large dense tree costs more CPU and dirty page writeback than a punch, but the next update rewrites all of it regardless. Adding `fallocate` preallocation changes the API contract of `clear()` (it can now fail), and that error has to be passed through `hash_tree::clear` and `cm_clear_hash_tree`.

**Proof of concept**: `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua`. It needs root, because it mounts a 96 MiB tmpfs at `bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/mnt` and unmounts it afterwards. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc/test_clear_punch_sigbus.lua
```
Exit 1 with `BUG: ... SIGBUS` means the bug reproduced. Exit 0 means fixed (no crash, or an error reported instead). Exit 77 means skipped (not root), and exit 2 means an unexpected result.

**ID**: `w2a-06-mapped-memory-clear-punch-hole-sigbus-enospc`

**Related**: [B52](#b52-a-full-disk-kills-a-sharing_all-machine-with-sigbus-on-writes-to-sparse-pages), [B04](#b04-crash-during-clear_hash_tree-leaves-zeroed-hashes-on-clean-pages).

### B65. Frontier stores fail for native Windows paths because hash-tree.lua splits paths only on slashes

**Title**: hash-tree.lua splits paths only on '/', so frontier_store / frontier_forest_store with a native Windows absolute path (C:\dir\f.json) always fail

**Problem**: `get_parent_directory(path)` is `path:match("^(.*)/[^/]*$") or "."`, and `write_file` builds the temporary-file prefix with `path:match("[^/]*$")`. Both split only on `/`. The C side (`os::create_temporary_file`, `os::sync_file`, `os::sync_directory` in `src/os-filesystem.cpp`) has explicit `_WIN32` branches. For a native Windows path such as `C:\node\frontier.json`, the directory comes out as `.` and the prefix as `C:\node\frontier.json.tmp.`. `create_temporary_file` then builds the template `./C:\node\frontier.json.tmp.XXXXXX`, which is not a valid name on Windows because a path component contains `:`. So every `frontier_store` and `frontier_forest_store` to such a path throws while creating the temporary file. The original claim of a silent durability loss does not hold. `sync_directory('.')` is also wrong, but `os::sync_directory` does nothing on Windows, and the store fails before it gets that far anyway.

**Origin**: introduced by this branch (commit `fcf6819 feat: store frontier forests durably in hash-tree`, which also added the `_WIN32` branches in `os-filesystem.cpp`).

**Area**: Lua libraries (`src/cartesi/hash-tree.lua` write_file / frontier_store / frontier_forest_store).

**Category**: portability / durability (on Windows the store fails outright).

**Location**:
- `src/cartesi/hash-tree.lua:505` (`get_parent_directory`)
- `src/cartesi/hash-tree.lua:509-514` (`write_file`; the temporary prefix comes from `path:match("[^/]*$")` at :510)
- `src/cartesi/hash-tree.lua:935-938` (`frontier_store`)
- `src/cartesi/hash-tree.lua:988-989` (`frontier_forest_store`)
- `src/os-filesystem.cpp:665-693` (`create_temporary_file`, template `dirname + "/" + prefix + "XXXXXX"`, with the `_WIN32` `_mktemp_s` branch)
- `src/os-filesystem.cpp:740-760` (`sync_directory`, which does nothing on Windows)

**Evidence**: The test runs on Linux. It intercepts `fs.new_temporary_file`, `fs.rename_file` and `fs.sync_directory`, calls the real `hash_tree.frontier_store` with `C:\node\frontier.json`, and prints the arguments it records:
```
$ eval $(make -s env); lua5.4 bugs/w2a-07-hash-tree-lua-parent-dir-ignores-backslash/test.lua
path            = C:\node\frontier.json
temporary dir   = .
temporary prefix= C:\node\frontier.json.tmp.
mkstemp template= ./C:\node\frontier.json.tmp.XXXXXX
synced dir      = .
BUG: temporary file directory is '.' instead of 'C:\node'
BUG: temporary file prefix contains path separators / drive colon: 'C:\node\frontier.json.tmp.'
BUG: synced directory is '.' instead of 'C:\node'
exit=1
```
The test exits 1 while the bug is present and 0 once it is fixed.

**Scenario**: A Lua tool or PRT recipe running on a Windows build calls `hash_tree.frontier_store(f, "D:\\prt\\frontier.json")` or `frontier_forest_store(forest, "C:\\node\\forest")` with a native backslash path, for example one taken from a Windows config value or an environment variable. Every epoch persist throws "unable to create temporary file", so the node cannot checkpoint its frontier. Several things limit how often this happens:
- Forward-slash Windows paths (`C:/node/f.json`) and relative backslash paths (`sub\f.json`) still work.
- The Makefiles and CI have no Windows target.
- Production validators (Rollups Node, Dave) run on Linux through the C API, not through this Lua module.
On Linux, `\` is an ordinary filename character, so Linux behaves correctly.

**Possible solution**: Treat both `/` and `\` as separators when running on Windows (or always, if a literal `\` in Linux file names is not a concern):
- the parent directory as `path:match("^(.*)[/\\][^/\\]*$")`
- the base name as `path:match("[^/\\]*$")`

Also handle the bare-drive forms: `C:f.json` has parent `C:`, and `C:\f.json` has parent `C:\`. A simpler alternative is to do this split in C++ with `std::filesystem::path::parent_path()` / `filename()` and expose it through `cartesi.filesystem`, so the Lua and C sides agree on what a path means.

**Severity**: low. Both reviewers and the prover agree. The bug hits only Windows, which has no supported build target, and only absolute paths written with backslashes. It fails loudly instead of corrupting state, forward slashes work around it, and no hashes, proofs or dispute outcomes are affected.

**Risks**:
- Of the bug: a Windows user of the Lua hash-tree library cannot persist frontiers or forests to native absolute paths.
- Of the fix: if `\` is treated as a separator on Linux too, a Linux file whose name really contains `\` would get its temporary file placed in, and its sync aimed at, a directory that does not exist, which fails. Limit the backslash handling to Windows, or document it. The drive-root and bare-drive cases need explicit tests.

**Proof of concept**: `bugs/w2a-07-hash-tree-lua-parent-dir-ignores-backslash/test.lua`. It needs no machine images and writes one throwaway temporary file to `$TMPDIR` (or `/tmp`). Run it from the repo root with:
```
eval $(make -s env); lua5.4 bugs/w2a-07-hash-tree-lua-parent-dir-ignores-backslash/test.lua
```

**ID**: `w2a-07-hash-tree-lua-parent-dir-ignores-backslash`

**Related**: [B34](#b34-frontier-stores-fail-for-files-directly-under-the-filesystem-root), [B42](#b42-filesystemrename_file-does-not-replace-existing-files-on-windows).

### B66. Verifying through a JSON-RPC machine object crashes on short sibling lists and accepts logs the local verifier rejects

**Title**: Verifying through a JSON-RPC machine object re-serializes an unchecked access log: the client segfaults on an empty `sibling_hashes` (out-of-bounds read on a short one), and logs the local verifier rejects are accepted

**Problem**: `cm_verify_step_uarch`, `cm_verify_reset_uarch` and `cm_verify_send_cmio_response` first parse the caller's JSON log into a C++ `access_log` with `from_json`. `from_json(access)` accepts a `sibling_hashes` array of any length. The count is checked against the proof depth (`64 - max(log2_size, 5)`) only later, in `access::make_proof`, during a local replay. When `m` is a JSON-RPC machine, `jsonrpc_machine::do_verify_*` skips the local replay. It sends the parsed log to the server through `to_json(access)`, and that function has two defects:
- It runs `for (int i = 0; i < depth; i++) s.push_back(encode_base64(sibling_hashes[i]))` and never compares `depth` with `sibling_hashes.size()`. A short vector is read out of bounds. An empty vector has a null data pointer, so the client segfaults every time.
- It drops data. Siblings beyond `depth` are cut off, and `written` / `written_hash` are emitted only for `write` accesses. So the server verifies a cleaned-up log and accepts logs that the local or static verifier rejects. The verdict on the same log depends on whether the verifier object is local or remote.

**Origin**: pre-existing. `origin/main` has the same `to_json(access)` loop and the same `jsonrpc_machine::do_verify_*` forwarding. This branch does not touch them.

**Area**: JSON-RPC client verification of access logs: `verify_step_uarch`, `verify_reset_uarch` and `verify_send_cmio_response` called on a remote machine object (C API with a `jsonrpc_machine`, Lua `remote:verify_*`). The bug is in access-log JSON (de)serialization in `json-util.cpp`.

**Category**: crash (client-side null or out-of-bounds read on untrusted input) / input validation (local vs. remote verifier inconsistency).

**Location**:
- `src/json-util.cpp:2278-2290`: the `sibling_hashes` loop in `to_json(const access &)` indexes `sibling_hashes[i]` up to `depth` with no bounds check (line 2287).
- `src/json-util.cpp:2269-2278`: `written_hash` / `written` are serialized only when `type == write`, so they are dropped silently from a `read` access.
- `src/json-util.cpp:1403-1408`: `from_json(access)` accepts a `sibling_hashes` vector of any length.
- `src/jsonrpc-machine.cpp:1033-1058`: `do_verify_step_uarch`, `do_verify_reset_uarch` and `do_verify_send_cmio_response` re-serialize the parsed `access_log` into the request.
- `src/cm.cpp:915-960` (`cm_verify_step_uarch`, `cm_verify_reset_uarch`) and `src/cm.cpp:1381` (`cm_verify_send_cmio_response`): parse the log, then dispatch to `m` when `m != nullptr`.
- For comparison, the local checks that the remote path skips: `src/access-log.hpp:188` ("access sibling hash count is inconsistent with proof size") and `src/uarch-replay-state-access.hpp:158` ("unexpected written data in ... read access").

**Evidence**: The test builds a 1 MiB RAM-only machine, runs `log_step_uarch`, spawns a JSON-RPC server, and verifies modified copies of the log two ways: locally (`cartesi.machine:verify_step_uarch`) and through the remote object. The two crash cases run in child processes.
```
honest log: local and remote accept
extra sibling: local	false	access sibling hash count is inconsistent with proof size	| remote	true	== after
BUG: extra sibling hash: local verifier rejects, remote verifier accepts
written on read access: local	false	unexpected written data in 1st access read access to uarch.cycle	| remote	true	== after
BUG: written data on read access: local verifier rejects, remote verifier accepts
missing siblings (empty): child exit=139
Segmentation fault
BUG: remote verify_step_uarch with empty sibling_hashes crashed the client process (exit 139, SIGSEGV)
missing siblings (few): child exit=0
child remote result:	false	siblings and read hash do not match root hash before 1st access to uarch.cycle
```
Run: `eval $(make -s env); lua5.4 bugs/p2-01-jsonrpc-client-verify-reserializes-unvalidated-access-/test-remote-verify-log.lua` (exits 1, under 1 s). With 40 siblings removed, this build does not crash. The loop reads heap memory past the vector and sends it to the server, which then rejects the log with a misleading error. Whether that read crashes depends on heap layout.

**Scenario**: A validator, dispute tool or app verifies a log it did not produce through a remote machine object, for example Lua `remote:verify_step_uarch(root, log)` or C `cm_verify_step_uarch(jsonrpc_m, ...)`. The counterparty or a corrupted store supplies the honest log with `accesses[1].sibling_hashes = []`. The verifying process segfaults inside `to_json` instead of getting an error, and the node or tool dies. With extra siblings, or `written` data on a read access, the remote verifier returns the honest after-hash where the local or static verifier raises an error. Tooling that compares the two, or relies on the remote verifier to reject malformed logs before passing them on (for example, before submitting them on-chain), gets inconsistent results. The PRT node recipes (`doc/recipes/prt.lua`, `prt-ethereum.lua`, `vg.lua`) are not affected. They call the static `cartesi.machine:verify_*`, which takes the local path and rejects these logs cleanly.

**Possible solution**:
- In `to_json(const access &)`, throw (or serialize the vector as-is) when `sibling_hashes.size() != depth`. Never index past `size()`.
- Serialize `written` / `written_hash` whenever they are present, whatever the access type, so the server sees exactly what the caller sent.
- Better still, check access-log shape in `from_json(access)`: the sibling count must equal `64 - max(log2_size, 5)`, read and written sizes must match `log2_size`, and a read access must have no written fields. Then the local and remote paths reject the same logs at parse time.
- Alternatively, have `jsonrpc_machine::do_verify_*` forward the caller's original JSON text instead of a round-tripped `access_log`.

Add regression tests: an empty or short `sibling_hashes`, an extra sibling, and `written` on a read access, each through a remote machine object, must raise an error the same way the local verifier does.

**Severity**: medium. Both reviewers rated it medium, down from the suspected high. The crash is a deterministic client segfault (a null or out-of-bounds read, not a write) on untrusted input passed to a legitimate public API. But the main validator path, the static or local verifier used by the PRT node, is not affected. The strictness mismatch only accepts logs that encode the honest transition and returns the honest after-hash, so no wrong state transition, hash or proof is ever accepted.

**Risks**:
- Of the bug: a process that verifies untrusted logs through a JSON-RPC machine can be crashed remotely by one malformed field. A short sibling list leaks client heap bytes to the server in the request. The verdict on the same log depends on whether the verifier is local or remote, which can mislead tooling that uses a remote verifier as a gate.
- Of the fix: a stricter `from_json` could reject logs that some callers produce today with redundant fields, such as written data on read accesses or extra siblings. Those logs are already rejected by the local verifier, so the change mainly affects the remote path. Changing what `to_json` emits for read accesses changes the JSON that `log_*` APIs return only if such logs can be produced, which the emulator itself never does.

**Proof of concept**: `bugs/p2-01-jsonrpc-client-verify-reserializes-unvalidated-access-/test-remote-verify-log.lua`. It needs `cartesi`, `cartesi.jsonrpc` and `cartesi-jsonrpc-machine` on PATH; no machine images are needed. Run from the repo root with `eval $(make -s env); lua5.4 bugs/p2-01-jsonrpc-client-verify-reserializes-unvalidated-access-/test-remote-verify-log.lua`. It exits 1 and prints BUG lines while the defect is present, and prints "OK: no defect" and exits 0 once fixed.

**ID**: `p2-01-jsonrpc-client-verify-reserializes-unvalidated-access-`

**Related**: [B44](#b44-json-parsers-truncate-64-bit-log2-sizes-in-access-logs-and-proofs-without-range-checks).

### B67. Memory ranges inside the uarch-state hash node are accepted and make uarch reset unprovable

**Title**: Config validation allows memory ranges inside the 2^22 uarch-state hash node (0x401000-0x5fffff), so log_reset_uarch fails and collect_uarch_cycle_root_hashes commits to a reset root that cannot be proven

**Problem**: The uarch reset is proven as a single write of the whole 2^22-byte hash-tree node at `UARCH_STATE_START_ADDRESS` (0x400000-0x7fffff). Replay (`do_reset_uarch` in `uarch-replay-state-access.hpp`), and the on-chain verifier modeled on it, set that node's hash to the constant `machine::get_uarch_pristine_hash()`. That constant assumes the node holds only the uarch shadow (0x400000-0x400fff) and the uarch RAM (0x600000-0x7fffff), with the gap 0x401000-0x5fffff all zero. Config validation does not enforce this. `machine_address_ranges::check` only checks that a range is addressable and does not overlap another range, so a flash drive (or other memory range) with an explicit `start` in the gap is accepted. On the record side, `m_m.reset_uarch()` resets only the uarch shadow and uarch RAM and leaves the gap alone. The code admits the guard is missing: `//??D I'd like to add an static_assert or some other guard mechanism to guarantee that uarch.ram and uarch.shadow are alone in the entire span of their common hash tree parent node`. Once a range in the gap holds non-zero data:
- `log_reset_uarch` always throws `written hash for uarch.state does not match expected hash in 1st access`;
- `reset_uarch` and `collect_uarch_cycle_root_hashes` (and so `collect_uarch_cycle_bundle`) produce a post-reset root that still contains the drive data, while the on-chain reset wipes the whole node to the pristine hash.

The emulator's commitment then differs from the state transition the verifier enforces, and no reset proof can be produced.

**Origin**: pre-existing. `origin/main` has the same overlap-only check and the same `??D` comment.

**Area**: machine config validation / uarch reset (`log_reset_uarch`, `verify_reset_uarch`, `reset_uarch`, `collect_uarch_cycle_root_hashes`, `collect_uarch_cycle_bundle`).

**Category**: correctness (unprovable commitment / divergence from on-chain semantics).

**Location**:
- `src/machine-address-ranges.cpp:382-400`: `machine_address_ranges::check` checks only addressability and overlap; nothing reserves 0x401000-0x5fffff.
- `src/uarch-replay-state-access.hpp:368-371`: `do_reset_uarch` checks a write of the whole node `(UARCH_STATE_START_ADDRESS, UARCH_STATE_LOG2_SIZE)` against `get_uarch_pristine_hash()`.
- `src/uarch-record-state-access.hpp:277-292`: `do_reset_uarch` logs a write of the same node, but `reset_uarch()` touches only the shadow and uarch RAM (`??D` comment at 278-280).
- `src/uarch-defines.h:24-27`: `UARCH_STATE_START_ADDRESS_DEF` = 0x400000, `UARCH_STATE_LOG2_SIZE_DEF` = 22. `src/address-range-defines.h:30-32`: shadow at 0x400000 (length 0x1000), uarch RAM at 0x600000.

**Evidence**: The test builds machines with a 4 KiB flash drive at 0x401000, 0x500000 and 0x5ff000. All three configs are accepted. It writes `"app data"` to the drive, runs the uarch to halt and calls `log_reset_uarch`, which fails every time. In each case the last leaf of `collect_uarch_cycle_root_hashes(1, 0, ...)` equals the root after `reset_uarch()`, which still includes the drive data. A control run with the same placement but an all-zero drive proves and verifies the reset without error, which is why the bug goes unnoticed.
```
BUG: flash drive at 0x401000 (inside uarch-state node 0x400000..0x800000) accepted; log_reset_uarch fails: written hash for uarch.state does not match expected hash in 1st access
  collect_uarch_cycle_root_hashes last leaf == reset_uarch root (unprovable root committed)
BUG: flash drive at 0x500000 (...) accepted; log_reset_uarch fails: written hash for uarch.state does not match expected hash in 1st access
  collect_uarch_cycle_root_hashes last leaf == reset_uarch root (unprovable root committed)
BUG: flash drive at 0x5ff000 (...) accepted; log_reset_uarch fails: written hash for uarch.state does not match expected hash in 1st access
  collect_uarch_cycle_root_hashes last leaf == reset_uarch root (unprovable root committed)
control: all-zero drive at 0x500000, log_reset_uarch + verify_reset_uarch ok
```
Run: `eval $(make -s env); lua5.4 bugs/p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo/test-memory-range-in-uarch-state-node.lua` (exit 1).

**Scenario**: A dapp author builds a template with an explicit drive start in the gap, for example `--flash-drive=start:0x500000,length:4096,...` or `flash_drive = {{start = 0x500000, ...}}`. The config is accepted, and `doc/README.md` describes flash drive placement as "configurable with constraints" without listing this gap as reserved. The drive holds non-zero data, either from its image or written by the guest at runtime. An honest PRT validator (Dave, the Rollups Node, or the Lua PRT node) computes its commitment with `collect_uarch_cycle_root_hashes`. Its reset leaves keep the drive data. When the dispute reaches a uarch-reset step, `log_reset_uarch` throws, so the honest player cannot produce the reset proof. Even with a proof, its leaf differs from the on-chain reset result. The honest player loses to an opponent whose roots follow the verifier's wipe-the-node semantics. The template is fixed in advance, so a dispute adversary cannot trigger this unless the template already has such a range. Default flash-drive placement never uses the gap.

**Possible solution**: In config validation (`machine_address_ranges::check` or where the machine registers its ranges), reject any address range other than the uarch shadow and the uarch RAM that intersects `[UARCH_STATE_START_ADDRESS, UARCH_STATE_START_ADDRESS + 2^UARCH_STATE_LOG2_SIZE)`, with a clear error. Replace the `??D` comment with that check, plus a `static_assert` that the shadow and uarch RAM both lie inside the node. Document 0x400000-0x7fffff as reserved in the physical memory map.

**Severity**: medium. Both reviewers rated it medium (one said possibly high). When triggered, the impact is critical: the reset proof cannot be produced and the commitment diverges from on-chain semantics, so an honest player loses the dispute. But it needs a rare, author-chosen config: a non-default explicit `start` in the 2 MiB gap, with a range that holds non-zero data.

**Risks**: Bug: affected templates fail silently. Nothing goes wrong until the gap range holds non-zero data and a dispute reaches a reset step, and by then the template is fixed on chain. Fix: low risk. Rejecting ranges in the gap could break an existing template or snapshot that already uses that placement. Such machines cannot produce valid reset proofs today anyway, so failing at load time is better than losing a dispute later. Loading a stored snapshot with such a range would also fail after the fix; the error message should explain why.

**Proof of concept**: `bugs/p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo/test-memory-range-in-uarch-state-node.lua`. Run from the repo root: `eval $(make -s env); lua5.4 bugs/p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo/test-memory-range-in-uarch-state-node.lua`. It exits 1 and prints `BUG:` lines while the bug is present. Once the gap is reserved, it prints `rejected by config validation ... (fixed)` for each start, then the control line and `OK`, and exits 0.

**ID**: `p2-02-memory-range-inside-uarch-state-node-breaks-reset-proo`

**Related**: [B35](#b35-collect_uarch_cycle_-reset-shortcut-diverges-from-reset_uarch-when-uarch-ram-is-not-the-built-in-image).

### B68. First frontier_forest_store of an in-memory expansion skips the per-level directory sync

**Title**: `frontier_forest_store` writes an in-memory expansion's top file and its children with a single directory sync (unlike `store_expansion`), so a crash can leave a shared, hash-addressed parent file without a child, and other forests can then no longer expand it with its bundle

**Problem**: The header comment of the frontier forest persistence code (`hash-tree.lua:487-494`) sets the rule: "a file becomes reachable only once the files below it are durable ... and so is the top file of an expansion". The rule matters because tree files are named only by hash and every forest that uses the directory shares them. `load_tree` is called lazily on any raw base value that a query (`descend_tree`) or `frontier_forest_expand_leaf` reaches. `store_expansion` (`606-613`) keeps the rule: it writes the children, syncs the directory, then writes the top file and syncs again.

`frontier_forest_expand_leaf` calls `store_expansion` only when the forest already has a directory (`if forest.directory then ...`, line 895). A forest that has no directory, is expanded in memory (allowed and documented), and is then stored for the first time goes through `frontier_forest_store` (`967-990`) instead. There `store_tree` writes children before parents, and `write_file` fsyncs and renames each file, but `sync_trees` (the only `fs.sync_directory`) runs once, after the whole batch (line 981). So the expansion's top file X and its child files are renamed with no directory sync between them.

If X's hash is already held as an opaque leaf by another forest A, committed earlier in the same directory, then X is reachable from A as soon as its file name exists. The frontier-file commit point protects only the forest being stored, not A. After a crash, a filesystem that does not keep rename order can keep X's entry and lose a child's. When A next reaches X, `load_tree` (`525-558`) does three things:
- puts a raw-hash tree in place of the missing child;
- checks only the parent hash, which still matches, so it accepts the partial X;
- marks X durable, so A's later stores never rewrite the missing child.

After that, a query through X returns nil ("the node is below an opaque hash"). `frontier_forest_expand_leaf(A, pos, X-bundle)` descends into the loaded X, reaches the lower-height raw child and fails with `leaf height mismatch` (line 892). That error looks like a malformed bundle. More generally, any first store of a tree whose hash another committed forest already holds as an opaque leaf has the same ordering gap, because `frontier_forest_store` does no per-height sync.

**Origin**: introduced by this branch. The store code came in with commit fcf6819 ("feat: store frontier forests durably").

**Area**: `src/cartesi/hash-tree.lua`, frontier forest persistence (`frontier_forest_store`, `frontier_forest_expand_leaf`, `load_tree`).

**Category**: durability (crash consistency / write ordering).

**Location**:
- `src/cartesi/hash-tree.lua:967-990`: `frontier_forest_store` runs `store_tree` over every level, with a single `sync_trees` at line 981.
- `src/cartesi/hash-tree.lua:577-595`: `store_tree` writes children then the parent, and each `write_file` fsyncs and renames with no directory sync.
- `src/cartesi/hash-tree.lua:598-603`, `606-613`: `sync_trees`, and `store_expansion`, which has the ordered child-sync-parent-sync sequence that the store path lacks.
- `src/cartesi/hash-tree.lua:525-558`: `load_tree` accepts a mixed tree whose child files are missing (replacing them with raw hashes) and marks it durable.
- `src/cartesi/hash-tree.lua:886-895`: `frontier_forest_expand_leaf` skips `store_expansion` without a directory, and fails with `leaf height mismatch` (line 892) when descending into a partial loaded tree.
- `src/cartesi/hash-tree.lua:487-494`: the header comment stating the durability rule that this path breaks.

**Evidence**: The test wraps `fs.rename_file` and `fs.sync_directory` and records the order of the calls. Forest A (height 3) holds X (height 2) and Y as opaque leaves and is stored in directory D. Forest B holds the same leaves, expands X in memory with a mixed bundle of two height-1 fixed-point trees, and is then stored in D for the first time. In the control case, forest C, which already has a directory, does the same expansion and so goes through `store_expansion`. A real reordering crash cannot be forced on a filesystem that keeps rename order, so the test then deletes X's right child file to stand in for the lost directory entry, reloads A and uses it.
```
frontier_forest_store (first store of in-memory expansion): child rename #2, X rename #3, dir sync in between: false
frontier_forest_expand_leaf on stored forest (store_expansion): child rename #2, X rename #4, dir sync in between: true
get_node_hash(A, 2, 0) after simulated crash:	nil	the node is below an opaque hash
expand_leaf(A, 0, X-bundle) after simulated crash:	false	.../src/cartesi/hash-tree.lua:892: leaf height mismatch
BUG: frontier_forest_store renames expansion top file X (already referenced by committed forest A) in the same batch as its child files with no directory sync in between; store_expansion does sync. ...
```
Run: `eval $(make -s env); lua5.4 bugs/p2-06-forest-store-batch-expansion-unordered-dir-sync/test-store-expansion-dir-sync.lua` (exits 1, under 1 s).

**Scenario**: An API user (a tool or app built on `cartesi.hash-tree`, not the PRT node) keeps several frontier forests in one shared tree directory. Forest A, already committed there, holds a bundle root X as an opaque leaf. The user builds forest B in memory, opens X with `frontier_forest_expand_leaf`, and then calls `frontier_forest_store(B, D, ...)` for the first time. Power is lost, or the OS crashes, after the per-file renames and before the single directory sync. The filesystem keeps `X.json` but drops a child's entry. After restart, querying A through X returns nil, and expanding A at X with the correct bundle raises `leaf height mismatch`. Nothing detects or repairs the partial X automatically.

The Lua PRT node is not exposed: it stores uarch claims (`store_uarch_claim`) before opening bundles, so `open_bundle` -> `expand_leaf` takes the ordered `store_expansion` path. Rollups Node and Dave use the C API, not this Lua module. A plain process crash cannot cause the problem, since children are always renamed before parents.

**Possible solution**: Make `frontier_forest_store` follow the module's own rule. Sync the directory before writing any parent file whose hash may already be referenced. Two simple ways:
- store level by level, children first, with a `sync_directory` per tree height;
- reuse the `store_expansion` ordering for subtrees that are not yet durable: write and sync the children, then write the parent.

To repair damage left by older versions, `load_tree` could also refuse, or not mark as durable, a mixed or fixed-point tree whose referenced child files are missing where a stored child is expected. Or `frontier_forest_expand_leaf` could accept a matching bundle in place of a loaded tree whose descendants are missing, and write the missing files.

**Severity**: low. Both reviewers and the prover agree. Triggering it takes three things together:
- an API usage pattern (expand before the first store) that the PRT validator node does not use;
- a power loss or OS crash inside a narrow window;
- a filesystem that reorders renames within one directory, which ext4 and XFS do not do in practice.

The result is a stuck query or expansion at one position, never a wrong hash or proof, because `load_tree` still checks the hash. It can be recovered by expanding A at the child level (`expand_leaf(A, 2, <height-1 forest>)`) or by storing the subtree again, since `store_tree` rewrites any file that does not exist. The candidate's claim that the position "can never be opened again" was corrected to this narrower impact.

**Risks**:
- Of the bug: forests that share a directory can be left with a hash-addressed file that is partial, accepted, and marked durable. Later queries return nil, and expansions with the correct bundle fail with a misleading "leaf height mismatch", so a caller may wrongly blame the bundle. The code also breaks its own documented durability contract, which weakens the guarantees other code may rely on.
- Of the fix: extra `fsync` calls on the directory (one per height, or per expansion) slow down large first stores. Changing `load_tree` to reject or re-check partial trees could make a forest that loads today fail, or need repair, when it opens.

**Proof of concept**: `bugs/p2-06-forest-store-batch-expansion-unordered-dir-sync/test-store-expansion-dir-sync.lua`. It needs only the `cartesi` Lua module and `cartesi.hash-tree`, with no machine images. It creates and removes a temporary `run.*` directory next to itself. Run from the repo root with `eval $(make -s env); lua5.4 bugs/p2-06-forest-store-batch-expansion-unordered-dir-sync/test-store-expansion-dir-sync.lua`. It prints a BUG line and exits 1 while the defect is present, and prints "OK: parent written after children are durable" and exits 0 once the store path syncs between the children and the parent.

**ID**: `p2-06-forest-store-batch-expansion-unordered-dir-sync`

**Related**: [B12](#b12-frontier_forest_store-drops-expansions-under-single-value-fixed-point-trees), [B14](#b14-forest-tree-files-keyed-only-by-hash-collide-across-heights-and-representations).

### B69. ArrayIndex conversion between JSON and Lua silently wraps out-of-range indices

**Title**: Unchecked ±1 in Lua/JSON ArrayIndex conversion silently wraps peer-supplied indices (signed overflow; UB only in builds without -fno-strict-overflow)

- **Problem**: `cartesi.fromjson` and `cartesi.tojson` (in `clua-i-machine.cpp`) shift values that have the `"ArrayIndex"` schema between 0-based JSON and 1-based Lua. The schemas that use it include the AccessLog bracket `where` field and `ArrayArrayIndex` (for example `mcycle_hash_offsets`). The shift does `v += 1` (JSON to Lua) and `v -= 1` (Lua to JSON) on `int64_t` with no range check. In the `number_unsigned` branch, the code also does `static_cast<int64_t>(uint64)` first, which turns any value above INT64_MAX into a negative number. So for peer-supplied JSON:
  - `where = 9223372036854775807` (INT64_MAX) overflows to `math.mininteger`;
  - `where = 18446744073709551615` (UINT64_MAX) silently becomes `0`.

  In the other direction, `math.mininteger` overflows to INT64_MAX. Each case is a signed integer overflow in C++. Nothing raises an error.
- **Origin**: pre-existing. The branch's diff does not touch these lines.
- **Area**: Lua JSON conversion (`cartesi.fromjson` / `cartesi.tojson`, the AccessLog / ArrayIndex / ArrayArrayIndex schemas). PRT nodes use it to decode step logs received from peers.
- **Category**: memory-safety / undefined behaviour (signed overflow), plus missing input validation.
- **Location**:
  - `src/clua-i-machine.cpp:414-417`: Lua to JSON, `int64_t v = lua_tointeger(L, idx); ... v -= 1;` (the overflow is at line 416).
  - `src/clua-i-machine.cpp:501-507`: JSON to Lua, the `number_integer` branch, `v += 1`.
  - `src/clua-i-machine.cpp:509-515`: JSON to Lua, the `number_unsigned` branch, `static_cast<int64_t>(get<uint64_t>())` then `v += 1` (the overflow is at line 512). nlohmann parses non-negative literals as unsigned, so this is the path peer input takes.
  - `src/Makefile:267-289`: default builds add `-fno-strict-overflow`; the `sanitize=yes` and `fuzz=yes` builds drop it and add `-fsanitize=address,undefined -fno-sanitize-recover=all`.
- **Evidence**: With the stock build, the test feeds an AccessLog whose bracket `where` is INT64_MAX or UINT64_MAX to `cartesi.fromjson(..., "AccessLog")`. It then serializes a bracket with `where = math.mininteger` through `cartesi.tojson(..., nil, "AccessLog")`. Every conversion wraps silently:
  ```
  $ eval $(make -s env); timeout 30 lua5.4 bugs/p2-07-clua-arrayindex-signed-overflow/test.lua
  fromjson where=INT64_MAX ->	-9223372036854775808
  BUG: JSON->Lua ArrayIndex conversion overflowed: INT64_MAX became -9223372036854775808
  fromjson where=UINT64_MAX ->	0
  BUG: JSON->Lua ArrayIndex conversion wrapped: UINT64_MAX became 0
  tojson where=math.mininteger ->	{"accesses":[],"brackets":[{"text":"x","type":"begin","where":9223372036854775807}],...}
  BUG: Lua->JSON ArrayIndex conversion overflowed: math.mininteger became 9223372036854775807
  (exit 1)
  ```
  The prover also rebuilt `clua-i-machine.o` with `-fsanitize=signed-integer-overflow -fno-sanitize-recover=all` and without `-fno-strict-overflow`, then relinked `cartesi.so`. With that build, the same test aborts the process:
  ```
  clua-i-machine.cpp:512:19: runtime error: signed integer overflow: 9223372036854775807 + 1 cannot be represented in type 'long int'
  (tojson path) clua-i-machine.cpp:416:23: runtime error: signed integer overflow: -9223372036854775808 - 1 cannot be represented in type 'long long int'
  ```
  A UBSan build that keeps the project's `-fno-strict-overflow` reports nothing and gives the same silent-wrap output as the stock build.
- **Scenario**: A malicious player in a PRT dispute (Dave, or a Rollups Node running the Lua PRT node) sends a `step_log` whose brackets contain `{"type":"begin","where":9223372036854775807,"text":"x"}`. The validator decodes it with `cartesi.fromjson(..., "AccessLog")`. The effects:
  - In a release build, any Lua code that reads `brackets[i].where` gets `math.mininteger` (or `0` for UINT64_MAX) instead of an error.
  - In a build made with `make sanitize=yes` or `fuzz=yes`, the validator process aborts on that message.

  Verification itself is not affected. When the log reaches C++, `json-util.cpp:1509` rejects any `where > accesses.size()`. The wrap round-trips (INT64_MAX goes to mininteger and back to INT64_MAX), so the bad bracket is still rejected. Hashes, proofs and `verify_*` results stay correct. `mcycle_hash_offsets` (ArrayArrayIndex) comes from the node's own collect calls, not from peers.
- **Possible solution**: Range-check before the shift and raise a Lua error on out-of-range values:
  - JSON to Lua: reject unsigned values above `INT64_MAX - 1` and signed values equal to `INT64_MAX`. Optionally, since these are indices, reject negative values too.
  - Lua to JSON: reject `v == INT64_MIN`, or more strictly, any `v < 1` for an ArrayIndex.

  Alternatively, use `__builtin_add_overflow` / `__builtin_sub_overflow` and throw on overflow.
- **Severity**: low. The prover and both reviewers agree. Shipped builds use `-fno-strict-overflow` (GCC's `-fwrapv`), so the overflow is defined wrapping and the optimizer cannot exploit it. The C++ side still rejects the wrapped indices, so no wrong hash or proof is accepted and no honest player can lose a dispute. What remains is silent corruption of out-of-range indices seen by Lua code, and a peer-triggerable abort only in the sanitize/fuzz debug builds.
- **Risks**:
  - Bug: Lua-side logic that trusts decoded `where` values (bounds, sorting, display) can misbehave on absurd peer input without any error. Nodes or CI fuzzers running sanitizer builds can be crashed remotely. A future build-flag change that drops `-fno-strict-overflow` would turn this into real UB in production.
  - Fix: low risk. Valid indices are far below the limits. A stricter check (rejecting `v < 1` or negative indices) could break callers that pass 0 or negative placeholders on purpose, so start with the overflow-only check.
- **Proof of concept**: `bugs/p2-07-clua-arrayindex-signed-overflow/test.lua` uses only the public `cartesi` Lua module and needs no machine image. It exits 1 when the bug reproduces. Run from the repo root:
  `eval $(make -s env); timeout 30 lua5.4 bugs/p2-07-clua-arrayindex-signed-overflow/test.lua`

  To see the abort, run the same test against a `cartesi.so` built with `-fsanitize=signed-integer-overflow -fno-sanitize-recover=all` and without `-fno-strict-overflow` (for example `make sanitize=yes`, which needs the ASan `LD_PRELOAD` that the Makefile sets up).

**ID**: `p2-07-clua-arrayindex-signed-overflow`

**Independent reproductions**: other hunters found, reproduced and confirmed the same root cause separately:

- `p3-03-arrayindex-signed-overflow`: run with `eval $(make -s env); lua5.4 bugs/p3-03-arrayindex-signed-overflow/test.lua`.

**Related**: [B62](#b62-lua-to-json-conversion-fails-on-numeric-keys-and-expands-sparse-integer-keys-into-huge-arrays).

### B70. JSON-RPC client cmio response functions read from a NULL data pointer

**Title**: JSON-RPC client send/log/verify_send_cmio_response read `length` bytes from a NULL data pointer (SIGSEGV), while the local machine returns an error or a no-op

- **Problem**: The local machine handles `data == NULL` in `send_cmio_response` and `log_send_cmio_response` on purpose:
  - NULL with `0 < length <= rx buffer` throws `invalid_argument("invalid data buffer")`.
  - NULL with an oversized `length` is accepted as a no-op ("Oversized responses do not consume the data buffer").
  - The static `verify_send_cmio_response` throws `"data is null"` for a small length.

  The JSON-RPC client (`jsonrpc_machine`) never checks for NULL. `do_send_cmio_response`, `do_log_send_cmio_response` and `do_verify_send_cmio_response` all call `encode_base64(std::span<const unsigned char>{data, length})` on the client side, so they read `length` bytes starting at address 0. The calling process gets SIGSEGV before any request reaches the server, where the local machine would have returned `cm_error` or succeeded. The spawned server process is left orphaned.
- **Origin**: pre-existing. The same NULL handling is already in `machine.cpp` on `origin/main`, and the branch does not touch the client code.
- **Area**: cmio / JSON-RPC client (`libcartesi_jsonrpc`).
- **Category**: crash (NULL dereference). Local and remote behave differently.
- **Location**:
  - `src/jsonrpc-machine.cpp:977-987`: `do_send_cmio_response`, `encode_base64(std::span{data, length})` at line 980.
  - `src/jsonrpc-machine.cpp:989-999`: `do_log_send_cmio_response` (line 993).
  - `src/jsonrpc-machine.cpp:1049-1058`: `do_verify_send_cmio_response` (line 1052).
  - For comparison: `src/machine.cpp:2004-2010` and `2016-2021` (the local NULL checks), and `src/replay-send-cmio-state-access.hpp:280` (`"data is null"`).
  - Reached via `src/cm.cpp:1349-1400` and `src/i-machine.hpp:333-385`, which forward `data` unchecked.
- **Evidence**: The C++ test uses the public C API to build a machine with 1 MiB of RAM. It sets `htif.tohost` to a manual rx-accepted yield and sets `iflags.Y=1`. Then it calls each of the three APIs with `data=NULL`, once with `length=3 MiB` (oversized) and once with `length=5`, using the current root hash as the revert hash. It runs each call on a local machine (`cm_new`) and on a spawned remote machine (`cm_jsonrpc_spawn_server`). Each case runs in a forked child, so a crash shows up as a signal. The local machine always returns cleanly; the remote one segfaults in all 6 cases:
  ```
  $ eval $(make -s env); sh bugs/p2-05-jsonrpc-cmio-null-data-segfault/run.sh
  cm_send_cmio_response          data=NULL len=3145728  local: returned success             [ok] | remote: CRASH signal 11 (Segmentation fault) []
  cm_send_cmio_response          data=NULL len=5        local: returned error (exit 1)      [invalid data buffer] | remote: CRASH signal 11 (Segmentation fault) []
  cm_log_send_cmio_response      data=NULL len=3145728  local: returned success             [ok] | remote: CRASH signal 11 (Segmentation fault) []
  cm_log_send_cmio_response      data=NULL len=5        local: returned error (exit 1)      [invalid data buffer] | remote: CRASH signal 11 (Segmentation fault) []
  cm_verify_send_cmio_response   data=NULL len=3145728  local: returned success             [ok] | remote: CRASH signal 11 (Segmentation fault) []
  cm_verify_send_cmio_response   data=NULL len=5        local: returned error (exit 1)      [data is null] | remote: CRASH signal 11 (Segmentation fault) []
  BUG: 6 remote NULL-data cases crashed the client
  ```
  The script exits 1 and runs in about 3 s.
- **Scenario**: A validator written against the C API through FFI (C/C++, or Go/Rust with raw pointers) uses spawned JSON-RPC machines, as the PRT node and the Rollups Node do. Suppose it rejects an oversized advance-state input without materializing it, passing NULL with the declared length, which the local implementation treats as valid. Or suppose an error path leaves `data` NULL with `length > 0`. The whole validator process then crashes with SIGSEGV instead of getting an error. It also orphans its server, and the same code passes in tests against a local machine. The Lua bindings always pass a Lua string, so the Lua PRT node and the CLI cannot reach this. Well-formed Rust slices are never NULL. The emulated application is not affected.
- **Possible solution**: Do the NULL check once in the `i_machine` wrappers (`src/i-machine.hpp`) or in `cm.cpp`, so every backend behaves the same. At minimum, check in the three `jsonrpc_machine::do_*` methods the way `machine.cpp` does: throw `invalid_argument` for NULL with `0 < length <= AR_CMIO_RX_BUFFER_LENGTH`. For NULL with an oversized length, the server still needs `length` to apply the oversized-response path. The client therefore cannot just send an empty buffer. It should either send a buffer of the right size (for example, encode `length` zero bytes, which costs bandwidth) or carry the length separately, which is a protocol change. A simpler alternative is to reject NULL with any `length > 0` across all backends and document that in `cm.h`.
- **Severity**: low. Both reviewers rated it low; the prover said low to medium. It only happens when a caller passes `data=NULL` with `length>0`, which `cm.h` does not document as valid ("Response data to send"), and normal callers (Lua, Rust slices) do not produce that. It does not affect hashes, proofs or dispute outcomes. Still, the result is a whole-process crash plus a local/remote divergence on an input that the local backend deliberately validates.
- **Risks**: Bug: an FFI validator process crashes and leaks a spawned server, and code tested against local machines behaves differently in production with remote machines. Fix: rejecting NULL plus oversized length everywhere would change the documented local no-op behavior. Encoding zero bytes on the client for oversized NULL inputs sends up to `length` bytes over the wire. Changing the RPC to carry an explicit length needs a protocol version bump.
- **Proof of concept**: `bugs/p2-05-jsonrpc-cmio-null-data-segfault/test_cmio_null_data.cpp` is a C++ program using the C API (`cm.h`, `cm-jsonrpc.h`). `bugs/p2-05-jsonrpc-cmio-null-data-segfault/run.sh` builds it against `src/libcartesi` and `src/libcartesi_jsonrpc` in a temp dir and runs it. It needs `cartesi-jsonrpc-machine` on `PATH`, which the env provides. It exits 1 while the bug is present. Run from the repo root:
  `eval $(make -s env); sh bugs/p2-05-jsonrpc-cmio-null-data-segfault/run.sh`

**ID**: `p2-05-jsonrpc-cmio-null-data-segfault`

**Related**: [B61](#b61-cm_translate_virtual_address-crashes-on-a-null-output-pointer).

### B71. fromjson rewrites strings that match a key of a struct, array or tuple schema

**Title**: Lua `fromjson` replaces any string equal to a key of an object (struct/array/tuple) schema with that schema's internal value; the mapping was meant only for enum schemas

**Problem**: In `clua_push_json_value`, the string case has the branch `schema.is_object() && schema.contains(data)`. It exists to map enum names to integers (for example `InterpreterBreakReason`: `"halted"` -> `1`). Nothing checks that the schema actually is an enum, meaning that all its values are integers. Every object schema takes this branch: struct schemas (`Proof`, `AccessLog`, user structs), `{items=...}` array schemas, and tuple schemas. So a JSON string that equals one of the schema's keys is replaced by `schema.at(data)`, which is a type name such as `"Base64"` or `"Base64Array"`, or a Lua table copied from a tuple's `items` list. On the other side, `tojson` writes strings unchanged and has no reverse (integer-to-name) mapping. As a result, `tojson` followed by `fromjson` with the same schema does not return the original value, and no error is raised.

**Origin**: Pre-existing. `origin/main` has the same branch and the same `fromjson(s, schema_name, dict)` signature. This branch's tuple-schema support (array-valued `items`) adds a new form of the bug, in which a string comes back as a table.

**Area**: Lua JSON binding (`cartesi.fromjson` / `cartesi.tojson`, `src/clua-i-machine.cpp`).

**Category**: correctness (silent type confusion; `tojson`/`fromjson` round trip is broken).

**Location**:
- `src/clua-i-machine.cpp:493-495`: `clua_push_json_value`, string case, `else if (schema.is_object() && schema.contains(data))`.
- `src/clua-i-machine.cpp:424-434`: `clua_push_managed_toclose_json_ref` (`tojson`), string case. It writes strings unchanged and has no reverse mapping.
- `src/clua-i-machine.cpp:532-545`: `clua_get_machine_schema_dict`. Its comment says the mapping is for "enumeration strings" only, but the dictionary has no enum marker.

**Evidence**: The test runs 5 cases and all of them fail. The enum path itself still works: `fromjson('"halted"', "InterpreterBreakReason")` returns `1`.
```
$ eval $(make -s env); lua5.4 bugs/p3-01-fromjson-object-schema-string-enum-rewrite/test.lua
tojson wrote: {"p":"target_hash"}
BUG: tojson->fromjson round trip of string in Proof-typed field: expected "target_hash", got Base64 (string)
BUG: fromjson '"items"' at Base64Array-typed field: expected "items", got Base64 (string)
BUG: tojson->fromjson round trip of string in tuple-typed field: expected "items", got ["Base64","ArrayIndex"] (table)
BUG: fromjson top-level string equal to Claim field name: expected "root", got Base64 (string)
BUG: fromjson '"sibling_hashes"' with schema Proof: expected "sibling_hashes", got Base64Array (string)
BUG: 5 case(s) where fromjson replaced a string with schema internals
exit=1
```

**Scenario**: The bug needs ill-typed input: a string where the schema expects a struct, array or tuple. Examples:
- A Lua app or PRT component stores a field typed with a struct schema that can also hold a string sentinel. After a restart, the value comes back as `"Base64"` and not as the original string.
- A peer sends `"arguments":"items"` for an event whose tuple schema is `{items={...}}`. The PRT game transport decodes it with `cartesi.fromjson` and a user schema, so the receiver gets a table of type-name strings and no error. That table could pass a naive `type(x)=="table"` check.

The emulator's own callers cannot hit this with data it produces:
- Proofs, access logs, root-hash arrays and configs are all well-typed.
- `hash-tree.lua` `STORED_SCHEMAS` could only be affected by a corrupted file, which then fails the existing asserts.

An adversary also gains nothing over sending a well-shaped array of arbitrary strings directly.

**Possible solution**:
- Apply the enum mapping only to enum schemas, either by checking that every value in the object schema is an integer or by adding an explicit enum marker to the schema dictionary. Never apply it to struct or `{items}` schemas.
- Optionally, map integers back to enum names in `tojson` so that enum values round-trip.
- Add a regression test that round-trips strings through struct, array and tuple schema positions.

**Severity**: low.
- The prover rated it low-to-medium; both reviewers rated it low.
- It only triggers on ill-typed input, which honest producers and the emulator's own APIs never emit.
- The effect is a silent type confusion in the Lua binding only. There is no crash, and hashes, proofs, step logs, verification, the C API and JSON-RPC are not affected.

**Risks**:
- Of the bug:
  - Persisted Lua state or peer messages are silently decoded into wrong-typed values (a schema type-name string, or a table), with no error.
  - Downstream code that does shallow type checks may accept them.
  - It is confusing to debug, because `tojson`/`fromjson` round trips look symmetric.
- Of the fix:
  - Code that relied, knowingly or not, on string-to-value mapping for non-integer object schemas would change behaviour. Unlikely, since such schemas hold type names.
  - The enum detection must keep `InterpreterBreakReason` (and any user enum schemas) working.
  - Adding a reverse mapping in `tojson` changes the JSON output for enum-typed integers, so check compatibility with JSON consumers that expect integers.

**Proof of concept**: `bugs/p3-01-fromjson-object-schema-string-enum-rewrite/test.lua`. Run it from the repo root:
```
eval $(make -s env); lua5.4 bugs/p3-01-fromjson-object-schema-string-enum-rewrite/test.lua
```
It exits with code 1 and prints `BUG:` lines while the defect is present, and prints `PASS` once it is fixed.

**ID**: `p3-01-fromjson-object-schema-string-enum-rewrite`

**Related**: [B69](#b69-arrayindex-conversion-between-json-and-lua-silently-wraps-out-of-range-indices).

### B72. tojson and fromjson truncate object keys at NUL bytes, merging distinct keys

**Title**: cartesi.tojson/fromjson truncate object keys at the first NUL byte, so distinct keys silently merge and data is lost

**Problem**: Lua strings and JSON strings can both contain NUL bytes, but the object-key paths of the Lua JSON bindings treat keys as C strings. In `tojson`, the key `"a\0b"` is read with `lua_tostring` and passed to `j[field_name]` as a `const char *`, so nlohmann builds the key with `strlen` and gets `"a"`. In `fromjson`, `lua_setfield(L, -2, field_name.c_str())` stores `"a\u0000b"` as `"a"`. Distinct keys therefore collapse into one, one value is dropped, and no error is raised. The schema lookup in `tojson` also uses the truncated key, so a key like `"hash\0x"` picks up the schema of field `hash`. String *values* are handled correctly, because that path uses `lua_tolstring` with its length (src/clua-i-machine.cpp:426), so keys and values are handled inconsistently. Which value survives a collision is not deterministic in `tojson`: it is whichever key `lua_next` visits last, and that order depends on Lua's per-run randomized string hash seed. One run gave `{"a":1}` and another gave `{"a":2}`.

**Origin**: pre-existing. origin/main has the same code at src/clua-i-machine.cpp:402 and :475, and this branch does not touch these lines.

**Area**: Lua JSON (`cartesi.tojson` / `cartesi.fromjson` in the Lua bindings)

**Category**: correctness (silent data loss)

**Location**:
- src/clua-i-machine.cpp:402-405, in the object branch of `clua_push_managed_toclose_json_ref`: `const char *field_name = lua_tostring(L, -2);`, which is then used for `clua_get_field_schema(...)` and `j[field_name] = ...`
- src/clua-i-machine.cpp:471-475, in the object branch of `clua_push_json_value`: `lua_setfield(L, -2, field_name.c_str());`

**Evidence**: The test round-trips keys that contain NUL in both directions, and every check fails without raising an error.
```
$ eval $(make -s env); lua5.4 bugs/p3-06-json-nul-in-keys-truncated-merged/test_json_nul_keys.lua
tojson:	true	{"a":1}
BUG: tojson truncated key 'a\0b' at NUL, merged with key 'a' (got {"a":1})
tojson single:	true	{"a":1}
BUG: tojson({['a\0b']=1}) dropped the bytes after NUL in key: {"a":1}
fromjson keys:	"a"=1
BUG: fromjson truncated key "a\u0000b" at NUL; t['a\0b']=nil t.a=1
(exit status 1)
```
- `tojson({["a\0b"]=1, a=2})` returns a single key, and which value survives changes from run to run.
- `tojson({["a\0b"]=1})` returns `{"a":1}` even though no key collides.
- `fromjson('{"a\u0000b":1,"a":2}')` returns a table that holds only `a=1`.

**Scenario**: A PRT validator, Dave component or app uses `cartesi.tojson`/`cartesi.fromjson` as a general serializer for a table keyed by binary data. For example, it persists state keyed by raw 32-byte hashes, which can contain 0x00 bytes, or keyed by labels that came from the wire. Entries whose keys share a prefix before a NUL overwrite each other. The state restored from JSON is missing entries or attaches them to the wrong key, and nothing reports an error. A peer-supplied JSON line given to `cartesi.fromjson` (as in the game-transport recipes) can also use a key like `"operation\u0000x"` that is read as `"operation"`. That peer already controls its whole message, though, so this gives it no extra power. Machine configs, the JSON-RPC schemas and the runtime config use only fixed ASCII field names, and the remote machine's C++ JSON path does not go through this code. Hashes, proofs, step logs and machine configs are therefore unaffected.

**Possible solution**:
- In `tojson`, read the key with `size_t len; const char *p = lua_tolstring(L, -2, &len);` and use `std::string key(p, len)` for both `clua_get_field_schema` and `j[key]`.
- In `fromjson`, push the key with `lua_pushlstring(L, key.data(), key.size())`, then use `lua_insert` and `lua_rawset` (or push the key before the value and call `lua_rawset`) instead of `lua_setfield`.
- Optionally, make `cartesi_mod_fromjson` read its input with `luaL_checklstring` so that any content after a raw NUL byte is parsed (and rejected) instead of being silently ignored.

**Severity**: low. Both reviewers agree. It is a real silent-data-loss defect whose outcome varies between runs, but it only affects generic tables whose keys contain NUL bytes. Validator-critical data (configs, RPC payloads, hashes, proofs) uses fixed ASCII keys, and the bug cannot cause a crash or memory corruption.

**Risks**:
- *Of the bug*: callers that serialize tables with binary keys can lose or misattribute data without noticing. Because `tojson`'s result depends on the hash seed, two nodes serializing the same table can produce different JSON.
- *Of the fix*: very small. Keys without NUL behave exactly as before. Keys with NUL now round-trip as `\u0000` escapes, which could surprise a consumer that relied on the truncation, but none is known. Using `lua_rawset` instead of `lua_setfield` skips `__newindex`; this does not matter here because the target table was just created with `lua_createtable`.

**Proof of concept**: `bugs/p3-06-json-nul-in-keys-truncated-merged/test_json_nul_keys.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/p3-06-json-nul-in-keys-truncated-merged/test_json_nul_keys.lua`. It exits with status 1 and prints `BUG:` lines while the bug is present, and exits with status 0 once it is fixed.

**ID**: `p3-06-json-nul-in-keys-truncated-merged`

**Related**: [B71](#b71-fromjson-rewrites-strings-that-match-a-key-of-a-struct-array-or-tuple-schema), [B73](#b73-fromjson-and-the-json-rpc-server-stop-parsing-at-a-nul-byte-and-accept-trailing-data).

### B73. fromjson and the JSON-RPC server stop parsing at a NUL byte and accept trailing data

**Title**: `cartesi.fromjson` (and the JSON-RPC server's request parsing) stops at the first NUL byte and accepts JSON followed by NUL plus any trailing data

**Problem**: `cartesi.fromjson` reads its argument with `luaL_checkstring`, which drops the Lua string's length, and passes the bare `const char *` to `clua_fromjson`. That function calls `nlohmann::json::parse(s, cb)`. nlohmann treats a `const char *` as a NUL-terminated C string, so parsing ends at the first embedded NUL. The end-of-input check, which normally rejects trailing data, never sees the bytes after the NUL. As a result `'{"a":1} x'` is rejected, but `'{"a":1}\0{"zzz'` is accepted and returns `{a=1}`. Lua strings are binary-safe, so callers expect the whole string to be validated. The JSON-RPC server has the same pattern: it parses `req.body().data()` as a C string, so a request body is only read up to its first NUL.

**Origin**: pre-existing (`fromjson` is unchanged from `origin/main`).

**Area**: Lua JSON (`cartesi.fromjson`); also the JSON-RPC server's request parsing.

**Category**: correctness (input validation)

**Location**:
- `src/clua-cartesi.cpp:176-180`: `cartesi_mod_fromjson`. Line 179 calls `luaL_checkstring(L, 1)`, which drops the length.
- `src/clua-i-machine.cpp:640-651`: `clua_fromjson(lua_State *, const char *s, ...)`. Line 646 calls `nlohmann::json::parse(s, clua_json_parse_callback)`.
- `src/jsonrpc-remote-machine.cpp:1947`: `json::parse(req.body().data(), jsonrpc_parse_callback)`, the same pattern on the server side. This one is not covered by the PoC.
- Affected callers that pass whole files: `src/cartesi/hash-tree.lua:528` (StoredTree), `:944` (Base64Array), `:994` (StoredFrontier) and `src/cartesi-machine.lua:3089` (`--load-config`).

**Evidence**: The test runs a control input and three NUL cases through `cartesi.fromjson`:
- Control: trailing garbage without a NUL is rejected.
- NUL followed by garbage is accepted.
- A JSON document followed by 4096 zero bytes is accepted.
- A `Base64Array` document followed by NUL and garbage is accepted.

Run with `eval $(make -s env); lua5.4 bugs/p3-05-fromjson-truncates-at-nul/test.lua`:
```
ok: trailing garbage without NUL rejected: ... parse error at line 1, column 9: ... last read: '1} x'; expected end of input
BUG: trailing garbage after NUL accepted (len=13), parsed a=1
BUG: zero-filled tail (file extended with NULs) accepted (len=4103), parsed a=1
BUG: Base64Array with trailing NUL+garbage accepted, #v=1
exit=1
```

**Scenario**: The PRT node loads its stored tree, frontier and epoch files with `cartesi.fromjson(fs.read_file(path), ...)`. If one of these files holds valid JSON, then NUL bytes, then anything else, it loads silently instead of being rejected as corrupt. This could happen if a file is extended with zero-filled blocks, if bytes are appended by mistake, or if a stale prefix document sits in front of other data. The same applies to a CLI user's `--load-config` file and to tooling that feeds wire data containing NUL to `fromjson`. On the JSON-RPC server, bytes after a NUL in a request body are silently ignored. In practice the impact is small:
- `filesystem.write_file` writes a temp file, fsyncs it and renames it into place, so a crash rarely leaves a valid prefix followed by NULs. A torn write normally gives an empty or fully zeroed file, and both fail to parse.
- The accepted prefix is always a complete, well-formed JSON value.
- The StoredTree and StoredFrontier loads re-check the height and hashes afterward.

**Possible solution**: In `cartesi_mod_fromjson`, use `size_t len; const char *s = luaL_checklstring(L, 1, &len);`. Change `clua_fromjson` to take a `std::string_view` or a `(ptr, len)` pair, and call `nlohmann::json::parse(s, s + len, cb)`. Update the internal callers, which pass `std::string`/`const char *` values from the C API, to pass the length. In `jsonrpc-remote-machine.cpp:1947`, parse `req.body()` (a string or iterator range) instead of `.data()`. Add a regression test: `fromjson('{"a":1}\0x')` must fail.

**Severity**: low. Both reviewers agree:
- It only matters when the input already holds a complete valid JSON value followed by a NUL, and the effect is that some corruption is hidden instead of rejected.
- Atomic writes make the corrupted-file case unlikely, and the downstream height and hash checks in `hash-tree.lua` catch most stale-content cases.
- It causes no wrong hashes or proofs, no crash or hang, and no memory-safety issue.

**Risks**:
- Bug: a corrupted state, frontier or config file can load as a valid prefix document instead of failing loudly. This makes corruption harder to diagnose, and a stale prefix could be used where the follow-up checks do not cover it. JSON-RPC request bodies are not strictly validated.
- Fix: very low risk. Inputs that hold valid JSON followed by NUL, which are malformed anyway, will now be rejected. Any caller that relied on NUL-terminated buffers with trailing slack would start failing, but no such caller was found. Callers of `clua_fromjson` must pass the correct length.

**Proof of concept**: `bugs/p3-05-fromjson-truncates-at-nul/test.lua`. Run from the repo root:
`eval $(make -s env); timeout 30 lua5.4 bugs/p3-05-fromjson-truncates-at-nul/test.lua`
It exits with 1 and prints `BUG:` lines while the bug is present. It prints `PASS` and exits with 0 once the bug is fixed.

**ID**: `p3-05-fromjson-truncates-at-nul`

**Related**: [B72](#b72-tojson-and-fromjson-truncate-object-keys-at-nul-bytes-merging-distinct-keys).

### B74. tojson silently writes NaN and infinities as null

**Title**: cartesi.tojson silently turns NaN/+Inf/-Inf into JSON null; fromjson reads it back as nil, so the field or array element is lost

**Problem**: When `clua_push_managed_toclose_json_ref` meets a non-integer Lua number, it stores the number in the `nlohmann::json` value as it is, with no `std::isfinite` check. `nlohmann::json::dump()` writes NaN, +Inf and -Inf as `null` and raises no error. `cartesi.fromjson` then maps `null` to `nil`. The result is silent data loss: `{a=0/0, b=1}` serializes to `{"a":null,"b":1}` and comes back without `a`, and `{1, 0/0, 3}` becomes `[1,null,3]`, which restores with a nil hole at `t[2]`. The reverse direction is strict, because `fromjson` rejects a literal `NaN` with a parse error. So the API is asymmetric, and only `tojson` loses data.

**Origin**: Pre-existing. The branch's diff to `src/clua-i-machine.cpp` does not touch the number case.

**Area**: Lua JSON binding (`cartesi.tojson` / `cartesi.fromjson`, and Lua-table-to-JSON conversion in general).

**Category**: correctness (silent data loss)

**Location**:
- `src/clua-i-machine.cpp:419-421`: in `clua_push_managed_toclose_json_ref`, the `LUA_TNUMBER` floating-point branch runs `j = lua_tonumber(L, idx);` and never checks whether the value is finite.
- `src/clua-i-machine.cpp:629`: `clua_tojson` calls `j.dump(indent)`, and this is where nlohmann writes non-finite values as `null`.

**Evidence**: The test round-trips `{a=v, b=1}` through `cartesi.tojson` and `cartesi.fromjson` for v = NaN, +Inf and -Inf, and does the same for the array `{1, 0/0, 3}`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/p3-07-json-nan-inf-serialized-as-null/test.lua
nan -> {"a":null,"b":1} -> a=nil
BUG: tojson serialized non-finite nan as null without error; fromjson round-trip loses field 'a'
inf -> {"a":null,"b":1} -> a=nil
BUG: tojson serialized non-finite inf as null without error; fromjson round-trip loses field 'a'
-inf -> {"a":null,"b":1} -> a=nil
BUG: tojson serialized non-finite -inf as null without error; fromjson round-trip loses field 'a'
array {1,nan,3} -> [1,null,3] -> #t=3 t[2]=nil
BUG: NaN array element silently becomes null/nil hole
```
The test exits 1 while the bug is present. It exits 0 once `tojson` raises an error for non-finite numbers, because it treats a `pcall` failure as the correct behaviour.

**Scenario**: A Lua tool, a PRT node helper or a CLI script stores a computed float in its JSON state with `cartesi.tojson`, for example a rate, a timeout or a progress ratio that divides by zero. The JSON is written without any error. After a restart the field is `nil`, so code that indexes or compares it either throws far from the cause or silently takes a default path. Machine config and runtime config are not affected: every field in those schemas is an integer or a string. A NaN passed by mistake in a config table would still become `null` and most likely fall back to a default without any error.
- Hashes, proofs, step logs and the PRT node's persisted state (EpochState, `epoch.json`, cache manifests, `hash-tree.lua`'s StoredTree) contain no floats. The `math.huge` in `prt-demo.lua`'s `get_progress` is a local accumulator that is never serialized.
- So validators, the Rollups Node and Dave are not affected today.

**Possible solution**: In the floating-point branch, check the value first and throw when it is not finite. For example: `const lua_Number n = lua_tonumber(L, idx); if (!std::isfinite(n)) { throw std::invalid_argument("cannot serialize non-finite number (NaN or Inf) to JSON"); } j = n;`. `clua_tojson` already catches `std::exception` and turns it into a Lua error. Check that the other callers of `clua_push_managed_toclose_json_ref`, such as `clua_tojsonschemadict` and the config conversion, also catch it. If they do not, use `luaL_error` directly; nothing has to be released at that point because only to-be-closed managed values are held. Add a regression test for `tojson` with NaN, Inf and -Inf, both as object fields and as array elements.

**Severity**: low. Both reviewers rated it low. Non-finite floats are lost silently, but no emulator schema field and no PRT-node persisted value is a float, so hashes, proofs, step logs and validator liveness cannot be affected. Writing `null` is also the same choice JavaScript's `JSON.stringify` makes. The defect is the silent loss in a general-purpose library function, where lua-cjson and Python's `json.dumps(allow_nan=False)` raise an error instead.

**Risks**:
- Of the bug: third-party Lua state that holds non-finite floats is silently lost or truncated, and the failure shows up later, far from its cause. A NaN in a config table is silently replaced by a default instead of being rejected.
- Of the fix: code that today relies on `tojson` succeeding with NaN or Inf (for example, logging or dumping debug tables that contain `math.huge`) would start raising errors. This is a behaviour change, so it should be noted in the changelog. A less disruptive alternative is to keep `null` but add an opt-in strict mode. That leaves the silent loss as the default behaviour.

**Proof of concept**: `bugs/p3-07-json-nan-inf-serialized-as-null/test.lua`. Run it from the repo root with `eval $(make -s env); lua5.4 bugs/p3-07-json-nan-inf-serialized-as-null/test.lua`. It exits 1 while the bug is present and 0 once it is fixed.

**ID**: `p3-07-json-nan-inf-serialized-as-null`

### B75. tojson writes unsigned 64-bit values of 2^63 or more as negative integers

**Title**: Lua tojson writes uint64 values >= 2^63 as negative JSON integers (e.g. `--store-config` with `format:json`)

- **Problem**: Lua 5.4 has only signed 64-bit integers. So when the Lua binding converts JSON to Lua (`clua_push_json_value`), a `number_unsigned` value at or above 2^63 becomes a negative Lua integer through `static_cast<int64_t>`. That step alone is unavoidable. The problem is the way back out. `clua_push_managed_toclose_json_ref` always stores a Lua integer as `int64_t`, and the only schema primitive it treats specially is `ArrayIndex`. No primitive writes the value back as `uint64_t`. As a result, JSON produced by `cartesi.tojson` (and anything built on it) contains negative numbers for fields that the JSON-RPC schema (`src/jsonrpc-discover.cpp`) documents as `UnsignedInteger`. Examples are `"ilrsc": -1`, `"imcyclemax": -1` and `"misa": -9223372036853460691`. For the same machine, the C API (`cm_get_initial_config`) writes `18446744073709551615` and `9223372036856090925`.
- **Origin**: pre-existing. `origin/main` has the same code, and the branch makes no relevant change to these paths.
- **Area**: Lua JSON layer (`cartesi.tojson` / `fromjson`) and the CLI's `--store-config=...,format:json`.
- **Category**: api-contract (interoperability).
- **Location**:
  - `src/clua-i-machine.cpp:509-515`: `clua_push_json_value`, `number_unsigned` case, `static_cast<int64_t>(j.get<uint64_t>())`.
  - `src/clua-i-machine.cpp:412-423`: `clua_push_managed_toclose_json_ref`, `LUA_TNUMBER` case, `int64_t v = lua_tointeger(...); j = v;`. Only `ArrayIndex` is special-cased.
  - `src/clua-cartesi.cpp:164-170`: `cartesi_mod_tojson`, which exposes the path to Lua.
  - `src/cartesi-machine.lua:3114-3116`: `serialize_config`, which writes `cartesi.tojson(config, 2)` to the user's file.
  - `src/json-util.cpp:802-826`: `ju_get_opt_field<uint64_t>`, which casts negative integers back to unsigned. This is why the emulator's own loaders do not notice the problem.
- **Evidence**: `test.lua` round-trips `m:get_initial_config()` through `cartesi.tojson`, runs `cartesi-machine.lua --store-config=<tmp>.json,format:json`, and looks for negative values in both outputs. `c.cpp` is a control that prints the same fields as the C API emits them. Run with `eval $(make -s env); timeout 120 lua5.4 bugs/p3-08-tojson-uint64-written-as-negative/test.lua`:
  ```
  tojson(get_initial_config()) negative fields: ilrsc=-1, imcyclemax=-1, misa=-9223372036853460691
  Lua value of processor.registers.ilrsc = -1 (C API value is 2^64-1 = 18446744073709551615)
  cartesi-machine --store-config JSON negative fields: ilrsc=-1, imcyclemax=-1, misa=-9223372036853460691
  BUG: Lua tojson writes uint64 fields >= 2^63 as negative JSON integers (violates UnsignedInteger schema)
  (exit status 1)
  ```
  The C API control (`c.cpp`) prints `"ilrsc":18446744073709551615,...` and `"misa":9223372036856090925,...`.
- **Scenario**: Suppose a Rollups Node, Dave component or other tool written in another language (Rust serde `u64`, Go `uint64`, or jq/JS scripts comparing magnitudes) reads a machine config or other JSON file written by the Lua tooling, for example `cartesi-machine --store-config=cfg.json,format:json`. That reader rejects `-1`, or it misreads a sentinel such as `imcyclemax` or `ilrsc` as a small signed value. The same applies to any Lua-produced JSON sent to a JSON-RPC server that is not the emulator. The PRT Lua node itself is not affected in practice. Its own `tojson` messages carry small integers, and the fields PRT depends on (`mcycle`, target addresses, log2 sizes) stay far below 2^63. Nodes that call the C API directly get correct unsigned JSON.
- **Possible solution**: In `clua_push_managed_toclose_json_ref`, write `j = static_cast<uint64_t>(v)` when the field schema marks the value as unsigned. One way is to add an `UnsignedInteger` primitive to the Lua schema dictionary and use it for the config, register and other `uint64` fields. Another is to default integer fields of known-unsigned schemas, such as the machine config, to unsigned output. Leave `fromjson` as is: the two's-complement Lua integer is the correct bit pattern.
- **Severity**: low. Both reviewers agreed. Hashes, proofs, step logs and machine state are unaffected, and the emulator's own consumers (C API, `cartesi-jsonrpc-machine`, `--load-config`) accept the negative values by design and round-trip them bit-exactly. The only impact is on strict external `u64` parsers reading JSON produced from Lua, and only for the few fields whose values reach 2^63 or more (`ilrsc`, `imcyclemax`, `misa`).
- **Risks**: Of the bug: stored configs and other Lua-produced JSON break the documented `UnsignedInteger` contract, which can cause parse failures or misread sentinels in tooling written in other languages. Of the fix: emitting unsigned values for fields that really are signed would turn small negative values into huge positive ones, so the unsigned primitive must only be applied to fields that are actually `uint64`. Users or tests that compare existing stored JSON byte for byte would see output change from `-1` to `18446744073709551615`. The C++ loaders accept both forms, so reading stays compatible.
- **Proof of concept**: `bugs/p3-08-tojson-uint64-written-as-negative/test.lua` (reproducer; exits 1 while the bug is present) and `bugs/p3-08-tojson-uint64-written-as-negative/c.cpp` (C API control). Run from the repo root:
  ```
  eval $(make -s env); timeout 120 lua5.4 bugs/p3-08-tojson-uint64-written-as-negative/test.lua
  # optional control:
  g++ -std=c++20 -Isrc bugs/p3-08-tojson-uint64-written-as-negative/c.cpp -Lsrc -lcartesi -o /tmp/p3-08-c && /tmp/p3-08-c
  ```

**ID**: `p3-08-tojson-uint64-written-as-negative`

**Related**: [B69](#b69-arrayindex-conversion-between-json-and-lua-silently-wraps-out-of-range-indices).

### B76. filesystem.get_file_size returns 2^63-1 for directories and blocks on FIFOs

**Title**: `cartesi.filesystem.get_file_size` returns 2^63-1 for directories and blocks forever on FIFOs

**Problem**: `filesystem.get_file_size` uses `io.open(filename, "rb")` followed by `f:seek("end")` and never calls `stat`, so it does not check that the path is a regular file. On Linux, `fopen` in read mode succeeds on a directory, and `lseek(SEEK_END)` on an ext4 (htree) directory returns `LLONG_MAX`. The function therefore returns `9223372036854775807` where it should raise an error. On a FIFO, a read-mode `fopen` blocks until a writer appears, so the call hangs forever. A file without read permission also fails, even though `stat` could still read its size. The documented contract is "Returns the size of a file in bytes".

**Origin**: Introduced by this branch. `src/cartesi/filesystem.lua` was added in commit 956a179 ("feat: add the cartesi.filesystem Lua module") and does not exist on `origin/main`.

**Area**: `cartesi.filesystem` Lua module, used by the PRT node recipe.

**Category**: Correctness (missing file-type validation; possible hang).

**Location**:
- `src/cartesi/filesystem.lua:96-100`: `filesystem.get_file_size`
- `doc/recipes/prt.lua:2734`: `assert(fs.get_file_size(outputs_log_path) >= outputs_log_size, "outputs.log lost committed records")`
- `src/os-filesystem.cpp:130-139`: `os::file_size`, a `stat`-based version that rejects directories but is not exposed to Lua

**Evidence**: The test creates a fresh directory under `/tmp` (ext4) and calls `pcall(fs.get_file_size, dir)`. It then creates a FIFO and calls `get_file_size` on it in a child process under a 3-second `timeout`.
```
$ eval $(make -s env); lua5.4 bugs/p3-09-fs-get-file-size-directory-fifo/test.lua
get_file_size(directory) ->	true	9223372036854775807
BUG: get_file_size on a directory returned 9223372036854775807 instead of failing
BUG: assert(fs.get_file_size(dir) >= outputs_log_size) would pass for any size
get_file_size(fifo) child output:	rc=124
BUG: get_file_size on a FIFO blocked (killed by 3s timeout)
exit=1
```
The test exits 1 while the bug is present and 0 once it is fixed. Both reviewers reproduced the directory result independently.

**Scenario**: During recovery, the PRT node runs the `outputs.log lost committed records` guard before it truncates `outputs.log`. If `outputs.log` in the node's data directory is a directory, for example from a bad layout, a leftover, or an operator mistake, the guard passes with a bogus size instead of reporting the problem. The next call, `fs.truncate_file`, then fails with "open() failed: Is a directory". The node stops with a misleading error and no state is corrupted. If a FIFO is planted at that path, or at any path a tool size-checks with this helper, the process hangs forever instead of failing. Hashes, proofs and step logs are not affected.

**Possible solution**: Expose a `stat`-based size function through `cartesi.filesystem`'s C core (`os::file_size`) and have it require `S_ISREG`. Note that `os::file_size` today rejects only `S_ISDIR`, so it should be tightened to reject FIFOs, sockets and devices too. An alternative is to open with `O_RDONLY|O_NONBLOCK`, `fstat`, require `S_ISREG`, and return `st_size`.

**Severity**: Low. Both reviewers agree. The trigger needs a malformed or hostile local data directory (an attacker with write access there can already disrupt the node in simpler ways). In the only real caller, the very next truncate fails anyway, so the visible effect is a different error message or a hang. No hashes, proofs or stored state are affected.

**Risks**:
- Of the bug: the guard passes for the wrong reason and the node reports a misleading error; a FIFO at a checked path causes an indefinite hang (local DoS); readable-size checks fail on files without read permission.
- Of the fix: low. Callers that relied on `get_file_size` working on non-regular files, such as block devices, which `seek("end")` sizes correctly while `stat` reports `st_size == 0`, would now get an error. If block devices must be supported, handle them explicitly (for example with `BLKGETSIZE64` or by keeping the seek path for `S_ISBLK`).

**Proof of concept**: `bugs/p3-09-fs-get-file-size-directory-fifo/test.lua`. Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/p3-09-fs-get-file-size-directory-fifo/test.lua
```
Requires `mkfifo` and `timeout` (coreutils). Exit code 1 means the bug reproduces; 0 means it is fixed.

**ID**: `p3-09-fs-get-file-size-directory-fifo`

### B77. filesystem.remove_directory deletes files and remove_file deletes empty directories

**Title**: cartesi.filesystem: remove_directory deletes regular files and remove_file deletes empty directories (both call os.remove)

**Problem:** `filesystem.remove_file` and `filesystem.remove_directory` are both `assert(os.remove(path))`. Lua's `os.remove` calls C `remove(3)`, which unlinks a file and also rmdirs an empty directory. Neither function checks what kind of entry it gets. Their doc comments promise "Removes a file." and "Removes an empty directory.", but `remove_directory(file)` silently deletes the file, and `remove_file(empty_dir)` silently deletes the directory. The C++ helpers `os::remove_directory` (`rmdir`) and `os::remove_file` (`unlink`) do check the kind, but `cartesi.filesystem.core` does not expose them.

**Origin:** Introduced by this branch. `src/cartesi/filesystem.lua` was added in commit 956a179 ("feat: add the cartesi.filesystem Lua module") and does not exist on `origin/main`.

**Area:** `cartesi.filesystem` Lua module (public Lua API used by the PRT node recipe `doc/recipes/prt.lua` and by the emulator's Lua code).

**Category:** api-contract

**Location:**
- `src/cartesi/filesystem.lua:123-124`: `filesystem.remove_file(filename)` is `assert(os.remove(filename))`.
- `src/cartesi/filesystem.lua:129-130`: `filesystem.remove_directory(dirname)` is `assert(os.remove(dirname))`.
- `src/os-filesystem.cpp:147-148` (`os::remove_directory`, `rmdir`) and `src/os-filesystem.cpp:193-194` (`os::remove_file`, `unlink`): kind-checking versions that already exist in C++.
- `src/clua-cartesi-filesystem.cpp:139-148`: the `filesystem_core_mod` table binds neither of them.

**Evidence:** `test.lua` creates a regular file and an empty directory in a temporary directory. It calls `fs.remove_directory` on the file and `fs.remove_file` on the directory, and checks whether each call raised an error or deleted the entry. Both calls succeed and delete the entry:
```
$ eval $(make -s env); lua5.4 bugs/p3-10-fs-remove-directory-removes-files/test.lua
BUG: fs.remove_directory(regular file) succeeded and deleted the file
BUG: fs.remove_file(empty directory) succeeded and deleted the directory
(exit 1)
```
When the bug is fixed, both calls fail, and the test prints `ok: ...` twice, then `PASS`, and exits 0.

**Scenario:** A caller uses `remove_directory` as a guard meaning "delete only if this is an empty directory", or `remove_file` as "delete only if this is a file". If the path is the other kind, the entry is deleted quietly instead of raising an error. The PRT node cannot reach the harmful direction. In `doc/recipes/prt.lua`, every `fs.remove_directory` call follows an `fs.list_directory` of the same path: `remove_leftover_stored_machine` (line 1126), `clear_epoch_directory` for `entries`/`forests`/`inputs`/`outputs` (lines 2628, 2633), and `remove_epoch_directory` (line 2645). So a regular file under one of those names makes `list_directory` fail first. The other direction is reachable: if `state.json`, `outputs.log`, an epoch file, or an entry inside `forests`/`inputs`/`outputs` were an empty directory, `remove_file` would rmdir it without complaint. That only removes an empty directory the node is already clearing. Other apps and CLI scripts that use the module, and future callers, lose the type check that the docs promise. None of this affects hashes, proofs, step logs, disputes, or stored machine state.

**Possible solution:** Bind `os::remove_file` (`unlink(2)`) and `os::remove_directory` (`rmdir(2)`) in `cartesi.filesystem.core` (`src/clua-cartesi-filesystem.cpp`). Then implement `filesystem.remove_file` and `filesystem.remove_directory` with those bindings instead of `os.remove`. Keep raising Lua errors that carry the path and the errno message (`EISDIR`/`EPERM` for unlink on a directory, `ENOTDIR` for rmdir on a file). Add a regression test, for example this PoC, to the Lua filesystem tests.

**Severity:** low. Both reviewers agree, and so does the prover. The documented contract does not hold in a newly shipped public API, but no in-scope caller relies on the check. The PRT node lists each directory before removing it. The only reachable wrong-kind deletion is an empty directory the node was clearing anyway. There is no effect on dispute correctness or validator liveness.

**Risks:**
- *Of the bug:* Silent deletion of the wrong kind of entry, for callers that treat the remove functions as kind-checked guards. A wrong-directory safety check like the one `clear_epoch_directory` aims for could quietly stop working in future code.
- *Of the fix:* Behavior gets stricter. Any existing caller that passes a directory to `remove_file`, or a file to `remove_directory`, will now get an error. No such caller was found in `src/`, `tests/` or `doc/recipes/prt.lua`. Error message text may change if callers or tests match on it. Error messages on platforms where `unlink` on a directory returns `EPERM` instead of `EISDIR` (macOS) differ, which matters only for tests that match on the message.

**Proof of concept:** `bugs/p3-10-fs-remove-directory-removes-files/test.lua` (pure Lua, no machine images needed). Run from the repo root:
```
eval $(make -s env); lua5.4 bugs/p3-10-fs-remove-directory-removes-files/test.lua
```
It exits 1 and prints the two `BUG:` lines while the bug is present. It prints `PASS` and exits 0 once fixed.

**ID**: `p3-10-fs-remove-directory-removes-files`

**Related**: [B76](#b76-filesystemget_file_size-returns-263-1-for-directories-and-blocks-on-fifos).

## Candidates that were not confirmed

These candidates were proposed and investigated but did not pass review. They are listed so that readers can see what
was ruled out, and why. Several were reproduced and rejected only because reviewers judged the behavior intended; a split
vote means at least one reviewer would have confirmed it.

| Candidate | Outcome | Reason |
|---|---|---|
| `const` C API hash calls (`cm_get_proof`, `cm_get_root_hash`, `cm_get_node_hash`) update the page cache without locking | rejected 2 to 1 | Reproduced: concurrent calls on one machine object crash or return wrong proofs. Rejected as misuse, since one machine object is not meant to be shared across threads. |
| `clone_file` hard-links read-only files, so clones alias the source inode | rejected 2 to 0 | Reproduced, but hard-linking read-only sources is the documented contract of `clone_file`. |
| `frontier_forest_expand_leaf` raises on a leaf that is already expanded | rejected 2 to 1 | Reproduced, but the documented precondition covers only opaque leaves. |
| `frontier_forest_load` reads every stored mixed tree at load time | rejected 2 to 1 | Reproduced (all tree files are read before any query), but hashes are correct and reviewers judged it the documented design, a performance matter only. |
| Page cache copies new words into a shared entry before hashing them | not reproduced | A real kill leaves the entry marked borrowed, so the reload fails loudly (B03) rather than trusting a torn entry. |
| CLI `--print-uarch-cycle-root-hashes` passes a fake revert tail in cmio mode | not reproduced | The CLI refuses that option combination before running. |
| `set_runtime_config` accepts `clear_hash_tree=true` and does nothing | rejected 2 to 1 | Reproduced, but the field is documented as applying at create or load only. |
| `cartesi.util.read_file` and `write_file` were removed | rejected 2 to 0 | A deliberate, changelogged change with a one-line migration to `cartesi.filesystem`. |
| `clear_hash_tree` commits about 50 MiB per machine | rejected 2 to 0 | One-time and bounded by the page-cache size; not a leak. |

`verify_hash_tree` not checking inner nodes was first rejected 2 to 1 (`ht-05`), then confirmed by another panel, and it
is listed as B30 with a reviewer note.

## Method and environment

Ten review workflows ran in two waves. Each hunter agent worked one area or angle and proposed candidates. A triage
agent merged duplicates. A prover agent wrote and ran a test for each candidate. Two independent reviewers, plus a
tie-breaker when they split, tried to refute each claim. A recorder agent wrote the entry. Issues found by more than one
group are listed once, with the other reproductions linked.

The second wave added differential testing of the hash tree and of dispute artifacts in normal operation. It compared
root hashes, node hashes, proofs, step logs, uarch and mcycle collections across store and load in every sharing mode,
`clear_hash_tree`, tiny page caches that force evictions, remote machines, and concurrency settings. It found no
divergence outside the crash, stale-cache and `replace_memory_range` scenarios listed above.

The tests ran on Ubuntu 24.04 (x86-64, ext4) against a local build of this branch. The uarch was built with GCC 13
rather than the official GCC 14 toolchain, so uarch-dependent hashes differ from upstream golden values. No test
compares against golden values.
