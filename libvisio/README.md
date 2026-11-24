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

Output lands in `libvisio/dist/libvisio-<version>-<target>.tar.gz` and `.sha256`.

## Releasing

```bash
git tag libvisio-v0.1.10 && git push origin libvisio-v0.1.10
```

Or run `.github/workflows/libvisio-release.yml` via **Actions → Run workflow**
(`dry_run=true` builds and smoke-tests all 4 targets without publishing).
