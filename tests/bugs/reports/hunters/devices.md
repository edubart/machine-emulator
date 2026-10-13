# Angle: `devices` — emulated devices and guest<->host I/O

Scope audited: HTIF (`htif-address-range.cpp`, `htif-constants.hpp`), CLINT
(`clint-address-range.cpp`), PLIC (`plic-address-range.cpp`, `plic-constants.hpp`),
RTC (`rtc.hpp`), CMIO (`send-cmio-response.cpp`, `machine-cmio-request.hpp`,
`machine.cpp::receive_cmio_request`, `cm.cpp` CMIO C-API,
`record/replay-send-cmio-state-access.hpp`, `state-access.hpp::do_write_memory_with_padding`),
device dispatch in `interpret.cpp`, the device-state-access bridge
(`device-state-access.hpp`, `i-device-state-access.hpp`), machine console
(`machine-console.cpp/.hpp` + console C-API), and VirtIO
(`virtio-address-range.cpp/.hpp`, `virtio-serializer.hpp`,
`virtio-console-address-range.cpp`, `virtio-p9fs-address-range.cpp/.hpp`,
`virtio-net-*.cpp`).

IMPORTANT ENVIRONMENT NOTE: partway through this audit the session's sandbox
began refusing ALL command execution (the `Bash` tool, including read-only
commands and builds) via a safety classifier unrelated to the actions
themselves. I was therefore unable to *compile and run* the PoC I wrote for
devices-1. The PoC is complete and self-contained in
`<SCRATCH>/work/devices/` (driver.c, crt.S, harness.c, run.sh) and the single
command to reproduce is `bash <SCRATCH>/work/devices/run.sh`. Both findings
below are proven by precise code traces; devices-1 additionally has the
ready-to-run PoC. I flag this honestly so the coordinator can execute the PoC
in a shell-enabled session.

---

### devices-1: VirtIO virtqueue descriptor-chain traversal has no cycle/length bound → guest-triggerable infinite loop (host hang / DoS)
- Status: PROVEN (by code trace; self-contained PoC written, not executed in-session — see environment note)
- Area: devices (VirtIO)
- Category: DoS (infinite loop) reachable from guest code
- Where: `src/virtio-address-range.cpp:150` `virtq::get_desc_rw_avail_len()`
  (also `virtq::read_desc_mem()` line 191 and `virtq::write_desc_mem()` line 238;
  reached from `virtio_address_range::on_device_queue_notify()` line 460, which
  every VirtIO device enters on a `QUEUE_NOTIFY` MMIO write).
- Problem: The descriptor-chain walkers follow `desc.next` in an unbounded
  `while (true)` loop. The only exits are (a) `virtq_get_desc()` failing a guest
  memory read, or (b) a descriptor without the `VIRTQ_DESC_F_NEXT` flag. There
  is no visited-set, no iteration counter, and no cap at the queue size
  (`vq.num`). `virtq_get_desc()` masks the index with `desc_idx & (vq.num-1)`
  and reads from guest RAM, which always succeeds for in-RAM descriptor tables.
  A guest that programs a descriptor whose `next` forms a cycle (e.g.
  `desc[0].next = 0` with `F_NEXT` set and `F_WRITE` clear) makes the loop run
  forever. `get_desc_rw_avail_len` is called from `on_device_queue_notify`
  *before* the device-specific handler, so this affects every VirtIO device
  (console, 9p, net). Reference implementations (e.g. QEMU `virtqueue_pop`)
  specifically cap the chain at `vq->vring.num` descriptors and raise
  "Looped descriptor" to prevent exactly this. That guard is absent here.

  Contributing gaps in the same area (sub-issues of this finding):
  * `is_power_of_2(0)` returns true (`(0 & (0u-1)) == 0`), so a guest can set
    `QUEUE_NUM = 0` (`mmio_write` `VIRTIO_MMIO_QUEUE_NUM`, line 716); then
    `vq.num - 1 == 0xFFFFFFFF` and the index masking becomes a no-op.
  * `VIRTIO_MMIO_QUEUE_READY` (line 720) sets `ready` without requiring a valid
    `num`, and `on_device_queue_notify` never checks `vq.num != 0`.
- Scenario: A host operator runs an *unreproducible* Cartesi machine (required
  for VirtIO; `iunrep != 0`, see `machine-address-ranges.cpp:540` and
  `doc/README.md` §"unreproducible mode") that shares a host directory with the
  guest via `--virtio-9p`, or exposes virtio-net/console, and the guest is
  untrusted (or merely buggy). A tiny guest driver performs the standard virtio
  init handshake, builds a 1-element self-referential descriptor chain, and
  writes `QUEUE_NOTIFY`. The emulator thread spins at 100% CPU inside
  `get_desc_rw_avail_len` and never returns from `cm_run`; the machine cannot be
  stepped, hashed, or shut down normally. For a node/host multiplexing untrusted
  machines this is a denial of service.
