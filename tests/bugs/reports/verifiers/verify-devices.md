# Independent verification — angle `devices` (verifier: verify-devices)

Environment note: partway through this verification the session's Bash tool began
refusing ALL command execution via a safety classifier unrelated to the actions
themselves (the same block the hunter reported). Before that happened I executed
the devices-1 reproducer (and a control), and the devices-2 stock-Linux-client
test, with real output captured below. The devices-2 raw-9p reproducer was
written and verified line-by-line against the source wire format but could not be
executed after the block engaged. All code-trace facts were re-derived by me from
the source with read-only tools.

---

### devices-1: VirtIO virtqueue descriptor-chain traversal has no cycle/length bound → guest-triggerable infinite loop (host hang / DoS)
- Verdict: CONFIRMED (independently reproduced and executed by me).
- Independent reproducer: `verify/verify-devices/devices-1/run.sh`
  - Independent of the hunter in two ways: targets the **virtio-console** device
    (device id 3), not p9fs; and uses a **two-node cycle** `desc[0].next=1 ->
    desc[1].next=0` (both read-only), not a self-loop.
  - Actual output (executed):
    ```
    [child] running cm_run(UINT64_MAX)...
    BUG REPRODUCED: emulator hung >8s inside virtio queue processing (cyclic
    descriptor chain, no cycle/length bound in virtq::get_desc_rw_avail_len)
    FINAL_EXIT=1
    ```
  - Control (terminating single descriptor, no F_NEXT) executed to prove the hang
    is caused specifically by the cycle and not a broken handshake:
    ```
    [child] cm_run returned: break=1 exit_code=0
    NO HANG: cm_run returned normally (bug appears fixed)
    CONTROL_EXIT=0
    ```
    The control also demonstrates exactly how a fixed/bounded walker would behave
    (returns from `cm_run`, guest HTIF-halts), i.e. my harness correctly
    distinguishes "hang" from "no hang".
- Root cause (my words):
  `src/virtio-address-range.cpp:157` `virtq::get_desc_rw_avail_len()` walks the
  descriptor chain in `while (true)` and advances `desc_idx = desc.next`
  (line 180) with **no visited-set, no iteration counter, and no cap at
  `vq.num`**. The only loop exits are a failed guest-memory read in
  `virtq_get_desc()` (line 74 — never fails for an in-RAM descriptor table) or a
  descriptor without `VIRTQ_DESC_F_NEXT`. A cyclic chain of read-only (or of
  write-only) descriptors therefore loops forever. The same unbounded pattern is
  in `read_desc_mem()` (line 200) and `write_desc_mem()` (line 247).
  `get_desc_rw_avail_len` is called from `on_device_queue_notify()` (line 490)
  for **every** VirtIO device before any device-specific handling, so every
  virtio device (console, 9p, net) is affected. The MMIO `QUEUE_NOTIFY` handler
  (line 726) calls this synchronously inside the interpreter's MMIO-write path,
  so the whole `cm_run` thread spins at 100% CPU and never returns.
  - Confirmed sub-findings (same locus, input validation):
    * `is_power_of_2(0)` returns `true` (`(0 & (0u-1)) == 0`), and the
      `VIRTIO_MMIO_QUEUE_NUM` handler (line 716) accepts `val==0`
      (`0 <= VIRTIO_QUEUE_NUM_MAX && is_power_of_2(0)`). So `vq.num == 0` is
      accepted, making `vq.num - 1 == 0xFFFFFFFF` and the index mask
      `desc_idx & (vq.num-1)` (lines 62/69/75) a no-op. The VirtIO spec requires
      QueueNum to be a nonzero power of two; accepting 0 is a real validation
      gap. (My PoC does not rely on this — it uses QUEUE_NUM=128 — but I
      confirmed the claim from code.)
    * `VIRTIO_MMIO_QUEUE_READY` (line 720) sets `ready` without requiring a valid
      `num`, and `on_device_queue_notify` never checks `vq.num != 0`.
