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
# Windows (windows-amd64) builds the same upstream sources with the MSYS2
# MINGW64 toolchain and ships MinGW-w64 .a archives, because that is what the Go
# sidecar's cgo link uses. Upstream only has autotools, so MSVC is not an option
# here; the archives carry the msvcrt-based MinGW64 runtime, matching Go's cgo
# toolchain. Run it from an MSYS2 MINGW64 shell (pacman -S
# mingw-w64-x86_64-toolchain mingw-w64-x86_64-boost make pkgconf zip).
#
# windows-arm64 is cross-compiled from the same x64 host with llvm-mingw
# (LLVM/UCRT, the toolchain Go's windows/arm64 cgo link uses): there is no
# aarch64-w64-mingw32 gcc. Target libraries (zlib, boost headers) come from
# MSYS2's CLANGARM64 prefix. See setup_windows_arm64().
#
# Bash 3.2 compatible (macOS default bash) and Windows/Git Bash compatible.
# -----------------------------------------------------------------------------
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

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
  --target <name>     Target triple: linux-amd64, linux-arm64, darwin-amd64,
                      darwin-arm64, windows-amd64, windows-arm64
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
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        Darwin)               os="darwin" ;;
        Linux)                os="linux" ;;
        *)                    os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
    esac
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "error: unsupported arch: $arch" >&2; exit 1 ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

[ -n "$TARGET" ] || TARGET="$(detect_host_target)"

# PIC_FLAG is empty on Windows: MinGW-w64 has no PIC distinction, and -fPIC is
# meaningless there. Every other knob below stays identical per target so the
# archives already published for linux/darwin are rebuilt from the same recipe.
PIC_FLAG="-fPIC"
ARCHIVE_EXT="tar.gz"
CROSS_TRIPLE=""
CONFIGURE_HOST=()
CONFIGURE_BOOST=()
case "$TARGET" in
    linux-amd64)  TARGET_OS="linux";  TARGET_ARCH="amd64" ;;
    linux-arm64)  TARGET_OS="linux";  TARGET_ARCH="arm64" ;;
    darwin-amd64) TARGET_OS="darwin"; TARGET_ARCH="amd64" ;;
    darwin-arm64) TARGET_OS="darwin"; TARGET_ARCH="arm64" ;;
    windows-amd64)
        TARGET_OS="windows"; TARGET_ARCH="amd64"
        PIC_FLAG=""
        ARCHIVE_EXT="zip"
        ;;
    windows-arm64)
        TARGET_OS="windows"; TARGET_ARCH="arm64"
        PIC_FLAG=""
        ARCHIVE_EXT="zip"
        # No aarch64-w64-mingw32 gcc exists: llvm-mingw provides the cross
        # compiler, and Go's windows/arm64 cgo link uses the same toolchain.
        CROSS_TRIPLE="aarch64-w64-mingw32"
        ;;
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

# Windows archives land as a .zip (PowerShell's Expand-Archive handles nothing
# else); every POSIX target keeps the .tar.gz it has always shipped.
pack_archive() {
    local stage="$1" out="$2" ext="$3"
    rm -f "$out"
    case "$ext" in
        zip)
            if command -v zip >/dev/null 2>&1; then
                ( cd "$stage" && zip -q -r -y "$out" . )
                return 0
            fi
            # bsdtar's -a picks the zip writer from the .zip suffix and names
            # entries with forward slashes. PowerShell's Compress-Archive writes
            # backslashes as path separators, which makes unzip warn and exit 1.
            if tar --version 2>/dev/null | grep -qi bsdtar; then
                ( cd "$stage" && tar -a -cf "$out" . )
                return 0
            fi
            die "creating ${out##*/} needs Info-ZIP 'zip' or bsdtar (MSYS2: pacman -S zip)"
            ;;
        *)
            tar -czf "$out" -C "$stage" .
            ;;
    esac
}

