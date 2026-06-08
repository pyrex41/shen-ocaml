# Shen-OCaml Status (2026-04-06)

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
- **Kernel test suite**: Not yet run (`kerneltests.shen` from ShenOSKernel-41.1)
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
