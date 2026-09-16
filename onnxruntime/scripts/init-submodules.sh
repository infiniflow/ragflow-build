#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fetch the onnxruntime submodule and pin it to the version recorded in
# onnxruntime/ORT_VERSION, then pull the recursive build dependencies.
#
# Handles the shallow-clone case where the tag ref is not fetched by default.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"        # <repo>/onnxruntime
REPO_ROOT="$(cd "$PKG_DIR/.." && pwd)"         # <repo>
ORT_SUBMODULE="onnxruntime/onnxruntime"        # path relative to REPO_ROOT
ORT_VERSION="$(tr -d '[:space:]' < "$PKG_DIR/ORT_VERSION")"

SHALLOW=1
FULL=0
for arg in "$@"; do
    case "$arg" in
        --full)   FULL=1; SHALLOW=0 ;;
        --depth)  SHALLOW=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "error: unknown option $arg" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

echo "==> syncing submodules"
git submodule sync --recursive

if [ "$SHALLOW" -eq 1 ]; then
    git submodule update --init --depth 1 "$ORT_SUBMODULE" || git submodule update --init "$ORT_SUBMODULE"
else
    git submodule update --init "$ORT_SUBMODULE"
fi

cd "$ORT_SUBMODULE"

echo "==> pinning onnxruntime to $ORT_VERSION"
git fetch --depth 1 origin "refs/tags/${ORT_VERSION}:refs/tags/${ORT_VERSION}" \
    || git fetch origin --tags --force
git checkout --detach "$ORT_VERSION"

# Apply vendored patches on top of the pinned tag. The upstream onnxruntime is
# pristine microsoft/onnxruntime; custom changes (e.g. the shared-initializer
# APIs) live as patches under onnxruntime/patches so they survive a clean
# checkout and the CI rebuild (which re-fetches the upstream tag from scratch).
PATCH_DIR="$PKG_DIR/patches"
if [ -d "$PATCH_DIR" ]; then
    shopt -s nullglob
    for p in "$PATCH_DIR"/*.patch; do
        echo "==> applying vendor patch $(basename "$p")"
        git apply --whitespace=nowarn "$p" || {
            echo "::error::failed to apply vendored patch $p"
            exit 1
        }
    done
    shopt -u nullglob
fi

echo "==> fetching recursive dependencies"
if [ "$FULL" -eq 1 ]; then
    git submodule update --init --recursive
else
    git submodule update --init --recursive --depth 1 --jobs 8 \
        || git submodule update --init --recursive
fi

echo "==> onnxruntime ready at $(pwd) ($(git rev-parse HEAD))"
