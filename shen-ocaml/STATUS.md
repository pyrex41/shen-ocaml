# Shen-OCaml Status (2026-06-08)

## Kernel conformance (Phase A)

Suite: ShenOSKernel-41.1 `test/shen/kerneltests.shen` (35 `report` groups) driven
by `test/shen/harness.shen`.

- **Per-group isolated run** (each group a fresh process — `scripts/run_kernel_suite.py`):
  **113 passed / 16 failed**, plus **N Queens** which hangs (see below). 129 tests
  account for + N Queens ≈ the ~134 shen-rust runs.
- **In-process regression gate** (`dune test` → `test_kernel_shen_suite`): the
  order-independent clean subset (22 groups) runs in one process: **76 passed / 0
  failed**. This is the always-on gate; the script above is the honest headline.

Both modes measured on the OCaml 4.14 apt sandbox (see implementation_plan.md
"Deviation"). Run the full table with `python3 scripts/run_kernel_suite.py`.

### Open conformance issues (the long tail)

1. **Type-checker rejects well-typed `(tc +)` code.** `(load "n queens.shen")`
   under `(tc +)` fails: *"type error in rule 1 of n-queens.all_Ns?"* on the
   plainly well-typed `all_Ns? : number --> (list number) --> boolean`. After the
   failed load, `(n-queens 5)` hangs (half-defined functions). The same family of
   `(tc +)` groups account for most failures: **yacc (4)**, **L interpreter (3)**,
   **secd (3)**, **quantifier machine (2)**, **montague (1)**, **search (1)**,
   **spreadsheet (1)**, **Prolog interpreter (1)**. Likely a single bug in how the
   sequent prover (sequent.kl / t-star.kl) executes on the interpreter. Needs a
   shen-cl reference to diff intermediate proof state (unavailable in this
   sandbox — network blocked). **Not yet fixed; highest-value next target.**
2. **Order-dependent `complement` (binary number datatype).** Passes in isolation,
   fails in-process after "Prolog tableau". `defprolog complement` gives it arity 6
   (its horn-clause procedure `define complement P1 P2 B L K C -> ...`); the binary
   `report` form is `shen->kl`-compiled as a unit, so `(complement [1 0])` is
   compiled to a currying lambda (6 > 1 args) *before* the in-group
   `(load "binary.shen")` redefines complement to arity 1 — so it returns a closure.
   An eval compile-vs-load timing interaction. Excluded from the in-process gate;
   tracked here.
3. **N Queens hang** is a downstream symptom of (1), not an independent bug.

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
