# ragflow-build

Vendored third-party dependencies and their release pipelines.

Each dependency owns a self-contained directory at the repository root:

```
.
├── .github/workflows/           # release pipelines (GitHub requires this path)
│   └── onnxruntime-release.yml
└── onnxruntime/                 # everything for this dependency
    ├── ORT_VERSION              # pinned upstream tag, e.g. v1.29.0
    ├── build.sh                 # build entry point
    ├── scripts/
    │   ├── init-submodules.sh       # fetch + pin the upstream source
    │   ├── package.sh               # assemble the distribution archive
    │   ├── build-macos-universal.sh # arm64 + x86_64 -> lipo
    │   └── cross-linux-aarch64.sh   # x86_64 -> aarch64 cross build
    ├── build/                   # build trees (git ignored)
    ├── dist/                    # release artifacts (git ignored)
    └── onnxruntime/             # upstream git submodule (microsoft/onnxruntime)
```

Adding another dependency later means adding one more top-level directory plus
one more workflow file — nothing here is onnxruntime specific except the
directory itself.

---

## onnxruntime

Pinned to **v1.29.0** (see `onnxruntime/ORT_VERSION`).

### 1. Get the sources

```bash
git clone <this-repo> ragflow-build
cd ragflow-build
bash onnxruntime/scripts/init-submodules.sh
```

This registers the submodule, checks out exactly the tag in `ORT_VERSION` and
pulls the recursive build dependencies. Use `--full` for an unshallow clone.

### 2. Build

```bash
cd onnxruntime
./build.sh \
    --config Release \
    --cmake_extra_defines onnxruntime_BUILD_SHARED_LIB=OFF \
    --minimal_build \
    --disable_ml_ops \
    --disable_rtti \
    --disable_exceptions \
    --include_ops_by_config onnxruntime/required_operators.config \
    --parallel
```

