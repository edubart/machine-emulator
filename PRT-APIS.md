# Emulator APIs used by the Lua PRT node

This catalog lists the emulator APIs that the experimental Lua PRT validator node on `feature/prt` calls. It covers
the node's modules in `doc/recipes/`: `prt.lua`, `prt-bridge.lua`, `prt-cast.lua`, `prt-deploy.lua`,
`prt-dishonest.lua`, `prt-epoch.lua`, `prt-ethereum.lua`, `prt-log-history.lua`, `prt-player.lua`,
`prt-transactions.lua`, `prt-websocket.lua`, `prtu.lua` and `prt-demo.lua`. Test drivers are excluded. Counts are
call sites, not calls at run time. It was built with `grep` over those files and checked against the call sites.

The categories match the second round of bug hunting recorded in `BUGS.md` (IDs starting with `p`).

## How the node uses the machine

- The working machine and its backup are JSON-RPC remote machines. `cartesi.jsonrpc.spawn_server("127.0.0.1:0")`
  creates a server. `fork_server` takes a snapshot at an input boundary. A rollback calls `shutdown_server`, then
  `swap` and `rebind_server` to the old address (`prt.lua:990-1080`).
- Stored machines are loaded in place with `SHARING_ALL` and snapshotted with `clone_stored` and `sync_stored`. A
  rollback through stored machines calls `remove_stored` and then `rename_stored` (`prt.lua:1100-1180`). Epoch
  templates are written with `store`, `sync_stored` and `rename_stored` (`prt.lua:2570-2690`).
- After every load the node asserts that `get_root_hash` equals the expected state hash.
- Dispute responses from other players are checked with the class methods `cartesi.machine:verify_send_cmio_response`,
  `verify_step_uarch` and `verify_reset_uarch` (`prt.lua:276-288`, `prt-ethereum.lua:174-184`). Their inputs are
  attacker-controlled.

## 1. Remote machine lifecycle (JSON-RPC)

| API | Call sites | Notes |
|---|---|---|
| `cartesi.jsonrpc.spawn_server(address)` | 1 | Always `"127.0.0.1:0"`. |
| `machine:fork_server()` | 3 | Snapshot at an input boundary. |
| `machine:swap(other)` | 4 | Swaps a remote machine with its backup, or with a `cartesi.new()` object. |
| `machine:rebind_server(address)` | 1 | Restores the original address after a rollback. |
| `machine:get_server_address()` | 1 | |
| `machine:shutdown_server()` | 5 | |
| `machine:set_cleanup_call(cartesi_jsonrpc.SHUTDOWN)` | 1 | Shuts a forked server down when its object is collected. |
| `cartesi.new()` | 2 | Empty machine objects. |
| `machine:destroy()` | 3 | Also through `<close>` variables. |

## 2. Stored machine lifecycle

| API | Call sites | Notes |
|---|---|---|
| `machine:load(dir, nil, sharing)` | 4 | `SHARING_ALL` in place, or a caller-chosen sharing mode. |
| `cartesi.machine(dir)` | 1 | Loads an epoch template. |
| `machine:store(dir)` | 1 | Into a temporary directory, then `sync_stored` and `rename_stored`. |
| `machine:clone_stored(from, to)` and `cartesi.machine:clone_stored(...)` | 4 | Snapshots and template copies. |
| `machine:sync_stored(dir)` | 3 | |
| `machine:rename_stored(from, to)` and `cartesi.machine:rename_stored(...)` | 4 | Commit and rollback. |
| `machine:remove_stored(dir)` and `cartesi.machine:remove_stored(...)` | 4 | Rollback and cache eviction. |
| `machine:get_initial_config()` | 1 | Reads `ram.length`. |

## 3. Execution and computation commitments

| API | Call sites | Notes |
|---|---|---|
| `machine:run(mcycle_end)` | 6 | Break reasons checked: `REACHED_TARGET_MCYCLE`, `YIELDED_MANUALLY`, `YIELDED_AUTOMATICALLY`, `YIELDED_SOFTLY`, `HALTED`, `MCYCLE_OVERFLOW`. |
| `machine:run_uarch(uarch_cycle)` | 2 | |
| `machine:read_reg(name)` | 18 | `mcycle`, `uarch_cycle`, `iflags_Y`, `iflags_H`, `htif_tohost_dev`, `htif_tohost_cmd`, `htif_tohost_reason`. |
| `cartesi.machine:get_reg_address(name)` | 2 | `iflags_Y`, `htif_tohost`. |
| `machine:collect_mcycle_root_hashes(end, log2_period, offset, bundle_height)` | 4 | Collected in chunks. |
| `machine:collect_mcycle_bundle(...)` | 5 | |
| `machine:collect_uarch_cycle_root_hashes(end, bundle_height, revert_uarch_tail)` | 6 | Including `MCYCLE_MAX` and `mcycle + 1` as the end. |
| `machine:collect_uarch_cycle_bundle(...)` | 3 | |
| Constants | | `MCYCLE_MAX`, `UARCH_CYCLE_MAX`, `ROLLUP_LOG2_MAX_UARCH_CYCLES_PER_MCYCLE`, `ROLLUP_LOG2_MAX_MCYCLES_PER_ADVANCE_STATE`, `ROLLUP_LOG2_MAX_ADVANCE_STATES_PER_EPOCH`, `ROLLUP_LOG2_MAX_OUTPUT_COUNT`, `UARCH_PRISTINE_STATE_HASH`. |

