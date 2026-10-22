# Application performance wave 1 — 2026-10-22

## Outcome

Implemented explicit native promotion of the real kernel's post-expansion KL,
safe dynamic frame/capture reductions, direct hot string primitive entries, and
broader application allocation profiling. This is the first wave of the
[application performance plan](../plans/application-performance.md), not completion
of automatic promotion/caching or a claim of general superiority over Chez.

The native-ceiling experiment produces a useful **2.13× list-work CPU improvement**
with **39.3% lower allocation**. Prolog improves modestly. Dictionary promotion
does not improve throughput in this run. **Do not enable blanket promotion.**

## Implementation and semantic boundaries

- Observe actual post-expansion top-level KL definitions at `eval-kl`. The exact
  created callable is reported before metadata hooks. Nested metadata redefinitions
  cannot cause an outer body to be paired with a different installed function.
- Compatible native factories construct callable registries, without `N.install`,
  `eval-kl`, user-body execution, source effects, or metadata callbacks.
- Validate the old binding group before compilation/loading and again against
  precollected stable cells immediately before publishing replacements. Final
  successful identity validation and publication allocate no objects/lookups.
  This avoids the GC-finalizer window introduced by allocating `Hashtbl.find_opt`
  during the final group check. Tests include zero-allocation validation and
  supplementary finalizer/redefinition stress; the latter is not a deterministic
  scheduling proof.
- Metadata identities (`ps`, `userdefs`, lambda-form entries) are preserved.
  Compatible redefinition, saved callables and numeric self guards remain valid.
  Mutable vector literals and stale/unobserved definitions fail closed.
- The host must be single-threaded; asynchronous host signal handlers or other
  asynchronous callbacks must not mutate bindings during promotion. This is not
  a signal-masking primitive or a concurrent publication transaction.
- `eval-promoted FILE DIR EXPR` loads source once normally, promotes the observed
  definitions, then evaluates the expression. Ordinary execution remains dynamic.
  Compiler failures fail the command; they are not hidden behind dynamic fallback.
  Artifacts are fresh, trusted, same-ABI and process-local—not a persistent cache.

Dynamic compilation now reuses temporary slots across completed lexical scopes,
omits unused binding/parameter slots while preserving argument/initializer effects,
and specializes one/two captures. Only proven read-only capture frames are shared;
writable calls remain fresh, including escaped and reentrant computations.

`str`, `cn`, `pos`, `tlstr`, `n->string`, `string->n` and `simple-error` use direct
native entries rather than constructing argument lists. Output allocation is not
misreported as removable overhead: `str` remains 32 bytes/call in its test, versus
56 with the old adapter; `cn` remains 40 versus 88. Division semantics are unchanged.

## Integrated qualification

Environment: macOS ARM64; release toolchain OCaml 5.3.0, Dune 3.20.2.
Oracle: upstream `tizoc/shen-scheme`
`8d261518db17fbfec32d1b268b40ed216b925c74`, Chez 10.3.0, unchanged 43.1 kernel.

Passed:

```sh
nix develop --command dune runtest --force
nix develop --command dune build --profile release @all
python3 scripts/check_native_promotion.py
python3 scripts/check_native_user.py
python3 scripts/check_native_typed.py "$ORACLE"
python3 scripts/check_kernel_suite.py --backend native --timeout 60
python3 scripts/check_scheme_oracle.py "$ORACLE" --kernel-suite
```

Canonical results remain **154 passed / 0 failed on both ports**. New regressions
exercise sparse parameters through arity nine, slot reuse, escaped captures,
reentrancy, handler captures, effect order, mutable literals, expanded Prolog,
stale whole groups, exact metadata identities, compiler failures and CLI source
effects running once. Existing million-depth tail-call tests still pass.

Static reviews covered frame aliasing, factory construction and publication.
Review found the allocating final-validation lookup; the integrated code uses
precollected cells instead. The asynchronous-host-mutation limitation is explicit.

## Native ceiling: five runs per mode/case

Fresh processes, reproducibly shuffled seed 431, identical checked Shen repeat
loop, one full untimed warmup, full GC before measuring. Work excludes reading,
source setup, compilation and promotion. This comparison is **dynamic versus
explicit promoted-compatible execution**, not automatic/default promotion and not
sealed application performance.

