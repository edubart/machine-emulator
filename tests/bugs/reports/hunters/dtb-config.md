# Angle: dtb-config (DTB and config-derived state vs host environment and input form)

Scope: `src/dtb.cpp`, `src/fdt-builder.hpp`, `src/machine-config.cpp`, `src/json-util.cpp` (config parse/serialize),
the init paths in `src/machine.cpp` (`init_processor`, `init_pmas_contents`, `init_dtb_contents`, constructor/load),
`src/machine-address-ranges.cpp` (label validation, on-disk create), and the CLI/Lua/JSON-RPC creation paths.
Question asked: does the same logical config always give the same template root hash, whatever the host environment and
input form? Is the DTB content correct for the configured machine?

`<SCRATCH>` = `<SCRATCH>`
PoCs: `<SCRATCH>/work/dtb-config/`

## Summary
| ID | Title | Status | Severity |
|----|-------|--------|----------|
| DTB-CONFIG-1 | The DTB (node unit-addresses, alias targets) and the stored-machine file names are formatted with the host process's C++ global locale. The same config gives a different template root hash and a different execution, and stored directories cannot be loaded across locales | PROVEN (fix validated) | Medium |
| DTB-CONFIG-2 | DT-reserved property names (`name`, `phandle`) accepted as flash/NVRAM labels | REJECTED (no guest impact, see below) | — |

No other input-form or host dependency of the root hash was found. The negative results are listed at the end and can be
re-run with `inputforms.sh`.

---

### DTB-CONFIG-1: The DTB and the stored file names depend on the host's C++ global locale, so the template root hash does too
- Status: PROVEN (on the release build in `src/`; the fix is validated by `fix/fix.sh`)
- Area: DTB / machine config / store-load
- Category: nondeterminism (host-environment dependency of the root hash), divergence (local vs JSON-RPC), data-loss
  (stored machine not loadable)
- Where:
  - `src/fdt-builder.hpp:131-134` `FDTBuilder::begin_node_num`: `std::ostringstream ss; ss << name << "@" << std::hex << n;`
    This builds every unit-address node name: `clint@`, `plic@`, `htif@`, `virtio@`, `memory@`, `fw_resv@`, `pmem@`, `uio@`,
    `rx_buffer@`, `tx_buffer@`, `cpu@`.
  - `src/dtb.cpp:210` and `:220` (`dtb_init`, `/aliases`): `target << "/pmem@" << std::hex << f.start;` and
    `target << "/uio@" << std::hex << n.start;`
  - `src/machine-config.cpp:41,47,53` `get_data_filename` / `get_dht_filename` / `get_dpt_filename`:
    `sout << dir << "/" << std::hex << std::setw(16) << std::setfill('0') << start << "-" << length << ".bin"`
    These names are used by `machine::store` and recomputed by `machine_config::load` → `adjust_backing_stores(dir)`
    (`machine-config.cpp:159`).