## 4. Inputs and cmio

| API | Call sites | Notes |
|---|---|---|
| `machine:receive_cmio_request()` | 3 | |
| `machine:send_cmio_response(reason, data, revert_root_hash)` | 1 | Advance-state inputs. |
| `machine:log_send_cmio_response(reason, data, revert_root_hash)` | 1 | |
| `cartesi.machine:verify_send_cmio_response(...)` | 2 | On logs from other players. |
| `machine:read_memory(AR_CMIO_TX_BUFFER_START, 32)` | 3 | Reads the outputs root. |
| `machine:write_memory(addr, data)` | 1 | The dishonest test player only. |
| Constants | | `HTIF_YIELD_REASON_ADVANCE_STATE`, `HTIF_YIELD_CMD_MANUAL`, `HTIF_YIELD_CMD_AUTOMATIC`, `HTIF_YIELD_MANUAL_REASON_RX_ACCEPTED`, `HTIF_YIELD_MANUAL_REASON_RX_REJECTED`, `HTIF_YIELD_AUTOMATIC_REASON_TX_OUTPUT`, `HTIF_DEV_YIELD`, `AR_RAM_START`, `AR_CMIO_TX_BUFFER_START`. |

## 5. Dispute proofs and state hashes

| API | Call sites | Notes |
|---|---|---|
| `machine:get_root_hash()` | 18 | Checked after every load, snapshot and rollback. |
| `machine:log_step_uarch()` | 4 | |
| `cartesi.machine:verify_step_uarch(root_before, log)` | 2 | On logs from other players. |
| `machine:log_reset_uarch()` | 1 | |
| `cartesi.machine:verify_reset_uarch(root_before, log)` | 2 | On logs from other players. |
| `machine:get_proof(address, log2_size)` | 4 | Word proofs (`HASH_TREE_LOG2_WORD_SIZE`). |
| `machine:get_node_hash(...)` | 4 | |
| `machine:read_memory(address, 32)` | 4 | Word reads for proofs. |

## 6. Hash trees and frontiers (`cartesi.hash-tree`)

| API | Call sites |
|---|---|
| `frontier_forest`, `frontier_forest_pad_back`, `frontier_forest_append`, `frontier_forest_push_back` | 9, 12, 3, 1 |
| `frontier_forest_get_root_hash`, `frontier_forest_get_node_hash`, `frontier_forest_get_siblings`, `frontier_forest_get_leaf_count` | 2, 4, 2, 3 |
| `frontier_forest_expand_leaf`, `frontier_forest_store`, `frontier_forest_load` | 1, 3, 3 |
| `frontier`, `frontier_copy`, `frontier_push_back`, `frontier_next_proofs` | 1, 2, 1, 1 |
| `frontier_get_root_hash`, `frontier_get_leaf_count`, `frontier_store`, `frontier_load` | 9, 6, 4, 1 |
| `verify_slice` | 3 |

## 7. Ethereum encoding (`cartesi.evmu`) and hashing

| API | Call sites |
|---|---|
| `evmu.bint(...)`, `evmu.bint.tobase`, `evmu.bint.tointeger` (from `cartesi.third-party.bint`) | 23, 2, 1 |
| `evmu.decode_abi`, `evmu.encode_abi` | 5, 1 |
| `evmu.encode_calldata_hex`, `evmu.decode_calldata` | 3, 1 |
| `evmu.encode_hex`, `evmu.decode_hex` | 1, 1 |
| `cartesi.keccak256(a[, b])`, `cartesi.hash(...)` | 5, 3 |
| `cartesi.tohex`, `cartesi.fromhex`, `cartesi.tobase64` | 16, 7, 2 |
| `cartesi.HASH_SIZE`, `cartesi.HASH_TREE_LOG2_WORD_SIZE` | 5, 2 |

## 8. JSON, files and utilities

| API | Call sites | Notes |
|---|---|---|
| `cartesi.tojson(value[, indent, schema_name, schemas])` | 4 | Writes epoch state with the custom `EpochState` schema. |
| `cartesi.fromjson(text[, schema_name, schemas])` | 3 | Reads it back. |
| `fs.exists`, `fs.read_file`, `fs.write_file`, `fs.get_file_size` | 16, 11, 4, 1 | |
| `fs.create_directory`, `fs.list_directory`, `fs.remove_directory`, `fs.remove_file` | 7, 7, 4, 7 | |
| `fs.sync_file`, `fs.sync_directory`, `fs.new_temporary_file`, `fs.truncate_file` | 5, 8, 2, 1 | Durable writes. |
| `fs.clone_file`, `fs.write_scope_temp_file`, `fs.temp_pathname` | 1, 1, 1 | |
| `cartesi.util.forward_method` | 1 | The dishonest test player only. |
