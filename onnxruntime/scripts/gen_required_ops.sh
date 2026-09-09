#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Regenerate onnxruntime/required_operators.config, the operator allow list the
# ORT build is reduced to (--include_ops_by_config).
#
# Run this whenever the DeepDoc weights change. A model that needs an operator
# missing from the list fails at runtime with "Could not find an implementation
# for <Op>(<opset>)", so a stale list ships a build that cannot serve.
#
# Requires python with `onnxruntime` and `onnx` installed:
#   pip install onnxruntime onnx
#
# Usage:
#   ./gen_required_ops.sh                      # download the models from the Hub
#   ./gen_required_ops.sh --models /path/dir   # use local .onnx models
#   ./gen_required_ops.sh --repo InfiniFlow/deepdoc
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
while [ -L "$SCRIPT_PATH" ]; do
    link_target="$(readlink "$SCRIPT_PATH")"
    case "$link_target" in
        /*) SCRIPT_PATH="$link_target" ;;
        *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$link_target" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Base names (without extension) of the DeepDoc weights the Go backend loads,
# plus the layout domain variants that ship alongside layout.onnx.
MODELS="det rec tsr layout layout.laws layout.manual layout.paper"

HF_REPO="InfiniFlow/deepdoc"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"
MODELS_DIR=""
OUTPUT="$PKG_DIR/required_operators.config"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --models <dir>    Directory with the .onnx models to inspect.
                    Default: download $MODELS from '$HF_REPO'.
  --repo <id>       Hugging Face repo holding the .onnx weights. Default: $HF_REPO
  --output <file>   Where to write the allow list. Default: $OUTPUT
  -h, --help        Show this help.

Set HF_ENDPOINT to use a mirror (e.g. https://hf-mirror.com).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --models) [ $# -ge 2 ] || die "--models requires a value"; MODELS_DIR="$2"; shift 2 ;;
        --repo)   [ $# -ge 2 ] || die "--repo requires a value";   HF_REPO="$2";   shift 2 ;;
        --output) [ $# -ge 2 ] || die "--output requires a value"; OUTPUT="$2";    shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || die "python3 is required"

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# collect the .onnx models
# ---------------------------------------------------------------------------
if [ -n "$MODELS_DIR" ]; then
    [ -d "$MODELS_DIR" ] || die "--models directory '$MODELS_DIR' does not exist"
    MODEL_SRC="$MODELS_DIR"
    info "using .onnx models from $MODEL_SRC"
else
    MODEL_SRC="$WORK_DIR/models"
    mkdir -p "$MODEL_SRC"
    for name in $MODELS; do
        info "downloading $name.onnx from $HF_REPO"
        # --retry alone does not cover transport errors such as
        # "SSL_ERROR_SYSCALL"; these are 100 MB+ of weights.
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --max-time 600 \
            -o "$MODEL_SRC/$name.onnx" \
            "$HF_ENDPOINT/$HF_REPO/resolve/main/$name.onnx" \
            || die "failed to download $name.onnx (set HF_ENDPOINT for a mirror)"
    done
fi

found=0
for name in $MODELS; do
    [ -f "$MODEL_SRC/$name.onnx" ] || continue
    found=$((found + 1))
done
[ "$found" -gt 0 ] || die "no DeepDoc .onnx models found in $MODEL_SRC"

# ---------------------------------------------------------------------------
# generate the allow list
# ---------------------------------------------------------------------------
# The conversion tool is what emits the required-operator config; it only reads
# .onnx inputs, so it is used here purely as the operator extractor. The
# converted .ort files are discarded - the tool writes the config next to them.
CONVERT_DIR="$WORK_DIR/converted"
mkdir -p "$CONVERT_DIR"

info "extracting required operators"
"$PYTHON" -m onnxruntime.tools.convert_onnx_models_to_ort \
    "$MODEL_SRC" --output_dir "$CONVERT_DIR" \
    || die "conversion failed; is 'pip install onnxruntime onnx' done?"

# Without --enable_type_reduction the file is required_operators.config (the
# safer variant: it does not restrict per-operator types).
GEN=""
for candidate in "$CONVERT_DIR/required_operators.config" \
                 "$CONVERT_DIR/required_operators_and_types.config"; do
    [ -f "$candidate" ] && GEN="$candidate" && break
done
[ -n "$GEN" ] || die "no required_operators*.config produced in $CONVERT_DIR"

cp "$GEN" "$OUTPUT"
info "wrote $OUTPUT"
echo
echo "Review the diff before committing; in particular make sure the"
echo "'com.microsoft' line is still present (PaddlePaddle fused kernels)."