- Problem: a default-constructed `std::ostringstream` uses a copy of the C++ global locale (`std::locale()`). libstdc++
  `num_put` applies the locale's digit grouping to integers in every base, including `std::hex`. If the process hosting
  libcartesi has called `std::locale::global(...)` with a locale that groups digits, two things change.
  The guest-visible DTB contents change. With en_US.UTF-8, `clint@2000000` becomes `clint@2,000,000` and
  `/pmem@80100000` becomes `/pmem@80,100,000`. With de_DE.UTF-8 they become `clint@2.000.000` and so on. Many C++
  applications call `std::locale::global(std::locale(""))` to honor LANG/LC_ALL, and libraries such as Boost.Locale
  recommend it. The DTB is part of the hashed state (`init_dtb_contents` → `dtb_init` writes into the DTB range at
  0x7ff00000), so the template root hash changes with no error. `,` and `.` are legal node-name characters, so the guest
  boots normally and the difference goes unnoticed. Every later state differs as well: Linux boots to halt in a
  different number of cycles and with a different final root hash.
  The stored file names change too. `0000000080000000-100000.bin` becomes `00000080,000,000-100,000.bin`. A machine
  stored by such a host cannot be loaded by a normal process, and the reverse also fails ("unable to open backing
  file"), because `load` recomputes the names with the loader's locale.
  The C locale (`setlocale`, `LC_ALL`/`LANG` in the environment) does not matter on its own. The CLI, the Lua
  bindings, plain C hosts and `cartesi-jsonrpc-machine` never set the C++ global locale, so they always produce the
  canonical DTB. That is why a locale-affected host also disagrees with a JSON-RPC server it spawns itself.
- Scenario: a node, deploy tool or test harness written in C++ (or a C++ program that embeds Lua and loads
  `cartesi.so`) calls `std::locale::global(std::locale(""))` and runs where `LANG=en_US.UTF-8` (the default on most Linux
  installs). Four things happen:
  (a) A template built from the dapp's config in that process gets a root hash that nobody else can reproduce from the
  same config. Re-creating the template to check the on-chain template hash fails without explaining why, and if this
  process built the deployed template, the commitment depends on the build host's locale.
  (b) In the same process, `cm_create` on a local machine and on a spawned JSON-RPC machine return different root hashes
  for the same config, and from then on every state hash differs.
  (c) Template or snapshot directories written by that process cannot be loaded by the CLI, by the JSON-RPC server, or
  by any C-locale node, and that process cannot load directories written by them (load failure, DoS).
  (d) The guest sees non-canonical node and alias names (`/proc/device-tree/aliases/<label>` → `/pmem@c0,000,000`).
  An attacker cannot trigger this. It comes from the honest operator's own environment, but it is silent and breaks
  the guarantee that the template hash depends only on the config.
- Evidence: `<SCRATCH>/work/dtb-config/run.sh` (about 2 s; `RUN_LINUX=1 ./run.sh` adds a Linux boot to halt, about 5 s).
  `poc_locale.cpp` is a C++ host that calls `std::locale::global(std::locale(""))` and then creates the same config
  (`c1.json`: 1 MiB RAM, 2 flash drives, 1 NVRAM) locally and through a spawned JSON-RPC server:
  ```
  === 1. control: C++ host, LC_ALL=C (classic locale)
  local  (C API, in this process) root hash: 623baeb66175d44cd03c16c19ce671b5ceeb7cb3211f227ae1505a1dfc0a8b21
  remote (JSON-RPC server)        root hash: 623baeb66175d44cd03c16c19ce671b5ceeb7cb3211f227ae1505a1dfc0a8b21
  === 2. same C++ host, LC_ALL=en_US.UTF-8 (std::locale::global(std::locale("")))
  local  (C API, in this process) root hash: fd24858579fd2e044e31cc47ff0da0373eb55808cfc5e888db755aa90fae963a
  remote (JSON-RPC server)        root hash: 623baeb66175d44cd03c16c19ce671b5ceeb7cb3211f227ae1505a1dfc0a8b21
    local  DTB string: "clint@2,000,000"
    local  DTB string: "memory@80,000,000"
    local  DTB string: "/pmem@80,100,000"
  --> local (in-process) root hash != remote (JSON-RPC server) root hash for the SAME config
  === 3. C API root hash of the same config, by host locale
    classic C++ locale              : 623baeb6...
    C++ global locale en_US.UTF-8   : fd248585...
    C++ global locale de_DE.UTF-8   : 5b485cd7...
    C setlocale(LC_ALL,"") de_DE   : 623baeb6...   (C locale alone has no effect)
  === 4. DTB differences (classic vs en_US)
  <     clint@2000000 {            >     clint@2,000,000 {
  <     plic@40100000 {            >     plic@40,100,000 {
  <   memory@80000000 {            >   memory@80,000,000 {
  <   pmem@80100000 {              >   pmem@80,100,000 {   (aliases likewise)
  === 5. machine stored by the en_US host, loaded by a classic-locale process
  0000000000000000-8,000.bin ...
  ERROR cm_load_new(...) -> -1: unable to open backing file '.../st_locale/0000000000000000-8000.bin': No such file or directory
  === 6. Linux boot to halt, same config (tests/build/images linux.bin + rootfs.ext2), classic vs en_US host locale
  break=1 mcycle=71088368 exit=2   final ed896c421f3a32f8ec8ed4e2491f7236deb6bbbaea5269707c8db1823f5d677f
  break=1 mcycle=71310523 exit=2   final 558666307d0f1bb807f52cba09acb6bd482f38b267bc0873707174e41f993ffc
  BUG REPRODUCED: DTB node names/aliases and stored file names are formatted with the host C++ global locale; ...
  ```
  Locale data is compiled into the work directory with `localedef` and used through `LOCPATH`, so no system change is
  needed (`locales.sh`).
- Possible solution: format with the classic locale on all three streams. Either imbue
  `std::locale::classic()`, or use `std::format("{}@{:x}", name, n)` / `std::to_chars`, which are locale-independent
  unless the `L` specifier is used. The patch is `<SCRATCH>/work/dtb-config/fix/fix.patch` (3 files, +1 line per stream):
  ```cpp
  // fdt-builder.hpp begin_node_num, dtb.cpp alias targets, machine-config.cpp get_*_filename
  std::ostringstream ss;
  ss.imbue(std::locale::classic());
  ss << name << "@" << std::hex << n;
  ```
  Validation: `fix/fix.sh` compiles the original and the patched `dtb.cpp` / `machine-config.cpp` into small harnesses
  and runs them under the en_US.UTF-8 C++ global locale. The original DTB digest is `8133d9df…` under the classic locale
  and `d6b1dfaf…` under en_US. The patched DTB is `8133d9df…` in both cases, the same as today's canonical DTB. The patched
  file name is `dir/0000000080000000-100000.bin` in both cases. The script prints `FIX VALIDATED`.
  As a further guard, `dtb_init` could check that each generated unit address matches `[0-9a-f]+`.
- Severity: Medium. The template root hash, every later state, and the portability of stored machines depend on the
  host environment without any error. Divergence needs a C++ host that sets the global locale. The stock CLI, Lua, the
  JSON-RPC server and C/Go/Rust hosts are not affected.
- Risks: if unfixed, a C++ integrator gets template hashes and snapshots that do not match the rest of the ecosystem and
  cannot tell why. Fix risk is minimal: hosts with the classic locale (all current tools) keep byte-identical DTBs, root
  hashes and file names, so there is no impact on existing templates or the on-chain step verifier. Templates already
  built on an affected host keep their non-canonical DTB, which is consistent with how they were stored.

---

### DTB-CONFIG-2: DT-reserved property names (`name`, `phandle`) accepted as memory-range labels
- Status: REJECTED. `validate_memory_range_label` (`machine-address-ranges.cpp:416`) accepts `name` and `phandle`,
  and these become properties of `/aliases` that have special meaning to Linux's `of_alias_scan`/unflatten. A Linux boot
  with flash drives labelled `name`, `phandle` and `okdrive` showed `/proc/device-tree/aliases/{name,phandle}` resolving
  correctly. The CLI's `$(flashdrive name)` helper mounted all three drives (`/dev/pmem1 on /mnt/name`,
  `/dev/pmem2 on /mnt/phandle`). There is no observable impact, so this is not reported.

