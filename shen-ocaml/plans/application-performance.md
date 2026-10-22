# Application performance path — 2026-10-22

Goal: improve ordinary compatible execution against pinned upstream Chez, not
just sealed numeric loops. Initial application CPU gaps: higher-order lists ~19×,
Prolog ~5.4×, string dictionaries ~3.1×; the short typed-load cases are competitive.

## Execution order

1. **Profile real applications.** Attribute CPU, allocation and GC separately
   from startup/expansion/typechecking. Add list/dictionary size scaling and
   unprofiled allocation runs; sampling overhead never enters speed claims.
2. **Measure native ceilings.** Run ordinary source through the actual kernel
   pipeline, observe post-expansion KL and explicitly promote eligible installed
   definitions to compatible native callables. Compare the identical checked
   application before/after promotion, excluding compilation from work throughput
   but reporting its cost. Do not replay source effects or metadata callbacks.
3. **Reduce closures/frames.** Specialize small captures, share proven immutable
   zero-slot environments, reduce local slots and avoid wrappers only where
   escape/effect analysis proves it safe. Escaped/reentrant frames remain fresh.
4. **Production native tier.** Add validated ABI-aware artifact reuse, then hot
   definition/group promotion. Publish only if source generation is still current.
   Failures need counters, warnings and strict CI behavior, not silent lost speed.
5. **Compatible dispatch.** Use compatible/sealed differences to target guarded
   direct calls and safe inlining. Guards cannot freeze a binding across callbacks
   that may redefine it, or restart work after effects have already happened.
6. **Residual runtime costs.** Target measured dictionary hashing/lookup, Prolog
   lazy unification and vectors, symbol identity, then bounded value-representation
   experiments. The tagged prototype is not a migration decision.

## Safety and acceptance

- Ordinary loaded code retains redefinition, currying/intermediate effect order,
  partials, errors, mutable literal identity and deep tail calls.
- A promotion factory only constructs callables. Validate the whole old binding
  group before publishing; installation must not rerun `put`, `ps`, declarations,
  `userdefs`, source initializers or arbitrary `eval-kl` effects.
- Unsupported promotion is explicit. A failed strict promotion experiment is not
  a successful dynamic fallback. Broad Shen staging belongs to the kernel, not
  to a growing syntax whitelist.
- Report default, explicit promoted-native and sealed tracks separately. Native
  ceiling experiments are not automatic/default promotion or startup speedups.
- Every optimization needs checked outputs, repeated measurements, allocation
  evidence and regression review. Preserve the unmodified reference kernel so
  host improvements and kernel changes are not conflated.
- Targets: first <2× Chez for every representative throughput case; then broad
  parity; then consistent wins with acceptable compile/startup/memory costs.
  These are goals, not promised outcomes or release criteria already achieved.

First implementation wave: expanded profiling, explicit native-ceiling experiment,
and safe dynamic closure/frame improvements. ABI-aware cache and automatic
promotion follow only after the ceiling measurements justify their complexity.
