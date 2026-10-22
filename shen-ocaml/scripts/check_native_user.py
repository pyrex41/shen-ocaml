#!/usr/bin/env python3
"""Compile actual Shen functions, load native code, and verify it in a fresh host."""
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    targets = ["test/test_native_user_slice.exe", "bin/main.exe"]
    subprocess.run(["nix", "develop", "--command", "dune", "build", "--profile", "release", *targets],
                   cwd=root, check=True, timeout=180)
    output_parent = root / "_build/qualification"
    output_parent.mkdir(parents=True, exist_ok=True)
    output_dir = Path(tempfile.mkdtemp(prefix="native-user-", dir=output_parent))
    test = str(root / "_build/default/test/test_native_user_slice.exe")
    result = subprocess.run(["nix", "develop", "--command", test, str(output_dir)],
                            cwd=root, text=True, capture_output=True, timeout=60)
    if result.returncode or "NATIVE_USER_RESULT native=pass" not in result.stdout:
        raise RuntimeError(result.stdout + result.stderr)
    print(result.stdout)
    plugins = list(output_dir.glob("*.cmxs"))
    if len(plugins) != 1:
        raise RuntimeError("expected exactly one native fixture artifact")
    fresh = subprocess.run([test, "--load-only", str(plugins[0])], cwd=root, text=True,
                           capture_output=True, timeout=30)
    if fresh.returncode or "NATIVE_USER_FRESH_HOST_RESULT" not in fresh.stdout:
        raise RuntimeError(fresh.stdout + fresh.stderr)
    print(fresh.stdout)
    cli = str(root / "_build/default/bin/main.exe")
    loaded = subprocess.run([cli, "eval-native", str(plugins[0]), "(native-slice-caller 40)"],
                            cwd=root, text=True, capture_output=True, timeout=30)
    if loaded.returncode or loaded.stdout.strip() != "42":
        raise RuntimeError(loaded.stdout + loaded.stderr)
    sealed_dir = output_dir / "sealed"
    compiled = subprocess.run(["nix", "develop", "--command", cli, "compile-native", "--sealed",
                               "test/fixtures/native_user_numeric.shen", str(sealed_dir)],
                              cwd=root, text=True, capture_output=True, timeout=60)
    if compiled.returncode:
        raise RuntimeError(compiled.stdout + compiled.stderr)
    sealed_plugin = Path(compiled.stdout.splitlines()[-1])
    if not sealed_plugin.is_file():
        raise RuntimeError("CLI did not produce its reported plugin")
    if "numeric_f" not in sealed_plugin.with_suffix(".ml").read_text():
        raise RuntimeError("sealed numeric source did not produce an unboxed worker")
    loaded = subprocess.run([cli, "eval-native", str(sealed_plugin), "(native-fast-sum 20000 0)"],
                            cwd=root, text=True, capture_output=True, timeout=30)
    if loaded.returncode or loaded.stdout.strip() != "200010000":
        raise RuntimeError(loaded.stdout + loaded.stderr)
    print(json.dumps(dict(status="pass", fresh_host="pass", cli="pass", artifact=str(plugins[0]))))


if __name__ == "__main__":
    main()
