# Angle: virtio-robust

Scope: host memory-safety review of the VirtIO message-parsing / buffer handling in
`src/virtio-p9fs-address-range.cpp`, `src/virtio-serializer.hpp`, and
`src/virtio-net-*.cpp` (plus the shared descriptor plumbing in
`src/virtio-address-range.cpp`), reachable from an untrusted guest driving the VirtIO
MMIO queues. Known items CM-13 (descriptor-chain loop) and CM-14 (symlink containment)
were treated as out of scope and skipped.

## Headline result

I did **not** find a provable host out-of-bounds read/write, integer-overflow-driven
OOB, or unchecked-string-length overflow in these files. The parsing path is
consistently bounds-checked (details and the negative evidence are in the REJECTED
section). The audit did surface three genuine defects, all **correctness / protocol**
bugs rather than host memory-safety, and all confined to the VirtIO 9P feature, which is
available only in unreproducible machines (`iunrep != 0`) and never participates in
reproducible execution or on-chain hashes. The most concrete is a serializer
reply-encoding bug (`op_getlock`).

Environment limitation (important): after I had written the reproducer, this session's
sandbox began refusing **all** compile/run commands (a session-wide safety classifier,
not specific to the commands). I could therefore not execute the ASan harness here. The
reproducer under `work/virtio-robust/` is complete and self-checking; it must be run from
an unrestricted shell (`sh work/virtio-robust/run.sh`). The findings below are derived
from source and C++ overload analysis; runtime status is marked accordingly.

---

### virtio-robust-1: `op_getlock` encodes the reply `client_id` as 256 raw bytes, not a 9P string
- Status: UNPROVEN at runtime (sandbox blocked execution); PROVEN by source + C++ overload
  analysis. Self-checking reproducer provided.
- Area: devices (VirtIO 9P) / serializer
- Category: input-validation / protocol-encoding (NOT host memory-safety)
- Where: `src/virtio-serializer.hpp:170-173` (`write_value(const char pval[N])`) combined
  with `src/virtio-p9fs-address-range.cpp:1800` (`out_msg.pack(..., &client_id)`),
  `client_id` declared `char client_id[P9_NAME_MAX]` at `:1772`.
- Problem: The serializer's only string overload for a `char` array,
  `template <int N> bool write_value(const char pval[N])`, has a parameter that (per the
  C++ array-to-pointer parameter adjustment) is really `const char *`. `N` then appears in
  no deducible position, so template argument deduction can never select this overload.
  `op_getlock` is the one call site that packs an array **by address**:
  `out_msg.pack(&lock_type, &lock_start, &lock_length, &proc_id, &client_id)`. The argument
  `&client_id` has type `char (*)[256]`, which does not convert to `const char *` (so the
  non-template `write_value(const char*)` string overload at `:166` is not viable), and the
  dead `write_value(const char[N])` template is not viable either. Overload resolution
  therefore binds the generic `template <typename T> write_value(const T *pval)` at `:154`
  with `T = char[256]`, which writes `sizeof(char[256]) = 256` **raw** bytes
  (`src/virtio-serializer.hpp:157`) with no 2-byte length prefix. The emitted Rgetlock
  reply's trailing `client[s]` field is thus 256 raw bytes instead of `len[2] + len bytes`,
  and the reply `size` is correspondingly wrong (7+1+8+8+4+256 = 284 instead of
  7+1+8+8+4+2+len). Contrast the read side, whose analogous template
  `read_value(char (*pval)[N])` (`:71-74`) keeps the pointer-to-array parameter, so `N` is
  deducible and strings are parsed correctly — the write side lost that.
- Why it is NOT host memory-safety: `client_id` is a fully value-initialized 256-byte
  buffer and exactly 256 bytes are read from it, so the host read is in bounds; the write
  goes through `write_desc_mem`, which is bounded (see REJECTED-A). The damage is a
  malformed reply handed to the guest, not host memory corruption.
- Scenario: A guest mounts the 9P share (`--virtio-9p` / `{"type":"p9fs"}`) and performs a
  POSIX `F_GETLK` on a file (Linux v9fs issues `Tgetlock`). The server's `Rgetlock` reply is
  malformed (wrong field encoding and wrong `size`), desynchronising the guest's 9P reply
  parse for that request. Dev-only feature; no on-chain/financial impact.
