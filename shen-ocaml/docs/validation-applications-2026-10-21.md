# Compatible workers, lean thunks and application qualification

Local, uncommitted qualification on macOS ARM64, OCaml 5.3.0 / Dune 3.20.2.
Reference: upstream `tizoc/shen-scheme` at
`8d261518db17fbfec32d1b268b40ed216b925c74`, built with Chez 10.3.0.
This extends the earlier [rebuild](validation-2026-10-21.md) and
[native optimization](validation-vigor-2026-10-21.md) reports; it does not replace
their measurement boundaries or claim that the full performance vision is done.

## Implemented and checked

- Compatible integer workers check all-`Int` operands, actual installed self
  identity and every canonical primitive used by the proof. Guard failure uses
  the original compatible body. Tests cover all eight primitives with three
  replacement callable shapes, old references/partials, duplicate definitions,
  repeat installation, metadata reentrancy, floats and machine-int boundaries.
  Ten checked 20,000-step calls allocate 416 bytes total, not per iteration.
  Hoisted guards require the single-threaded, callback-free worker assumption.
- Lean `Thunk` wrappers measure about **16 bytes vs 96 bytes** for the old
  zero-arity native wrapper. Applying an existing thunk 100,000 times allocates
  only 96 bytes of measurement overhead. Captured state, nested freeze, error
  propagation, zero-arity overapplication, legacy interoperability and million-deep
  tails pass. Frames remain fresh; there is no speculative frame recycling.
- Wholly typed function-only files now compile through fork-isolated built-in
  checking. Checking and translation use the same normalized bodies. Signature
  predicates are native code too: loading uses neither `declare` nor `eval-kl`
  and does not invoke ambient demodulation or foreign signature closures.
  All declaration conflicts are checked before signature-table mutation.
  Matching native-owned signatures may be reloaded; foreign declarations fail.
- The isolated [tagged-value experiment](../experiments/tagged_value/README.md)
  passes boundary and minor/full/compaction stress. It reduces allocations but
  regresses traversal and has mixed mutation timings. It is **not integrated**;
  only a bounded reversible trial is recommended.
- Empty default `*home-directory*` permits absolute and cwd-relative paths,
  without overwriting an embedding host's preexisting prefix. CLI regression passes.

Typed support is deliberately limited: single-threaded Unix staging host, built-in
scalar/list/arrow types, core forms and function-only files. General macros,
packages, datatypes, custom patterns/type theory and arbitrary top-level effects
remain excluded. The type-registration step is atomic with respect to its checks;
the complete function/metadata loader is not a transaction or a sandbox.

## Qualification

Passed in the integrated tree:

```sh
nix develop --command dune runtest --force
nix develop --command dune build --profile release @all
python3 scripts/check_native_user.py
python3 scripts/check_native_typed.py "$ORACLE"
python3 scripts/check_kernel_suite.py --backend native --timeout 60
python3 scripts/check_scheme_oracle.py "$ORACLE" --kernel-suite
```

Both canonical suites report **154 passed, 0 failed**. Typed and untyped native
checks include compilation, fresh-host load and execution, metadata, isolation,
redefinition and fail-closed behavior. The strict typed checker verifies the exact
upstream pin and genuinely rejected invalid typed loads, not just error text.
Typed staging uses `eval-kl` for compiler-owned predicates only inside its isolated
child; typed loading and native user execution do not need it.

One parallel qualification attempt hit a shared Dune/Nix build timeout; the typed
checker passed when rerun sequentially. This is not counted as a semantic failure
or hidden as a successful first attempt.

## Default application scorecard

Five fresh processes per port/case, randomized/interleaved with seed 431. Both
ports execute identical checked Shen code. Work CPU includes answer checks and
the shared Shen repeat loop. Setup is measured separately. External wall includes
boot, driver/setup, validation and output. No native-file/sealed results enter
this table. These are current-state comparisons, **not before/after speedups**.

