#!/usr/bin/env python3
"""Repeat the checked backend benchmark; record samples, medians and source identity."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess


def fingerprint(root):
    paths = set()
    for pattern in ["src/**/*.ml", "src/**/*.mli", "src/**/dune", "bin/*.ml", "bin/dune", "tools/*.ml",
                    "tools/dune", "native_kernel/dune", "bench/*.ml", "bench/*.kl", "bench/dune"]:
        paths.update(root.glob(pattern))
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--seed", type=int, default=431)
    parser.add_argument("--output", type=Path, default=Path("_build/qualification/backend-comparison.json"))
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("use at least three independent process runs")
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["nix", "develop", "--command", "dune", "build", "--profile", "release",
                    "bench/compare_native.exe"], cwd=root, check=True, timeout=180)
    samples = []
    compiler = None
    orders = []
    for run in range(args.runs):
        output = subprocess.check_output([str(root / "_build/default/bench/compare_native.exe"),
                                          "--seed", str(args.seed + run)],
                                         cwd=root, text=True, timeout=60)
        rows = []
        for line in output.splitlines():
            if line.startswith("# ocaml="):
                compiler = line.removeprefix("# ocaml=")
            if line.startswith("# order="):
                orders.append(line.removeprefix("# order=").split(","))
            if not line.startswith("RESULT\t"):
                continue
            _, mode, workload, reps, wall, cpu, allocated = line.split("\t")
            rows.append(dict(run=run, mode=mode, workload=workload, repetitions=int(reps),
                             wall_s=float(wall), cpu_s=float(cpu), allocated_bytes=int(allocated)))
        if len(rows) != 16:
            raise RuntimeError(f"expected 16 checked workload rows, received {len(rows)}")
        samples.extend(rows)
    summaries = []
    for mode, workload in sorted({(row["mode"], row["workload"]) for row in samples}):
        rows = [row for row in samples if row["mode"] == mode and row["workload"] == workload]
        summary = dict(mode=mode, workload=workload)
        for key in ["wall_s", "cpu_s", "allocated_bytes"]:
            values = [row[key] for row in rows]
            summary[key] = dict(median=statistics.median(values), min=min(values), max=max(values))
        summaries.append(summary)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True))
    report = dict(platform=platform.platform(), machine=platform.machine(), ocaml=compiler, revision=revision,
                  dirty=dirty, source_sha256=fingerprint(root), runs=args.runs, seed=args.seed, orders=orders,
                  boundaries="checked microbenchmarks; reproducibly shuffled backend order; excludes boot/compilation; no Chez ratio",
                  summaries=summaries, samples=samples)
    output_path = args.output if args.output.is_absolute() else root / args.output
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n")
    for summary in summaries:
        legacy = next(row for row in summaries if row["mode"] == "legacy" and row["workload"] == summary["workload"])
        ratio = legacy["cpu_s"]["median"] / summary["cpu_s"]["median"]
        print(f'{summary["mode"]:20} {summary["workload"]:22} '
              f'cpu={summary["cpu_s"]["median"]:.6f}s relative_to_legacy={ratio:.2f}x')
    print(f"saved {output_path}")


if __name__ == "__main__":
    main()