- Evidence: `work/virtio-robust/` (`run.sh`, `driver.c`, `harness.c`, `crt.S`). The
  bare-metal guest sends `Tgetlock` with `client_id` declared length 200 / 200 'c' bytes and
  then inspects the `Rgetlock` reply on the wire: the client field begins at reply offset 28
  — `0xC8,0x00` (length-prefixed 200) means fixed, `0x63` ('c', i.e. raw bytes) with
  `size >= 284` means the defect is present, in which case the guest HTIF-halts with code 55
  and the harness prints `BUG REPRODUCED: op_getlock encodes client_id as 256 raw bytes ...`
  and exits 1. Run: `sh work/virtio-robust/run.sh` (needs an unrestricted shell;
  uses the ASan libcartesi at `scratchpad/asan/src`).
- Possible solution: fix the serializer so the string-array case is reachable, e.g. make the
  overload take a pointer-to-array like the reader does:
  `template <int N> bool write_value(const char (*pval)[N]) { return write_u16_string(&(*pval)[0], strnlen(&(*pval)[0], N)); }`
  (or change `op_getlock` to pass `client_id` by decay, like `op_version` does with its
  version literal). After the fix the reproducer halts 0 / prints `OK`.
- Severity: Low (malformed reply in a dev-only, unreproducible feature; no host memory
  corruption, no hash/proof impact).
- Risks if unfixed: guest-side 9P `getlock` misbehaves on the share. Fix risk: none for
  reproducible execution (VirtIO absent there); changes only the 9P wire bytes of `Rgetlock`.

---

### virtio-robust-2: `op_version` ignores the guest-requested `msize`
- Status: UNPROVEN (latent/benign today); flagged by source review.
- Area: devices (VirtIO 9P)
- Category: correctness (NOT memory-safety)
- Where: `src/virtio-p9fs-address-range.cpp:2110-2129`, specifically `:2113-2121`.
- Problem: `op_version` parses the client's `msize` into a local `uint32_t msize`
  (`:2113`, read at `:2114`) but then computes
  `m_msize = std::min<uint32_t>(m_msize, P9_MAX_MSIZE)` at `:2121`, using the **member**
  `m_msize` instead of the parsed local `msize`. Since `m_msize` is initialised to
  `P9_MAX_MSIZE` in the constructor (`:977`) and reset to it in `do_on_device_reset`
  (`:1005`), the negotiated `msize` is always `P9_MAX_MSIZE` regardless of what the client
  requested; the parsed `msize` is dead.
- Memory-safety angle (REJECTED): one might expect `get_iounit()` (`...hpp:452-454`,
  `m_msize - P9_IOUNIT_HEADER_SIZE`) to underflow for a tiny `msize`. It cannot, precisely
  because this bug keeps `m_msize` pinned at `P9_MAX_MSIZE` (8216), so
  `get_iounit() = min(8216-24, 8192) = 8192` always. The naive "fix"
  (`m_msize = std::min(msize, P9_MAX_MSIZE)`) would REINTRODUCE a `get_iounit()` underflow
  for a guest sending `msize < 24`; a correct fix must also floor `msize`
  (e.g. `m_msize = clamp(msize, P9_IOUNIT_HEADER_SIZE+1, P9_MAX_MSIZE)`).
- Scenario: Linux v9fs takes `min(requested, returned)`, so an over-large returned `msize`
  is harmless in practice; impact is a spec deviation only.
- Severity: Low.

---

### virtio-robust-3: `op_readdir` `first_entry` is always false (first-entry errors swallowed)
- Status: UNPROVEN; flagged by source review.
- Area: devices (VirtIO 9P)
- Category: correctness (NOT memory-safety)
- Where: `src/virtio-p9fs-address-range.cpp:1845`.
- Problem: `const bool first_entry = (msg.offset == start_offset);` compares the **input**
  unserializer's cursor `msg.offset` against `start_offset`, a constant used to initialise
  the **output** serializer (`:1835`). `msg.offset` has already advanced past the request
  header+args (to 23) and never equals `start_offset` (11), so `first_entry` is permanently
  false. The flag is meant to distinguish "error on the very first directory entry" (which
  should be reported, `:1850-1852`, `:1866-1868`, `:1895-1897`) from "stop after partial
  results". With it stuck false, a `readdir`/`telldir`/`lstat` failure on the first entry is
  silently turned into an empty (EOF) reply instead of an error. The intended expression is
  almost certainly `out_msg.offset == start_offset`.
- Why not memory-safety: all reply writes still go through the bounded `out_msg.pack`; only
  error reporting is affected.
- Scenario: a transient I/O error while listing a shared directory makes the guest see the
  directory as empty rather than getting an error.
- Severity: Low.

---

