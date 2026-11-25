#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fetch the onnxruntime submodule and pin it to the version recorded in
# onnxruntime/ORT_VERSION, then pull the recursive build dependencies.
#
# The source comes from the gitcode.com mirror of the upstream repository, as
# recorded in the repo root `.gitmodules`: github.com/microsoft/onnxruntime is
# no longer reachable and the mirror is the only place the tree is published.
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
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "error: unknown option $arg" >&2; exit 1 ;;
    esac
done

cd "$REPO_ROOT"

# --- credentials -------------------------------------------------------------
# `actions/checkout` authenticates only the repository it checked out: it writes
# `http.https://github.com/.extraheader` into that repository's config.
# `git submodule update` reads that entry from the parent config and replays it
# into the child clone -- not through the environment, so unsetting
# GIT_CONFIG_PARAMETERS changes nothing. On Git for Windows the replayed value
# breaks the request (GitHub answers 401 and git asks for a username CI cannot
# supply), and adding a second header on top makes the request carry two
# Authorization headers, which GitHub reports as "Repository not found".
#
# The submodules are public upstream repositories, so the inherited credentials
# are not needed at all: delete them and authenticate with the workflow token as
# the only header, and only if anonymous access is refused.
git config --local --unset-all 'http.https://github.com/.extraheader' 2>/dev/null || true
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
    if [ ${#SUBMODULE_TOKEN_ARGS[@]} -gt 0 ]; then
        echo "==> anonymous clone refused, retrying with the workflow token" >&2
        git "${SUBMODULE_TOKEN_ARGS[@]}" submodule update "$@"
        return
    fi
    echo "error: submodule update failed and GITHUB_TOKEN is not set to retry" >&2
    return 1
}

# `.gitmodules` is the only place the source URL lives (no second copy here), so
# a missing entry is an error rather than a silent fallback to the dead upstream.
ORT_GIT_URL="$(git config -f .gitmodules --get "submodule.${ORT_SUBMODULE}.url" 2>/dev/null || true)"
if [ -z "$ORT_GIT_URL" ]; then
    echo "error: submodule.${ORT_SUBMODULE}.url is missing from .gitmodules" >&2
    exit 1
fi

# `git clone` runs as its own repository: it reads the global configuration
# only, so the parent `.git/config` (and the credentials `actions/checkout` put
# there) never reach it. A fresh CI workspace has nothing to update, so clone
# directly instead of going through `git submodule`, which is exactly the path
# that replays the parent config into the child git process.
clone_ort_directly() {
    local depth=()
    [ "$SHALLOW" -eq 1 ] && depth=(--depth 1)
    echo "==> cloning $ORT_GIT_URL at $ORT_VERSION"
    rm -rf "$ORT_SUBMODULE"
    mkdir -p "$(dirname "$ORT_SUBMODULE")"
    if git clone ${depth[@]+"${depth[@]}"} --branch "$ORT_VERSION" "$ORT_GIT_URL" "$ORT_SUBMODULE"; then
        return 0
    fi
    [ ${#SUBMODULE_TOKEN_ARGS[@]} -gt 0 ] || return 1
    echo "==> anonymous clone refused, retrying with the workflow token" >&2
    rm -rf "$ORT_SUBMODULE"
    git "${SUBMODULE_TOKEN_ARGS[@]}" clone ${depth[@]+"${depth[@]}"} \
        --branch "$ORT_VERSION" "$ORT_GIT_URL" "$ORT_SUBMODULE"
}

# A submodule that is already initialised has its git directory here. Updating
# it is the normal developer flow and keeps the working tree a real submodule;
# only a fresh workspace takes the clone path above.
if [ -d "$REPO_ROOT/.git/modules/$ORT_SUBMODULE" ]; then
    echo "==> syncing submodules"
    git submodule sync --recursive
    if [ "$SHALLOW" -eq 1 ]; then
        submodule_update --init --depth 1 "$ORT_SUBMODULE" \
            || submodule_update --init "$ORT_SUBMODULE" \
            || clone_ort_directly
    else
        submodule_update --init "$ORT_SUBMODULE" || clone_ort_directly
    fi
else
    clone_ort_directly
fi

cd "$ORT_SUBMODULE"

echo "==> pinning onnxruntime to $ORT_VERSION"
# The clone above already carries the tag; only a pre-existing submodule
# worktree (shallow, no tags) needs the explicit fetch.
if ! git rev-parse -q --verify "refs/tags/${ORT_VERSION}" >/dev/null 2>&1; then
    git fetch --depth 1 origin "refs/tags/${ORT_VERSION}:refs/tags/${ORT_VERSION}" \
        || git fetch origin --tags --force
fi
git checkout --detach "$ORT_VERSION"

# Apply vendored patches on top of the pinned tag. The upstream tree is the
# pristine onnxruntime (mirrored on gitcode.com); custom changes (e.g. the
# shared-initializer APIs) live as patches under onnxruntime/patches so they
# survive a clean checkout and the CI rebuild (which re-fetches the tag).
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
