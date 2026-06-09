#!/usr/bin/env bash
# Run the Phase C typed-vs-erased benchmark, self-labeling the toolchain so the
# numbers are unambiguous. On a flambda compiler it builds with the optimizing
# `flambda` profile (dune/dune-project `(env (flambda ...))`); otherwise it builds
# with defaults and prints a clear non-flambda note. Never fabricates numbers.
set -euo pipefail
cd "$(dirname "$0")/.."

FLAMBDA=$(ocamlopt -config 2>/dev/null | awk '/^flambda:/ {print $2}')
OCAMLV=$(ocamlopt -version 2>/dev/null || echo "?")
echo "toolchain: ocaml ${OCAMLV}, flambda=${FLAMBDA}"

if [ "${FLAMBDA}" = "true" ]; then
  echo "building with --profile flambda (-O3 -inline 1000 -unsafe)"
  dune build --profile flambda bench/typed_vs_erased/bench_main.exe
  EXE=_build/flambda/bench/typed_vs_erased/bench_main.exe
else
  echo "NOTE: flambda not present — these are NON-FLAMBDA numbers (a floor)."
  echo "      reproduce the canonical figures on a flambda 5.3 host (see FLAMBDA.md)."
  dune build bench/typed_vs_erased/bench_main.exe
  EXE=_build/default/bench/typed_vs_erased/bench_main.exe
fi

"${EXE}" 2>&1 | grep -vE "Native overwrite|Primitives init"
