#!/usr/bin/env python3
"""Checked native ceiling of ordinary expanded source; not automatic promotion."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

from run_comparison import fingerprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--seed", type=int, default=431)
    parser.add_argument("--case", choices=["list", "dictionary", "prolog"], action="append", dest="cases")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0:
        parser.error("positive runs/timeout required")
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["nix", "develop", "--command", "dune", "build", "--profile", "release",
                    "bench/application_native.exe"], cwd=root, check=True, timeout=180)
    parent = root / "_build/qualification"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="native-ceiling-", dir=parent))
    source = fingerprint(root)
    inputs = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [root / "bench/application_support.shen", root / "test/shen/einsteins-riddle.shen"]}
    tasks = [(run, case, mode) for run in range(args.runs)
             for case in args.cases or ["list", "dictionary", "prolog"]
             for mode in ["dynamic", "promoted"]]
    random.Random(args.seed).shuffle(tasks)
    samples = []
    for run, case, mode in tasks:
        command = [str(root / "_build/default/bench/application_native.exe"),
                   "--mode", mode, "--case", case, "--output-dir", str(directory)]
        started = time.perf_counter()
        # Promotion invokes ocamlopt: keep the matching toolchain in PATH.
        result = subprocess.run(["nix", "develop", "--command", *command], cwd=root,
                                capture_output=True, text=True, timeout=args.timeout)
        elapsed = time.perf_counter() - started
        text = result.stdout + result.stderr
        transcript = directory / f"{run}-{case}-{mode}.log"
        transcript.write_text(text)
        rows = [line.split("\t") for line in result.stdout.splitlines() if line.startswith("CEILING_RESULT\t")]
        if result.returncode or len(rows) != 1:
            raise RuntimeError(f"ceiling failure: {transcript}\n{text[-4000:]}")
        _, got_mode, got_case, repetitions, definitions, cpu, wall, allocated, promotion = rows[0]
        if (got_mode, got_case) != (mode, case):
            raise RuntimeError("ceiling result identity mismatch")
        samples.append(dict(run=run, case=case, mode=mode, repetitions=int(repetitions),
            definitions=int(definitions), cpu_s=float(cpu), wall_s=float(wall),
            allocated_bytes=float(allocated), promotion_wall_s=float(promotion),
            external_wall_s=elapsed, transcript=str(transcript)))
        print(f"{mode:8} {case:12} cpu={float(cpu):.6f}s alloc={float(allocated):.0f}B promotion={float(promotion):.3f}s", flush=True)
    if fingerprint(root) != source:
        raise RuntimeError("source changed during native ceiling run")
    for name, digest in inputs.items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError("application input changed during native ceiling run")
    summaries = []
    for case, mode in sorted({(row["case"], row["mode"]) for row in samples}):
        rows = [row for row in samples if (row["case"], row["mode"]) == (case, mode)]
        summary = dict(case=case, mode=mode)
        for key in ["cpu_s", "wall_s", "allocated_bytes", "promotion_wall_s", "external_wall_s"]:
            values = [row[key] for row in rows]
            summary[key] = dict(median=statistics.median(values), min=min(values), max=max(values))
        summaries.append(summary)
    report = dict(platform=platform.platform(), source_sha256=source, inputs=inputs,
        runs=args.runs, seed=args.seed, samples=samples, summaries=summaries,
        revision=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        boundaries="explicit compatible promotion of observed post-expansion definitions; same checked Shen repeat loop; one full warmup; work excludes source setup/compilation/promotion; external includes Nix; no automatic promotion or Chez claim")
    output = directory / "results.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"saved {output}")


if __name__ == "__main__":
    main()
