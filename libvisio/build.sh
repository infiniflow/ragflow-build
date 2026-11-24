#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build and package UNMODIFIED upstream libvisio + librevenge + libxml2 static
# archives for the current host platform.
#
# Upstream sources are NOT modified or patched:
#   - libxml2 2.12.9      (MIT)
#   - librevenge 0.0.5    (MPL-2.0 OR LGPL-2.1+)
#   - libvisio 0.1.10     (MPL-2.0)
#
# To avoid linking libicu (which collides with the ICU runtime embedded in
# libpdfium.a), libvisio is compiled with -I libvisio/icu_shim, remapping the
# 3 ICU converter functions (ucnv_open / ucnv_getNextUChar / ucnv_close) to
# visio_ucnv_* symbols supplied by the consumer (e.g. via POSIX iconv).
#
# Bash 3.2 compatible (macOS default bash).
# -----------------------------------------------------------------------------
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="${PKG_DIR}/LIBVISIO_VERSION"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

REVENGE_VERSION="0.0.5"
REVENGE_URL="https://downloads.sourceforge.net/project/libwpd/librevenge/librevenge-${REVENGE_VERSION}/librevenge-${REVENGE_VERSION}.tar.xz"
REVENGE_SHA256="106d0c44bb6408b1348b9e0465666fa83b816177665a22cd017e886c1aaeeb34"

LIBXML2_VERSION="2.12.9"
LIBXML2_URL="https://download.gnome.org/sources/libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz"
LIBXML2_SHA256="59912db536ab56a3996489ea0299768c7bcffe57169f0235e7f962a91f483590"

VISIO_0_1_10_SHA256="9e9eff75112d4d92d92262ad7fc2599c21e26f8fc5ba54900efdc83c0501e472"

TARGET=""
VERSION="$DEFAULT_VERSION"
DIST_DIR="${PKG_DIR}/dist"
JOBS=""

usage() {
    cat << 'EOF'
Usage: libvisio/build.sh [options]

Options:
  --target <name>     Target triple: linux-amd64, linux-arm64, darwin-amd64, darwin-arm64
  --version <ver>     libvisio version tag (default: libvisio/LIBVISIO_VERSION, e.g. v0.1.10)
  --dist-dir <path>   Output directory for release archive (default: libvisio/dist)
  --jobs <n>, -j <n>  Parallel make jobs
  -h, --help          Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)   TARGET="$2"; shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --dist-dir) DIST_DIR="$2"; shift 2 ;;
        --jobs|-j)  JOBS="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$VERSION" in
    v*) BARE_VERSION="${VERSION#v}" ;;
    *)  BARE_VERSION="$VERSION"; VERSION="v${VERSION}" ;;
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

[ -n "$JOBS" ] || JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256_of "$file")"
    if [ "$actual" != "$expected" ]; then
        echo "error: sha256 mismatch for ${file}: got ${actual}, want ${expected}" >&2
        exit 1
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

VISIO_URL="https://dev-www.libreoffice.org/src/libvisio/libvisio-${BARE_VERSION}.tar.xz"
VISIO_SHA256=""
if [ "$BARE_VERSION" = "0.1.10" ]; then
    VISIO_SHA256="$VISIO_0_1_10_SHA256"
fi

ICU_SHIM_DIR="${PKG_DIR}/icu_shim"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ragflow-libvisio-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PREFIX="${WORK}/install"
mkdir -p "$PREFIX" "$DIST_DIR"

EXTRA_INC=""
if [ -n "${VISIO_EXTRA_INCLUDE_DIR:-}" ]; then
    EXTRA_INC="-I${VISIO_EXTRA_INCLUDE_DIR}"
elif [ "$TARGET_OS" = "darwin" ] && command -v brew >/dev/null 2>&1; then
    BOOST_PREFIX="$(brew --prefix boost 2>/dev/null || true)"
    if [ -n "$BOOST_PREFIX" ] && [ -d "${BOOST_PREFIX}/include" ]; then
        EXTRA_INC="-I${BOOST_PREFIX}/include"
    fi
fi

echo "==> Downloading unmodified libxml2 ${LIBXML2_VERSION}, librevenge ${REVENGE_VERSION}, libvisio ${BARE_VERSION}"
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "${WORK}/libxml2.tar.xz" "$LIBXML2_URL"
verify_sha256 "${WORK}/libxml2.tar.xz" "$LIBXML2_SHA256"

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "${WORK}/librevenge.tar.xz" "$REVENGE_URL"
verify_sha256 "${WORK}/librevenge.tar.xz" "$REVENGE_SHA256"

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "${WORK}/libvisio.tar.xz" "$VISIO_URL"
if [ -n "$VISIO_SHA256" ]; then
    verify_sha256 "${WORK}/libvisio.tar.xz" "$VISIO_SHA256"
