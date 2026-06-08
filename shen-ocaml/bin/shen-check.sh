#!/bin/bash
# Gate 4: Verify Shen specs with tc+ (sequent-calculus type checker)
# Uses shen-sbcl to load specs with type checking enabled.
set -euo pipefail

SPEC="${1:-specs/core.shen}"

if ! command -v shen-sbcl &>/dev/null; then
  echo "ERROR: shen-sbcl not found. Install via: brew tap Shen-Language/homebrew-shen && brew install shen-sbcl"
  echo "RESULT: FAIL"
  exit 1
fi

if [ ! -f "$SPEC" ]; then
  echo "ERROR: spec file not found: $SPEC"
  echo "RESULT: FAIL"
  exit 1
fi

echo "shen-check: verifying $SPEC with tc+"

# Run shen-sbcl with type checking enabled, load the spec.
# -l prevents the REPL from starting, so it exits after loading.
# Timeout after 30 seconds to prevent hangs.
timeout 30 shen-sbcl -q -e "(tc +)" -l "$SPEC" 2>&1
STATUS=$?

if [ $STATUS -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL (exit code $STATUS)"
  exit 1
fi
