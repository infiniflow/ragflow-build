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

# --- credentials -------------------------------------------------------------
# `actions/checkout` authenticates only the repository it checked out: it writes
# an `http.https://github.com/.extraheader` entry into that repository's config,
# and `git submodule update` replays the entries of that config into the child
# git process through GIT_CONFIG_PARAMETERS. Git for Windows hands the replayed
# value to the network layer mangled, GitHub answers 401 and git asks for a
# username CI cannot supply:
#   fatal: could not read Username for 'https://github.com'
#   fatal: Cannot prompt because user interactivity has been disabled
# The submodules are public upstream repositories, so the inherited credentials
# are not needed: drop the replay variable and fall back to the workflow token
# only if anonymous access is refused.
unset GIT_CONFIG_PARAMETERS
export GIT_TERMINAL_PROMPT=0

SUBMODULE_TOKEN_ARGS=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    SUBMODULE_TOKEN_ARGS=(-c "http.https://github.com/.extraheader=AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')")
fi

submodule_update() {
    if git submodule update "$@"; then
        return 0
    fi
    echo "==> submodule update failed; checking the credentials in play" >&2
    if git config --get-all 'http.https://github.com/.extraheader' >/dev/null 2>&1; then
        echo "    the parent repository still carries an http.extraheader entry" >&2
    fi
    if [ ${#SUBMODULE_TOKEN_ARGS[@]} -gt 0 ]; then
        echo "==> retrying with the workflow token" >&2
        git "${SUBMODULE_TOKEN_ARGS[@]}" submodule update "$@"
        return
    fi
    echo "error: submodule update failed and GITHUB_TOKEN is not set to retry" >&2
    return 1
}

echo "==> syncing submodules"
git submodule sync --recursive

if [ "$SHALLOW" -eq 1 ]; then
    submodule_update --init --depth 1 "$ORT_SUBMODULE" || submodule_update --init "$ORT_SUBMODULE"
else
    submodule_update --init "$ORT_SUBMODULE"
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
    submodule_update --init --recursive
else
    submodule_update --init --recursive --depth 1 --jobs 8 \
        || submodule_update --init --recursive
fi

echo "==> onnxruntime ready at $(pwd) ($(git rev-parse HEAD))"
