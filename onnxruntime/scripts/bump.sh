#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Point the onnxruntime submodule at a new upstream release.
#
#   onnxruntime/scripts/bump.sh v1.30.0
#
# Steps performed:
#   1. verify the tag exists upstream
#   2. write it to onnxruntime/ORT_VERSION
#   3. check the submodule out at that tag
#   4. refresh the recursive build dependencies
#   5. regenerate the operator allow list (--skip-ops-config to skip)
#
# Then build locally, commit the submodule pointer + ORT_VERSION (and the
# regenerated operator allow list), and push a release-v<version> tag to
# trigger the release workflow.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"        # <repo>/onnxruntime
ORT_SRC="$PKG_DIR/onnxruntime"
ORT_VERSION_FILE="$PKG_DIR/ORT_VERSION"

VERSION="${1:-}"
SKIP_SUBMODULES=0
SKIP_OPS_CONFIG=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        sed -n '2,18p' "$0"; exit 0 ;;
        --skip-submodules) SKIP_SUBMODULES=1; shift ;;
        --skip-ops-config) SKIP_OPS_CONFIG=1; shift ;;
        -*)               echo "error: unknown option $1" >&2; exit 1 ;;
        *)                VERSION="$1"; shift ;;
    esac
done

[ -n "$VERSION" ] || { echo "error: usage: $(basename "$0") <version>   e.g. v1.30.0" >&2; exit 1; }
case "$VERSION" in
    v*) : ;;
    *)  echo "error: version must start with 'v' (got '$VERSION')" >&2; exit 1 ;;
esac

[ -d "$ORT_SRC" ] || { echo "error: submodule missing at $ORT_SRC" >&2; exit 1; }

current="$(tr -d '[:space:]' < "$ORT_VERSION_FILE")"
echo "==> current version: $current"

echo "==> verifying $VERSION exists upstream"
if ! git -C "$ORT_SRC" ls-remote --exit-code --tags origin "refs/tags/${VERSION}" >/dev/null 2>&1; then
    echo "error: tag '$VERSION' not found on the onnxruntime remote" >&2
    echo "       available tags: git -C $ORT_SRC ls-remote --tags origin | tail" >&2
    exit 1
fi

echo "==> writing $ORT_VERSION_FILE"
printf '%s\n' "$VERSION" > "$ORT_VERSION_FILE"

if [ "$SKIP_SUBMODULES" -eq 1 ]; then
    echo "==> --skip-submodules given, leaving the checkout untouched"
    echo "done. ORT_VERSION is now $VERSION"
    exit 0
fi

echo "==> fetching $VERSION"
git -C "$ORT_SRC" fetch --depth 1 origin "refs/tags/${VERSION}:refs/tags/${VERSION}" \
    || git -C "$ORT_SRC" fetch origin --tags --force

echo "==> checking out $VERSION"
git -C "$ORT_SRC" checkout --detach "$VERSION"

echo "==> refreshing recursive dependencies"
git -C "$ORT_SRC" submodule update --init --recursive --depth 1 --jobs 8 \
    || git -C "$ORT_SRC" submodule update --init --recursive

# A new runtime can fuse differently, so the allow list is refreshed here. It is
# advisory: bumping the version is already done at this point, and the file is
# checked in, so warn instead of failing the bump. The release workflow's model
# smoke test is the real guard against shipping a stale list.
if [ "$SKIP_OPS_CONFIG" -eq 1 ]; then
    echo "==> --skip-ops-config given, keeping the current operator allow list"
else
    echo "==> regenerating the operator allow list"
    if ! "$SCRIPT_DIR/gen_required_ops.sh"; then
        echo "warning: could not regenerate required_operators.config" >&2
        echo "         run onnxruntime/scripts/gen_required_ops.sh before releasing" >&2
    fi
fi

echo
echo "onnxruntime bumped to $VERSION ($(git -C "$ORT_SRC" rev-parse --short HEAD))"
echo
echo "next steps:"
echo "  cd onnxruntime && ./build.sh --jobs 4        # verify the build locally"
echo "  git add onnxruntime/ORT_VERSION onnxruntime/onnxruntime onnxruntime/required_operators.config"
echo "  git commit -m 'onnxruntime: bump to $VERSION'"
echo "  git tag release-$VERSION && git push origin main --tags"
