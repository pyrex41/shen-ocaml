#!/usr/bin/env python3
"""Qualify typed native staging/loading and matching semantic rejection on Chez."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile

PIN = "8d261518db17fbfec32d1b268b40ed216b925c74"


def run(command, cwd, timeout=90):
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        raise RuntimeError("typed qualification timeout\n" + stdout + stderr)
    if process.returncode:
        raise RuntimeError(stdout + stderr)
    return stdout + stderr


def quote(path):
    value = str(path)
    if any(c in value for c in ['"', "\\", "\n", "\r"]):
        raise ValueError("unsupported Shen source path")
    return '"' + value + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    oracle = args.oracle.resolve()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=oracle, text=True).strip()
    if commit != PIN:
        parser.error(f"expected pinned upstream {PIN}, got {commit}")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=oracle, check=True)
    run(["nix", "develop", "--command", "dune", "build", "--profile", "release",
         "test/test_native_typed_staging.exe"], root, 180)
    parent = root / "_build/qualification"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="native-typed-", dir=parent))
    executable = str(root / "_build/default/test/test_native_typed_staging.exe")
    result = run(["nix", "develop", "--command", executable, str(output)], root)
    if "NATIVE_TYPED_STAGING pass" not in result:
        raise RuntimeError(result)
    print(result)
    artifacts = list(output.glob("*.cmxs"))
    if len(artifacts) != 1:
        raise RuntimeError("expected one typed native artifact")
    fresh = run([executable, "--load-only", str(artifacts[0])], root)
    if "NATIVE_TYPED_FRESH_HOST pass" not in fresh:
        raise RuntimeError(fresh)
    fixture = root / "test/fixtures/native_typed_staging.shen"
    command = [str(oracle / "_build/bin/shen-scheme"), "eval", "-e", "(tc +)",
               "-e", f"(load {quote(fixture)})",
               "-e", '(if (= (native-typed-call 40) 42) true (simple-error "typed call"))',
               "-e", '(if (= (native-typed-length [1 2]) 2) true (simple-error "typed list"))',
               "-e", '(if (native-typed-even 100) true (simple-error "typed mutual"))',
               "-e", '(if (= (native-typed-zero) 42) true (simple-error "typed zero"))']
    command += ["-e", '(if (= ((native-typed-lambda 42) 17) 17) true (simple-error "typed lambda"))']
    for index, body in enumerate(["true", "(+ X true)", '(+ X "bad")']):
        invalid = output / f"invalid-{index}.shen"
        invalid.write_text(f"(define native-typed-invalid-{index} {{ number --> number }} X -> {body})\n")
        # Untyped loading must succeed, then genuinely typed loading must fail.
        command += ["-e", "(tc -)", "-e", f"(load {quote(invalid)})", "-e", "(tc +)",
                    "-e", f'(if (= (trap-error (load {quote(invalid)}) (/. E rejected)) rejected) true (simple-error "invalid typed definition accepted"))']
    command += ["-e", '(output "~%TYPED_ORACLE_DONE~%")']
    checked = run(command, root)
    if "TYPED_ORACLE_DONE" not in checked:
        raise RuntimeError(checked)
    (output / "scheme.log").write_text(checked)
    print(json.dumps(dict(status="pass", native="pass", fresh_host="pass", oracle="pass",
                          oracle_commit=commit, artifact=str(artifacts[0]))))


if __name__ == "__main__":
    main()
