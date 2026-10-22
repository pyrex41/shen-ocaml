# Shen-OCaml status — 2026-10-21

## Delivered locally

- Real KL-to-native-OCaml backend; the full 23-file 43.1 kernel is compiled.
- Resolved lexical IR, free-variable analysis, and compiled-closure dynamic tier.
- Default CLI uses the native kernel and dynamic compiler. Legacy CLI retained.
- Explicit compatible/sealed call binding; tested cross-backend redefinition.
- Stable mutable function cells and specialized arity 0–8 dispatch.
- Closures, currying, overapplication, errors, effect order and deep tail calls.
- Shared primitive fixes: boolean interning, callable/symbol discrimination,
  mixed-numeric equality/hash consistency, and interactive output flushing.
- Cached boolean results, direct primitive entries, allocation-free vector-equality
  traversal, scalar-hash fast paths, and direct syntactic exception handlers.
- Guarded unboxed integer workers for compatible and sealed recursive numeric subsets;
  compatible guards preserve self/primitive redefinition and old references.
- Lean zero-arity thunks (16-byte wrapper vs 96-byte previous representation),
  with fresh invocation frames and capture-free closure fast paths.
- Restricted typed/untyped `.shen` function-module compilation to native `.cmxs`, with
  fresh-process loading, compatible/sealed modes, source metadata and late-bound
  saved `fn` references. Compilation does not run user function bodies.
- Fork-isolated built-in typechecking and native signature predicates; typed loading
  does not use `eval-kl`, `declare` or ambient type hooks and rejects foreign types.
- Checked default-only application scoreboard, reproducibly randomized jobs and
  separate CPU/allocation sampling. Tagged-value experiment remains isolated.
- Explicit post-expansion KL promotion with stale-group checks and no metadata or
  source-effect replay, exposed by `eval-promoted`; automatic promotion is not enabled.
- Compact dynamic frames/read-only captures and direct hot string primitive entries.

## Verified on this machine (macOS ARM64, OCaml 5.3.0)

- `nix develop --command dune runtest`: passing enabled regression tests.
- Current 43.1 canonical suite, native kernel + dynamic compiler: **154 passed, 0 failed**.
- Same canonical fixture suite on freshly built upstream Scheme: **154/0**.
- Shared KL corpus: **33 checks** pass in dynamic, native-compatible and sealed
  modes, and on upstream Scheme.
- One-million-deep self/mutual tail-call tests; CLI and literal/hash edge tests.
- Arity 5–8: partial splits, overapplication, generic/legacy replacement, ordered
  effects and deep recursion; cached boolean/call allocation assertions.
- Integer workers: 36 mixed numeric cases, float fallback, existing overflow
  behavior, primitive shadowing and effect rejection; no per-iteration allocation.
- Native user-module tests pass with `eval-kl` disabled during compilation/loading,
  including fresh-host loading, `ps`/`userdefs`, saved/partial `fn` redefinition and
  fail-closed unsupported source. Both compatible and sealed CLI paths pass.
- Typed staging/fresh-host loading and rejection checks pass against the pinned
  Scheme reference. Typed staging itself uses compiler-owned `eval-kl` in its child.
- Vendored 23 kernel files byte-for-byte match the checksum-verified upstream
  43.1 tarball used by the Scheme reference.

Reference: `tizoc/shen-scheme` master at
`8d261518db17fbfec32d1b268b40ed216b925c74`, built with Chez 10.3.0.
Kernel archive SHA-256:
`900eedef44f440af78f9395ed06e689ce1604546fc309f5bc7c8bc84cc651920`.

These are concrete test results, not a claim of complete language equivalence.
The long suite remains opt-in, not silently included in ordinary `dune runtest`.
The vendored suite was refreshed with 20 previously missing 43.1 tests; its
harness differs only to make failure reporting noninteractive.

Seven-run measurements show substantial improvements over the legacy walker.
A narrow sealed integer loop now beats the measured Chez dynamic case, but most
workloads and especially the dynamic tier remain slower. Latest results/boundaries:
[validation-vigor-2026-10-21.md](docs/validation-vigor-2026-10-21.md).
The 2026-10-21 five-run default application CPU medians were competitive for those typed
loads but OCaml remains 5.4× slower on Prolog, 3.1× on dictionaries and 19× on the
higher-order list pipeline. See [application validation](docs/validation-applications-2026-10-21.md).

The [2026-10-22 wave](docs/validation-promotion-2026-10-22.md) adds controlled native
ceilings: explicit promotion improves list CPU ~2.13× and allocation ~39%, with
modest Prolog gains and no dictionary throughput win. The fresh default scorecard
still trails Chez ~6×/3.3×/20× on Prolog/dictionary/lists; no general superiority or
historical before/after speedup is claimed. See the [next-work plan](plans/application-performance.md).

## Outstanding

- General macro/package/datatype-aware native source compilation, automatic promotion,
  ABI-aware compilation caching and standalone applications.
- Remaining primitive adapters, larger-arity calls and continuation allocation.
- Runtime interned symbols and improved number/value representation.
- Arbitrary-precision integers and audited overflow/numerical edge behavior.
- Nested `defun` expressions in executable backends (explicit compile error).
- Broad upstream port-specific tests (native modules, Unicode/argv and embedding).
- Broader repeated application qualification against Chez; Linux qualification.
- Installable runtime packaging (the root Nix default still provides a toolchain).

The old status is retained in `docs/legacy-status-2026-04-06.md`.
