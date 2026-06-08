#!/usr/bin/env python3
"""Full ShenOSKernel-41.1 conformance run for shen-ocaml (Phase A oracle).

Runs every (report ...) group in test/shen/kerneltests.shen, each in its own
fresh kernel process with a per-group wall-clock timeout, and prints a per-group
pass/fail/time table plus the grand total. This is the honest, committed
conformance measurement (the in-process `dune test` gate covers only the
order-independent clean subset for fast regression detection — see
test/test_kernel_shen_suite.ml).

Why per-process: a group can hang (e.g. N Queens under a type-checker bug), and
isolating each group lets the run complete and localizes failures. Isolated runs
can therefore differ from a single monolithic run where state leaks between
groups (e.g. "binary number datatype" after "Prolog tableau"); such cross-group
effects are documented in STATUS.md.

Usage:
  scripts/run_kernel_suite.py [name-substring] [per_group_timeout_secs]
  scripts/run_kernel_suite.py            # all groups, 45s each
  scripts/run_kernel_suite.py prolog 30  # only groups matching "prolog", 30s each

Exit code: 0 if (passed >= BASELINE_PASS and failed <= BASELINE_FAIL), else 1.
The baselines below are the measured 2026-06 figures; ratchet them as fixes land.
"""
import subprocess, sys, re, time, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEN_DIR = os.path.join(ROOT, "test", "shen")
KERNEL = os.path.join(ROOT, "kernel")
BIN = os.path.join(ROOT, "_build", "default", "bin", "main.exe")

# Measured baseline (per-process isolated run, OCaml 4.14 sandbox, 2026-06).
# 113/16 -> 128/6 (Bool/Sym boolean equality) -> 133/1 (type primitive arity 2).
# Remaining failure: spreadsheet (1).
BASELINE_PASS = 133
BASELINE_FAIL = 1


def split_forms(text):
    forms, depth, cur, instr, esc = [], 0, [], False, False
    for ch in text:
        if instr:
            cur.append(ch)
            if esc: esc = False
            elif ch == '\\': esc = True
            elif ch == '"': instr = False
            continue
        if ch == '"':
            instr = True; cur.append(ch)
        elif ch == '(':
            depth += 1; cur.append(ch)
        elif ch == ')':
            depth -= 1; cur.append(ch)
            if depth == 0:
                forms.append(''.join(cur).strip()); cur = []
        elif depth > 0:
            cur.append(ch)
    return forms


def name_of(form):
    m = re.match(r'\(report\s+"([^"]+)"', form)
    return m.group(1) if m else None


def run_group(form, timeout):
    inp = '(load "harness.shen")\n(reset)\n' + form + '\n'
    t0 = time.time()
    try:
        p = subprocess.run([BIN], input=inp, capture_output=True, text=True,
                           timeout=timeout, cwd=SHEN_DIR,
                           env={**os.environ, "SHEN_KERNEL_DIR": KERNEL})
        out = p.stdout + p.stderr
        ps = re.findall(r'passed \.\.\. (\d+)', out)
        fs = re.findall(r'failed \.\.\. (\d+)', out)
        return ("ok", int(ps[-1]) if ps else 0, int(fs[-1]) if fs else 0,
                time.time() - t0)
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", 0, 0, time.time() - t0)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "-" else None
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 45
    if not os.path.exists(BIN):
        sys.exit(f"binary not built: {BIN}\n  run: dune build")
    with open(os.path.join(SHEN_DIR, "kerneltests.shen")) as f:
        forms = [x for x in split_forms(f.read()) if x.startswith("(report")]
    tot_p = tot_f = 0
    print(f"{'GROUP':32} {'PASS':>4} {'FAIL':>4} {'TIME':>7}  STATUS")
    for form in forms:
        nm = name_of(form)
        if only and only.lower() not in nm.lower():
            continue
        status, p, fl, dt = run_group(form, timeout)
        tot_p += p; tot_f += fl
        print(f"{nm:32} {p:>4} {fl:>4} {dt:>6.1f}s  {status}", flush=True)
    print(f"{'TOTAL':32} {tot_p:>4} {tot_f:>4}")
    if only:
        return 0
    ok = tot_p >= BASELINE_PASS and tot_f <= BASELINE_FAIL
    print(f"baseline: pass>={BASELINE_PASS} fail<={BASELINE_FAIL} -> "
          f"{'OK' if ok else 'REGRESSION'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