All of the flags above are already the defaults, so a plain `./build.sh` is
identical. Note that `--disable_contrib_ops` is **not** one of them, see
[Operator allow list](#operator-allow-list).

| Option | Description |
| --- | --- |
| `--target <name>` | `linux-x86_64`, `linux-aarch64`, `osx-arm64`, `osx-x86_64`, `osx-universal`, `windows-x64`, `windows-arm64`. Default: detected from the host. Windows targets are implemented but not exercised in CI right now, see [Platform status](#platform-status). |
| `--build-dir <path>` | Build root. Default `onnxruntime/build/<target>`. |
| `--dist-dir <path>` | Where the archive lands. Default `onnxruntime/dist`. |
| `--jobs <n>`, `-j <n>` | Max parallel compile jobs. Default: one per core, capped at 4 when less than 8 GB of RAM is free. |
| `--update` | Run `git submodule update --init --recursive` first. |
| `--clean` | Wipe the build directory for this target first. |
| `--no-package` | Build only, skip the tarball/zip. |
| `-h`, `--help` | Full help. |

onnxruntime translation units are memory hungry (~1–1.5 GB each), so building
with one job per core gets OOM killed on a small machine. Use `--jobs 2` if 4 is
still too much.

Extra defaults applied on top:

- `--skip_tests` — upstream `build.py` runs ctest by default, which downloads
  hundreds of MB of ONNX test data. Pass `--test` to opt back in.
- `--cmake_generator Ninja` — unix only, and only when ninja is installed.
  Windows keeps the Visual Studio generator.
- `--compile_no_warning_as_error` — new compilers trip `-Werror` upstream.
- `--allow_running_as_root` — only when running as root.

Build trees are platform specific: `onnxruntime/build/<target>` for most
targets, and `onnxruntime/build/osx-universal/{arm64,x86_64,universal}` for the
universal build.

### 3. Artifacts

`onnxruntime/dist/onnxruntime-<version>-<target>.zip` plus a `.sha256` file.
Every platform ships a zip, so consumers need only one extraction tool:

```
onnxruntime-v1.29.0-linux-x86_64/
├── BUILD_INFO.txt        # version, target, commit, configuration
├── LICENSE
├── include/              # public headers, flattened like upstream packages
│   ├── onnxruntime_c_api.h
│   ├── onnxruntime_cxx_api.h
│   ├── cpu_provider_factory.h
│   └── ...
└── lib/
    └── libonnxruntime.a  # single fat static library
```

Windows produces `lib/onnxruntime.lib` instead of `lib/libonnxruntime.a`; the
archive is a zip there too.

A static build has no single self-contained `libonnxruntime.a`: the
`onnxruntime` CMake target is an `INTERFACE` library that pulls in the
component libs listed in `onnxruntime_INTERNAL_LIBRARIES` (session, optimizer,
providers, framework, graph, util, mlas, common, flatbuffers) plus the external
deps (abseil, onnx, onnx_proto, protobuf, re2, ...). `scripts/package.sh`
collects every archive in the build tree and merges them into one fat library
(`ar -M` MRI script on Linux, `libtool -static` on macOS, MSVC `lib.exe` on
Windows), so consumers only need:

```bash
g++ app.cc -I<pkg>/include <pkg>/lib/libonnxruntime.a -lpthread -ldl -lm -o app
```

Because everything lives in one archive, the linker rescans it until all
symbols resolve — no manual link order is needed. Use `g++` (or add
`-lstdc++`): this is a C++ library even when your own code is C.

The measured `linux-x86_64` result is **7.6 MB** compressed / **35 MB**
uncompressed — versus ~200 MB for a default full build.

#### What goes into the fat archive

`--minimal_build` drops CUDA and (with `--disable_ml_ops`) the ML ops, but
**not** the ONNX protobuf layer, which ORT still needs to read model metadata
and opsets. These are genuine dependencies, verified with `nm --undefined-only` on the component
libs (`onnxruntime_framework` alone references ~251 abseil, 94 onnx and 45
protobuf symbols):

- abseil (~70 archives), onnx, onnx_proto, protobuf-**lite**, re2, cpuinfo
- `onnxruntime_flatbuffers` — the ORT schema wrappers (`onnxruntime::fbs::utils::*`)

Everything else is stripped out:

| Excluded | Why |
| --- | --- |
| gtest / gmock | test framework; also never downloaded (`onnxruntime_BUILD_UNIT_TESTS=OFF`) |
| `onnxruntime_test_utils`, `onnxruntime_unittest_utils` | test helpers |
| `onnx_test_data_proto`, `onnx_test_runner_common` | test data |
| `protoc` | code generator, not needed at runtime |
| `protobuf` (full) | onnxruntime uses protobuf-lite; the full lib only exists for protoc and would force consumers to link `-lz` |
| `flatbuffers` (third party) | Loading an `.ort` model only needs the header-only template types (`flatbuffers::String` / `Vector` / `Offset`). The runtime features of `libflatbuffers.a` — schema Parser, reflection — are never referenced. `flatbuffers::Verifier` is a header-only template, so it is instantiated inline and needs no library. |

Each exclusion was validated by linking with `-Wl,--whole-archive` (which forces
every object to resolve) and diffing the undefined symbols before and after:
**zero new undefined symbols** in every case. The only symbols left unresolved
are three `OrtInteropAPI::ReleaseExternal*` entry points belonging to the plugin
EP interop layer, which are absent upstream as well and never referenced by a
normal link.

#### Operator allow list

The build is reduced to the operators RAGFlow actually needs via
`--include_ops_by_config onnxruntime/required_operators.config`. Without it,
`--minimal_build` still compiles the whole kernel registry, which is most of
what a "minimal" build otherwise saves.

The list is generated from the DeepDoc weights (`det`, `rec`, `tsr`, `layout`
and the layout domain variants) and is checked in. Regenerate it whenever the
models change:

```bash
pip install onnxruntime onnx
onnxruntime/scripts/gen_required_ops.sh            # pulls the models from the Hub
onnxruntime/scripts/gen_required_ops.sh --models /path/to/onnx
```

A model needing an operator that is not in the list fails at runtime with
`Could not find an implementation for <Op>(<opset>)`, so a stale list ships a
build that cannot serve. The release workflow guards against that by loading
all four DeepDoc models with the packaged archive before uploading it.

Two things that are easy to get wrong:

- **Do not add `--disable_contrib_ops`.** The DeepDoc weights come from
  PaddlePaddle and use the `com.microsoft` fused kernels (`FusedConv`,
  `FusedMatMul`, `QuickGelu`) — they are in the allow list precisely because
  they are required. Disabling contrib ops makes every model fail to load even
  though the build succeeds.
- **Keep type reduction off.** `--enable_type_reduction` would emit
  `required_operators_and_types.config` and narrow each kernel to the observed
  types, which is a further size win but a much tighter contract to maintain.

---

## Releasing

`.github/workflows/onnxruntime-release.yml` builds all enabled targets in
parallel and publishes them to a GitHub release.

### Cutting a release

The tag carries the version — push it and the matching release is built and
published:

```bash
onnxruntime/scripts/bump.sh v1.30.0          # see "Upgrading" below
cd onnxruntime && ./build.sh --jobs 4         # verify locally first
git add onnxruntime/ORT_VERSION onnxruntime/onnxruntime
git commit -m "onnxruntime: bump to v1.30.0"
git tag release-v1.30.0
git push origin main --tags
```

`release-v1.30.0` → builds and publishes onnxruntime **v1.30.0** on that tag.

| Trigger | Version source | Behaviour |
| --- | --- | --- |
| push tag `release-v*` | parsed from the tag name | Build all enabled targets, publish a **public** release |
| push tag `onnxruntime-v*` | parsed from the tag name | same — preferred once the repo vendors more than one dependency |
| `workflow_dispatch` | the `ort_version` input, else `ORT_VERSION` | `draft` (default on) and `dry_run` available |

`ORT_VERSION` remains the local development default. If the tag disagrees with
it the workflow emits a warning so the drift does not go unnoticed.

Runner mapping:

| Target | Runner | Status |
| --- | --- | --- |
| `linux-x86_64` | `ubuntu-latest` | ✅ native, verified end to end |
| `linux-aarch64` | `ubuntu-24.04-arm` | ⏳ native arm64, not yet run |
| `osx-arm64` | `macos-latest` | ⏳ native arm64, not yet run |
| `osx-universal` | `macos-latest` | ⏳ two slices merged with `lipo`, not yet run |
| `windows-x64` | `windows-latest` | ⛔ disabled, see below |
| `windows-arm64` | `windows-latest` | ⛔ disabled, see below |

### Platform status

**Windows is disabled in CI.** The runner image has no Visual Studio instance,
so CMake configure fails:

```
CMake Error at CMakeLists.txt:11 (project):
  Generator
    Visual Studio 17 2022
  could not find any instance of Visual Studio.
```

`build.sh` still implements `windows-x64` and `windows-arm64` — only the matrix
rows in the workflow are commented out. To re-enable, uncomment the two
`windows-*` entries in `.github/workflows/onnxruntime-release.yml` (and restore
the Windows rows in the release body table). Packaging additionally needs MSVC's
`lib.exe`, which `scripts/package.sh` locates via `PATH` or `vswhere.exe`.

**Shell compatibility: the scripts target bash 3.2.** macOS ships bash 3.2,
which has no associative arrays (`declare -A`) and no `mapfile`. Everything is
written with plain indexed arrays and `while read` loops, so the same code runs
on the macOS runner, on Linux, and in Git Bash on Windows.

### Testing the workflow before a real release

Do not push a release tag to find out whether the pipeline works. Order:

1. **Syntax / config check, no runner time.** Validate the YAML and confirm the
   matrix resolves as intended:

   ```bash
   python3 -c "import yaml;d=yaml.safe_load(open('.github/workflows/onnxruntime-release.yml'));print([m['target'] for m in d['jobs']['build']['strategy']['matrix']['include']])"
   ```

   [`actionlint`](https://github.com/rhysd/actionlint) goes further and catches
   expression and context mistakes.

2. **Dry run on GitHub, all enabled targets.** Push the branch, then
   Actions → *onnxruntime release* → **Run workflow** with
   `dry_run = true`. Every platform builds and uploads artifacts, nothing is
   published. Download the artifacts and smoke test one of them.

   > The workflow must exist on the **default branch** before `Run workflow`
   > appears in the UI. Push it to `main` first (a dry run publishes nothing).

3. **Optional: run it locally with `act`.**
   [nektos/act](https://github.com/nektos/act) executes workflows in Docker.
   It only covers the `ubuntu-*` jobs — macOS and Windows runners cannot be
   emulated — but it is the fastest way to debug the shell steps:

   ```bash
   act workflow_dispatch -W .github/workflows/onnxruntime-release.yml \
       -j build --matrix target:linux-x86_64 \
       --input ort_version=v1.29.0 --input dry_run=true
   ```

4. **Real release.** Only after the dry run is green:

   ```bash
   git tag release-v1.29.0 && git push origin release-v1.29.0
   ```

The `release` job downloads every artifact, generates a download table from the
archives that actually exist (platform, size, SHA-256), writes a combined
`checksums.txt`, and attaches all of it to the GitHub release — so the file list
can never drift out of sync with the build matrix.

If a single target fails, `fail-fast: false` keeps the other five running, and
re-running the workflow after pushing a fix rebuilds everything (there is no
build cache between runs).

### Upgrading onnxruntime

```bash
onnxruntime/scripts/bump.sh v1.30.0
```

That verifies the tag exists upstream, writes it to `onnxruntime/ORT_VERSION`,
checks the submodule out at it (`--depth 1`), refreshes the recursive deps and
regenerates the operator allow list (`--skip-ops-config` to skip that step).
Then verify and commit:

```bash
cd onnxruntime && ./build.sh --jobs 4
git add onnxruntime/ORT_VERSION onnxruntime/onnxruntime onnxruntime/required_operators.config
git commit -m "onnxruntime: bump to v1.30.0"
```

Finally push `release-v1.30.0` to build and publish the new version.

Two things worth knowing:

- **`ORT_VERSION` is the local default, the tag is what ships.** On a tag push
  the version is parsed from the tag, so bumping the file alone does not
  trigger anything. Keep them in sync (the workflow warns when they drift) —
  `bump.sh` updates the file, and the tag you push should match it.
- **Recursive deps change between releases.** `bump.sh` re-runs
  `git submodule update --init --recursive`, because upstream regularly moves
  the pinned abseil / protobuf / onnx revisions.

To list available upstream tags:

```bash
git -C onnxruntime/onnxruntime ls-remote --tags origin | grep -oE 'refs/tags/v[0-9.]+$' | sort -V | tail
```

### Notes

- **linux-aarch64 without an arm runner.** `ubuntu-24.04-arm` requires a
  public repository or a paid plan. On `ubuntu-latest` the build script detects
  the mismatched host and falls back to `scripts/cross-linux-aarch64.sh`, which
  installs `crossbuild-essential-arm64` and cross compiles. Change `os` in the
  workflow matrix to switch.
- **Windows generator.** The script deliberately keeps the default Visual
  Studio generator on Windows; ninja is only auto-selected on unix where the
  toolchain is already on `PATH`. Pass `--cmake_generator Ninja` from a
  developer prompt to override.
- **Reproducibility.** `build.sh` re-checks out the pinned tag whenever the
  submodule work tree is clean, so a stale checkout cannot silently end up in a
  release.
