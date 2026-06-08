# Shen-OCaml Architecture

## Overview

Port of Shen Language (kernel 41.1) to OCaml 5.3. Follows the standard Shen porting approach: implement KL primitives in the host, provide a tree-walking interpreter for `eval-kl`, and bootstrap the full kernel from `.kl` files.

Current architecture:
- **Interpreter-first**: All kernel `.kl` files are loaded and evaluated by a tree-walking interpreter at boot time.
- **AOT data embedding**: Kernel `.kl` files can be pre-parsed and embedded as OCaml AST literals (via `ocaml_gen.ml`), avoiding file I/O at boot. This is data AOT, not code AOT.
- **Code AOT** (not yet implemented): Compiling KL to actual OCaml function bodies for native performance.

## Value Representation (`src/runtime/value.ml`)

```ocaml
type value =
  | Int of int
  | Float of float
  | Str of string
  | Sym of string       (* symbol name as string *)
  | Bool of bool
  | Cons of value * value
  | Nil
  | Vec of value array  (* mutable absvector *)
  | Closure of (value list -> value)
  | Stream of stream    (* In_chan | Out_chan *)
  | Error of string     (* for simple-error *)
```

Notes:
- `Sym` stores the symbol name directly as a string (not interned ID). Symbol interning exists in `symbol.ml` but is not integrated into the `Sym` variant — this is a known simplification.
- `Closure` is a plain function `value list -> value`. Arity is not stored in the closure itself; instead `make_closure` in `primitives.ml` creates a wrapper that checks argument count and handles partial application.
- Type-dispatched `equal` function avoids polymorphic compare in hot paths.

## Symbol Interning (`src/runtime/symbol.ml`)

- Global intern table: `string -> { name: string; id: int }`
- Pre-interns common symbols (true, false, +, -, etc.)
- Currently used for ID-based equality in specific contexts, but `Sym of string` in value.ml means most equality goes through string comparison.
- Future optimization: switch `Sym` to use interned IDs for O(1) equality everywhere.

## Dual Namespaces (`src/runtime/env.ml`)

Two separate hashtables keyed by string:
- `fn_table`: function bindings (name → Closure value)
- `global_table`: global variable bindings (name → value)

`set`/`value` operate on globals. `set_fn`/`get_fn` operate on functions. These never collide.

After kernel boot, `register_fn_metadata` stores arity and `shen.lambda-form` in the kernel's property vector for each function. This is required because the kernel's `eval` → `process-applications` rewrites function calls to `(fn name)` form, which looks up `shen.lambda-form`.

## Calling Convention and Partial Application

- All functions are `Closure of (value list -> value)`.
- `make_closure arity f` creates a closure that:
  - If called with exactly `arity` args: calls `f` directly
  - If called with fewer: returns a new closure capturing partial args
  - If called with more: calls `f`, then applies the result to remaining args
- No static/dynamic call distinction yet — everything goes through the dynamic path.
- Direct OCaml calls for AOT-compiled functions is a future optimization.

## Tail-Call Strategy

- OCaml handles tail calls natively for direct recursive calls.
- The interpreter's `eval` is naturally tail-recursive for `if`, `let`, `cond`, `do`.
- `IR.lower()` in `ir.ml` annotates tail positions but this is not yet consumed by any backend.
- No trampoline is currently needed — OCaml's TCO handles the common cases.

## Eval-KL

- Tree-walking interpreter in `src/interp/eval.ml` (213 lines).
- `eval : local_env -> kl_expr -> value` with lexical environment threading.
- Special forms recognized in `eval_app` by symbol name: `defun`, `lambda`, `let`, `if`, `cond`, `freeze`, `thaw`, `trap-error`, `do`, `and`, `or`.
- The KL parser produces only `KLApp` nodes for lists — special forms are dispatched at eval time, not parse time.
- `eval-kl` primitive calls back through `eval_kl_from_value_hook` to break the Primitives↔Eval dependency cycle.

## Boot Process (`src/interp/boot.ml`)