- Evidence: PoC in `<SCRATCH>/work/devices/` — `driver.c` (bare-metal
  virtio-mmio driver: full ACKNOWLEDGE/DRIVER/features/FEATURES_OK/queue/
  DRIVER_OK handshake, then `desc[0].next=0` with `F_NEXT`, `avail.idx=1`,
  `QUEUE_NOTIFY=0`), `crt.S`, `harness.c` (creates an `iunrep=1` machine with a
  `p9fs` virtio device at 0x40010000, loads the driver into RAM, runs `cm_run`
  under an 8s watchdog child), `run.sh`. Reproduce with
  `bash <SCRATCH>/work/devices/run.sh`. Expected: `BUG REPRODUCED: emulator hung
  >8s inside virtio queue processing` and exit code 1. A fixed emulator (chain
  cap + `notify_device_needs_reset`) would let `QUEUE_NOTIFY` return and the
  guest would HTIF-halt, printing `NO HANG` and exit 0.
  Code trace (self-referential chain, `desc[0]`): `get_desc_rw_avail_len`
  reads `desc[0]` → not `F_WRITE` → `read_len += len` → `F_NEXT` set so no
  break → `desc_idx = desc.next = 0` → repeat forever.
- Possible solution: Bound the traversal. Track the number of descriptors
  visited and abort (via `notify_device_needs_reset`) once it exceeds `vq.num`
  (as the VirtIO spec requires a chain to be shorter than the queue size), in
  all three walkers (`get_desc_rw_avail_len`, `read_desc_mem`, `write_desc_mem`).
  Additionally reject `QUEUE_NUM == 0` in `is_power_of_2`/the `QUEUE_NUM` handler
  and refuse to process a queue whose `num` is 0.
- Severity: Medium — guest-reachable DoS (hang) of the emulator host process.
  Only reachable in unreproducible mode (not in on-chain/verifiable machines),
  but directly relevant to anyone running untrusted guests with VirtIO devices
  (the documented 9p host-directory-sharing use case).
- Risks if unfixed: a single malicious/buggy guest hangs the emulator process
  indefinitely (unresponsive, 100% CPU). Fix risk: minimal — it only rejects
  malformed/cyclic chains that a conforming driver never produces; does not
  affect reproducible-mode root hashes (VirtIO is absent there).

---

### devices-2: VirtIO 9P `Tsymlink` target is unrestricted → untrusted guest escapes the shared host directory (arbitrary host file read/write)
- Status: PROVEN (by code trace)
- Area: devices (VirtIO 9p / guest↔host filesystem)
- Category: input-validation / host security boundary break (path traversal)
- Where: `src/virtio-p9fs-address-range.cpp:1310` `op_symlink()` (symlink target
  `symtgt` is used verbatim: `symlink(symtgt, path.c_str())`, line 1335), in
  combination with `op_walk()` (line 2173) / `op_lopen()` (line 1166) which
  resolve multi-component host paths with the process's full privileges and no
  `O_NOFOLLOW`/`openat2(RESOLVE_BENEATH)` containment.
- Problem: The 9p server is a *passthrough* that builds host paths textually and
  calls libc `open`/`lstat`/`symlink`/`link`/`rename` on them. Name components
  passed to create-type ops are validated by `is_name_legal()` (rejects `/`,
  `.`, `..`, empty — line 959), and `op_walk`'s `..` handling is correctly
  guarded against climbing above the root by an inode+dev comparison
  (`is_same_stat_ino(&root_st, &st)`, line 2218) — so *textual* traversal
  cannot escape. However, `op_symlink` places **no restriction on the symlink
  target** `symtgt` (a full `P9_PATH_MAX` string copied straight from the guest).
  A guest can create, inside the shared root, a symlink pointing anywhere on the
  host (`"/"`, `"/etc/passwd"`, `"../../.."`). Subsequent `Twalk`/`Tlopen` on
  that name (or a path through it) is resolved by the host kernel, following the
  symlink out of the shared tree. The guest then reads/writes arbitrary host
  files accessible to the emulator process.
- Scenario: An operator shares a directory with an untrusted guest via
  `--virtio-9p` (unreproducible mode). Guest does: `Tattach` → `Twalk` to root →
  `Tsymlink name="esc" symtgt="/etc/passwd"` (creates `<root>/esc` → /etc/passwd)
  → `Twalk ["esc"]` → `Tlopen` (O_RDONLY follows the symlink) → `Tread`. Result:
  the guest reads host `/etc/passwd` (and by the same technique any file/dir the
  emulator user can reach; writable targets enable modification). This defeats
  the intent that the guest is confined to the shared directory.
