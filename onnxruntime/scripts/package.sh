#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Package a completed onnxruntime build into a distributable archive.
#
# A static onnxruntime build does NOT produce a single self contained
# libonnxruntime.a: the `onnxruntime` CMake target is an INTERFACE library that
# pulls in a list of component libs (onnxruntime_INTERNAL_LIBRARIES) plus
# external deps (abseil, onnx, protobuf, re2, flatbuffers ...). They are all
# merged here into one fat archive, mirroring the layout of the official
# onnxruntime release packages:
#
#   onnxruntime-<version>-<target>/
#     include/               public headers, flattened like upstream packages
#     lib/libonnxruntime.a   single fat static library (.lib on Windows)
#     LICENSE
#     BUILD_INFO.txt
# -----------------------------------------------------------------------------
set -euo pipefail

SOURCE_DIR=""
BUILD_DIR=""
DIST_DIR=""
TARGET=""
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --source)    SOURCE_DIR="$2"; shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --dist-dir)  DIST_DIR="$2"; shift 2 ;;
        --target)    TARGET="$2"; shift 2 ;;
        --version)   VERSION="$2"; shift 2 ;;
        -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
        *)           echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done

[ -n "$SOURCE_DIR" ] || { echo "error: --source is required" >&2; exit 1; }
[ -n "$BUILD_DIR" ]  || { echo "error: --build-dir is required" >&2; exit 1; }
[ -n "$TARGET" ]     || { echo "error: --target is required" >&2; exit 1; }
[ -n "$VERSION" ]    || { echo "error: --version is required" >&2; exit 1; }
[ -n "$DIST_DIR" ]   || DIST_DIR="$PWD/dist"

# Every platform ships a .zip so consumers only need one extraction tool.
# Only the library file name differs between Windows and the rest.
case "$TARGET" in
    windows-*) LIB_EXT="lib" ; LIB_NAME="onnxruntime.lib" ;;
    *)         LIB_EXT="a"   ; LIB_NAME="libonnxruntime.a" ;;
esac
ARCHIVE_EXT="zip"

# macOS universal builds merge both slices into <build>/universal
PICK_DIR="$BUILD_DIR"
if [ -d "$BUILD_DIR/universal" ]; then
    PICK_DIR="$BUILD_DIR/universal"
fi

PKG_NAME="onnxruntime-${VERSION}-${TARGET}"
STAGE_DIR="$DIST_DIR/$PKG_NAME"

echo "==> packaging $PKG_NAME from $PICK_DIR"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/include" "$STAGE_DIR/lib"

# --- headers -----------------------------------------------------------------
# Flattened exactly like the official onnxruntime release packages (see
# get_c_cxx_api_headers() in cmake/onnxruntime.cmake): the public session API,
# the framework headers (provider_options.h) and the enabled EPs.
copied_headers=0
copy_header() {
    [ -f "$1" ] || return 0
    cp -f "$1" "$STAGE_DIR/include/"
    copied_headers=$((copied_headers + 1))
}

# The whole public session API, flattened out of core/session/
while IFS= read -r header; do
    copy_header "$header"
done < <(find "$SOURCE_DIR/include/onnxruntime/core/session" -maxdepth 1 -type f \
    \( -name '*.h' -o -name '*.inc' \) | sort)

# ... plus the two headers upstream packages ship alongside them. The other
# core/framework headers are internal (custom op / EP authoring) and are left
# out on purpose to keep include/ identical to an official release package.
copy_header "$SOURCE_DIR/include/onnxruntime/core/framework/provider_options.h"
copy_header "$SOURCE_DIR/include/onnxruntime/core/providers/cpu/cpu_provider_factory.h"

if [ "$copied_headers" -eq 0 ]; then
    echo "error: no public headers found under $SOURCE_DIR/include/onnxruntime" >&2
    exit 1
fi
echo "==> copied $copied_headers headers"

# --- collect every static library --------------------------------------------
# Includes the third party deps CMake builds under _deps/; only object dirs are
# skipped.
# while-read instead of mapfile: macOS ships bash 3.2, which has neither
# mapfile nor associative arrays.
FOUND_LIBS=()
while IFS= read -r found_lib; do
    [ -n "$found_lib" ] && FOUND_LIBS+=("$found_lib")
done < <(find "$PICK_DIR" -type f -name "*.${LIB_EXT}" \
    -not -path '*/CMakeFiles/*' -print 2>/dev/null | sort)

