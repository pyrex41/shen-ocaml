#!/bin/bash
# Wrapper to run Shen REPL with piped input, avoiding cursor-agent hanging on nix.
# Usage: echo '(+ 1 1)' | bin/run-shen.sh
# Or:    bin/run-shen.sh '(+ 1 1)' '(value *version*)'
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
  # Args mode: each arg is a Shen expression
  for expr in "$@"; do echo "$expr"; done | \
    timeout 60 nix develop --command bash -c './_build/default/bin/main.exe' 2>&1 | \
    grep -v "^warning:" | grep -v "^shen-ocaml dev shell" | grep -v "^  ocaml:" | grep -v "^  dune:"
else
  # Stdin mode
  timeout 60 nix develop --command bash -c './_build/default/bin/main.exe' 2>&1 | \
    grep -v "^warning:" | grep -v "^shen-ocaml dev shell" | grep -v "^  ocaml:" | grep -v "^  dune:"
fi