| Application work | Repetitions | OCaml CPU median (range), s | Chez CPU median (range), s | OCaml / Chez |
|---|---:|---:|---:|---:|
| Typed Prolog interpreter load | 1 | .02919 (.02426–.03769) | .03627 (.02833–.04372) | .80× |
| Einstein Prolog query | 20 | .40335 (.37287–.40851) | .07408 (.07004–.07746) | 5.44× |
| String-key dictionary, 2,000 entries | 100 | .20027 (.16688–.23779) | .06523 (.05736–.07060) | 3.07× |
| Higher-order 1,000-element list pipeline | 5,000 | .94691 (.88438–1.07138) | .04972 (.04730–.05141) | 19.04× |
| capcov datatype/judge batch | 1 | .03016 (.02309–.03335) | .04053 (.02409–.04480) | .74× |

The two short typechecking ranges overlap: do not treat their median ratios as
robust universal wins. The capcov case loads real datatype/judge sources and checks
valid/distinct vs invalid/duplicate IDs; it is not a full capcov modelcheck run.
Every case verifies answers; typed cases also require poisoned units to fail.

External wall medians (OCaml / Chez seconds): typed load .136/.345, Prolog
.473/.518, dictionary .244/.375, list pipeline 1.015/.317, capcov .082/.369.
Startup can dominate short jobs and must not be substituted for work throughput.

Raw samples, phase timings, hashes, source drivers and transcripts:
`_build/qualification/application-scoreboard-yltywovg/results.json`.
Reproduce from `shen-ocaml/`:

```sh
python3 bench/run_applications.py "$ORACLE" --runs 5 --capcov /path/to/capcov
```

## Native/dynamic microbenchmarks — separate track

Seven processes, seed 431, recorded randomized backend order. Median aggregate
CPU seconds for 20 checked repetitions, excluding parsing/installation/boot:

| KL workload | Dynamic tier | Native compatible | Native sealed | Chez dynamic |
|---|---:|---:|---:|---:|
| Tail sum | .012809 | .000276 | .000200 | .000384 |
| Higher order | .021199 | .005179 | .001946 | .000561 |
| List build/traverse | .012885 | .004077 | .001911 | .000447 |
| Structural equality | .003321 | .000817 | .000393 | .000162 |

Compatible tail sum now has the same **3,456-byte total allocation** as sealed,
instead of the earlier 19.2 MB boxed compatible path. This narrow integer-worker
case is about 1.4× faster than measured Chez dynamic; sealed is about 1.9× faster.
These very short measurements are not an application-wide result. Other cases
remain slower than Chez, and ordinary loaded functions use the dynamic tier.
The OCaml outer measurement loop is a host loop; Chez uses a Shen loop.

Arity 5–8 diagnostics pass: specialized entries allocate 736 bytes total per
20-run case versus 54.4–83.2 MB for equivalent generic-list-ABI controls. This is
an ABI diagnostic, not a historical speed comparison.

Raw microbench reports: `_build/qualification/backend-comparison.json` and
`_build/qualification/scheme-comparison.json`.

## Profiling and next performance work

A separate five-second macOS CPU sample was saved and checked nonempty:
`_build/qualification/application-scoreboard-cu_fys3b/cpu-sample.txt`.
It shows substantial dynamic closure dispatch alongside kernel Prolog operations,
equality, callable application and vector accesses. Recursive stack counts are
not exclusive CPU percentages. Sampling is not included in scorecard medians.
The runner now saves sampler stdout/stderr and verifies the actual sample file;
an earlier invocation returned success without leaving an artifact and is not
used as profile evidence.

Separate Memprof diagnostic (five Prolog queries, rate .001):
`_build/qualification/prolog-lean-allocation-profile.json`.
Statistical allocator shares include dynamic frame/capture/closure construction,
kernel lazy unification (~27.5%), and the remaining lean thunk wrapper (~9%).
Those shares are noisy sampled attribution, not exact totals or an unsampled
before/after timing claim. No full-program speedup is inferred from wrapper size.

The next priorities remain general correctly staged native application compilation
and ABI-aware promotion/caching, then measured frame/capture/continuation costs.
Preserving escaped closure state and redefinition is mandatory. Runtime symbol
interning, numeric correctness/bigints and broader Linux/platform qualification
are still open. Default execution is **not yet generally faster than Chez**.