if [ ${#FOUND_LIBS[@]} -eq 0 ]; then
    echo "error: no static libraries found under $PICK_DIR" >&2
    exit 1
fi

# basename without the lib prefix / extension, used as the sort key
lib_key() {
    local base
    base="$(basename "$1")"
    base="${base%.${LIB_EXT}}"
    base="${base#lib}"
    printf '%s' "$base"
}

# Test only code and build time tools. onnxruntime_BUILD_UNIT_TESTS=OFF keeps
# gtest out of the build tree entirely; this list is the belt and braces that
# also covers builds made with the unit tests left on.
EXCLUDE_LIBS=(
    gtest gtest_main gmock gmock_main
    onnxruntime_test_utils onnxruntime_unittest_utils
    onnx_test_data_proto onnx_test_runner_common
    benchmark benchmark_main
    protoc protoc_lib
    # Full protobuf. onnxruntime uses protobuf-lite (onnxruntime_USE_FULL_PROTOBUF
    # is off); the full lib only exists for protoc and drags in a zlib dependency
    # (deflate/inflate) that consumers would otherwise have to link with -lz.
    # Note this is matched exactly, so libprotobuf-lite.a is kept.
    protobuf libprotobuf
    # Third party flatbuffers. Loading an .ort model only needs the header only
    # template types (flatbuffers::String / Vector / Offset); the actual runtime
    # features of libflatbuffers.a (schema Parser, reflection, Verifier) are not
    # referenced. Verified by a --whole-archive link with and without it: zero
    # new undefined symbols. libonnxruntime_flatbuffers.a (the ORT schema
    # wrappers, onnxruntime::fbs::utils::*) is NOT excluded, that one is needed.
    flatbuffers
)

ALL_LIBS=()
skipped=()
for lib in "${FOUND_LIBS[@]}"; do
    key="$(lib_key "$lib")"
    drop=0
    for excluded in "${EXCLUDE_LIBS[@]}"; do
        if [ "$key" = "$excluded" ]; then drop=1; break; fi
    done
    if [ $drop -eq 1 ]; then
        skipped+=("$key")
    else
        ALL_LIBS+=("$lib")
    fi
done
[ ${#skipped[@]} -gt 0 ] && echo "==> skipping test/tooling libs: ${skipped[*]}"

# A key -> path map, implemented with two parallel indexed arrays because bash
# 3.2 (macOS) has no associative arrays. First match wins, so there is exactly
# one canonical copy per library.
LIB_KEYS=()
LIB_PATHS=()
lib_index_of() {
    local needle="$1" idx
    for ((idx = 0; idx < ${#LIB_KEYS[@]}; idx++)); do
        if [ "${LIB_KEYS[$idx]}" = "$needle" ]; then
            printf '%s' "$idx"
            return 0
        fi
    done
    return 1
}
for lib in "${ALL_LIBS[@]}"; do
    key="$(lib_key "$lib")"
    lib_index_of "$key" >/dev/null || { LIB_KEYS+=("$key"); LIB_PATHS+=("$lib"); }
done

# reverse topological ordering taken from cmake/onnxruntime.cmake
# (onnxruntime_INTERNAL_LIBRARIES) followed by onnxruntime_EXTERNAL_LIBRARIES
ORDER=(
    onnxruntime_session
    onnxruntime_optimizer
    onnxruntime_providers
    onnxruntime_lora
    onnxruntime_framework
    onnxruntime_graph
    onnxruntime_util
    onnxruntime_mlas
    onnxruntime_common
    onnxruntime_flatbuffers
    onnx onnx_proto
    protobuf-lite libprotobuf-lite protobuf libprotobuf
    re2
    # only used when the platform actually builds them (date/nsync are header
    # only or absent on most targets); unknown entries are simply skipped
    date nsync cpuinfo
)
# Everything left (mainly the ~70 abseil archives) is appended alphabetically,
# which is deterministic and fine because the linker rescans a single archive
# until all symbols resolve.
#
# These third party libs are genuine dependencies, even for --minimal_build:
# nm --undefined-only on the component libs shows onnxruntime_framework
# referencing ~251 absl / 94 onnx / 45 protobuf symbols, graph ~160 onnx,
# providers ~5 re2. minimal build drops CUDA, contrib and ML ops, not the ONNX
# protobuf layer that ORT still needs to read model metadata and opsets.

ORDERED=()
for wanted in "${ORDER[@]}"; do
    idx="$(lib_index_of "$wanted" || true)"
    if [ -n "$idx" ]; then
        ORDERED+=("${LIB_PATHS[$idx]}")
        # drop it so it does not get appended again below
        unset "LIB_KEYS[$idx]" "LIB_PATHS[$idx]"
        LIB_KEYS=(${LIB_KEYS[@]+"${LIB_KEYS[@]}"})
        LIB_PATHS=(${LIB_PATHS[@]+"${LIB_PATHS[@]}"})
    fi
done
# remaining keys, alphabetically. The keys and paths stay aligned because both
# arrays are compacted together above.
while IFS= read -r key; do
    [ -z "$key" ] && continue
    idx="$(lib_index_of "$key" || true)"
    [ -n "$idx" ] && ORDERED+=("${LIB_PATHS[$idx]}")
done < <(printf '%s\n' ${LIB_KEYS[@]+"${LIB_KEYS[@]}"} | sort)

echo "==> merging ${#ORDERED[@]} static libraries into $LIB_NAME"

# --- merge into one fat archive ----------------------------------------------
find_msvc_lib() {
    if command -v lib.exe >/dev/null 2>&1; then command -v lib.exe; return 0; fi
    local vswhere install_dir found
    for vswhere in "/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" \
                   "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"; do
        if [ -x "$vswhere" ]; then
            install_dir="$("$vswhere" -latest -property installationPath 2>/dev/null | tr -d '\r' | tail -1)"
            if [ -n "$install_dir" ] && command -v cygpath >/dev/null 2>&1; then
                install_dir="$(cygpath -u "$install_dir")"
            fi
            if [ -n "$install_dir" ] && [ -d "$install_dir" ]; then
                found="$(find "$install_dir/VC/Tools/MSVC" -maxdepth 4 \
                    -path '*Hostx64/x64/lib.exe' -print 2>/dev/null | sort | tail -1)"
                if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
            fi
        fi
    done
    return 1
}

merge_libs() {
    local out="$1"; shift
    local mri rsp

    case "$(uname -s)" in
        Darwin*)
            libtool -static -o "$out" "$@"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            local lib_exe
            if ! lib_exe="$(find_msvc_lib)"; then
                echo "error: MSVC 'lib.exe' not found." >&2
                echo "       Run this from a Visual Studio developer prompt or" >&2
                echo "       set up the MSVC environment before packaging." >&2
                return 1
            fi
            echo "    using $(printf '%s' "$lib_exe")"
            rsp="$(mktemp)"
            printf '"%s"\n' "$@" > "$rsp"
            "$lib_exe" /NOLOGO "/OUT:$out" "@$rsp"
            rm -f "$rsp"
            ;;
        *)
            mri="$(mktemp)"
            {
                echo "CREATE $out"
                for lib in "$@"; do echo "ADDLIB $lib"; done
                echo "SAVE"
                echo "END"
            } > "$mri"
            ar -M < "$mri"
            rm -f "$mri"
            ranlib "$out"
            ;;
    esac
}

rm -f "$STAGE_DIR/lib/$LIB_NAME"
merge_libs "$STAGE_DIR/lib/$LIB_NAME" "${ORDERED[@]}"

[ -s "$STAGE_DIR/lib/$LIB_NAME" ] || { echo "error: merged library is empty" >&2; exit 1; }

# --- metadata ----------------------------------------------------------------
[ -f "$SOURCE_DIR/LICENSE" ] && cp -f "$SOURCE_DIR/LICENSE" "$STAGE_DIR/LICENSE"

cat > "$STAGE_DIR/BUILD_INFO.txt" <<EOF
project       : onnxruntime custom static build
version       : ${VERSION}
target        : ${TARGET}
build host    : $(uname -s) $(uname -m)
build date    : $(date -u +"%Y-%m-%dT%H:%M:%SZ")
source commit : $(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)

configuration :
  Release / static library (onnxruntime_BUILD_SHARED_LIB=OFF)
  --minimal_build
  --disable_ml_ops
  --disable_rtti
  --disable_exceptions
  --include_ops_by_config required_operators.config
  (contrib ops stay enabled: the DeepDoc weights need the com.microsoft
   fused kernels - FusedConv, FusedMatMul, QuickGelu)

contents      :
  include/  public C/C++ headers (flattened, same layout as upstream packages)
  lib/      single fat static library built from ${#ORDERED[@]} archives

usage         :
  g++ app.cc -I<pkg>/include <pkg>/lib/${LIB_NAME} -lpthread -ldl -lm -o app
EOF

# --- archive -----------------------------------------------------------------
mkdir -p "$DIST_DIR"
ARCHIVE_NAME="${PKG_NAME}.${ARCHIVE_EXT}"
rm -f "$DIST_DIR/$ARCHIVE_NAME"

# 'zip' when available (stores Unix permissions and symlinks correctly and does
# not need an external compressor), otherwise fall back to tar's
# --auto-compress, which picks the zip format from the .zip suffix.
if command -v zip >/dev/null 2>&1; then
    ( cd "$DIST_DIR" && zip -q -r -y "$ARCHIVE_NAME" "$PKG_NAME" )
else
    ( cd "$DIST_DIR" && tar -a -cf "$ARCHIVE_NAME" "$PKG_NAME" )
fi

if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$DIST_DIR" && sha256sum "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256" )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256" )
fi

echo "==> created $DIST_DIR/$ARCHIVE_NAME ($(du -h "$DIST_DIR/$ARCHIVE_NAME" | cut -f1))"
