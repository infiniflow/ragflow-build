#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build a customized onnxruntime (minimal, static, reduced operator set, no
# ml ops, no RTTI, no exceptions) for the current host or for an explicit
# target platform.
#
# The upstream onnxruntime sources live in the git submodule
# `onnxruntime/onnxruntime` (pinned to the version in `onnxruntime/ORT_VERSION`).
#
# Usage:
#   ./build.sh
#   ./build.sh --config Release \
#              --cmake_extra_defines onnxruntime_BUILD_SHARED_LIB=OFF \
#              --minimal_build --disable_ml_ops \
#              --disable_rtti --disable_exceptions --parallel
#   ./build.sh --target osx-universal
#   ./build.sh --target windows-arm64 --build-dir /tmp/ort-build
#
# Every unknown flag is forwarded verbatim to onnxruntime's
# `tools/ci_build/build.py`, so the full upstream option set stays available.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
while [ -L "$SCRIPT_PATH" ]; do
    link_target="$(readlink "$SCRIPT_PATH")"
    case "$link_target" in
        /*) SCRIPT_PATH="$link_target" ;;
        *) SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$link_target" ;;
    esac
done
# <repo>/onnxruntime  -> package directory holding this script
PKG_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# <repo>              -> repository root, shared with other dependencies
REPO_ROOT="$(cd "$PKG_DIR/.." && pwd)"
SCRIPT_DIR="$PKG_DIR/scripts"

ORT_SRC="$PKG_DIR/onnxruntime"
ORT_VERSION_FILE="$PKG_DIR/ORT_VERSION"
ORT_VERSION="$(tr -d '[:space:]' < "$ORT_VERSION_FILE")"
# Operator allow list this build is reduced to. Regenerate it whenever the
# models change: scripts/gen_required_ops.sh
REQUIRED_OPS_CONFIG="$PKG_DIR/required_operators.config"
ORT_BUILD_PY="$ORT_SRC/tools/ci_build/build.py"

SUPPORTED_TARGETS="linux-x86_64 linux-aarch64 osx-arm64 osx-x86_64 osx-universal windows-x64 windows-arm64"

# --- user overridable locations --------------------------------------------
TARGET=""
BUILD_ROOT="$PKG_DIR/build"
DIST_DIR="$PKG_DIR/dist"
DO_UPDATE=0
DO_CLEAN=0
DO_PACKAGE=1
EXPLICIT_BUILD_ROOT=0
JOBS=""

# --- defaults requested by this project ------------------------------------
# store_true style flags that are ON unless the user passes them explicitly
# (--parallel is handled separately so it can take a job count)
#
# NOTE: --disable_contrib_ops is deliberately NOT in this list. RAGFlow's
# DeepDoc weights are converted from PaddlePaddle models and depend on the
# com.microsoft fused kernels (FusedConv, FusedMatMul, QuickGelu); dropping
# contrib ops makes every DeepDoc model fail with
# "Could not find an implementation for FusedConv(1)". Operator coverage is
# narrowed by the allow list in required_operators.config instead, which keeps
# those kernels while still excluding everything the models do not use.
DEFAULT_FLAGS=(--minimal_build --disable_ml_ops \
               --disable_rtti --disable_exceptions)
# --key value style defaults
DEFAULT_KV=(--config Release --include_ops_by_config "$REQUIRED_OPS_CONFIG")
# -D style defaults (user values are appended, so they win)
DEFAULT_CMAKE_DEFINES=(
    onnxruntime_BUILD_SHARED_LIB=OFF
    # upstream defaults this ON, which fetches googletest and compiles the whole
    # unit test tree even with --skip_tests (that only skips *running* them)
    onnxruntime_BUILD_UNIT_TESTS=OFF
)

USER_ARGS=()          # everything forwarded to build.py as-is
USER_CMAKE_DEFINES=() # collected separately so they can be merged
# Flags the caller passed explicitly, so the defaults below can skip them.
# Kept as a plain indexed array + helper: macOS still ships bash 3.2, which has
# no associative arrays (declare -A).
SEEN_FLAGS=()
mark_seen() { SEEN_FLAGS+=("$1"); }
has_seen() {
    local needle="$1" item
    for item in ${SEEN_FLAGS[@]+"${SEEN_FLAGS[@]}"}; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
    cat <<EOF
Usage: onnxruntime/build.sh [options] [-- <onnxruntime build.py options>]

Project options:
  --target <name>       Target platform, one of:
                          ${SUPPORTED_TARGETS}
                        Default: auto-detected from the host.
  --build-dir <path>    Build root. Default: ${BUILD_ROOT}
  --dist-dir <path>     Directory for packaged artifacts. Default: ${DIST_DIR}
  --jobs <n>, -j <n>    Max parallel compile jobs. Default: one per core, capped
                        at 4 when less than 8 GB of RAM is free (onnxruntime
                        translation units need ~1-1.5 GB each).
  --update              Run 'git submodule update --init --recursive' first.
  --clean               Delete the build directory for this target first.
  --no-package          Build only, do not create a tarball/zip in --dist-dir.
  -h, --help            Show this help.

Default onnxruntime options (skipped when you pass them yourself):
  ${DEFAULT_KV[*]} ${DEFAULT_FLAGS[*]} --parallel <jobs>
  --cmake_extra_defines ${DEFAULT_CMAKE_DEFINES[*]}
  --cmake_generator Ninja   (only when ninja is installed)
  --skip_tests              (build.py runs ctest by default, pass --test to keep it)
  --compile_no_warning_as_error
  --allow_running_as_root   (only when running as root)

Any other option is forwarded verbatim to
onnxruntime/tools/ci_build/build.py.
EOF
}

# ---------------------------------------------------------------------------
# host / target detection
# ---------------------------------------------------------------------------
host_os() {
    case "$(uname -s)" in
        Linux*)                         echo linux ;;
        Darwin*)                        echo osx ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) echo windows ;;
        *)                              echo unknown ;;
    esac
}

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64|AMD64) echo x86_64 ;;
        arm64|aarch64)      echo aarch64 ;;
        *)                  echo "$(uname -m)" ;;
    esac
}

detect_target() {
    local os arch
    os="$(host_os)"
    arch="$(host_arch)"
    case "$os" in
        linux)   echo "linux-$arch" ;;
        osx)     if [ "$arch" = "aarch64" ]; then echo "osx-arm64"; else echo "osx-x86_64"; fi ;;
        windows) if [ "$arch" = "aarch64" ]; then echo "windows-arm64"; else echo "windows-x64"; fi ;;
        *)       echo "" ;;
    esac
}

# onnxruntime translation units are memory hungry (~1-1.5 GB each). On a box
# with little free RAM, building with one job per core gets OOM killed, so cap
# the default when memory is tight. --jobs always wins.
default_jobs() {
    local ncpu avail_mb jobs
    ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    jobs="$ncpu"
    avail_mb=0
    if [ -r /proc/meminfo ]; then
        avail_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    elif [ "$(host_os)" = "osx" ] && command -v vm_stat >/dev/null 2>&1; then
        # free + speculative + file-backed pages, in MB
        avail_mb="$(vm_stat 2>/dev/null | awk '
            /Pages free/            { f = $3 }
            /Pages speculative/     { s = $3 }
            /File-backed pages/     { b = $3 }
            END { gsub(/\./, "", f); gsub(/\./, "", s); gsub(/\./, "", b)
                  printf "%d", (f + s + b) * 4096 / 1048576 }')"
    fi
    if [ "${avail_mb:-0}" -gt 0 ] && [ "$avail_mb" -lt 8192 ] 2>/dev/null; then
        jobs=4
        [ "$ncpu" -lt 4 ] && jobs="$ncpu"
    fi
    echo "$jobs"
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --target|-t)
            [ $# -ge 2 ] || die "--target requires a value"
            TARGET="$2"; shift 2 ;;
        --build-dir)
            [ $# -ge 2 ] || die "--build-dir requires a value"
            BUILD_ROOT="$2"; EXPLICIT_BUILD_ROOT=1; shift 2 ;;
        --dist-dir)
            [ $# -ge 2 ] || die "--dist-dir requires a value"
            DIST_DIR="$2"; shift 2 ;;
        --jobs|-j)
            [ $# -ge 2 ] || die "--jobs requires a value"
            JOBS="$2"; shift 2 ;;
        --update)   DO_UPDATE=1; shift ;;
        --clean)    DO_CLEAN=1; shift ;;
        --package)  DO_PACKAGE=1; shift ;;
        --no-package) DO_PACKAGE=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        --cmake_extra_defines)
            [ $# -ge 2 ] || die "--cmake_extra_defines requires a value"
            USER_CMAKE_DEFINES+=("$2")
            mark_seen "--cmake_extra_defines"
            shift 2 ;;
        --include_ops_by_config)
            # Key/value pair: forward both tokens and remember it so the
            # default allow list below is not applied as well.
            [ $# -ge 2 ] || die "--include_ops_by_config requires a value"
            USER_ARGS+=("$1" "$2")
            mark_seen "--include_ops_by_config"
            shift 2 ;;
        --config|--build_dir|--cmake_generator|--osx_arch|--path_to_protoc_exe|--target|-t)
            # handled or rejected below; stay out of the default merging
            die "'$1' is managed by this script, use the documented project options instead" ;;
        --minimal_build|--disable_contrib_ops|--disable_ml_ops|--disable_rtti|--disable_exceptions|--parallel|--update|--clean|--skip_tests)
            USER_ARGS+=("$1"); mark_seen "$1"; shift ;;
        *)
            USER_ARGS+=("$1"); shift ;;
    esac
done

if [ -z "$TARGET" ]; then
    TARGET="$(detect_target)"
    [ -n "$TARGET" ] || die "unable to detect the host platform, pass --target explicitly"
    info "no --target given, detected host target: $TARGET"
fi

case " $SUPPORTED_TARGETS " in
    *" $TARGET "*) : ;;
    *) die "unsupported target '$TARGET' (supported: $SUPPORTED_TARGETS)" ;;
esac

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
[ -f "$ORT_BUILD_PY" ] || die "onnxruntime submodule missing at $ORT_SRC, run 'git submodule update --init --recursive'"

# The shipped allow list is only applied when the caller did not pass one, so
# only require the file in that case.
if ! has_seen "--include_ops_by_config" && [ ! -f "$REQUIRED_OPS_CONFIG" ]; then
    die "missing operator allow list $REQUIRED_OPS_CONFIG; regenerate it with scripts/gen_required_ops.sh"
fi

PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || die "python3 is required to drive onnxruntime's build"

if [ "$DO_UPDATE" -eq 1 ]; then
    info "updating submodules (recursive)"
    git -C "$REPO_ROOT" submodule sync --recursive
    git -C "$REPO_ROOT" submodule update --init --recursive
fi

# pin the submodule to the requested release unless the work tree is dirty
if git -C "$ORT_SRC" rev-parse -q --verify "refs/tags/$ORT_VERSION" >/dev/null 2>&1; then
    current_commit="$(git -C "$ORT_SRC" rev-parse HEAD)"
    wanted_commit="$(git -C "$ORT_SRC" rev-parse "refs/tags/$ORT_VERSION^{commit}")"
    if [ "$current_commit" != "$wanted_commit" ] && [ -z "$(git -C "$ORT_SRC" status --porcelain)" ]; then
        info "checking out onnxruntime $ORT_VERSION"
        git -C "$ORT_SRC" checkout --detach "$wanted_commit"
    fi
fi

# ---------------------------------------------------------------------------
# assemble the onnxruntime build.py argument list
# ---------------------------------------------------------------------------
ORT_ARGS=()

# default flags the user did not specify explicitly
for flag in "${DEFAULT_FLAGS[@]}"; do
    if ! has_seen "$flag"; then
        ORT_ARGS+=("$flag")
    fi
done

# --parallel. build.py takes an optional job count: bare '--parallel' means
# "one job per core", '--parallel N' means at most N.
if [ -n "$JOBS" ]; then
    ORT_ARGS+=(--parallel "$JOBS")
elif ! has_seen "--parallel"; then
    ORT_ARGS+=(--parallel "$(default_jobs)")
fi

# default key/value pairs the user did not specify explicitly
i=0
while [ $i -lt ${#DEFAULT_KV[@]} ]; do
    key="${DEFAULT_KV[$i]}"
    val="${DEFAULT_KV[$((i + 1))]}"
    if ! has_seen "$key"; then
        ORT_ARGS+=("$key" "$val")
    fi
    i=$((i + 2))
done

# merge cmake defines: defaults first so user values win
for def in "${DEFAULT_CMAKE_DEFINES[@]}" ${USER_CMAKE_DEFINES[@]+"${USER_CMAKE_DEFINES[@]}"}; do
    ORT_ARGS+=(--cmake_extra_defines "$def")
done

# Prefer ninja on unix like hosts. On Windows the MSVC toolchain is only on the
# PATH inside a developer prompt, so keep the default Visual Studio generator
# there unless the caller explicitly asked for something else.
if [ "$(host_os)" != "windows" ] && ! printf '%s\n' "${USER_ARGS[@]}" | grep -qx -- "--cmake_generator"; then
    if command -v ninja >/dev/null 2>&1 || command -v ninja-build >/dev/null 2>&1; then
        ORT_ARGS+=(--cmake_generator Ninja)
    fi
fi

# newer compilers trip -Werror in the upstream tree
if ! has_seen "--compile_no_warning_as_error"; then
    ORT_ARGS+=(--compile_no_warning_as_error)
fi

# build.py runs ctest by default, which pulls hundreds of MB of ONNX test data.
# A release build only needs the library; pass --test to opt back in.
if ! has_seen "--test" && ! has_seen "--skip_tests"; then
    ORT_ARGS+=(--skip_tests)
fi

# onnxruntime's build.py refuses to run as root without this
if [ "$(id -u)" = "0" ] && [ "$(host_os)" != "windows" ]; then
    ORT_ARGS+=(--allow_running_as_root)
fi

# anything the user asked for goes last so it can override the defaults
ORT_ARGS+=(${USER_ARGS[@]+"${USER_ARGS[@]}"})

# ---------------------------------------------------------------------------
# per target build
# ---------------------------------------------------------------------------
if [ "$EXPLICIT_BUILD_ROOT" -eq 0 ]; then
    BUILD_DIR="$BUILD_ROOT/$TARGET"
else
    BUILD_DIR="$BUILD_ROOT"
fi

if [ "$DO_CLEAN" -eq 1 ]; then
    info "removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# A static build turns `onnxruntime` into an INTERFACE library, so external deps
# that are only reachable through INTERFACE_LINK_LIBRARIES never enter the build
# graph and are left uncompiled. re2 is one of them: the RegexFullMatch kernel
# references re2::RE2, but nothing depends on the re2 target, so the final link
# dies with "undefined reference to re2::RE2::RE2". Build those targets by hand.
MISSING_INTERFACE_DEPS=(re2)

ort_config() {
    local i
    for ((i = 0; i < ${#ORT_ARGS[@]}; i++)); do
        if [ "${ORT_ARGS[$i]}" = "--config" ]; then
            printf '%s' "${ORT_ARGS[$((i + 1))]}"
            return
        fi
    done
    echo Release
}

build_interface_only_deps() {
    local build_dir="$1" bin_dir dep found
    bin_dir="$(find "$build_dir" -name CMakeCache.txt -print -quit 2>/dev/null)"
    [ -n "$bin_dir" ] || return 0
    bin_dir="$(dirname "$bin_dir")"
    for dep in "${MISSING_INTERFACE_DEPS[@]}"; do
        found="$(find "$build_dir" \( -name "lib${dep}.a" -o -name "${dep}.lib" \) -print -quit 2>/dev/null)"
        [ -n "$found" ] && continue
        info "building external dependency that the static build graph skips: $dep"
        cmake --build "$bin_dir" --config "$(ort_config)" --target "$dep" \
            || echo "warning: target '$dep' could not be built" >&2
    done
}

ort_build() {
    local build_dir="$1"; shift
    info "building onnxruntime $ORT_VERSION for $TARGET in $build_dir"
    mkdir -p "$build_dir"
    ( cd "$ORT_SRC" && "$PYTHON" "$ORT_BUILD_PY" --build_dir "$build_dir" "$@" )
    build_interface_only_deps "$build_dir"
}

case "$TARGET" in
    linux-x86_64)
        [ "$(host_arch)" = "x86_64" ] || echo "warning: cross building linux-x86_64 is untested" >&2
        ort_build "$BUILD_DIR" "${ORT_ARGS[@]}"
        ;;
    linux-aarch64)
        if [ "$(host_arch)" = "aarch64" ]; then
            ort_build "$BUILD_DIR" "${ORT_ARGS[@]}"
        else
            info "host is $(host_arch), cross compiling for aarch64"
            BASH="$(command -v bash)"
            "$BASH" "$SCRIPT_DIR/cross-linux-aarch64.sh" \
                "$ORT_SRC" "$BUILD_DIR" "$PYTHON" "${ORT_ARGS[@]}"
        fi
        ;;
    osx-arm64)
        [ "$(host_os)" = "osx" ] || die "osx-arm64 must be built on macOS"
        ort_build "$BUILD_DIR" --osx_arch arm64 "${ORT_ARGS[@]}"
        ;;
    osx-x86_64)
        [ "$(host_os)" = "osx" ] || die "osx-x86_64 must be built on macOS"
        ort_build "$BUILD_DIR" --osx_arch x86_64 "${ORT_ARGS[@]}"
        ;;
    osx-universal)
        [ "$(host_os)" = "osx" ] || die "osx-universal must be built on macOS"
        bash "$SCRIPT_DIR/build-macos-universal.sh" \
            "$ORT_SRC" "$BUILD_DIR" "$PYTHON" "${ORT_ARGS[@]}"
        ;;
    windows-x64)
        [ "$(host_os)" = "windows" ] || die "windows-x64 must be built on Windows"
        ort_build "$BUILD_DIR" "${ORT_ARGS[@]}"
        ;;
    windows-arm64)
        [ "$(host_os)" = "windows" ] || die "windows-arm64 must be built on Windows"
        ort_build "$BUILD_DIR" --arm64 "${ORT_ARGS[@]}"
        ;;
esac

info "build finished: $BUILD_DIR"

# ---------------------------------------------------------------------------
# packaging
# ---------------------------------------------------------------------------
if [ "$DO_PACKAGE" -eq 1 ]; then
    bash "$SCRIPT_DIR/package.sh" \
        --source "$ORT_SRC" \
        --build-dir "$BUILD_DIR" \
        --dist-dir "$DIST_DIR" \
        --target "$TARGET" \
        --version "$ORT_VERSION"
fi
