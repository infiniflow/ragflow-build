# svgrender (static)

Standalone C-API static library (`libsvgrender.a` + `svgrender.h`) wrapping the
unmodified upstream Rust [`resvg`](https://crates.io/crates/resvg) crate
(`0.45.1`, **Apache-2.0 OR MIT**) to rasterize SVG documents into white-backed
PNG bytes.

## Features

- Zero upstream `resvg` source modifications.
- Blocks all external file/network `href` image loads (only inline `data:` URIs
  are allowed).
- Bounded output sizing (`max_side` and `max_pixels`).
- Deterministic sans-serif CJK/Latin font fallback (`Noto Sans CJK SC`,
  `Carlito`, `Liberation Sans`, `DejaVu Sans`, `WenQuanYi Zen Hei`). On Windows
  the curated `%WINDIR%\Fonts` list is loaded instead (`Microsoft YaHei`,
  `SimSun`, `Segoe UI`, `Arial`, ...), so fallback order stays predictable
  without parsing every face the machine has.

## Local build

```bash
bash svgrender/build.sh
```

Output lands in `svgrender/dist/svgrender-<version>-<target>.tar.gz` and `.sha256`.

### Windows

`windows-amd64` is built for the **`x86_64-pc-windows-gnu`** Rust target, not
MSVC: the archive has to link next to `libvisio` and the Go sidecar's cgo
objects, which are MinGW-w64 (msvcrt). Prerequisites, from an MSYS2 MINGW64
shell (or Git Bash with the mingw64 toolchain on `PATH`):

```bash
pacman -S mingw-w64-x86_64-gcc zip
rustup target add x86_64-pc-windows-gnu
bash svgrender/build.sh --target windows-amd64
```

The archive is `svgrender-<version>-windows-amd64.zip` and contains
`lib/libsvgrender.a` plus `include/svgrender.h`. The final link needs the Win32
libraries Rust's std references (`-lws2_32 -luserenv -lbcrypt -lntdll`); the
release workflow's smoke test links and runs a probe exactly that way.

`windows-arm64` is rejected on purpose: the Go sidecar links MinGW-w64 and there
is no aarch64-w64-mingw32 toolchain to pair with it.

## Releasing

```bash
git tag svgrender-v0.45.1 && git push origin svgrender-v0.45.1
```

Or run `.github/workflows/svgrender-release.yml` via **Actions → Run workflow**
(`dry_run=true` builds and smoke-tests all 4 targets without publishing).
