#!/bin/bash
# Run Shen REPL from the test/shen directory so (load ...) finds test files.
# Usage: bin/run-shen-test.sh '(load "cartprod.shen")' '(cartesian-product [1 2 3] [1 2 3])'
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export SHEN_KERNEL_DIR="$PROJECT_DIR/kernel"
cd "$PROJECT_DIR/test/shen"

if [ $# -gt 0 ]; then
  for expr in "$@"; do echo "$expr"; done | \
    timeout 120 nix develop "$PROJECT_DIR" --command bash -c "$PROJECT_DIR/_build/default/bin/main.exe" 2>&1 | \
    grep -v "^warning:" | grep -v "^shen-ocaml dev shell" | grep -v "^  ocaml:" | grep -v "^  dune:"
else
  timeout 120 nix develop "$PROJECT_DIR" --command bash -c "$PROJECT_DIR/_build/default/bin/main.exe" 2>&1 | \
    grep -v "^warning:" | grep -v "^shen-ocaml dev shell" | grep -v "^  ocaml:" | grep -v "^  dune:"
fi
