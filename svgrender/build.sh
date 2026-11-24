#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build and package the standalone resvg C-API static library (libsvgrender.a)
# using unmodified upstream resvg (Apache-2.0 OR MIT).
#
# Windows is built for the `x86_64-pc-windows-gnu` target on purpose: the
# archive is consumed by the Go sidecar's cgo link, which is MinGW-w64 based
# (the same toolchain that links libvisio), so an MSVC staticlib would not be
# linkable next to it. That needs a MinGW-w64 gcc on PATH (MSYS2 MINGW64 shell),
# not MSVC. windows-arm64 is not supported: there is no aarch64-w64-mingw32
# toolchain to pair with the cgo link.
#
# Bash 3.2 compatible (macOS default bash) and Windows/Git Bash compatible.
# -----------------------------------------------------------------------------
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${PKG_DIR}/SVGRENDER_VERSION"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

TARGET=""
VERSION="$DEFAULT_VERSION"
DIST_DIR="${PKG_DIR}/dist"

usage() {
    cat << 'EOF'
Usage: svgrender/build.sh [options]

Options:
  --target <name>     Target triple: linux-amd64, linux-arm64, darwin-amd64,
                      darwin-arm64, windows-amd64
  --version <ver>     Release version tag (default: svgrender/SVGRENDER_VERSION, e.g. v0.45.1)
  --dist-dir <path>   Output directory for release archive (default: svgrender/dist)
  -h, --help          Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)   TARGET="$2"; shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --dist-dir) DIST_DIR="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$VERSION" in
    v*) : ;;
    *)  VERSION="v${VERSION}" ;;
esac

die() { echo "error: $*" >&2; exit 1; }

detect_host_target() {
    local os arch
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        Darwin)               os="darwin" ;;
        Linux)                os="linux" ;;
        *)                    os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) die "unsupported arch: $arch" ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

[ -n "$TARGET" ] || TARGET="$(detect_host_target)"

# RUST_TARGET stays empty for the native unix targets so their build output path
# (target/release) and therefore their bytes are exactly what they were before
# the windows target existed.
RUST_TARGET=""
LIB_FILE="libsvgrender.a"
ARCHIVE_EXT="tar.gz"
case "$TARGET" in
    linux-amd64)  TARGET_OS="linux";  TARGET_ARCH="amd64" ;;
    linux-arm64)  TARGET_OS="linux";  TARGET_ARCH="arm64" ;;
    darwin-amd64) TARGET_OS="darwin"; TARGET_ARCH="amd64" ;;
    darwin-arm64) TARGET_OS="darwin"; TARGET_ARCH="arm64" ;;
    windows-amd64)
        TARGET_OS="windows"; TARGET_ARCH="amd64"
        RUST_TARGET="x86_64-pc-windows-gnu"
        ARCHIVE_EXT="zip"
        ;;
    windows-arm64)
        die "windows-arm64 is not supported: the Go sidecar links with MinGW-w64 and
       there is no aarch64-w64-mingw32 toolchain to build this archive with.
       Build windows-amd64 instead."
        ;;
    *) die "unsupported target: $TARGET" ;;
esac

preflight_windows() {
    [ "$TARGET_OS" = "windows" ] || return 0

    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) die "windows-amd64 must be built on Windows from a MinGW-w64 shell
       (MSYS2 MINGW64, or Git Bash with the mingw64 gcc on PATH)" ;;
    esac

    local cc="" candidate machine
    for candidate in x86_64-w64-mingw32-gcc gcc; do
        if command -v "$candidate" >/dev/null 2>&1; then cc="$candidate"; break; fi
    done
    [ -n "$cc" ] || die "MinGW-w64 gcc not found on PATH (MSYS2: pacman -S mingw-w64-x86_64-gcc)"
    machine="$("$cc" -dumpmachine 2>/dev/null || true)"
    case "$machine" in
        *mingw*) ;;
        *) die "$cc is not a MinGW-w64 compiler ($machine); rustc needs
       x86_64-w64-mingw32-gcc to link a windows-gnu staticlib" ;;
    esac

    # The Go sidecar links the msvcrt-based MinGW64 runtime; a UCRT build would
    # mix two C runtimes into one binary.
    case "${MSYSTEM:-}" in
        UCRT64|CLANG64|CLANGARM64)
            echo "warning: MSYSTEM=$MSYSTEM targets the UCRT, but the Go sidecar links the" >&2
            echo "         msvcrt-based MinGW64 runtime; run this from the MINGW64 environment." >&2
            ;;
    esac

    if command -v rustup >/dev/null 2>&1; then
        if ! rustup target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
            die "rust target $RUST_TARGET is not installed; run 'rustup target add $RUST_TARGET'"
        fi
    fi
}