| Work, batch repetitions | Dynamic CPU median [range], s | Promoted CPU median [range], s | Dynamic / promoted | Allocation, dynamic → promoted |
|---|---:|---:|---:|---:|
| List pipeline, 5,000 × 1,000 elements | .76029 [.74756–.82714] | .35692 [.30785–.37818] | 2.13× | 2,242,480,192 → 1,361,280,152 B |
| Einstein Prolog, 20 queries | .32079 [.30494–.35897] | .28010 [.25981–.30445] | 1.15× | 226,127,072 → 173,826,392 B |
| String dictionary, 100 × 2,000 keys | .13104 [.12334–.15474] | .14066 [.12734–.16016] | .93× | 128,260,992 → 117,045,752 B |

Allocations are identical across all five runs within each mode/case. Promotion
wall medians [ranges]: list .922 [.578–1.738] s; Prolog .698 [.677–1.136] s;
dictionary 1.161 [.616–1.340] s. Compilation can outweigh saved execution for short
jobs. Dictionary CPU ranges overlap and its promoted median regresses despite
8.7% lower allocation; do not infer a throughput win from allocation alone.

Raw report: `_build/qualification/native-ceiling-bizq8ta5/results.json`.

## Default execution against Chez: separate five-run scorecard

No promotion is enabled here. Jobs are randomized/interleaved with seed 431;
typed loads include poisoned-input rejection. Reported values are aggregate
work CPU medians, with setup/external wall stored separately in the raw report.

| Work | OCaml, s | Chez, s | OCaml / Chez |
|---|---:|---:|---:|
| Typed interpreter load, 1 | .02338 | .02495 | .94× |
| Einstein Prolog, 20 | .35394 | .05910 | 5.99× |
| Dictionary, 100 | .15256 | .04653 | 3.28× |
| Higher-order lists, 5,000 | .81905 | .04018 | 20.39× |
| capcov datatype/judge batch, 1 | .02708 | .02901 | .93× |

Short typed-case ranges overlap; they are not robust universal wins. The capcov
case is a real datatype/judge batch, not a full modelcheck application. Historical
absolute times fluctuate with machine load; this is not a controlled before/after
claim against yesterday's scorecard. Default execution is **still much slower**
than Chez on the three throughput cases.

Raw report: `_build/qualification/application-scoreboard-jr0kp7r9/results.json`.
Both final reports record runtime/compiler source fingerprint
`b54f3f7c5531cc0536ee113d979528ad99cc8b75789c08dff11709bd2037ef90`.
The default runner also records executable hashes and rejects source/binary drift.

## Controlled frame-only ablation

An additional private-copy experiment changed only `src/interp/compiled.ml`,
preserving the same definition-observer hook in both versions. Five randomized
runs/variant/case used unprofiled allocation diagnostics, including per-query
read/eval, with setup and one warmup excluded. **This auxiliary experiment used
OCaml 5.4.1**, not the 5.3.0 integrated scorecard toolchain.

| Batch | Baseline allocation | Compact-frame allocation | Change |
|---|---:|---:|---:|
| Lists, 5,000 | 2,614,800,136 B | 2,374,920,136 B | −9.17% |
| Dictionary, 100 | 159,500,136 B | 159,507,336 B | +0.0045% |
| Prolog, 20 | 272,687,816 B | 229,943,496 B | −15.68% |

CPU median changes were −4.15%, −5.19%, **+2.15%** respectively, with overlapping
ranges. There is no established general frame-only CPU speedup. The accepted
benefit is measured allocation reduction and simpler bounded frame use, not a
claim that less allocation necessarily means less CPU.
Private source manifests, exact diff and samples remain under
`/private/var/folders/1_/dpmffg5j371662md64zvsktm0000gp/T/opencode/frame-ablation.PejSsV/`.

## Next decision

Prioritize higher-order application/partial-wrapper costs and native kernel
dispatch plus lazy-unification continuation construction. Promotion alone cannot
close the measured gaps. Gate future automatic promotion by actual work saved and
compilation cost; dictionaries already demonstrate why a universal threshold or
unconditional promote-everything policy is insufficient. Persistent caching needs
ABI/source/option validation and explicit failures before any default rollout.
