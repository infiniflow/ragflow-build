# libvisio (static)

Unmodified upstream **libvisio** + **librevenge** + **libxml2** static archives
for RAGFlow.

## Upstream components (zero source modifications)

| Component | Version | License |
| --- | --- | --- |
| `libvisio` | `0.1.10` (`libvisio/LIBVISIO_VERSION`) | MPL-2.0 |
| `librevenge` (`0.0`, `stream`, `generators`) | `0.0.5` | MPL-2.0 OR LGPL-2.1+ |
| `libxml2` | `2.12.9` | MIT |

## ICU symbol isolation

Upstream `libvisio` references 3 ICU converter functions (`ucnv_open`,
`ucnv_getNextUChar`, `ucnv_close`). Because consumers may statically link
`libpdfium.a` (which embeds its own ICU runtime), `libvisio` is compiled against
the compile-time headers in `libvisio/icu_shim/unicode/` that remap those 3
functions to `visio_ucnv_open`, `visio_ucnv_getNextUChar`, and
`visio_ucnv_close`. Consumers supply those 3 symbols (for example via POSIX
`iconv`) with zero ICU link collisions and zero modifications to upstream
`libvisio` source code.

## Local build

```bash
# Ubuntu / Debian: sudo apt-get install -y libboost-dev pkg-config zlib1g-dev
# macOS:           brew install boost pkg-config
bash libvisio/build.sh
```

Output lands in `libvisio/dist/libvisio-<version>-<target>.tar.gz` and `.sha256`
(a `.zip` for the Windows target).

## Windows

Upstream only ships autotools, so MSVC is not an option: `windows-amd64` is
built with the **MSYS2 MINGW64** (msvcrt) toolchain and ships ordinary MinGW-w64
`.a` archives — the same runtime the Go sidecar's cgo link uses. Build it from
an MSYS2 MINGW64 shell, not from Git Bash (autotools needs MSYS2's `make`,
`pkg-config` and shell):

```bash
pacman -S mingw-w64-x86_64-toolchain mingw-w64-x86_64-boost pkgconf zip
bash libvisio/build.sh --target windows-amd64
```

The script refuses to run when `gcc` is not a MinGW-w64 compiler or the boost
headers are missing, and warns when `MSYSTEM` is `UCRT64`/`CLANG64` (a UCRT build
would mix two C runtimes into one binary). The archive contents match the other
platforms — `lib/libvisio-0.1.a`, `librevenge-*.a`, `libxml2.a` — and
`-fPIC` is dropped because MinGW-w64 has no PIC distinction.

`windows-arm64` is not supported: MSYS2 has no `aarch64-w64-mingw32` gcc for an
autotools build.

## Releasing

```bash
git tag libvisio-v0.1.10 && git push origin libvisio-v0.1.10
```

Or run `.github/workflows/libvisio-release.yml` via **Actions → Run workflow**
(`dry_run=true` builds and smoke-tests all 4 targets without publishing).