fi

tar -xf "${WORK}/libxml2.tar.xz" -C "$WORK"
tar -xf "${WORK}/librevenge.tar.xz" -C "$WORK"
tar -xf "${WORK}/libvisio.tar.xz" -C "$WORK"

echo "==> Building static libxml2 ${LIBXML2_VERSION} (unmodified)"
(
    cd "${WORK}/libxml2-${LIBXML2_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --without-python --without-lzma --without-icu \
        --without-http --without-ftp --without-catalog \
        --without-modules --without-debug --without-zlib \
        --without-readline --without-history --without-iconv \
        CFLAGS="-O2 -fPIC"
    make -j"$JOBS"
    make install
)

echo "==> Building static librevenge ${REVENGE_VERSION} (unmodified)"
(
    cd "${WORK}/librevenge-${REVENGE_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-tests --without-docs --disable-werror \
        CFLAGS="-O2 -fPIC" \
        CXXFLAGS="-O2 -fPIC -std=c++17 ${EXTRA_INC}" \
        CPPFLAGS="${EXTRA_INC}"
    make -j"$JOBS"
    make install
)

echo "==> Building static libvisio ${BARE_VERSION} (unmodified upstream, ICU shimmed to visio_ucnv_*)"
(
    cd "${WORK}/libvisio-${BARE_VERSION}"
    # Keep pre-generated gperf outputs strictly newer than tokens.txt/tokens.gperf
    # so gperf is not required on build hosts.
    touch src/lib/tokens.gperf
    sleep 1
    touch src/lib/tokens.h src/lib/tokenhash.h
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
    ICU_CFLAGS="-I${ICU_SHIM_DIR}" ICU_LIBS=" " \
    LIBXML_CFLAGS="-I${PREFIX}/include/libxml2" LIBXML_LIBS=" " \
    ./configure \
        --prefix="$PREFIX" \
        --enable-static --disable-shared \
        --disable-tests --without-docs --disable-tools --disable-werror \
        CFLAGS="-O2 -fPIC" \
        CXXFLAGS="-O2 -fPIC -std=c++17 -I${ICU_SHIM_DIR} ${EXTRA_INC} -I${PREFIX}/include/librevenge-0.0 -I${PREFIX}/include/libxml2" \
        CPPFLAGS="-I${ICU_SHIM_DIR} ${EXTRA_INC} -I${PREFIX}/include/librevenge-0.0 -I${PREFIX}/include/libxml2"
    make -j"$JOBS"
    make install
)

STAGE="${WORK}/stage"
mkdir -p "${STAGE}/lib" "${STAGE}/include" "${STAGE}/licenses"

for a in \
    libvisio-0.1.a \
    librevenge-generators-0.0.a \
    librevenge-stream-0.0.a \
    librevenge-0.0.a \
    libxml2.a; do
    cp "${PREFIX}/lib/${a}" "${STAGE}/lib/${a}"
    strip_llvm_linker_options "${STAGE}/lib/${a}"
done

cp -R "${PREFIX}/include/libvisio-0.1" "${STAGE}/include/"
cp -R "${PREFIX}/include/librevenge-0.0" "${STAGE}/include/"

# Copy upstream license notices verbatim.
cp "${WORK}/libvisio-${BARE_VERSION}/COPYING.MPL" "${STAGE}/licenses/libvisio-MPL-2.0.txt"
cp "${WORK}/librevenge-${REVENGE_VERSION}/COPYING.MPL" "${STAGE}/licenses/librevenge-MPL-2.0.txt"
cp "${WORK}/libxml2-${LIBXML2_VERSION}/Copyright" "${STAGE}/licenses/libxml2-MIT.txt"

printf '%s/%s\n' "$TARGET_OS" "$TARGET_ARCH" > "${STAGE}/.ragflow_platform"

cat > "${STAGE}/BUILD_INFO.txt" << EOF
package=libvisio
version=${VERSION}
target=${TARGET}
libvisio=${BARE_VERSION} (unmodified upstream)
librevenge=${REVENGE_VERSION} (unmodified upstream)
libxml2=${LIBXML2_VERSION} (unmodified upstream)
icu_mode=compile-time header shim -> visio_ucnv_*
EOF

ARCHIVE_NAME="libvisio-${VERSION}-${TARGET}.tar.gz"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
tar -czf "$ARCHIVE_PATH" -C "$STAGE" .

SHA="$(sha256_of "$ARCHIVE_PATH")"
printf '%s  %s\n' "$SHA" "$ARCHIVE_NAME" > "${ARCHIVE_PATH}.sha256"

echo "==> Packaged ${ARCHIVE_PATH}"
ls -lh "$ARCHIVE_PATH"
cat "${ARCHIVE_PATH}.sha256"
