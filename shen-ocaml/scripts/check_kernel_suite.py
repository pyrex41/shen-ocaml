#!/usr/bin/env python3
"""Run the opt-in canonical suite with a hard execution deadline and honest totals."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["legacy", "native"], default="native")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    root = Path(__file__).resolve().parents[1]
    env = dict(os.environ, SHEN_FULL_KERNEL_TESTS="true",
               SHEN_KERNEL_BACKEND=args.backend, SHEN_KERNEL_DIR=str(root / "kernel"),
               SHEN_TEST_DIR=str(root / "test/shen"))
    target = "test/test_kernel_shen_suite.exe"
    subprocess.run(["nix", "develop", "--command", "dune", "build", "--profile", "release", target],
                   cwd=root, env=env, check=True, timeout=180)
    log_dir = root / "_build" / "qualification"
    log_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w+", suffix=".log", prefix=f"kernel-{args.backend}-",
                                     dir=log_dir, delete=False) as log:
        started = time.perf_counter()
        process = subprocess.Popen([str(root / "_build/default" / target)], cwd=root,
                                   env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        timed_out = False
        try:
            process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        log.seek(0)
        text = log.read()
        matches = re.findall(r"KERNEL_RESULT passed=(\d+) failed=(\d+)", text)
        totals = dict(zip(["passed", "failed"], map(int, matches[-1]))) if matches else {}
        status = "timeout" if timed_out else (
            "pass" if process.returncode == 0 and totals.get("passed") == 154
            and totals.get("failed") == 0 else "fail")
        print(json.dumps(dict(backend=args.backend, status=status, returncode=process.returncode,
                              wall_s=round(time.perf_counter() - started, 6),
                              expected=154,
                              suite_sha256=hashlib.sha256((root / "test/shen/kerneltests.shen").read_bytes()).hexdigest(),
                              log=log.name, **totals)))
        if status != "pass":
            print("\n".join(text.splitlines()[-30:]), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