- Severity (my rating): **Medium**. Guest-reachable total hang of the host
  emulator process, trivially triggered (even by a merely buggy driver). But it
  requires unreproducible mode (VirtIO is rejected otherwise —
  `machine-address-ranges.cpp:539-540`, "virtio devices are only supported in
  unreproducible machines") and virtio, which `doc/README.md` and the CLI
  (`cartesi-machine.lua` help: "NON REPRODUCIBLE OPTION, DON'T USE THIS OPTION IN
  PRODUCTION") document as a development-only feature that gives up state-hash
  verifiability. Not reachable in on-chain/fraud-proof machines, so no PRT/
  proof-soundness impact. I concur with the hunter's Medium.
- Risks / Fix assessment: Unfixed, one malicious or buggy guest hangs the
  emulator indefinitely (100% CPU, unresponsive, cannot be stepped/hashed/shut
  down normally) — a DoS for any host multiplexing untrusted dev machines. The
  hunter's proposed fix (bound the walk by descriptor count ≤ `vq.num` in all
  three walkers and abort via `notify_device_needs_reset`; plus reject
  `QUEUE_NUM==0`) is correct and complete. Both halves are needed: a
  "count ≤ num" bound with `num==0` still allowed would reject every chain. Fix
  risk is minimal and does **not** change any root hash (VirtIO is absent from
  reproducible machines) — it only rejects malformed/cyclic chains a conforming
  driver never produces.

---

### devices-2: VirtIO 9P `Tsymlink` target is unrestricted → untrusted guest escapes the shared host directory
- Verdict: CONFIRMED by code trace; executable escape PoC written & wire-verified
  but not executed (Bash classifier block). I DID execute a stock-Linux-client
  test that produced an important realism refinement (below).
- Independent reproducers in `verify/verify-devices/devices-2/`:
  1. `run.sh` — boots the real Linux guest image with a p9fs `--volume` share and
     runs `ln -s <abs host path> /mnt/share/esc; cat /mnt/share/esc`. I executed
     this. Result (after making the share writable for the dapp uid):
     ```
     host view of share after run:
     lrwxrwxrwx 1 1001 1001 140 esc -> /.../devices-2/outside/secret.txt
     ...
     cat: /mnt/share/esc: No such file or directory
     NO ESCAPE
     ```
     Important finding: with the **stock Linux 9p client** (9P2000.L,
     `access=client`), the symlink is resolved **guest-side** via Treadlink, so an
     absolute host-only target resolves against the *guest* root and fails
     (ENOENT). A naive `ln -s /abs/host/path` from a normal guest shell therefore
     does NOT escape. This refines the hunter's write-up, which should not be read
     as "any guest doing `ln -s` escapes".
  2. `run_raw.sh` + `driver.c` — a bare-metal **raw 9P2000.L client** (does not
     use the Linux client, so no guest-side symlink resolution). It performs
     exactly the hunter's sequence over the virtqueue: Tversion → Tattach →
     Tsymlink(name="esc", symtgt=`<abs host path outside share>`) → Twalk(["esc"])
     → Tlopen(flags=O_RDONLY) → Tread, then copies the returned bytes to a known
     guest address for the harness to read back and match the marker. I verified
     every request/reply layout against `virtio-serializer.hpp` and each `op_*` in
     `virtio-p9fs-address-range.cpp`. It was **not executed** (Bash blocked); the
     coordinator can run it in a shell-enabled session. Expected:
     `BUG REPRODUCED: ... marker leaked: MARKER_7f3a9b_HOST_SECRET_redacted`.
  - SAFETY: both PoCs touch only files I create inside the verify dir
    (`outside/secret.txt` with a self-chosen marker, shared via `share/`). No
    system or user file is targeted.
- Root cause (my words):
  The 9p server is a textual host-path passthrough with **no containment at path
  resolution time**:
  * `op_symlink` (`virtio-p9fs-address-range.cpp:1310`): `name` is checked by
    `is_name_legal()` (line 960: rejects `/`, `.`, `..`, empty) but the target
    `symtgt` (a full `P9_PATH_MAX` guest string) is passed verbatim to
    `symlink(symtgt, "<root>/name")` (line 1335) — a guest can create a symlink
    pointing anywhere on the host.
  * `op_lopen` (line 1187): `open(fidp->path, oflags)` where `oflags` has
    `O_NOFOLLOW` only if the guest set `P9_O_NOFOLLOW` (line 805) — a malicious
    guest opens read-only (flags=0 → O_RDONLY, no O_NOFOLLOW), so the host kernel
    **follows** the symlink out of the share.
  * `op_walk` (line 2173) resolves components with `lstat` (no follow) and a
    correct `..`-above-root guard (`is_same_stat_ino(&root_st, &st)`, line 2218),
    so purely **textual** `..`/name traversal cannot escape — I confirm the
    hunter's claim that `..` is blocked. But walking *through* an existing symlink
    component (`lstat("<root>/esc/etc/passwd")`) is resolved by the host kernel,
    and `op_lopen` following the final symlink is the simplest path. There is no
    `chroot`, no `openat2(RESOLVE_BENEATH)`, no realpath-prefix check anywhere.
  Deeper point (correcting "validate symtgt is enough"): the real defect is the
  absence of containment during resolution. Even if `op_symlink` validated its
  target, a symlink that the *operator* placed in the shared dir, or one reachable
  via `op_lopen`/`op_walk`, would still be followed out of the share. Tlopen also
  accepts write flags, so this is host file **read and write/truncate/create**,
  not read-only.
  - Tlink/Trenameat: `op_link` (line 1964) and `op_renameat` (line 2054) build
    both sides from fid paths + a legal `name`; since fid paths are confined by
    `op_walk`, and `link(2)`/`renameat` do not follow a final symlink, they are
    not an independent escape vector beyond what a symlinked fid already gives.
    The symlink target is the real hole.
- Severity (my rating): **Medium**. A genuine host-security boundary break
  (arbitrary host file read/write for files the emulator process can reach) by an
  untrusted guest. Downgraded from "High" because: (a) it is confined to the
  documented development-only unreproducible/virtio-9p mode (no on-chain/fraud-
  proof exposure); (b) the practical bar is "untrusted guest running a *custom*
  9p client" — the stock Linux client with plain `ln -s` does not escape, as I
  demonstrated; and (c) it is the well-known 9p-passthrough caveat. It stays at
  Medium (not Low) because an untrusted guest can trivially ship a raw 9p driver,
  and no warning or mitigation exists in code or docs. I concur with the hunter's
  Medium.
- Risks / Fix assessment: Unfixed → host information disclosure and tampering for
  developers who expose p9fs to untrusted guest images. Correct/complete fix:
  containment at resolution time — pin a root dir fd and use
  `openat2(..., RESOLVE_BENEATH|RESOLVE_NO_MAGICLINKS)` (and `O_NOFOLLOW` on the
  final component where symlinks must not be traversed) for all host file ops,
  and/or canonicalize every final path and reject it unless prefixed by
  `m_root_path`. The hunter's "at minimum validate `symtgt` in `op_symlink`" is
  **insufficient** on its own (a pre-existing or otherwise-created symlink would
  still be followed). No root-hash/on-chain compatibility impact (VirtIO absent
  from reproducible machines). Expected side effect: legitimate symlinks pointing
  outside the share stop resolving — acceptable and expected for an
  untrusted-guest sharing mode.

---

### Cross-cutting confirmations
- VirtIO (and thus both findings) is reachable only with `iunrep != 0`
  (unreproducible mode): `machine-address-ranges.cpp:539-540` throws otherwise.
  The CLI auto-sets `iunrep=1` for `--virtio-9p`, `--volume`, `--virtio-net`,
  `--virtio-console` (`cartesi-machine.lua:1318/1325/1338/1397...`), so the
  realistic scenario — a developer running an untrusted machine image with
  `--virtio-*`/`--volume` — does enable these devices. Documented as development-
  only, non-verifiable (`doc/README.md:7262`, README template:2334/4000).
- Neither finding affects reproducible/on-chain machines, PRT fraud proofs, step
  logs, or root hashes.
