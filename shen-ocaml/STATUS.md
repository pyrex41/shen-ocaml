# Shen-OCaml Status (2026-06-08)

## Type-directed specialization (Phase C) — the differentiator

The thing no other Shen port does: **consume the `(tc +)` signature to drop tags.**
`src/codegen/ocaml_specialize.ml` emits, for a single-clause `define` whose declared
signature is monomorphic over `number` and whose body stays in an int subset
(`+ - *`, comparisons, `if`, `let`, calls to other specialized functions), a second
entry point over **unboxed OCaml `int`** (native ops, no tag dispatch) beside the
uniform `value` entry.

- **Type query**: the declared `{ number --> ... }` signature is the *only* input
  (never the body). The proof warrant is the checker — `test_specialize` loads the
  source under `(tc +)` and refuses a fast path for anything that doesn't
  type-check. (The kernel stores signatures as compiled prolog abstractions in
  `shen.*sigf*`, not readable types, so the declared type is read from the source
  it came from — faithful and tc+-proven.)
- **Soundness (tests written first)**: bit-identical to the interpreter on every
  input incl. 63-bit overflow (both paths native `int`); float args and
  non-subset bodies fall back to the uniform entry silently; **redefinition** of
  any web member invalidates the web (`Spec.web_valid` + an `Env` redefine hook) so
  callers observe the new definition. All in `test_specialize`.
- **Measured (BENCHMARKS.md, `bench/typed_vs_erased`)**: unboxed vs an *inlined
  tagged* baseline = **1.4–2.0×** on loop-carried folds (the honest tag-erasure
  win — below the thesis's order-of-10× because that needs flambda, absent on the
  apt 4.14 sandbox; treat as a floor). vs the full uniform table-dispatch path =
  127–261× end-to-end (mostly dispatch, **not** tags — reported separately).
- **Demonstration**: `bench/typed_vs_erased/README.md` shows the source, the
  signature, the generated OCaml for *both* entry points, and the ladder.

v1 scope (narrow by design): single-clause `number`-mono int functions. Out of
scope (recorded in the plan): floats/`/`, polymorphic + list/vector specialization,
cross-module specialization, JIT, and devirtualizing the uniform path. The kernel
suite (134/0) is untyped KL, so specialization does nothing there — expected.

## AOT backend (Phase B) — kernel compiled to native OCaml

`src/codegen/ocaml_compile.ml` is a true KL→OCaml compiler (vs `ocaml_gen.ml`,
which emits the AST as data). Each `defun` compiles to a native OCaml closure over
the uniform `value` type; control forms map to native OCaml; global calls go
through the function table for redefinition safety and free interop.

- **Whole kernel AOT-compiled**: `gen_aot_kernel` compiles all 21 `.kl` files to
  one OCaml module (`aot_kernel_compiled/`). **1073 defuns compiled** to native
  code; **60 forms interpreted** (the few giant type-checker defuns over the
  node-size gate — which would overflow `ocamlopt`'s stack — plus genuine
  top-level effects), run via the oracle `eval_kl`. Boot with `SHEN_AOT=1` (or
  `Aot_boot.boot_kernel_aot ()`).
- **Conformance: 134/0 in AOT mode**, identical to interpreted
  (`SHEN_AOT=1 python3 scripts/run_kernel_suite.py`). Exit gate met: suite green
  interpreted *and* AOT.
- **Boot time: 5.0× faster** — interpreted ~123 ms median vs AOT ~25 ms median
  (7 runs each, apt OCaml 4.14 sandbox). See BENCHMARKS.md.
- **Bit-identical**: `test_aot_fixture` proves AOT == interpreter on factorial,
  mutual recursion, let/and/or/cond/lambda/trap-error, partial application, and
  200k-deep tail recursion. `test_aot_kernel_boot` smoke-checks the AOT kernel.

Not yet done in Phase B: direct-call devirtualization within a unit (calls go
through the table for now), AOT-compiling the giant type-checker defuns (gated to
the interpreter), and a flatter codegen so those compile without the node gate.

## Kernel conformance (Phase A)

Suite: ShenOSKernel-41.1 `test/shen/kerneltests.shen` (35 `report` groups) driven
by `test/shen/harness.shen`.

