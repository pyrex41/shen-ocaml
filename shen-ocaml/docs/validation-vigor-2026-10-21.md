# Speed tranche validation — 2026-10-21

This extends the [first compiler milestone](validation-2026-10-21.md).
All changes remain local. Platform: macOS ARM64, OCaml 5.3.0, release builds.
Current benchmark source fingerprint:
`48bb45e96548f2bbd9f511c75df3cc397c6ffcf29dd5cca0771b4684dbbab802`.

## Implemented

- Specialized native/dynamic calls through arity **8**, including currying,
  overapplication, legacy/generic replacements and mutable function cells.
- Shared boolean results and direct list/predicate/hash/comparison entries.
- Direct handlers for syntactic `trap-error` lambdas: no callable/thunk allocation
  on the successful path. General handler expressions remain eager and ordered.
- Vector equality without a per-comparison loop closure; scalar hashing without
  structural-hash state allocation.
- Guarded, sealed integer workers for a small integer-closed recursive subset.
  Floats/non-integers fall back to the original boxed native body. Unsupported
  effects and shadowed primitives disable this optimization. Existing machine-int
  overflow is preserved, not presented as arbitrary-precision Shen arithmetic.
- Actual untyped function-only `.shen` compilation to native `.cmxs` and fresh-host
  loading, separately from compilation. No `eval-kl` interception/replay.
- Load-time source metadata for `ps`/`userdefs`, and late-bound saved/partial `fn`
  references. These address two independently reviewed compatibility defects.
- Statistical allocation profiler for standalone typechecking and Prolog workloads.

## Correctness

- Dune regressions pass, including the shared 33-check semantic corpus in all tiers.
- Current canonical 43.1 suite: **154 passed, 0 failed** on OCaml and pinned upstream
  `tizoc/shen-scheme` (`8d261518db17fbfec32d1b268b40ed216b925c74`).
- Wide calls: all partial splits, overapplication, ordered effects, redefinition
  and 200,000-deep calls pass in dynamic/compatible/sealed modes.
- Cached boolean/equality/comparison allocation loop: 96 bytes measurement overhead
  across 100,000 iterations, with no per-iteration boolean allocation.
- Integer workers: 36 mixed numeric cases, float fallback, machine-int overflow,
  effect rejection and primitive-shadow checks pass. Ten 20,000-step calls allocated
  256 bytes total in the focused test, not per iteration.
- Native user compilation/loading passes with `eval-kl` disabled, in a fresh host
  as well as the compiling process. CLI compatible loading and sealed compilation
  pass. `ps`, `userdefs`, repeated loading and saved/partial `fn` redefinition pass.
- Unsupported source is rejected before execution, including top-level effects,
  typed definitions, packages, macros, custom macro/source-form registries,
  nested definitions, changing arities and unsupported named partial applications.
- Saved and partially applied `fn` redefinition fixtures also pass on Scheme.

## Repeated CPU snapshot

Seven process runs, median CPU milliseconds per 20 checked repetitions, with
parsing/installation/compilation excluded. The same workload bodies are used.

| Workload | Compiled dynamic | Native compatible | Native sealed | Chez dynamic |
|---|---:|---:|---:|---:|
| Tail sum | 13.311 | 5.955 | **0.201** | 0.380 |
| Higher-order loop | 21.501 | 6.053 | 1.910 | 0.804 |
| List build/traverse | 12.940 | 4.572 | 1.616 | 0.442 |
| Structural equality | 3.432 | 0.832 | 0.388 | 0.147 |

The sealed integer-loop case is about **1.9x faster than the measured Chez dynamic
case**, not a general win over Scheme. There is no sealed Chez application result,
and the other workloads remain slower. Fixed mode order and machine contention
produce dispersion; do not attribute small CPU changes to individual patches.

Allocations are the stronger evidence:

- Sealed tail-sum: **19,203,456 -> 3,456 bytes** over the same 400,000 iterations,
  comparing saved before/after backend reports. Loop-interior boxing is gone.
- Compatible higher-order loop: **19,204,256 -> 12,803,936 bytes**.
- Compatible list build/traverse: **19,205,856 -> 11,205,536 bytes**.
- Eight-argument ABI control: **83,200,416 -> 6,400,416 bytes** for identical compiled
  bodies through generic versus specialized dispatch. Seven-run median CPU was
  7.084 ms versus 3.117 ms. This isolates ABI cost, not an entire historical port.

Raw reports under `_build/qualification/`: `pre-vigor-backend.json`,
`post-vigor-backend.json`, `scheme-comparison.json`, `wide-call-comparison.json`,
and the typechecker/Prolog allocation profiles. The historical pre-report is a
saved local artifact; the reproducible runners generate fresh current reports.

## Native-user scope and cost

The frontend accepts untyped function-only modules with standard patterns, core
forms, explicit lambdas, saturated module/runtime named calls and dynamic calls.
The static runtime-call list is **not a sandbox** or a limit on reachable dynamic
callees. Custom compile-time behavior is rejected rather than silently ignored.

Compilation does not install user functions or run their bodies. Loading installs
native functions and source metadata. Generated KL data is only source metadata,
never an execution fallback. Native plugins are trusted code for the exact host ABI.

Compiler subprocess time is deliberately separate: observed fixture compilations
varied from roughly 1 to 12 seconds under changing machine load. Reopening an
existing artifact does not recompile it. Automatic ABI-aware compilation caching,
typed/macro/package-aware native files, automatic promotion and standalone apps
remain outstanding.

## Profiling-driven next targets

Successful-path exception-wrapper allocation and vector-comparison callback
allocation were removed based on Memprof samples. Remaining sampled hotspots:

- Typechecking: cons construction (about 28%) and abstract-vector allocation
  (about 14%) in this standalone load.
- Prolog: lazy-unification continuations, dynamic invocation frames, zero-argument
  callable construction and closure capture arrays.

These are statistical **allocation** shares, not CPU shares. Profile timing and GC
counters include profiler bookkeeping and must not be used as speed measurements.
Next work should address continuation/frame lifetime and richer native user code,
not assume that adding more arithmetic special cases solves the dynamic-tier gap.

## Commands

```sh
nix develop --command dune runtest --force
python3 scripts/check_kernel_suite.py --backend native --timeout 60
python3 scripts/check_scheme_oracle.py "$ORACLE" --kernel-suite
python3 scripts/check_native_user.py
python3 bench/run_comparison.py --runs 7 --output _build/qualification/post-vigor-backend.json
python3 bench/run_scheme.py "$ORACLE" --runs 7
nix develop --command dune exec --profile release bench/compare_wide.exe
```
