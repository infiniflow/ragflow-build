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
  `Carlito`, `Liberation Sans`, `DejaVu Sans`, `WenQuanYi Zen Hei`, falling back
  to system fonts on macOS).

## Local build

```bash
bash svgrender/build.sh
```

Output lands in `svgrender/dist/svgrender-<version>-<target>.tar.gz` and `.sha256`.

## Releasing

```bash
git tag svgrender-v0.45.1 && git push origin svgrender-v0.45.1
```

Or run `.github/workflows/svgrender-release.yml` via **Actions → Run workflow**
(`dry_run=true` builds and smoke-tests all 4 targets without publishing).
