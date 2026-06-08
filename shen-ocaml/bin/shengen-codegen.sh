#!/bin/bash
# Gate 1: Regenerate OCaml guard types from Shen specs.
# Usage: shengen-codegen.sh [spec.shen] [output-base]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="${1:-specs/core.shen}"
OUTPUT="${2:-src/generated/guard_types}"

echo "shengen-codegen: generating from $SPEC -> ${OUTPUT}.ml / ${OUTPUT}.mli"

python3 "$SCRIPT_DIR/shengen-ocaml" "$SPEC" "$OUTPUT"

echo "shengen-codegen: done"
