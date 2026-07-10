# third_party/smc — provenance

Vendored SMC command-line tool source, used by NapCat's charge limiter
(PLAN.md ADR §2/§3). Built by `make smc` into `dist/smc`; NOT bundled into
NapCat.app and NOT installed by the build — installation to
`/usr/local/napcat/smc` is performed only by the user-run `scripts/setup.sh`.

- **Upstream**: https://github.com/hholtmann/smcFanControl (directory `smc-command/`)
- **Pinned commit**: `e1bd672bcd2d72eddff9b6da7b9cae38e35c4206` (master HEAD as of
  vendoring on 2026-07-09; commit date 2022-12-03)
- **Files taken** (fetched from
  `https://raw.githubusercontent.com/hholtmann/smcFanControl/e1bd672bcd2d72eddff9b6da7b9cae38e35c4206/smc-command/<file>`):
  | File | SHA-256 |
  |---|---|
  | `smc.c` | `13c0336cc51045de9f095d2e38bce6dc36dcccd145b3ff450b9c309768dbcf23` |
  | `smc.h` | `eda500485ba3663b8597acf88a09c9aa02fd2ed876bb4076ac776425ee8b5244` |
  | `LICENSE` | `ab15fd526bd8dd18a9e77ebc139656bf4d33e97fc7238cd11bf60e2b9b8666c6` |
- **Not taken**: upstream `Makefile` (builds universal i386/x86_64 with SDK
  flags irrelevant here — NapCat's top-level Makefile compiles natively with
  `cc smc.c -framework IOKit -framework CoreFoundation`) and `README.md`
  (smcFanControl app docs, not smc-command docs).
- **License**: GPL-2.0 (see `LICENSE` in this directory; upstream copyright
  headers in `smc.c`/`smc.h` kept intact). The smc binary is a separate
  standalone program invoked via `sudo`; it is not linked into NapCat.
  Attribution also required in the top-level README (PLAN.md P5).
- **Local modifications**: none. Files are byte-identical to upstream at the
  pinned commit (verify with the SHA-256 table above).
- **Build note**: `smc.c` guards its `main()` behind `#ifdef CMD_TOOL_BUILD`
  (upstream also compiles the file into smcFanControl.app as a library), so
  the compile command must pass `-DCMD_TOOL_BUILD` — matching the upstream
  smc-command Makefile's `CPPFLAGS`. Without it, linking fails with
  "Undefined symbols: _main".
