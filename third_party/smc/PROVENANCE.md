# third_party/smc — provenance

Vendored SMC command-line tool source, used by NapCat's charge limiter
(PLAN.md ADR §2/§3). Built by `make smc` into `dist/smc`; NOT bundled into
NapCat.app and NOT installed by the build — installation to
`/usr/local/napcat/smc` is performed only by the user-run `scripts/setup.sh`.

- **Upstream**: https://github.com/hholtmann/smcFanControl (directory `smc-command/`)
- **Pinned commit**: `e1bd672bcd2d72eddff9b6da7b9cae38e35c4206` (master HEAD as of
  vendoring on 2026-07-09; commit date 2022-12-03)
- **Files taken** (fetched from
  `https://raw.githubusercontent.com/hholtmann/smcFanControl/e1bd672bcd2d72eddff9b6da7b9cae38e35c4206/smc-command/<file>`).
  "Upstream" is the file as fetched; "In this tree" is the file as committed
  here, after the local modifications below:
  | File | Upstream SHA-256 | In this tree SHA-256 |
  |---|---|---|
  | `smc.c` | `13c0336cc51045de9f095d2e38bce6dc36dcccd145b3ff450b9c309768dbcf23` | `b883bdfc9c040f42110d89ae1085ac4497965289af9410826724efcf72f5b78a` (modified) |
  | `smc.h` | `eda500485ba3663b8597acf88a09c9aa02fd2ed876bb4076ac776425ee8b5244` | `eda500485ba3663b8597acf88a09c9aa02fd2ed876bb4076ac776425ee8b5244` (unchanged) |
  | `LICENSE` | `ab15fd526bd8dd18a9e77ebc139656bf4d33e97fc7238cd11bf60e2b9b8666c6` | `ab15fd526bd8dd18a9e77ebc139656bf4d33e97fc7238cd11bf60e2b9b8666c6` (unchanged) |

  Verify with `shasum -a 256 third_party/smc/smc.c third_party/smc/smc.h
  third_party/smc/LICENSE`. To see the local changes, diff `smc.c` against
  the upstream URL above.
- **Not taken**: upstream `Makefile` (builds universal i386/x86_64 with SDK
  flags irrelevant here — NapCat's top-level Makefile compiles natively with
  `cc -Wall -Wformat-security -Werror=format-security -O2 -D_FORTIFY_SOURCE=2
  smc.c -framework IOKit -framework CoreFoundation`) and `README.md`
  (smcFanControl app docs, not smc-command docs).
- **License**: GPL-2.0 (see `LICENSE` in this directory; upstream copyright
  headers in `smc.c`/`smc.h` kept intact). The smc binary is a separate
  standalone program invoked via `sudo`; it is not linked into NapCat.
  Attribution also required in the top-level README (PLAN.md P5).
- **Local modifications**: `smc.h` and `LICENSE` are byte-identical to
  upstream. `smc.c` was changed on 2026-11-22 (NapCat issue #102). The
  helper runs as root through exact-argument sudoers entries, so none of the
  bugs below was reachable as shipped; the changes are defence in depth. A
  notice at the top of `smc.c` lists the same changes, as GPL-2.0
  section 2(a) requires.
  1. **Bounded `-w` parse.** Upstream looped `strlen(value)` times instead
     of `strlen(value) / 2`, reading past the string and writing past the
     32-byte `SMCVal_t.bytes[]`. AddressSanitizer reports a stack buffer
     overflow for any value longer than 35 characters. `parseHexValue()`
     now accepts only an even count of 2 to 64 hex digits and refuses
     anything else with `Error: value is not valid`. `SMCWriteSimple()` had
     the same loop and now uses the same parser.
  2. **Literal format strings.** `SMCReadKey2()`, `SMCWriteSimple()` and
     `main()` passed the key to `sprintf()` as the format string, so a key
     such as `%99d` overflowed the 5-byte `val.key`. They now use
     `snprintf(..., "%s", key)`. These were the only three calls that
     `-Werror=format-security` flags.
  3. **Zeroed `val`.** `main()` and `SMCWriteSimple()` `memset` their
     `SMCVal_t` before use.
  4. **Exact command-line forms.** `main()` no longer uses `getopt`. It
     accepts exactly `smc -k <key> -r` and `smc -k <key> -w <value>`, the
     forms NapCat's read-back probe and its six sudoers entries use. The
     key must be exactly four printable ASCII characters. Every other flag
     (`-l`, `-f`, `-t`, `-v`, `-h`), order, repetition or extra argument
     prints `Error: unsupported arguments` plus usage and exits 1, before
     the SMC connection is opened. The functions behind the removed flags
     (`SMCPrintAll()`, `SMCPrintFans()`, `SMCPrintTemps()`) stay in the
     file, unchanged, but nothing calls them any more.

  For a valid key and value, the two remaining forms behave as upstream did:
  same `printVal` lines, same `Error:` lines, exit status 0 after the SMC
  call.
- **Build note**: `smc.c` guards its `main()` behind `#ifdef CMD_TOOL_BUILD`
  (upstream also compiles the file into smcFanControl.app as a library), so
  the compile command must pass `-DCMD_TOOL_BUILD` — matching the upstream
  smc-command Makefile's `CPPFLAGS`. Without it, linking fails with
  "Undefined symbols: _main".
