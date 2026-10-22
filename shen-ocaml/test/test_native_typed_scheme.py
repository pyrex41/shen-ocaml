#!/usr/bin/env python3
"""Explicit Scheme oracle for the restricted typed fixture; no Scheme build."""
from pathlib import Path
import subprocess
import sys

fixture = Path(__file__).resolve().parent / "fixtures/native_typed_staging.shen"
if any(c in str(fixture) for c in ['"', "\\", "\n"]):
    raise SystemExit("unsupported fixture path")
expressions = [
    "(tc +)",
    f'(load "{fixture}")',
    '(if (= (native-typed-call 40) 42) (output "TYPED_CALL_PASS~%") (simple-error "call"))',
    '(if (= (native-typed-length [1 2]) 2) (output "TYPED_LIST_PASS~%") (simple-error "list"))',
    '(if (native-typed-even 100) (output "TYPED_MUTUAL_PASS~%") (simple-error "mutual"))',
    '(if (= (native-typed-zero) 42) (output "TYPED_ZERO_PASS~%") (simple-error "zero"))',
]
for body in ["true", "(+ X true)"]:
    source = f"(define native-typed-bad {{ number --> number }} X -> {body})"
    escaped = source.replace('"', '\\"')
    expressions.append(
        f'(trap-error (shen.typecheck (hd (read-from-string "{escaped}")) A) '
        '(lambda E (error-to-string E)))'
    )
command = [sys.argv[1], "eval"]
for expression in expressions:
    command.extend(["-e", expression])
result = subprocess.run(command, text=True, capture_output=True, timeout=60)
output = result.stdout + result.stderr
print(output, end="")
assert result.returncode == 0, result.returncode
for marker in ["TYPED_CALL_PASS", "TYPED_LIST_PASS", "TYPED_MUTUAL_PASS", "TYPED_ZERO_PASS"]:
    assert marker in output, marker
assert output.count("type error in rule 1 of native-typed-bad") == 2
print("NATIVE_TYPED_SCHEME_ORACLE pass")