# Everything the Windows build needs has to be present before the first
# configure runs: autotools drives the build, boost is header-only for libvisio,
# and the compiler must be the MinGW-w64 one so the .a archives carry the same
# runtime (msvcrt) as Go's cgo link.
preflight_windows() {
    [ "$TARGET_OS" = "windows" ] || return 0
    # windows-arm64 is cross-compiled; setup_windows_arm64 checks its own tools.
    if [ "$TARGET_ARCH" = "arm64" ]; then
        return 0
    fi

    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) die "windows-amd64 must be built on Windows from an MSYS2 MINGW64 shell" ;;
    esac

    # m4 is not part of the toolchain packages, but the windres shim
    # (build/win32/lt-compile-resource) runs it over every .rc file, so a build
    # without it dies minutes in at the resource step.
    local tool
    for tool in gcc g++ make pkg-config windres m4; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "missing $tool: run this from the MSYS2 MINGW64 shell with
       'pacman -S mingw-w64-x86_64-toolchain mingw-w64-x86_64-boost make pkgconf m4 zip'"
    done

    case "$(gcc -dumpmachine 2>/dev/null || true)" in
        *mingw*) ;;
        *) die "gcc is not a MinGW-w64 compiler ($(gcc -dumpmachine 2>/dev/null)); the
       Go sidecar links the msvcrt-based MinGW64 runtime, so a Cygwin or MSVC
       compiler cannot produce compatible archives" ;;
    esac

    # libvisio needs boost headers only; the MSYS2 MINGW64 prefix is already on
    # the default include path, so this is a presence check, not a flag.
    printf '#include <boost/shared_ptr.hpp>\n' | g++ -E -x c++ - >/dev/null 2>&1 \
        || die "boost headers not found (MSYS2: pacman -S mingw-w64-x86_64-boost)"

    case "${MSYSTEM:-}" in
        UCRT64|CLANG64|CLANGARM64)
            echo "warning: MSYSTEM=$MSYSTEM targets the UCRT, but the Go sidecar links the" >&2
            echo "         msvcrt-based MinGW64 runtime; run this from MINGW64 instead." >&2
            ;;
    esac
}

# MSYS2's CLANGARM64 prefix holds the aarch64 libraries this cross build needs
# (zlib, boost headers). It is reachable as /clangarm64 from any MSYS2 shell of
# the same installation.
ARM64_PREFIX="${ARM64_PREFIX:-/clangarm64}"

setup_windows_arm64() {
    [ "$TARGET_OS" = "windows" ] || return 0
    [ "$TARGET_ARCH" = "arm64" ] || return 0

    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) die "windows-arm64 is cross-compiled from Windows, run this in an MSYS2 shell" ;;
    esac

    local tool
    for tool in "${CROSS_TRIPLE}-clang" "${CROSS_TRIPLE}-clang++" \
                "${CROSS_TRIPLE}-ar" "${CROSS_TRIPLE}-ranlib" \
                "${CROSS_TRIPLE}-windres" make m4 pkg-config; do
        command -v "$tool" >/dev/null 2>&1 \
            || die "missing $tool: put llvm-mingw's bin on PATH
       (https://github.com/mstorsjo/llvm-mingw, the ucrt-x86_64 archive: it runs
       on an x64 host and targets aarch64-w64-mingw32)"
    done

    { [ -f "${ARM64_PREFIX}/include/zlib.h" ] && [ -f "${ARM64_PREFIX}/lib/libz.a" ]; } \
        || die "${ARM64_PREFIX} carries no aarch64 zlib
      (MSYS2: pacman -S mingw-w64-clang-aarch64-zlib, or set ARM64_PREFIX)"
    [ -d "${ARM64_PREFIX}/include/boost" ] \
        || die "${ARM64_PREFIX} carries no boost headers
      (MSYS2: pacman -S mingw-w64-clang-aarch64-boost, or set ARM64_PREFIX)"

    export CC="${CROSS_TRIPLE}-clang"
    export CXX="${CROSS_TRIPLE}-clang++"
    export AR="${CROSS_TRIPLE}-ar"
    export RANLIB="${CROSS_TRIPLE}-ranlib"
    export NM="${CROSS_TRIPLE}-nm"
    export STRIP="${CROSS_TRIPLE}-strip"
    export WINDRES="${CROSS_TRIPLE}-windres"
    export DLLTOOL="${CROSS_TRIPLE}-dlltool"
    export LDFLAGS="-L${ARM64_PREFIX}/lib"
    # pkg-config must see the target .pc files only, never the x64 ones of the
    # MINGW64 prefix: that is the prefix the autotools builds install into plus
    # CLANGARM64, which carries zlib.pc for aarch64. Both paths are MSYS-style,
    # so the ':' separator is unambiguous.
    export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${ARM64_PREFIX}/lib/pkgconfig"
    # librevenge's zlib check is PKG_CHECK_MODULES(zlib), i.e. a pkg-config
    # lookup; state the answer directly as well so a missing .pc cannot abort
    # the cross build.
    export ZLIB_CFLAGS="-I${ARM64_PREFIX}/include"
    export ZLIB_LIBS="-L${ARM64_PREFIX}/lib -lz"
    CONFIGURE_HOST=(--build=x86_64-w64-mingw32 --host="${CROSS_TRIPLE}")
    # AX_BOOST_BASE looks for boost on its own; point it at the cross prefix
    # instead of relying on it honouring CPPFLAGS.
    CONFIGURE_BOOST=(--with-boost="${ARM64_PREFIX}")
    EXTRA_INC="-I${ARM64_PREFIX}/include ${EXTRA_INC}"
}

