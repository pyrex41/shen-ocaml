# Compiler reboot validation — 2026-10-21

Historical first-milestone snapshot. The subsequent speed/native-user tranche is
recorded in [validation-vigor-2026-10-21.md](validation-vigor-2026-10-21.md).

## Inputs

- macOS ARM64, OCaml 5.3.0, Dune 3.20.2; release-profile measurements.
- Upstream `tizoc/shen-scheme` at
  `8d261518db17fbfec32d1b268b40ed216b925c74`, freshly bootstrapped with Chez 10.3.0.
- Official 43.1 archive SHA-256:
  `900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`.
  All 23 vendored kernel files match its KL sources byte for byte.
- Executable-source fingerprint for backend measurements:
  `2297cb89bf93800ecd0d26161c838ed144880c069a43215d451bd1b3d33c1b46`.
  This identifies the uncommitted working tree, not an existing release.

## Correctness gates

| Gate | Result |
|---|---|
| Forced Dune regression suite | PASS |
| Current canonical 43.1 tests, native kernel + dynamic compiler | **154 passed, 0 failed** |
| Same canonical tests on upstream Scheme | **154 passed, 0 failed** |
| Shared semantic corpus, dynamic/native-compatible/native-sealed | 33 checks in each mode, PASS |
| Shared semantic corpus on upstream Scheme | PASS |
| Million-deep self and mutual native tail calls | PASS |
| Compatible redefinition across compiled/interpreted boundary | PASS |
| Sealed binding retention | PASS |
| Vector literal identity, case-sensitive binding names, numeric hashing | PASS |
| CLI: eval, multiple forms, typed definitions, redefinition, REPL EOF, errors | PASS |
| Python runner syntax and `git diff --check` | PASS |

The original vendored suite was stale: its 134 cases omitted 20 new 43.1 checks.
Those checks were restored. A truncated Lisp test fixture was restored as well.
The oracle runner verifies every applicable test source against the official
archive (ignoring trailing whitespace), except the noninteractive harness and
the extra local `tiny.shen` fixture. The harness counts failures instead of asking
whether to continue; predictions and test expressions are not weakened.

The canonical script resets its counters at the end. The OCaml driver snapshots
them before reset, and the runner requires exactly 154 passes and zero failures.
A timeout, missing counters, missing tests or a nonzero process status fails.

## Performance snapshot

Median CPU milliseconds for **20 repetitions**, across seven process runs.
Every workload checks its answer. Parsing, loading and compilation are excluded.

| Workload | Legacy walker | Compiled dynamic | Native compatible | Native sealed | Chez dynamic |
|---|---:|---:|---:|---:|---:|
| Tail sum | 139.842 | 13.383 | 6.445 | 2.185 | 0.354 |
| Higher-order loop | 177.488 | 24.045 | 6.352 | 3.650 | 0.584 |
| List build/traverse | 148.600 | 15.485 | 6.283 | 2.978 | 0.401 |
| Structural equality | 32.053 | 2.799 | 1.046 | 0.521 | 0.149 |

These demonstrate large improvements over the old interpreter, **not superiority
to Chez**. The dynamic compiler remains approximately 19–41x slower than Chez on
these kernels; native-compatible bodies remain approximately 7–18x slower.
Sealed OCaml bodies are still slower than the measured Chez dynamic bodies.
No sealed Chez application comparison has been made.

Conditions and caveats:

- Same KL workload definitions for each backend. The higher-order lambda is
  created inside the chosen backend, not by the outer legacy test invocation.
- Tiny outer invocation/result-check costs are included in OCaml measurements.
  The Scheme runner includes a Shen repeat loop instead of an OCaml host loop.
- Mode order is fixed; machine contention produces noticeable dispersion.
  For example native-compatible tail-sum CPU ranged from 3.609 to 8.251 ms.
- Raw samples, allocation counts and min/median/max values are saved under
  `_build/qualification/`; the commands below regenerate them.
- Separate complete-suite runs measured about 2.8–3.4s wall time for OCaml and
  1.5–1.6s for Scheme. These are illustrative runs, not repeated end-to-end
  qualification or startup benchmarks.

Likely next performance targets are the boxed value representation, larger-arity
calls, remaining primitive adapters, and native compilation of user Shen files.
The current user-code tier executes compiled host closures, not machine-code JIT
output. Arbitrary-precision numeric semantics and Linux remain unqualified.

## Reproduction

From `shen-ocaml/`, with `ORACLE` pointing to the pinned, bootstrapped upstream
checkout (including `make fetch-kernel`'s extracted canonical test sources):

```sh
nix develop --command dune runtest --force
python3 scripts/check_kernel_suite.py --backend native --timeout 60
python3 scripts/check_scheme_oracle.py "$ORACLE" --kernel-suite
python3 bench/run_comparison.py --runs 7
python3 bench/run_scheme.py "$ORACLE" --runs 7
```

The oracle was built in a separate temporary checkout; the sibling Scheme fork
was not modified. No changes have been pushed or released.