- **Per-group isolated run** (each group a fresh process — `scripts/run_kernel_suite.py`):
  **134 passed / 0 failed** — full kernel conformance (matches the shen-rust count).
  Progression: 113/16 → 128/6 (Bool/Sym boolean equality) → 133/1 (`type` primitive
  arity 2) → 134/0 (`str` errors on non-atoms).
- **In-process regression gate** (`dune test` → `test_kernel_shen_suite`): 31 of the
  35 groups run in one process: **119 passed / 0 failed**. This is the always-on
  gate (excludes the order-dependent binary group and the slowest groups
  primes/einsteins/c- for speed); the script above is the honest headline.

Both modes measured on the OCaml 4.14 apt sandbox (see implementation_plan.md
"Deviation"). Run the full table with `python3 scripts/run_kernel_suite.py`.

### Fixed: type-checker rejected all well-typed `(tc +) ... --> boolean` code

The biggest conformance bug. `(load "n queens.shen")` under `(tc +)` failed with
*"type error in rule 1 of n-queens.all_Ns?"* on a plainly well-typed
`all_Ns? : number --> (list number) --> boolean`, and the same root cause sank
N Queens, search, L interpreter, quantifier machine, secd, and Prolog interpreter
(+15 tests). **Root cause:** the type checker's base-literal rule `shen.primitive`
(t-star.kl) types a literal by calling `(boolean? <term>)`, `(number? <term>)`, …
on the term *as data*. The kernel's `boolean?` (sys.kl) is `(= true V)`/`(= false V)`.
But `true`/`false` evaluate to this port's `Bool` variant, while an unevaluated
literal in a `define` body is the *symbol* `true`/`false` — and `Value.equal` did
not equate `Bool b` with `Sym "true"/"false"`. So `true : boolean` was unprovable;
the term fell through to the `symbol?` branch and clashed with the declared
`boolean`. **Fix:** `Value.equal` now equates `Bool b` with the `true`/`false`
symbols, and `is_true` accepts the `true` symbol (value.ml). Regression covered by
the conformance suite (128/6) and `test_eval` boolean cases.

### Fixed: `type` primitive had wrong arity (broke all typed `defcc` grammars)

`(type Expr Type)` is the arity-2 type-annotation primitive (returns `Expr`), but
this port registered it as **arity 1**. The kernel's YACC default-semantics path
(`shen.use-type-info` → `(type Out ResultType)`) over-applied it → "too many
arguments", failing every typed `defcc` grammar. Fixed `pr_type`/metadata to
arity 2 (primitives.ml). Impact: yacc 9/4 → 13/0, montague 2/1 → 3/0 (128/6 → 133/1).

### Fixed: `str` was lenient on non-atoms (broke `symbol?` on closures)

`str` stringified *any* value (a closure became `"<closure>"`). The kernel's
`symbol?` (sys.kl) falls through to `(trap-error (shen.analyse-symbol? (str V)) … false)`,
so `(symbol? <closure>)` returned true → `fixed-value?` kept lambda-valued
spreadsheet cells instead of applying them. Fixed `str` to error on closures /
streams / errors (primitives.ml). Impact: spreadsheet 1/1 → 2/0 (133/1 → **134/0**).

### Open conformance issues (none blocking — full suite green)

1. **Order-dependent `complement` (binary number datatype).** Passes in isolation,
   fails in-process after "Prolog tableau". `defprolog complement` gives it arity 6
   (its horn-clause procedure `define complement P1 P2 B L K C -> ...`); the binary
   `report` form is `shen->kl`-compiled as a unit, so `(complement [1 0])` is
   compiled to a currying lambda (6 > 1 args) *before* the in-group
   `(load "binary.shen")` redefines complement to arity 1 — so it returns a closure.
   An eval compile-vs-load timing interaction. Excluded from the in-process gate.
3. **Monolithic single-process run is slow.** Running all 35 groups in one process
   times out (>200s) even though every group is fast in isolation (~50s total) and
   none hang — cross-group state accumulation. A perf/state-leak item, not a
   correctness failure; the per-group script is the conformance oracle.

Also noted while debugging: the **REPL `define` path does not type-check** under
`(tc +)` (an ill-typed `(define bad {number --> boolean} X -> X)` is accepted at
the REPL though `load` correctly rejects it). Tracked for a later fix; the suite
loads via `load`, which does type-check.