preflight_windows

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

# Cross tools, --host and the aarch64 include path; a no-op for every other
# target. Runs after EXTRA_INC so it can prepend the arm64 prefix.
setup_windows_arm64

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
        ${CONFIGURE_HOST[@]+"${CONFIGURE_HOST[@]}"} \
        --enable-static --disable-shared \
        --without-python --without-lzma --without-icu \
        --without-http --without-ftp --without-catalog \
        --without-modules --without-debug --without-zlib \
        --without-readline --without-history --without-iconv \
        CFLAGS="-O2 ${PIC_FLAG}"
    make -j"$JOBS"
    make install
)

echo "==> Building static librevenge ${REVENGE_VERSION} (unmodified)"
(
    cd "${WORK}/librevenge-${REVENGE_VERSION}"
    ./configure \
        --prefix="$PREFIX" \
        ${CONFIGURE_HOST[@]+"${CONFIGURE_HOST[@]}"} \
        ${CONFIGURE_BOOST[@]+"${CONFIGURE_BOOST[@]}"} \
        --enable-static --disable-shared \
        --disable-tests --without-docs --disable-werror \
        CFLAGS="-O2 ${PIC_FLAG}" \
        CXXFLAGS="-O2 ${PIC_FLAG} -std=c++17 ${EXTRA_INC}" \
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
    # libxml2 is built --disable-shared, so every object that includes its
    # headers has to see LIBXML_STATIC: xmlexports.h otherwise declares the API
    # __declspec(dllimport) on Windows and the objects reference __imp_xml*,
    # which a static libxml2.a cannot satisfy. libxml2's pkg-config carries the
    # define in Cflags.private, which the LIBXML_CFLAGS override below drops, so
    # it also goes into CPPFLAGS where it reaches every compile.
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
    ICU_CFLAGS="-I${ICU_SHIM_DIR}" ICU_LIBS=" " \
    LIBXML_CFLAGS="-I${PREFIX}/include/libxml2 -DLIBXML_STATIC" LIBXML_LIBS=" " \
    ./configure \
        --prefix="$PREFIX" \
        ${CONFIGURE_HOST[@]+"${CONFIGURE_HOST[@]}"} \
        --enable-static --disable-shared \
        --disable-tests --without-docs --disable-tools --disable-werror \
        CFLAGS="-O2 ${PIC_FLAG}" \
        CXXFLAGS="-O2 ${PIC_FLAG} -std=c++17 -I${ICU_SHIM_DIR} ${EXTRA_INC} -I${PREFIX}/include/librevenge-0.0 -I${PREFIX}/include/libxml2" \
        CPPFLAGS="-DLIBXML_STATIC -I${ICU_SHIM_DIR} ${EXTRA_INC} -I${PREFIX}/include/librevenge-0.0 -I${PREFIX}/include/libxml2"
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

if [ "$TARGET_OS" = "windows" ]; then
    if [ "$TARGET_ARCH" = "arm64" ]; then
        cat >> "${STAGE}/BUILD_INFO.txt" << EOF
toolchain=$("${CROSS_TRIPLE}-clang" -dumpmachine 2>/dev/null || echo unknown) / llvm-mingw, UCRT runtime
EOF
    else
        cat >> "${STAGE}/BUILD_INFO.txt" << EOF
toolchain=$(gcc -dumpmachine 2>/dev/null || echo unknown) / MinGW-w64, msvcrt runtime
EOF
    fi
fi

ARCHIVE_NAME="libvisio-${VERSION}-${TARGET}.${ARCHIVE_EXT}"
ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"
pack_archive "$STAGE" "$ARCHIVE_PATH" "$ARCHIVE_EXT"

SHA="$(sha256_of "$ARCHIVE_PATH")"
printf '%s  %s\n' "$SHA" "$ARCHIVE_NAME" > "${ARCHIVE_PATH}.sha256"

echo "==> Packaged ${ARCHIVE_PATH}"
ls -lh "$ARCHIVE_PATH"
cat "${ARCHIVE_PATH}.sha256"
