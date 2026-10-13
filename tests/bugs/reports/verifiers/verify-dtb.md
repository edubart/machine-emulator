# verify-dtb: independent verification report

`<SCRATCH>` = `<SCRATCH>`
`<V>` = `<SCRATCH>/verify/verify-dtb`

| id | verdict | severity (mine) | hunter's rating |
|---|---|---|---|
| DTB-CONFIG-1 | CONFIRMED. Fix validated on a real patched `libcartesi.so`. No other locale-sensitive formatting on hashed or persisted paths. | Medium (low end) | Medium |

---

### DTB-CONFIG-1: The DTB unit addresses, the `/aliases` targets and the stored-machine file names follow the host process's C++ global locale

- **Verdict: CONFIRMED.**

#### Reproducers

1. **Hunter's PoC.** I re-ran it unchanged from a clean copy in `<V>/hunter/` (`./run.sh`, rc=1). Every claim in
   the write-up reproduces.
   - Under en_US the local root hash is `fd248585…` while the JSON-RPC server returns `623baeb6…`.
   - The DTB contains `clint@2,000,000` and `/pmem@80,100,000`.
   - A directory stored under en_US cannot be loaded by a classic-locale process.
   - de_DE gives a third hash (`5b485cd7…`). `setlocale(LC_ALL,"")` on its own has no effect.

   One cosmetic problem: `run.sh` uses `tee /dev/stderr`. When stdout and stderr both go to the same file
   (`./run.sh > f 2>&1`), this reopens and truncates the file, so only the tail of the output is left. Running
   `./run.sh 2>&1 | cat` shows the full output. This does not affect the result.

2. **My independent reproducer: `<V>/run.sh`** (source `<V>/repro.cpp`, about 3 s, exit 1 + `BUG REPRODUCED`).
   `LIBDIR=<dir> ./run.sh` runs the same test against another build. It differs from the hunter's PoC in several ways:
   - It needs no system locale data. The "grouping" locale is `std::locale(classic, new numpunct{grouping "\3", sep ','})`.
   - It runs in one process and toggles the C++ global locale between `cm_create_new` calls.
   - It decodes the DTB by walking the FDT structure block, not by substring search. It checks every unit address
     and every `/aliases` target against `[0-9a-f]+`.
   - It checks store/load in both directions.
   - It includes real named-locale controls. The script compiles `C.UTF-8`, `en_US.UTF-8` and `de_DE.UTF-8` into
     `<V>/locales` with `localedef` and passes them through `LOCPATH`.

   Output on the release build (`<V>/out_release.txt`):
   ```
   [1] classic global locale        root hash 820e9b84de622f43...  invalid unit addresses: 0
   [2] grouping global locale       root hash f790c1531f4c009b...  invalid unit addresses: 15
       node  clint@2000000          -> clint@2,000,000
       node  htif@40008000          -> htif@40,008,000
       node  memory@80000000        -> memory@80,000,000
       node  pmem@80020000          -> pmem@80,020,000
       node  uio@80040000           -> uio@80,040,000
       node  rx_buffer@60000000     -> rx_buffer@60,000,000          (plic, fw_resv, tx_buffer, 2nd pmem likewise)
       alias inputs=/pmem@80020000  -> inputs=/pmem@80,020,000       (flashdrive0/1, nvram0, state likewise)
       --> same config, same process, different template root hash
   [3] files stored under grouping: 0000000000000000-8,000.bin, 000000000010,000-1,000.bin, ...
       load grouping-stored dir under classic : unable to open backing file '.../0000000000000000-8000.bin': No such file or directory when initializing shadow state
       load classic-stored dir under grouping : unable to open backing file '.../0000000000000000-8,000.bin': No such file or directory ...
       load grouping-stored dir under grouping: ok f790c1531f4c009b...
   [4] std::locale::global("C.UTF-8")       root hash 820e9b84...  (= classic)
   [4] std::locale::global("en_US.UTF-8")   root hash f790c153...  (DIFFERS, e.g. node "clint@2,000,000")
   [4] std::locale::global("de_DE.UTF-8")   root hash 6c59d3a9...  (DIFFERS, e.g. node "clint@2.000.000")
   BUG REPRODUCED: ...
   ```
   The synthetic facet gives exactly the en_US.UTF-8 hash. `C.UTF-8` (the usual container locale) does not trigger
   the defect, because its LC_NUMERIC has `grouping -1`.

3. **Execution divergence, Linux boot to halt** (`<V>/fixcheck.sh`, part 2; `tests/build/images`, 64 MiB RAM,
   rootfs plus a labelled data drive, entrypoint `cat /proc/device-tree/aliases/data`):
   ```
   rel lib, C           guest alias /pmem@c0000000     mcycle=57849418 final=700b53de...
   rel lib, en_US.UTF-8 guest alias /pmem@c0,000,000   mcycle=57939550 final=c1101e24...
   ```
   The guest boots normally in both cases, so the divergence is silent.

#### Root cause