---

## Negative results (re-runnable: `<SCRATCH>/work/dtb-config/inputforms.sh` → `ALL EQUAL`, exit 0)
For one config, all of these gave the same root hash:
- **JSON input forms (C API).** Reversed key order at every level, numbers as floats or exponents (`1.048576e6`,
  `4096.0`, `8.192E3`), explicit `-1` (auto) starts and version registers versus omitted ones, and duplicate keys
  (nlohmann keeps the last value, as do the JSON-RPC server and `cartesi.fromjson`). nlohmann objects are `std::map`, so
  key order can never matter. Hex strings for numbers are rejected consistently ("not an unsigned integer") by the C API,
  JSON-RPC and Lua. The JSON-RPC schema declares integers only. The CLI's `util.parse_number` handles hex and decimal
  text safely and rejects decimal values above INT64_MAX.
- **Round trips.** `cm_get_initial_config` → `cm_create`; store(ALL) → load → store → load (`config.json` byte-identical);
  `cm_create` with a directory (on-disk) and then load; CLI `--store-config` in JSON and in Lua → `--load-config`
  (including `init` text with backslashes, tabs and control bytes, since `%q` and hex integers round-trip exactly).
- **Creation paths.** CLI `--initial-hash`, the C API, the Lua bindings (`cartesi.machine`) and JSON-RPC (spawned
  server) agree for the Linux config the CLI builds (rootfs, labelled data drive with mke2fs, NVRAM, entrypoint).