- Evidence: Code trace above. `op_symlink` (lines 1310-1363): `name` is checked
  with `is_name_legal`, but `symtgt` is passed directly to `symlink(2)` with no
  check that it stays within `m_root_path`. `op_lopen` (line 1187) does
  `open(fidp->path.c_str(), oflags)` with host-default symlink following; `op_walk`
  (lines 2200-2235) uses `lstat` + textual `join_path_name`, so intermediate
  symlink components are resolved by the kernel. No `chroot`, no `openat2`
  RESOLVE_BENEATH, no realpath-prefix check anywhere in the 9p ops. (I could not
  run the Linux-guest end-to-end PoC because command execution was blocked
  mid-session; the escape follows directly from standard POSIX symlink
  resolution semantics applied to these unguarded host calls.)
- Possible solution: Either (a) document p9fs as trusted-guest-only and refuse
  it for untrusted workloads, or (b) implement a containment model: resolve every
  final host path and reject it if it does not have `m_root_path` as a prefix
  after canonicalization, open with `openat2(..., RESOLVE_BENEATH|RESOLVE_NO_MAGICLINKS)`
  relative to a pinned root fd, and/or reject absolute/`..`-containing symlink
  targets (as QEMU's "mapped" security model does). At minimum validate `symtgt`
  in `op_symlink`.
- Severity: Medium — serious host-security boundary break (arbitrary host file
  access by an untrusted guest), but limited to the unreproducible/dev VirtIO 9p
  scenario and is the well-known "9p passthrough" caveat; may be an accepted
  design limitation (no mitigation or warning is present in code or docs, which
  is itself the concern). Not a factor for on-chain/verifiable machines.
- Risks if unfixed: host information disclosure / tampering for operators who
  expose p9fs to untrusted guests. Fix risk: a containment model changes 9p
  behavior for legitimate symlinks that point outside the share (they would stop
  resolving); acceptable and expected for an untrusted-guest mode.

---

### Additional observations (Low / not independently reported)
- `op_version` (`virtio-p9fs-address-range.cpp:2110`, line 2121): reads the
  guest-negotiated `msize` but never uses it — it sets
  `m_msize = min(m_msize, P9_MAX_MSIZE)` (a no-op, `m_msize` is already
  `P9_MAX_MSIZE`), instead of `m_msize = min(msize, P9_MAX_MSIZE)`. Effect: the
  device ignores a smaller msize the driver requested and keeps the maximum. Not
  memory-unsafe (all replies still go through the bounded `write_desc_mem`), so
  Low; noted for correctness.
- `op_getlock`/`op_lock` reply pack `&client_id` where `client_id` is
  `char[P9_NAME_MAX]`; the matching `write_value` overload writes the full
  fixed-size 256-byte buffer rather than a length-prefixed string. The buffer is
  zero-initialized and bounded by `write_desc_mem`, so it is not memory-unsafe,
  but it is a protocol-encoding inconsistency (read side uses a u16-length
  string). Low.

### Areas checked and found SOLID (no bug)
- HTIF (`htif-address-range.cpp`): read/write accept only 8-byte aligned access
  to the 5 defined CSRs; `ihalt/iconsole/iyield` are read-only (writes fault);
  tohost dispatch logs the write first then handles halt/console/yield; unknown
  devices are silently ignored consistently. iflags Y/X set and fromhost acks
  match the yield/console protocol. No width/misalignment divergence between
  interpret and uarch (same code).
- CLINT (`clint-address-range.cpp`): msip is 4-byte, mtime/mtimecmp 8-byte;
  partial/other widths fault; writing mtimecmp clears MTIP and
  `set_rtc_interrupt` re-raises it deterministically on RTC ticks.
- PLIC (`plic-address-range.cpp`): claim/complete, pending masking by
  girqsrvd, and mip updates are bounded (`val` checked `1..31` before shifts;
  `ilog2` only on non-zero). Interrupts are host-sourced only via VirtIO, i.e.
  only in unreproducible mode.
- CMIO: `machine::receive_cmio_request` validates `available_length <=
  AR_CMIO_TX_BUFFER_LENGTH` (no OOB read) and `<= data.size()`;
  `send_cmio_response` no-ops on not-yielded / wrong-reason / oversized data /
  rounds `dataLength` up to a power-of-two ≤ rx-buffer log2 size;
  `write_memory_with_padding` zero-pads only up to the rounded `write_length` and
  does so **identically** across `state_access`, `record_send_cmio_state_access`,
  and `replay_send_cmio_state_access` (verified line-by-line) — so send/log/verify
  agree and the root hash is consistent.
- Machine console (`machine-console.cpp`): `read_output`/`write_input` clamp with
  `min(size, max_length)`; `append_input`/`append_output` truncate to available
  space; virtio-console caps guest chunks at 4096. Bounded.
- virtio-net packet buffers: `packet_len` underflow in
  `do_net_write_packet_to_host` is caught by the `> VIRTIO_NET_ETHERNET_MAX_LENGTH`
  check before the read; `slirp_packet.buf` is exactly `VIRTIO_NET_ETHERNET_MAX_LENGTH`
  and `packet_len <= MAX` is enforced. Safe (apart from the shared devices-1 DoS).