A default-constructed `std::ostringstream` is imbued with a copy of the C++ global locale. libstdc++'s
`num_put::_M_insert_int` applies `numpunct::grouping()` in every base, including `std::hex`. `<V>/libcxx/g.cpp`
shows `clint@2,000,000` and `00000080,000,000`, and that `std::to_string` is unaffected. I could not run libc++
here. Its `__widen_and_group_int` also groups hex digits (it skips only a `0x` prefix), so macOS/Clang hosts very
likely behave the same, but I have not verified that.

The affected sites:
- `src/fdt-builder.hpp:131-134` `FDTBuilder::begin_node_num`: `ss << name << "@" << std::hex << n`. This covers
  every node with a unit address: `clint`, `plic`, `htif`, `virtio`, `memory`, `fw_resv`, `pmem`, `uio`,
  `rx_buffer` and `tx_buffer`. `cpu@0` is unaffected because it has a single digit.
- `src/dtb.cpp:209-210` and `:219-220` (`dtb_init`): the alias targets `/pmem@…` and `/uio@…`.
- `src/machine-config.cpp:40-41`, `:46-47` and `:52-53`: `get_data_filename`, `get_dht_filename` and
  `get_dpt_filename`. `machine::store` (`src/machine.cpp:421-423`) and `machine_config::load` →
  `adjust_backing_stores` → `adjust_ar_backing_store_config` (`src/machine-config.cpp:88-90`, called from `:159`)
  both use these names. Each one is computed with the locale that is current at that moment.

The DTB is written into the hashed DTB range (0x7ff00000) at creation, so the template root hash depends on the
host locale. `cm_jsonrpc_spawn_server` starts the server with `posix_spawnp` (`src/jsonrpc-machine.cpp:485`), so
the server always starts with the classic C++ locale. That is why an affected host disagrees even with a server it
spawned itself. Nothing in `doc/`, the CHANGELOG or the tests mentions locales, so this is not intended behaviour.

#### Audit of other formatting on hashed or persisted paths (task item)

I grepped `src/` for `ostringstream`/`stringstream`, `std::hex`/`std::dec`/`setw`, `imbue`/`locale`,
`std::to_string`, `printf`-family calls, `strto*`/`std::sto*`, `strftime` and `operator<<`. The three sites
above are the only ones that are both locale-sensitive and on a hashed or persisted path. The others:

| site | locale-sensitive? | on hashed/persisted path? | verdict |
|---|---|---|---|
| `dtb.cpp:211,221` `"flashdrive"/"nvram" + std::to_string(i)` | no (`to_string` ≡ `%d`, never grouped; libstdc++ uses `__to_chars_10_impl`; i ≤ 7 anyway) | DTB | safe |
| `dtb.cpp:45` `misa_to_isa_string` | no (characters only) | DTB | safe |
| `fdt-builder.hpp:71,102` `dt_strings` stream | no (strings only) | DTB | safe |
| `machine.cpp:1948-1962`, `replay-send-cmio-state-access.hpp:140-199`, `uarch-replay-state-access.hpp:171` | yes (would group hex in messages) | exception text only | cosmetic only |
| `jsonrpc-machine.cpp:451`, `jsonrpc-remote-machine.cpp:809` `ss << endpoint` | no: Boost.Asio `endpoint::to_string()` imbues `std::locale::classic()` (`boost/asio/ip/detail/impl/endpoint.ipp:183`) | spawn/fork addresses | safe (the hunter's PoC spawns and talks to a server under en_US without problems) |
| `jsonrpc-machine.cpp:479` `snprintf("--server-fd=%d")` | no (C printf, no `'` flag) | spawn argv | safe |
| `jsonrpc-machine.cpp:132,440`, `jsonrpc-remote-machine.cpp:798` `std::stoi(port)` | no grouping is accepted by `strtol` | address parsing | safe |
| `jsonrpc-remote-machine.cpp:116` `strftime` | uses the local time zone | server log prefix only | safe |
| `os-filesystem.cpp:93,109` | strings only | error text | safe |
| `hash-tree*.cpp`, `page-hash-tree-cache.hpp`, virtio/plic `fprintf` | — | debug stderr | safe |
| `config.json` via nlohmann `dump()`/`parse()` | no (custom integer and Grisu writers; the parser adjusts the decimal point with `localeconv`) | persisted config | safe |
| CLI `src/cartesi-machine.lua` | `string.format`/`tostring` use C printf without `'`. `lua.c` never calls `setlocale` | CLI-built config | safe |

I also checked this empirically. With the three sites patched, the en_US C++ global locale gives byte-identical
results everywhere I measured: the template root hash, stored file names, cross-locale loads, and a full Linux boot
to halt (same mcycle and final hash). So no other locale dependency shows up during creation, store, load or
execution.

#### Who is realistically affected

The defect needs both of the following:
- (a) The process that hosts `libcartesi` in-process (C API or the `cartesi.so` Lua module) calls
  `std::locale::global(...)` with a named locale.
- (b) That locale groups digits. This is true of en_US, de_DE and most real locales, but not of C, POSIX or C.UTF-8.

Hosts that are **not affected**:
- The `cartesi-machine` CLI, which is Lua (standalone `lua5.4` never touches the C++ locale).
- `cartesi-jsonrpc-machine`, which is C++ but never sets a locale.
- Every remote (JSON-RPC) machine, whatever the client.
- Go hosts such as the Rollups Node, Rust hosts such as the PRT/Dave tooling, Python, Node and C hosts. A C-only
  `setlocale` does not change the C++ global locale. The hunter verified this and I agree.

Hosts that **are affected**: custom C++ hosts or tools that adopt the user locale. Examples are the common
`std::locale::global(std::locale(""))` idiom, Boost.Locale's documented `std::locale::global(gen(""))`, and,
according to its documentation, glibmm's `Glib::init()` by default. I did not test the frameworks here. These hosts
must also run on a machine whose LANG/LC_ALL/LC_NUMERIC names a grouping locale, which is typical of developer
desktops. Minimal Docker images usually ship only C/C.UTF-8, and there `std::locale("")` either stays classic or
throws.

I know of no first-party or known downstream host that meets (a).

#### Severity: **Medium (low end)**. I agree with the hunter, with a narrower scope.

- Why Medium and not Low:
  - The same config silently produces a different template root hash. There is no error, the guest boots normally,
    and every later state differs.
  - A long-running C++ host that switches locale after start-up writes snapshots that it, and everyone else, cannot
    load later. My reproducer shows this in one process.
  - In the same process, a local machine and a JSON-RPC machine disagree.
  - This breaks the guarantee that the hash depends only on the config, which PRT and template reproducibility rely on.
- Why not High or Critical:
  - No attacker or guest can trigger it. It depends on the operator's own host code and environment.
  - No current first-party or known downstream host is affected.
  - On the node side the failure is mostly loud. An affected host that loads a canonical template or snapshot fails
    with "unable to open backing file" because the file names differ. It does not silently compute a different
    state. The silent part is limited to creating a machine from a config inside an affected host (template-building
    or verification tooling).
  - It cannot make an invalid transition provable, and the on-chain step verifier is not involved.

#### Fix assessment

The proposed fix (`<SCRATCH>/work/dtb-config/fix/fix.patch`, `imbue(std::locale::classic())` on the 3 streams) is
**correct and complete for the hashed and persisted paths**.

I validated it on a **real relinked `libcartesi.so`**, whereas the hunter validated only a harness:
`<V>/fixcheck.sh` copies the release tree, applies the patch, rebuilds `dtb.o` and `machine-config.o`, relinks, and
then runs my reproducer plus the Linux boot comparison. It prints `FIX VALIDATED` with rc=0
(`<V>/out_fixcheck.txt`):
```
[2] grouping global locale       root hash 820e9b84...  invalid unit addresses: 0
    load grouping-stored dir under classic : ok 820e9b84...   (and vice versa)
[4] std::locale::global("en_US.UTF-8")   root hash 820e9b84...  (= classic)
fix lib, en_US.UTF-8 guest alias /pmem@c0000000     mcycle=57849418 final=700b53de...   (= release lib, classic)
FIX VALIDATED
```

- **Compatibility:** for classic-locale hosts (all current tools), the DTB, root hashes and file names stay
  byte-identical. The template hash is `820e9b84…` with both libraries, and the Linux final hash `700b53de…` matches
  too. Existing templates and the on-chain step verifier are unaffected.
- **Migration note:** directories that an affected host stored before the fix have grouped file names. The patched
  library will not load them until the files are renamed to the canonical names. Their DTB contents remain
  non-canonical, so their root hashes remain different from the canonical template.
- **Alternatives and hardening:**
  - `std::format("{}@{:x}", …)` or `std::to_chars` are also locale-independent, provided the `L` specifier is not
    used.
  - Add a regression test in `tests/misc` that sets a synthetic grouping `numpunct` facet as the global locale and
    compares the root hash and the `store`/`load` round trip. This is the technique in `repro.cpp` and needs no
    locale data on CI.
  - Optionally assert in `dtb_init` that unit addresses match `[0-9a-f]+`.

#### Files
- `<V>/run.sh`, `<V>/repro.cpp`: independent reproducer (exit 1 = bug present, 0 = fixed). `<V>/out_release.txt`
  holds the release output.
- `<V>/fixcheck.sh`: real-library fix validation plus the Linux boot comparison. `<V>/out_fixcheck.txt` and
  `<V>/out_fixed.txt` hold its output. `<V>/fixbuild/src/libcartesi.so` is the patched library, kept with its
  objects deleted.
- `<V>/hunter/`: a clean copy of the hunter's PoC and `fix/`, re-run unchanged (both `run.sh` → rc=1 and
  `fix/fix.sh` → `FIX VALIDATED`).
- `<V>/libcxx/g.cpp`: a 10-line demonstration that libstdc++ groups `std::hex` output and that `std::to_string` does
  not group.