1. `primitives.ml:initialise()` — registers 44 primitives in fn_table.
2. `boot.ml:set_port_metadata()` — sets `*language*`, `*implementation*`, etc.
3. Load all 21 kernel `.kl` files via parser + interpreter (order doesn't matter per 41.1 spec, but we use a fixed order matching other ports).
4. `patch_kernel_hash()` — replaces kernel's `hash` with a native version that avoids integer overflow.
5. `boot.ml:register_all_metadata()` — registers arity and `shen.lambda-form` for all primitives in the kernel's property vector.
6. `shen.initialise` — runs the kernel's init function.
7. Enter REPL via `shen.repl` or process user input.

The REPL routes user input through the kernel's own `eval` function (not `eval-kl` directly), which runs macroexpansion, `process-applications`, and the full Shen compilation pipeline. This is why `shen.lambda-form` metadata is essential.

## Primitives (`src/runtime/primitives.ml`)

44 KL primitives registered, organized by category:
- Arithmetic: `+`, `-`, `*`, `/`, `>`, `<`, `>=`, `<=`
- Equality: `=` (type-dispatched)
- Lists: `cons`, `hd`, `tl`, `cons?`
- Symbols: `intern`, `str`, `symbol?`
- Strings: `cn`, `pos`, `tlstr`, `n->string`, `string->n`, `string?`
- Vectors: `absvector`, `<-address`, `address->`, `vector?`
- Predicates: `number?`, `boolean?`
- I/O: `open`, `close`, `read-byte`, `write-byte`
- Control: `if`, `and`, `or` (also special forms in eval)
- Globals: `set`, `value`
- Errors: `simple-error`, `error`, `error-to-string`, `trap-error` (special form)
- Meta: `type`, `eval-kl`, `tc`, `get-time`, `apply`

Note: `if`, `and`, `or` exist as both special forms in eval.ml (for short-circuit behavior) and as registered primitives. The eval special form takes precedence.

## Code Generation (`src/codegen/ocaml_gen.ml`)

Currently emits KL AST as OCaml data literals (not executable code):
- `emit_expr` converts KL AST nodes to OCaml constructor syntax
- `mangle` converts Shen symbol names to valid OCaml identifiers (k_ prefix + hex encoding for special chars)
- `emit_forms_module` wraps parsed .kl forms as a module exporting `forms : kl_expr list`
- `emit_kernel_bundle` generates all 21 kernel files as a single module

This "data AOT" path avoids re-parsing .kl files at boot but still interprets them. True "code AOT" (KL → OCaml function bodies) is not yet implemented.

## Guard types and the four-gate loop

Shen specs in `specs/core.shen` drive **shengen-ocaml**, which emits `src/generated/guard_types.{ml,mli}`. Those modules are compiled as the internal dune library **`shen_guard_types`** (`src/generated/dune`), and the main **`shen`** library depends on it (`src/dune`).

`src/runtime/guard_types_link.ml` is a small witness module that calls representative `Shen_guard_types.Guard_types` builders so that if shengen renames or changes signatures, **Gate 2 (`dune build`)** fails at compile time. `Interp.Boot` includes `module _ = Runtime.Guard_types_link` so that witness stays on the kernel boot dependency chain (not only compiled as an orphan module). This closes the backpressure chain from specs through generated OCaml types into the build graph.

Typical gates (project automation): **shengen** regenerates guard types → **build** → **test** → **shen-check** (typed Shen verification on specs).

## Testing

- `test/test_parser.ml` — parser basics
- `test/test_symbol.ml` — symbol interning
- `test/test_eval.ml` — interpreter special forms, primitives, partial application
- `test/test_repl_path.ml` — integration test with full kernel boot + eval pipeline
- `test/test_codegen_smoke.ml` — codegen output verification
- `test/test_types_kl_aot.ml` — AOT kernel bundle compilation proof

## Known Issues and Simplifications

- `Sym of string` doesn't use interned IDs — symbol equality is string comparison
- `Closure` doesn't carry explicit arity — `make_closure` wraps with arity checking
- IR tail annotations exist but aren't consumed by any backend
- Guard types use `float` for all numeric fields (shengen limitation); runtime integration beyond the compile-time witness in `guard_types_link.ml` is still minimal
- Several stub functions remain: `ast.ml:of_value`, `parser.ml:to_value/from_value`