## What Works

- **Kernel boot**: All 21 .kl files from ShenOSKernel-41.1 load and evaluate successfully
- **`shen.initialise`** runs without errors
- **Post-boot metadata**: All 45 registered primitives plus native `hash` have arity + `shen.lambda-form` registered in the property vector
- **REPL**: Real Shen REPL with balanced parenthesis input, routed through kernel `eval`
- **Verified expressions** (via kernel eval path, not just eval-kl):
  - `(+ 1 1)` → `2`
  - `(value *version*)` → `"41.1"`
  - `(cons 1 (cons 2 ()))` → `(1 2)`
  - `(hd (cons 1 2))` → `1`
  - `(let X 5 (+ X 1))` → `6`
  - `(tc +)` → `true` (type checker activates)
  - `(defun f (X) (* X 2))` then `(f 3)` → `6`
  - `(trap-error (simple-error "boom") (lambda E (error-to-string E)))` → `"boom"`
- **46 KL primitives total**: 45 in `Primitives.initialise` plus native `hash` installed before kernel boot (porting-guide count)
- **Interpreter**: Full tree-walking eval with lexical environments, all KL special forms
- **Partial application**: Under-application returns new closure, over-application chains
- **Native overwrites**: `=`, `+`, `*`, `-` have optimized hot-path implementations
- **Parser**: Full s-expression parser for .kl files
- **AOT data embedding**: All 21 kernel files can be pre-parsed to OCaml AST literals
- **Shen backpressure**: specs/core.shen (14 types) → shengen-ocaml → guard_types.{ml,mli} → library `shen_guard_types`, witness `Runtime.Guard_types_link`, depended on by `Interp.Boot` (Gate 2)
- **Build**: `dune build`, `dune test`, all 4 backpressure gates pass
- **Nix**: Reproducible dev environment via flake.nix (OCaml 5.3.0, dune 3.20.2)

## What Partially Works

- **`(tc +)` and typed define**: Type checker activates but may be slow on complex types
- **AOT codegen**: Emits KL as OCaml data literals; not yet compiling to native function bodies
## What Doesn't Work Yet

- **Code AOT**: No compilation of KL to OCaml function bodies
- **IR tail annotations**: `ir.ml` annotates tail positions but no backend consumes them
- **Symbol interning in values**: `Sym of string` uses string equality, not interned IDs
- **Native vs shen-cl `overwrite.lsp`**: Not yet compared (reference tree not in this workspace)
- **Type checker on typed user code**: rejects some well-typed `(tc +)` programs (see Open conformance issues)
## Code Sizes

| File | Lines | Purpose |
|------|-------|---------|
| src/runtime/primitives.ml | ~485 | KL primitives + native hash + overwrites + metadata |
| src/codegen/ocaml_gen.ml | 235 | KL→OCaml literal emitter + name mangling |
| src/interp/eval.ml | 213 | Tree-walking interpreter |
| src/kl/parser.ml | 158 | S-expression parser |
| src/interp/boot.ml | 105 | Kernel loader and bootstrapper |
| bin/main.ml | 90 | CLI/REPL |
| src/runtime/value.ml | 60 | Runtime value type |
| src/kl/ir.ml | 58 | IR with tail-position annotations |
| src/runtime/env.ml | 53 | Dual namespace environment |
| src/runtime/symbol.ml | 53 | Symbol interning |
| src/kl/ast.ml | 36 | KL AST type definition |

## Next Steps

1. Run kernel test suite and document pass/fail
2. Typed define, Prolog, pattern matching smoke tests (Task 6)
3. Code AOT: compile KL to OCaml function bodies
4. Integrate interned symbol IDs into `Sym` variant for O(1) equality
5. Compare native overwrites to shen-cl `overwrite.lsp` when that tree is available

## Verification

```bash
cd shen-ocaml
nix develop --command bash -c 'dune build && dune test'
make all                    # runs all 4 backpressure gates
./bin/shen-check.sh         # Shen tc+ on specs
printf "(+ 1 1)\n(value *version*)\n" | nix develop --command bash -c './_build/default/bin/main.exe'
```