## REJECTED memory-safety candidates (negative evidence for the angle)

- REJECTED-A — descriptor read/write are bounded; a bad `desc.paddr` cannot OOB the host.
  `virtq::read_desc_mem`/`write_desc_mem` (`src/virtio-address-range.cpp:191-283`) compute
  `data_off + chunk_len = chunk_end_off - start_off <= len`, so copies stay within the
  caller's `len`-byte buffer. The only raw accesses are
  `a->read_memory(desc.paddr+off, ...)` / `a->write_memory(...)`. `machine::read_memory`
  (`src/machine.cpp:1661`) treats any gap / out-of-range guest paddr as **pristine zeros**
  (never a host OOB), and `machine::write_memory` (`:1714`) calls `m_ars.find(paddr,length)`
  and throws for device / non-memory / read-only / cross-range targets; the throw is caught
  in `state_access::do_write_memory` (`src/state-access.hpp:435-444`) → `write_desc_mem`
  returns false → `notify_device_needs_reset`. Huge/overflowing `desc.len` only makes the
  walker claim a large buffer or wrap `buf_start_off`, which leads to a graceful early
  return or `false`, not an OOB.

- REJECTED-B — `read_u16_string` null terminator is in bounds.
  `src/virtio-serializer.hpp:76-96`: it reads a `uint16_t len`, then checks
  `len + 1 > data_max_len` (promoted to `int`, no overflow), which permits `len <=
  data_max_len - 1`; it reads `len` bytes into `data[0..len)` and writes `data[len] = 0`
  with `len <= N-1 < N`. All fixed buffers (`char[32]`, `char[128]`, `char[256]=P9_NAME_MAX`,
  `char[4096]=P9_PATH_MAX`) are covered. The crafted-boundary messages in the reproducer
  (version len 31/32/0xFFFF; attach uname 127/128; walk names 255/256) exercise exactly this
  and are expected not to trip ASan.

- REJECTED-C — IO counts are capped before use.
  `op_read` (`:2287-2288`) and `op_write` (`:2322-2323`) reject `count > buf.size()`
  (`P9_IOUNIT_MAX = 8192`) before `pread`/`pwrite`/`read_bytes`/`write_bytes`, so the fixed
  `std::array<uint8_t, P9_IOUNIT_MAX>` host buffers are never overrun. (Note: `op_read`
  writes `count` bytes, not `ret_count`, but `buf` is value-initialised, so this is zero
  padding — not a stale-memory info leak — and is bounded.)

- REJECTED-D — `op_walk` element count and names are bounded.
  `nwname > P9_MAXWELEM (16)` is rejected (`:2185-2187`); each name is read into a fresh
  `char[P9_NAME_MAX]` via the bounded `read_u16_string`; each `wqid` is packed via the
  bounded serializer. No fixed-size table is indexed by a guest value (fids live in a
  `std::unordered_map`), so "fid table bounds" does not apply. Pointer/reference stability
  across `m_fids` inserts is handled correctly (the code nulls `fidp` before `&m_fids[newfid]`
  in `op_walk`, and `unordered_map` keeps element references valid across rehash).

- REJECTED-E — VirtIO net buffers are bounded.
  In `do_net_write_packet_to_host` (tuntap `:141`, slirp `:320`), `packet_len =
  read_avail_len - VIRTIO_NET_ETHERNET_FRAME_OFFSET` can underflow but is immediately caught
  by `packet_len > VIRTIO_NET_ETHERNET_MAX_LENGTH` (drop); the subsequent
  `read_desc_mem(..., packet_len)` fills a `VIRTIO_NET_ETHERNET_MAX_LENGTH`-byte array with
  `packet_len <= MAX`. The receive paths and `slirp_send_packet` (`:89-121`, `memcpy` guarded
  by `len > MAX`) are likewise bounded by the 2048-byte frame buffer.

## Reproducer
`work/virtio-robust/{run.sh,driver.c,harness.c,crt.S}`. The bare-metal guest brings up the
9P device, runs the init handshake, and sends 19 crafted single T-messages (string-length
boundaries, huge/boundary counts, over-limit walk count, truncated message, Tgetlock)
against the ASan+UBSan libcartesi. Oracles: (1) ASan/UBSan abort ⇒ host memory-safety defect
(none expected — see REJECTED); (2) wire inspection of the `Rgetlock` reply ⇒ virtio-robust-1
(expected to fire: exit 1, `BUG REPRODUCED`). NOT executed in this session (sandbox blocked
builds); run from an unrestricted shell.
