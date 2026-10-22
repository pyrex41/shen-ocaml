#!/usr/bin/env python3
"""Measure identical KL workloads on the pinned upstream Scheme dynamic compiler."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

PIN = "8d261518db17fbfec32d1b268b40ed216b925c74"
CASES = [
    ("tail-sum", "(bench.sum 20000 0)", "200010000"),
    ("higher-order", "(bench.run-hof)", "20000"),
    ("list-build-traverse", "(bench.length (bench.build 10000 []) 0)", "10000"),
    ("structural-equality", "(= (bench.build 2000 []) (bench.build 2000 []))", "true"),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--runs", type=int, default=7)
    args = parser.parse_args()
    if args.runs < 3:
        parser.error("use at least three runs")
    checkout = args.checkout.resolve()
    root = Path(__file__).resolve().parents[1]
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if commit != PIN:
        parser.error(f"expected {PIN}, got {commit}")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=checkout, check=True)
    workload = root / "bench/workloads.kl"
    if any(c in str(workload) for c in ['"', "\\", "\n"]):
        parser.error("workload path cannot contain quotes, backslashes or newlines")
    command = [str(checkout / "_build/bin/shen-scheme"), "eval", "-e",
               f'''(let Forms (read-from-string-unprocessed (read-file-as-string "{workload}"))
                 (do (map (fn eval-kl) Forms)
                   (map (/. Form (update-lambda-table (hd (tl Form))
                                   (length (hd (tl (tl Form)))))) Forms)))''',
               "-e", "(define bench.repeat 0 F -> true N F -> (do (thaw F) (bench.repeat (- N 1) F)))"]
    for name, expression, expected in CASES:
        checked = f'(if (= {expression} {expected}) true (simple-error "wrong benchmark result"))'
        command += ["-e", f'''(do {checked}
          (let Wall (get-time unix) CPU (get-time run)
            (do (bench.repeat 20 (freeze {checked}))
              (let CPU (- (get-time run) CPU) Wall (- (get-time unix) Wall)
                (output "~%SCHEME_RESULT {name} ~A ~A~%" Wall CPU)))))''']
    samples = []
    for run in range(args.runs):
        result = subprocess.run(command, cwd=checkout, capture_output=True, text=True,
                                timeout=60)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        # The launcher prints expression results as well as explicit output;
        # accept only marker lines (not its repeated multiline string result).
        rows = []
        for line in result.stdout.splitlines():
            fields = line.split()
            if len(fields) == 4 and fields[0] == "SCHEME_RESULT":
                _, name, wall, cpu = fields
                row = dict(run=run, workload=name, wall_s=float(wall), cpu_s=float(cpu))
                if row not in rows:
                    rows.append(row)
        if len(rows) != len(CASES):
            raise RuntimeError(f"missing/ambiguous markers: {result.stdout}")
        samples.extend(rows)
    summaries = []
    for name, _, _ in CASES:
        rows = [row for row in samples if row["workload"] == name]
        summaries.append(dict(workload=name, **{key: dict(median=statistics.median(row[key] for row in rows),
                                                         min=min(row[key] for row in rows),
                                                         max=max(row[key] for row in rows))
                                               for key in ["wall_s", "cpu_s"]}))
    output = root / "_build/qualification/scheme-comparison.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(dict(commit=commit, runs=args.runs, repetitions=20,
                                     workload_sha256=hashlib.sha256(workload.read_bytes()).hexdigest(),
                                     boundaries="dynamic Scheme compilation; excludes loading/compilation; checked results; Shen repeat-loop overhead included",
                                     summaries=summaries, samples=samples), indent=2) + "\n")
    for summary in summaries:
        print(f'{summary["workload"]:22} scheme_dynamic_cpu={summary["cpu_s"]["median"]:.6f}s')
    print(f"saved {output}")


if __name__ == "__main__":
    main()
