#!/usr/bin/env python3
"""Checked, interleaved application scoreboard for default OCaml and pinned Chez.

No sealed/native-file results are mixed into this scorecard. In-program CPU/wall
phases separate setup from checked application work; external wall includes boot,
driver loading, setup, validation and output. Optional sample(1) CPU profiles run
separately and never enter the timing summary.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import signal
import statistics
import subprocess
import sys
import tempfile
import time

from run_comparison import fingerprint

PIN = "8d261518db17fbfec32d1b268b40ed216b925c74"
ROOT = Path(__file__).resolve().parents[1]


def shen_string(path):
    value = str(path)
    if any(c in value for c in ['"', "\\", "\n", "\r"]):
        raise ValueError("Shen source paths cannot contain quotes, backslashes or line breaks")
    return '"' + value + '"'


def relative(path):
    return shen_string(os.path.relpath(path, ROOT))


def cases(capcov):
    definitions = {
        "typecheck-prolog-interpreter": dict(setup="(tc +)", repetitions=1, expected="loaded",
            body='(load "test/shen/prologinterp.shen")',
            checks=['(scoreboard.check "typechecker-active" (> (inferences) 0) true)',
                    '(scoreboard.check "ill-typed-load-rejected" (trap-error (load SCORE_BAD_UNIT) (/. E rejected)) rejected)'],
            files=[ROOT / "test/shen/prologinterp.shen"]),
        "prolog-einstein": dict(setup='(do (load "test/shen/einsteins-riddle.shen") true)',
            repetitions=20, expected="german", body="(prolog? (riddle))", checks=[],
            files=[ROOT / "test/shen/einsteins-riddle.shen"]),
        "string-key-dictionary": dict(setup="true", repetitions=100, expected="2001000",
            body="(scoreboard.dictionary 2000)", checks=[], files=[]),
        "higher-order-list-pipeline": dict(setup="true", repetitions=5000, expected="501500",
            body="(scoreboard.list-pipeline 1000)", checks=[], files=[]),
    }
    if capcov:
        base = capcov / "packages/capabilities/shen/modelcheck"
        datatype_names = ["table-list", "wf-writes", "cell", "cell-list", "wf-matrix",
                          "wf-atlas", "wf-registry", "id-list"]
        judge_names = ["judge-writes", "judge-matrix", "judge-atlas", "judge-registry", "judge-ids"]
        paths = [base / "prelude.shen"] + [base / "types" / (name + ".shen")
                    for name in datatype_names + judge_names]
        if not all(path.is_file() for path in paths):
            raise ValueError("capcov checkout is missing required modelcheck sources")
        loads = " ".join(f"(load {relative(path)})" for path in paths[1:])
        body = f"(do (tc +) {loads} (load SCORE_VALID_IDS))"
        definitions["capcov-datatype-batch"] = dict(
            setup=f"(do (tc -) (load {relative(paths[0])}) true)", repetitions=1,
            expected="loaded", body=body,
            checks=['(scoreboard.check "capcov-invalid-ids-rejected" (trap-error (load SCORE_BAD_IDS) (/. E rejected)) rejected)'],
            files=paths)
    return definitions


def driver(name, case, paths, profile_seconds=None):
    replacements = {token: relative(path) for token, path in paths.items()}
    def replace(text):
        for token, path in replacements.items():
            text = text.replace(token, path)
        return text
    body = replace(case["body"])
    lines = ['(set *hush* true)', '(load "bench/application_support.shen")',
             f'(scoreboard.measure {name} setup 1 (freeze {case["setup"]}) true)']
    if profile_seconds is None:
        lines.append(f'(scoreboard.measure {name} work {case["repetitions"]} (freeze {body}) {case["expected"]})')
        lines.extend(replace(check) for check in case["checks"])
        lines += ['(set *hush* false)', f'(output "~%SCORE_DONE {name}~%")']
    else:
        lines += [f'(scoreboard.profile (+ (get-time unix) {profile_seconds}) '
                  f'(freeze {body}) {case["expected"]} {name} 0)',
                  '(set *hush* false)', f'(output "~%SCORE_PROFILE_DONE {name}~%")']
    return "\n".join(lines) + "\n"


def execute(command, timeout, transcript):
    started = time.perf_counter()
    with transcript.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError(f"scoreboard timeout: {transcript}")
    return process.returncode, time.perf_counter() - started, transcript.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("oracle", type=Path)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--seed", type=int, default=431)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--capcov", type=Path)
    parser.add_argument("--case", action="append", dest="selected")
    parser.add_argument("--cpu-profile", choices=["ocaml-default", "chez-default"])
    parser.add_argument("--profile-seconds", type=int, default=5)
    args = parser.parse_args()
    if args.runs < 1 or args.timeout <= 0 or args.profile_seconds < 1:
        parser.error("positive runs, timeout and profile duration required")
    oracle = args.oracle.resolve()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=oracle, text=True).strip()
    if commit != PIN:
        parser.error(f"expected pinned Scheme revision {PIN}, received {commit}")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=oracle, check=True)
    native = ROOT / "_build/default/bin/main.exe"
    subprocess.run(["nix", "develop", "--command", "dune", "build", "--profile", "release", "bin/main.exe"],
                   cwd=ROOT, check=True, timeout=180)
    choices = cases(args.capcov.resolve() if args.capcov else None)
    selected = args.selected or list(choices)
    if not set(selected) <= choices.keys():
        parser.error("unknown scenario; capcov scenario requires --capcov")
    directory = ROOT / "_build/qualification"
    directory.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="application-scoreboard-", dir=directory))
    paths = {"SCORE_BAD_UNIT": workdir / "bad-type.shen", "SCORE_VALID_IDS": workdir / "valid-ids.shen",
             "SCORE_BAD_IDS": workdir / "bad-ids.shen"}
    paths["SCORE_BAD_UNIT"].write_text('(define scoreboard-invalid { number --> number } X -> "not-a-number")\n')
    paths["SCORE_VALID_IDS"].write_text("(mc.judge-ids [" + " ".join(f"id{i}" for i in range(30)) + "])\n")
    paths["SCORE_BAD_IDS"].write_text("(mc.judge-ids [duplicate duplicate])\n")
    commands = {"ocaml-default": [str(native), "script"],
                "chez-default": [str(oracle / "_build/bin/shen-scheme"), "script"]}
    source_fingerprint = fingerprint(ROOT)
    binaries = {backend: hashlib.sha256(Path(command[0]).read_bytes()).hexdigest()
                for backend, command in commands.items()}
    tasks = [(run, backend, name) for run in range(args.runs)
             for name in selected for backend in commands]
    random.Random(args.seed).shuffle(tasks)
    samples = []
    fingerprints = {}
    expected_inputs = {name: {path: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in [ROOT / "bench/application_support.shen", *choices[name]["files"]]}
                       for name in selected}
    for run, backend, name in tasks:
        case = choices[name]
        source = driver(name, case, paths)
        program = workdir / f"{name}.shen"
        program.write_text(source)
        fingerprints[name] = dict(driver_sha256=hashlib.sha256(source.encode()).hexdigest(),
            inputs={os.path.relpath(path, ROOT): digest for path, digest in expected_inputs[name].items()})
        def assert_inputs_unchanged():
            for path, digest in expected_inputs[name].items():
                if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    raise RuntimeError(f"scoreboard input changed during measurement: {path}")
        assert_inputs_unchanged()
        transcript = workdir / f"{run}-{backend}-{name}.log"
        status, elapsed, text = execute(commands[backend] + [str(program)], args.timeout, transcript)
        assert_inputs_unchanged()
        if status != 0 or f"SCORE_DONE {name}" not in text:
            raise RuntimeError(f"scoreboard failure ({status}): {transcript}\n{text[-3000:]}")
        phases = {}
        for line in text.splitlines():
            fields = line.split()
            if len(fields) == 6 and fields[:2] == ["SCORE_RESULT", name]:
                _, _, phase, reps, cpu, wall = fields
            else:
                continue
            value = dict(repetitions=int(reps), cpu_s=float(cpu), wall_s=float(wall))
            if not all(math.isfinite(value[key]) and value[key] >= 0 for key in ["cpu_s", "wall_s"]):
                raise RuntimeError("invalid clock result")
            if phase in phases and phases[phase] != value:
                raise RuntimeError("ambiguous phase result")
            phases[phase] = value
        if set(phases) != {"setup", "work"} or phases["work"]["repetitions"] != case["repetitions"]:
            raise RuntimeError(f"missing/incorrect phases: {transcript}")
        samples.append(dict(run=run, backend=backend, case=name, external_wall_s=elapsed,
                            phases=phases, transcript=str(transcript)))
        print(f"{backend:14} {name:30} cpu={phases['work']['cpu_s']:.6f}s external={elapsed:.3f}s", flush=True)
    summaries = []
    for name in selected:
        for backend in commands:
            rows = [row for row in samples if row["case"] == name and row["backend"] == backend]
            summaries.append(dict(case=name, backend=backend,
                cpu_s={key: function(row["phases"]["work"]["cpu_s"] for row in rows)
                       for key, function in [("median", statistics.median), ("min", min), ("max", max)]},
                external_wall_s=statistics.median(row["external_wall_s"] for row in rows)))
    if fingerprint(ROOT) != source_fingerprint:
        raise RuntimeError("compiler/runtime source changed during application measurement")
    for backend, command in commands.items():
        if hashlib.sha256(Path(command[0]).read_bytes()).hexdigest() != binaries[backend]:
            raise RuntimeError(f"backend executable changed during measurement: {backend}")
    result = dict(oracle_commit=commit, platform=platform.platform(), seed=args.seed,
                  source_sha256=source_fingerprint, executable_sha256=binaries,
                  runs=args.runs, track="default-compatible-only", fingerprints=fingerprints,
                  summaries=summaries, samples=samples,
                  caveats="Fresh process per sample; shared checked Shen program; work includes result checks and Shen repeat loop; external wall includes boot/driver/setup/output; fixed reps; no native-file/sealed results")
    (workdir / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    if args.cpu_profile:
        if sys.platform != "darwin":
            parser.error("CPU sampling currently requires macOS sample(1)")
        name = selected[0]
        program = workdir / "cpu-profile.shen"
        program.write_text(driver(name, choices[name], paths, args.profile_seconds + 2))
        transcript = workdir / "cpu-profile.log"
        with transcript.open("w") as stream:
            process = subprocess.Popen(commands[args.cpu_profile] + [str(program)], cwd=ROOT,
                                       stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
            sample = workdir / "cpu-sample.txt"
            try:
                sampled = subprocess.run(["/usr/bin/sample", str(process.pid), str(args.profile_seconds),
                                          "-mayDie", "-file", str(sample)], capture_output=True, text=True,
                                         timeout=args.profile_seconds + 20)
                (workdir / "sample-command.log").write_text(sampled.stdout + sampled.stderr)
                process.wait(timeout=args.profile_seconds + args.timeout)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            if (sampled.returncode or process.returncode or not sample.is_file()
                    or sample.stat().st_size == 0
                    or f"SCORE_PROFILE_DONE {name}" not in transcript.read_text()):
                raise RuntimeError(f"CPU profile failed: {sampled.stderr}\n{transcript.read_text()[-2000:]}")
        print(f"CPU profile (separate from timings): {sample}")
    print(f"saved {workdir / 'results.json'}")


if __name__ == "__main__":
    main()
