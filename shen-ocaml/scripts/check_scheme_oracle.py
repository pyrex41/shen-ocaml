#!/usr/bin/env python3
"""Check the shared KL corpus against an explicitly supplied upstream Scheme build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

PIN = "8d261518db17fbfec32d1b268b40ed216b925c74"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--kernel-suite", action="store_true")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if commit != PIN:
        parser.error(f"expected upstream revision {PIN}, got {commit}")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=checkout, check=True)
    root = Path(__file__).resolve().parents[1]
    fixture = root / "test/fixtures/native.kl"
    # JSON quoting is sufficient for this ASCII fixture path; reject quote/backslash
    # paths rather than silently mis-escaping Shen's byte-string reader.
    if any(c in str(fixture) for c in ['"', "\\", "\n"]):
        parser.error("fixture path cannot contain quotes, backslashes or newlines")
    command = [str(checkout / "_build/bin/shen-scheme"), "eval", "-e",
               f'(map (fn eval-kl) (read-from-string-unprocessed (read-file-as-string "{fixture}")))']
    references = root / "test/fixtures/native_refs.shen"
    command += ["-e", f'(load "{references}")']
    if args.kernel_suite:
        canonical = checkout / "ShenOSKernel-43.1/tests"
        for path in (root / "test/shen").glob("*.shen"):
            if path.name in ["harness.shen", "tiny.shen"]:
                continue
            reference = canonical / path.name
            if not reference.exists() or path.read_bytes().rstrip() != reference.read_bytes().rstrip():
                parser.error(f"vendored test differs from canonical 43.1: {path.name}")
        command += ["-e", '(load "harness.shen")', "-e", '(load "kerneltests.shen")']
    command += ["-e", '(output "~%ORACLE_RESULT corpus=pass~%")']
    started = time.perf_counter()
    result = subprocess.run(command, cwd=root / "test/shen" if args.kernel_suite else checkout,
                            text=True, capture_output=True, timeout=args.timeout)
    passed = result.returncode == 0 and "ORACLE_RESULT corpus=pass" in result.stdout
    totals = {}
    if args.kernel_suite:
        matches = re.findall(r"passed \.\.\. (\d+)\s+failed \.\.\. (\d+)", result.stdout)
        if matches:
            totals = dict(zip(["passed", "failed"], map(int, matches[-1])))
        passed = passed and totals == dict(passed=154, failed=0)
    print(json.dumps(dict(status="pass" if passed else "fail", commit=commit,
                          fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
                          wall_s=round(time.perf_counter() - started, 6),
                          returncode=result.returncode, **totals)))
    if not passed:
        print(result.stdout + result.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