- **C locale and environment.** `LC_ALL`/`LANG` set to de_DE.UTF-8 or en_US.UTF-8 for the CLI, `setlocale(LC_ALL,"")`
  in a C host, and `os.setlocale("")` in Lua with float-valued config fields have no effect. nlohmann parses and dumps
  numbers without depending on the locale, and Lua floats travel as JSON doubles. The library reads no environment
  variables apart from the JSON-RPC log level and the server binary path. The CLI reads `TERM`/`LANG` only for `-i`,
  which forces `iunrep=1`, and `CARTESI_IMAGES_PATH` only selects which default image files are used.
- **Lua table iteration order.** Lua randomizes its hash seed, but it cannot leak into the config. JSON objects are
  sorted, arrays are walked by index, `dump_table` sorts keys, and no CLI `pairs()` loop builds init, bootargs or
  entrypoint text.
- **Flash drive order and labels.** These change the DTB node and alias order and the PMA table, which is intentional
  (pmem numbering follows DT order). `flashdriveN`/`nvramN` aliases always match the CLI's `$(flashdrive flashdriveN)`
  indexing. Label validation runs before `dtb_init` and rejects duplicates, reserved `flashdrive<digits>`/`nvram<digits>`,
  uppercase letters and invalid characters.
- **DTB content checked against the config.** `memory` reg equals the RAM length; `pmem`/`uio` reg and alias targets
  equal the configured start and length; virtio nodes use `AR_FIRST_VIRTIO_START + i*AR_VIRTIO_LENGTH` and PLIC irq
  `i+1`, which matches `push_back_virtio`; the `yield` node follows `htif.iyield`; `riscv,isa` comes from `misa`. The
  `rv64acdfimsu` string is non-canonical but is the same as upstream and is accepted by Linux. The DTB is generated only
  when `dtb.backing_store.newly_created()`. A stored or loaded DTB is never regenerated, and generation is consistent
  between in-memory and on-disk creation.
- **`init_processor` coverage.** Every `registers_state` field that `to_json` serializes is written to the shadow,
  except `x0` and `mvendorid`/`marchid`/`mimpid`. Those cannot be written and are validated. Nothing derived from the
  config is left out of the hashed state.
- **DTB builder under ASan/UBSan** (`dtb_edge.lua` against `<SCRATCH>/asan`). `init` from 0 bytes up to the 1 MiB limit
  (clean "not enough space to store FDT" error), bootargs of 4095, 4096 and 4097 bytes (the limit is enforced), 8 flash
  plus 8 NVRAM drives with 31-character labels, a 9th drive (rejected), and embedded NULs in bootargs, init and
  entrypoint. No sanitizer reports.

## Files
- `<SCRATCH>/work/dtb-config/run.sh` is the DTB-CONFIG-1 reproducer (exit 1 = bug present). Supporting files:
  `poc_locale.cpp`, `rh.cpp` (C API root-hash, DTB-dump, store and load tool), `fdtdump.py`, `c1.json`, `linux_cfg.json`
  and `locales.sh`.
- `<SCRATCH>/work/dtb-config/fix/fix.patch` and `fix/fix.sh` hold the fix and its validation (`FIX VALIDATED`, exit 0).
- `<SCRATCH>/work/dtb-config/inputforms.sh` re-runs the negative-results matrix (`ALL EQUAL`, exit 0), using
  `lrh.lua` and `jrh.lua` for the Lua and JSON-RPC creation paths. `dtb_edge.lua` holds the ASan edge cases.
