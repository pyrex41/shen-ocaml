#!/usr/bin/env bash
# Emit OCaml [kl_expr list] modules for every kernel .kl file (same order as Interp.Boot).
# Usage: from repo root, after `dune build tools/gen_kl_forms.exe`:
#   ./bin/emit-all-kernel-ml.sh [output_dir]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-${ROOT}/src/generated/kernel_ml}"
mkdir -p "$OUT"
EXE="${ROOT}/_build/default/tools/gen_kl_forms.exe"
if [[ ! -x "$EXE" ]]; then
  echo "build gen_kl_forms first: dune build tools/gen_kl_forms.exe" >&2
  exit 1
fi
klfiles=(
  core.kl
  toplevel.kl
  sys.kl
  reader.kl
  prolog.kl
  load.kl
  writer.kl
  macros.kl
  declarations.kl
  types.kl
  t-star.kl
  sequent.kl
  track.kl
  dict.kl
  compiler.kl
  stlib.kl
  init.kl
  extension-features.kl
  extension-expand-dynamic.kl
  extension-launcher.kl
  yacc.kl
)
for base in "${klfiles[@]}"; do
  kl="${ROOT}/kernel/${base}"
  stem="${base%.kl}"
  # Valid OCaml module basename (hyphens → underscores)
  mod="${stem//-/_}_forms"
  echo "emit ${base} -> ${mod}.ml"
  "$EXE" "$kl" "${OUT}/${mod}.ml"
done
echo "Wrote ${#klfiles[@]} modules under ${OUT}"
