#!/usr/bin/env python3
"""Strict post-expansion native promotion API/CLI qualification."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from check_native_typed import run


def main():
    root = Path(__file__).resolve().parents[1]
    run(["nix", "develop", "--command", "dune", "build", "--profile", "release",
         "test/test_native_promote.exe", "bin/main.exe"], root, 180)
    parent = root / "_build/qualification"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="native-promotion-", dir=parent))
    result = run(["nix", "develop", "--command",
                  str(root / "_build/default/test/test_native_promote.exe"), str(directory)], root)
    (directory / "api.log").write_text(result)
    if "NATIVE_PROMOTE_RESULT" not in result:
        raise RuntimeError(result)
    fixture = directory / "cli.shen"
    fixture.write_text('''(set cli-promote-count (+ (trap-error (value cli-promote-count) (/. E 0)) 1))
(define cli-promote-add X -> (+ X 2))
''')
    command = ["nix", "develop", "--command", str(root / "_build/default/bin/main.exe"),
               "eval-promoted", str(fixture), str(directory),
               '(if (= (value cli-promote-count) 1) (cli-promote-add 40) (simple-error "source replay"))']
    cli = run(command, root)
    (directory / "cli.log").write_text(cli)
    if not cli.strip().endswith("42"):
        raise RuntimeError(cli)
    # A compiler failure must fail the command, not silently run the dynamic tier.
    failed = subprocess.run(command, cwd=root,
        env=dict(os.environ, SHEN_OCAML_OCAMLOPT="/usr/bin/false"),
        text=True, capture_output=True, timeout=60)
    (directory / "compiler-failure.log").write_text(failed.stdout + failed.stderr)
    if failed.returncode != 1 or "Error:" not in failed.stderr or "42" in failed.stdout.splitlines():
        raise RuntimeError("CLI hid a promotion compilation failure")
    print(result)
    print(json.dumps(dict(status="pass", api="pass", cli="pass", failure_visible="pass", logs=str(directory))))


if __name__ == "__main__":
    main()
