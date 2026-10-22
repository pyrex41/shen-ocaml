# Performance reboot — 2026-10-21

Implementation has since delivered the native kernel, compiled dynamic tier,
stable function cells, arity 0–8 dispatch and 154/0 current canonical tests.
The next application-focused plan is `application-performance.md`; measured
explicit promotion and remaining gaps are in `../docs/validation-promotion-2026-10-22.md`.
See `../STATUS.md` for current evidence.
The assessment below records the starting point and intended remaining work.

## Decision proposed

Rewrite the compiler/runtime core incrementally, keeping the legacy interpreter
available as a development comparison, not as the performance architecture.
Retain parser code and fixtures only where they pass independent semantic tests.
Do not delete the existing port or equate a successful boot with compatibility.

The behavioral/performance reference is **tizoc/shen-scheme upstream**, currently
`8d261518db17fbfec32d1b268b40ed216b925c74` (master). See `bench/README.md`.
Target the 43.1 kernel family, recording exact artifact checksums. Local fork
kernel optimizations are a separate experimental variable, not a host speedup.

## Findings from the existing implementation

- Kernel boot and enabled `dune runtest` tests pass under OCaml 5.3.0.
- The canonical kernel suite is disabled in `test/dune` with an explicit comment
  that it loops. There is no full-compatibility result.
- `ocaml_gen.ml` emits syntax-tree data, not native function bodies.
- Every function takes a `value list`; local variables use association lists;
  symbols in runtime values remain strings despite a separate intern table.
- `ir.ml` does not resolve lexical variables, and its tail annotations do not
  drive execution. It is not an adequate compiler IR as written.
- Both primitive and user-function overapplication currently return an error.
  Error values coexist with exceptions; these semantics need an oracle audit.
- `ARCHITECTURE.md` and `STATUS.md` contain stale descriptions and counts.

## Architecture to prove, not assume

1. **Resolved KL IR.** Resolve lexical bindings once, identify free variables,
   normalize evaluation order explicitly with ANF-style lets, and distinguish
   function-name calls from calls through values. Preserve Shen's left-to-right
   effects; OCaml operand evaluation order must never leak into Shen behavior.
2. **Shared runtime.** Interned symbols, separate global and function cells,
   explicit arity and partial-application objects, arity-specialized apply entry
   points, and exceptions for nonlocal error propagation. Measure representation
   choices before introducing unsafe tagging or `Obj` tricks.
3. **Real native kernel.** Generate OCaml function bodies and compile with
   `ocamlopt`. No AST dispatch or argument-list construction on proven static
   saturated calls. Use native tail calls, including mutually recursive groups.
4. **Fast dynamic tier.** Compile `eval-kl` once to resolved instructions or
   executable closures; do not walk raw syntax on every invocation. This tier
   supplies low-latency REPL behavior but is not the final user-code speed path.
5. **Native user code.** Add batch KL/Shen-to-OCaml compilation and native module
   loading (`Dynlink` where supported), followed by standalone application builds.
   Measure compile latency separately. Only choose an in-process machine-code JIT
   if profiling shows its benefits justify a second backend and its maintenance.
6. **Compatible versus sealed compilation.** Ordinary execution must observe
   redefinition through stable function cells or validated/invalidation-aware
   fast paths. Direct cross-function calls that freeze bindings belong in an
   explicit sealed mode. Do not silently change interactive Shen semantics.

Unification, property lookup, strings, equality and numerical specialization are
profile-driven follow-ups. Reuse the OCaml GC initially. Avoid parallelism and a
custom collector until evidence identifies a real bottleneck.

## Acceptance gates and sequence

### 0 — Establish an honest oracle

- Pin and build the upstream Scheme reference without altering the sibling fork.
- Record kernel provenance for both ports and reconcile the canonical test suite.
- Differential tests: left-to-right effects, currying/overapplication, redefinition,
  error propagation, strict booleans, vector literals/identity, bytes, streams,
  numerical equality and overflow behavior, and deep tail calls.
- Make the full kernel suite runnable with a timeout and machine-readable totals;
  disabled or timed-out tests are not passes.

### 1 — Native vertical slice

- Implement resolved IR and native generation for constants, lets, conditionals,
  static calls and tail recursion. Compile generated output in tests; do not
  merely assert that emitted source contains expected strings.
- Add closures, partial application, errors, dynamic calls and definition cells.
- Run the same semantic fixtures through the old interpreter, new dynamic tier,
  native output and Scheme. Agreement with legacy alone is insufficient.

### 2 — Full kernel and native user programs

- Compile the unmodified pinned kernel and pass the canonical suite.
- Support loading Shen source, macros, Prolog, typechecking, namespaces and
  programmable patterns through the real kernel pipeline.
- Demonstrate a loaded user function running native code, not just a native
  kernel calling an interpreter. Test redefinition across compiled modules.

### 3 — Performance qualification

- Startup/boot, read/expand/compile, and execution reported separately.
- Workloads: recursion, higher-order calls, allocation/list traversal, equality,
  dictionaries, Prolog search/unification, typechecking, and representative
  applications (including capcov typed batches when available).
- Compare dynamic-to-dynamic and native-app-to-native-app; also publish the
  practical end-to-end load-and-run comparison. Include CPU, wall time, allocated
  bytes, peak RSS, binary size and compilation cost with repeated-run dispersion.
- Goal: compete with or beat Chez on representative workloads. No speed claim
  until checked outputs, exact revisions and reproducible measurements exist.

## Work completed in this assessment

Added `bench/baseline.ml`, a checked release-profile legacy baseline covering boot,
tail recursion, higher-order calls, list traversal, equality and Shen reader/eval.
It is groundwork only: no new compiler, kernel update, Scheme ratio, or full
compatibility qualification has been delivered yet.