preflight_windows

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Windows consumers expect a .zip (PowerShell's Expand-Archive handles nothing
# else); POSIX keeps the .tar.gz it has always shipped.
pack_archive() {
    local stage="$1" out="$2" ext="$3"
    rm -f "$out"
    case "$ext" in
        zip)
            if command -v zip >/dev/null 2>&1; then
                ( cd "$stage" && zip -q -r -y "$out" . )
                return 0
            fi
            if command -v powershell >/dev/null 2>&1; then
                local win_stage win_out
                win_stage="$(cygpath -w "$stage")"
                win_out="$(cygpath -w "$out")"
                powershell -NoProfile -NonInteractive -Command \
                    "Compress-Archive -Path '${win_stage}\\*' -DestinationPath '${win_out}' -Force"
                return 0
            fi
            die "creating ${out##*/} needs 'zip' (MSYS2: pacman -S zip) or PowerShell"
            ;;
        *)
            tar -czf "$out" -C "$stage" .
            ;;
    esac
}

strip_llvm_linker_options() {
    [ "$TARGET_OS" = "linux" ] || return 0
    local archive="$1"
    if command -v readelf >/dev/null 2>&1 && ! readelf -S "$archive" 2>/dev/null | grep -q '\.linker-options'; then
        return 0
    fi
    local objcopy_bin=""
    if command -v objcopy >/dev/null 2>&1; then
        objcopy_bin=objcopy
    elif command -v llvm-objcopy >/dev/null 2>&1; then
        objcopy_bin=llvm-objcopy
    else
        return 0
    fi
    "$objcopy_bin" --remove-section=.linker-options "$archive"
}

echo "==> Building libsvgrender.a (${VERSION}, ${TARGET})"
CARGO_ARGS=(build --release --locked)
if [ -n "$RUST_TARGET" ]; then
    CARGO_ARGS+=(--target "$RUST_TARGET")
fi
( cd "$PKG_DIR" && cargo "${CARGO_ARGS[@]}" )

if [ -n "$RUST_TARGET" ]; then
    LIB_PATH="${PKG_DIR}/target/${RUST_TARGET}/release/${LIB_FILE}"
else
    LIB_PATH="${PKG_DIR}/target/release/${LIB_FILE}"
fi
[ -f "$LIB_PATH" ] || die "cargo produced no ${LIB_FILE} at ${LIB_PATH}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ragflow-svgrender-stage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAGE="${WORK}/stage"
mkdir -p "${STAGE}/lib" "${STAGE}/include" "$DIST_DIR"

cp "$LIB_PATH" "${STAGE}/lib/${LIB_FILE}"
strip_llvm_linker_options "${STAGE}/lib/${LIB_FILE}"
cp "${PKG_DIR}/svgrender.h" "${STAGE}/include/svgrender.h"
printf '%s/%s\n' "$TARGET_OS" "$TARGET_ARCH" > "${STAGE}/.ragflow_platform"

cat > "${STAGE}/BUILD_INFO.txt" << EOF
package=svgrender
version=${VERSION}
target=${TARGET}
rust_target=${RUST_TARGET:-host}
resvg=0.45.1 (unmodified crates.io release, Apache-2.0 OR MIT)
rustc=$(rustc --version)
EOF

if [ "$TARGET_OS" = "windows" ]; then
    cat >> "${STAGE}/BUILD_INFO.txt" << EOF
toolchain=$(gcc -dumpmachine 2>/dev/null || echo unknown) / MinGW-w64, msvcrt runtime
EOF
fi

ARCHIVE_NAME="svgrender-${VERSION}-${TARGET}.${ARCHIVE_EXT}"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
pack_archive "$STAGE" "$ARCHIVE_PATH" "$ARCHIVE_EXT"

SHA="$(sha256_of "$ARCHIVE_PATH")"
printf '%s  %s\n' "$SHA" "$ARCHIVE_NAME" > "${ARCHIVE_PATH}.sha256"

echo "==> Packaged ${ARCHIVE_PATH}"
ls -lh "$ARCHIVE_PATH"
cat "${ARCHIVE_PATH}.sha256"
