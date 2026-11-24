#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build and package the standalone resvg C-API static library (libsvgrender.a)
# using unmodified upstream resvg (Apache-2.0 OR MIT).
#
# Bash 3.2 compatible (macOS default bash).
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
  --target <name>     Target triple: linux-amd64, linux-arm64, darwin-amd64, darwin-arm64
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

detect_host_target() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "error: unsupported arch: $arch" >&2; exit 1 ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

[ -n "$TARGET" ] || TARGET="$(detect_host_target)"

case "$TARGET" in
    linux-amd64)  TARGET_OS="linux";  TARGET_ARCH="amd64" ;;
    linux-arm64)  TARGET_OS="linux";  TARGET_ARCH="arm64" ;;
    darwin-amd64) TARGET_OS="darwin"; TARGET_ARCH="amd64" ;;
    darwin-arm64) TARGET_OS="darwin"; TARGET_ARCH="arm64" ;;
    *) echo "error: unsupported target: $TARGET" >&2; exit 1 ;;
esac

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
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
(
    cd "$PKG_DIR"
    cargo build --release --locked
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ragflow-svgrender-stage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAGE="${WORK}/stage"
mkdir -p "${STAGE}/lib" "${STAGE}/include" "$DIST_DIR"

cp "${PKG_DIR}/target/release/libsvgrender.a" "${STAGE}/lib/libsvgrender.a"
strip_llvm_linker_options "${STAGE}/lib/libsvgrender.a"
cp "${PKG_DIR}/svgrender.h" "${STAGE}/include/svgrender.h"
printf '%s/%s\n' "$TARGET_OS" "$TARGET_ARCH" > "${STAGE}/.ragflow_platform"

cat > "${STAGE}/BUILD_INFO.txt" << EOF
package=svgrender
version=${VERSION}
target=${TARGET}
resvg=0.45.1 (unmodified crates.io release, Apache-2.0 OR MIT)
rustc=$(rustc --version)
EOF

ARCHIVE_NAME="svgrender-${VERSION}-${TARGET}.tar.gz"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
tar -czf "$ARCHIVE_PATH" -C "$STAGE" .

SHA="$(sha256_of "$ARCHIVE_PATH")"
printf '%s  %s\n' "$SHA" "$ARCHIVE_NAME" > "${ARCHIVE_PATH}.sha256"

echo "==> Packaged ${ARCHIVE_PATH}"
ls -lh "$ARCHIVE_PATH"
cat "${ARCHIVE_PATH}.sha256"
