# shen-ocaml Implementation Plan (revised 2026-04-06)

## Current state

What works end-to-end:
- dune project builds, tests pass, all 4 backpressure gates pass
- KL parser (parser.ml, ast.ml) — parses s-expressions from .kl files
- Runtime value types, symbol interning, dual namespace env
- 45 primitives registered in primitives.ml plus native `hash` (46 total per porting guide), with post-boot metadata
- Full eval.ml — local env, all KL special forms, partial application
- boot.ml loads all 21 kernel .kl files, calls shen.initialise, registers fn metadata
- REPL with balanced parens, kernel eval path — `(+ 1 1)` → `2`, `(tc +)` → `true`
- AOT codegen stub: emits KL AST as OCaml data literals
- Shen backpressure: specs/core.shen → shengen-ocaml → guard_types.{ml,mli}

## Reference material

- Kernel .kl files: `kernel/` (21 files from ShenOSKernel-41.1)
- Full requirements: `../ocaml-port-build-prompt.md`
- Porting guide: `../cl-source/ShenOSKernel-41.1/doc/porting.md` (46 primitives needed)
- CL primitives: `../shen-cl/src/primitives.lsp` (reference implementation)
- Scheme primitives: `../shen-scheme/src/primitives.scm`
- Kernel test suite: `../cl-source/ShenOSKernel-41.1/tests/kerneltests.shen`
- Individual test files: `../cl-source/ShenOSKernel-41.1/tests/*.shen`

## Environment

- **Canonical**: OCaml 5.3.0 via `nix develop` (flake.nix in project root), dune 3.20.2.
  All OCaml commands: `nix develop --command bash -c '...'`.

### Deviation: sandbox toolchain (host limitation, documented per ground rules)

Some CI/sandbox hosts (e.g. Claude Code web execution) have **no `nix` and no
network access to `opam.ocaml.org`**, so the canonical OCaml 5.3 toolchain cannot
be installed there. On those hosts the project is built with Ubuntu apt's
**OCaml 4.14.1 + dune 3.14.0** (`apt-get install ocaml-nox ocaml-dune
ocaml-findlib`). To keep one source tree buildable in *both* environments the
following backwards-compatible changes were made (5.3/nix still satisfies them):

- `dune-project`: `(lang dune 3.20)` → `(lang dune 3.14)`; ocaml floor
  `(>= 5.3.0)` → `(>= 4.14)`. (Lower floors; 5.3 + dune 3.20 remain valid.)
- Removed the unused `(using menhir 2.1)` stanza — there are **no `.mly`** files.
- Removed the unused `cmdliner` dependency from `bin/dune` — `bin/main.ml` never
  referenced it. Pure dead-dep removal.

No source code uses OCaml-5-only features (no effects/Domain/`In_channel`), so the
interpreter, codegen, and kernel boot build unchanged under 4.14. **Future work**
(Phase C specialization) may want flambda / `Int63` overflow intrinsics that are
better on 5.x; if a 5.x-only feature is adopted, the 4.14 fallback must be guarded
or the apt path retired with a note here.

**Gate status in the apt sandbox**: Gate 2 (`dune build`) and Gate 3 (`dune test`)
run and pass. Gate 1 (`shengen-codegen.sh`) and Gate 4 (`shen-check.sh`, needs
`shen-sbcl`) require external tools unavailable here; `specs/core.shen` and the
generated `guard_types.{ml,mli}` were not modified, so their verified state is
unchanged. Re-run gates 1/4 on a nix host before relying on type-bearing claims.

## Completed tasks

### Task 1: Fix primitive fn metadata ✅

After kernel boot, `register_all_metadata()` iterates all 45 registered primitives (plus `register_hash_fn_metadata` for `hash`) and registers arity + `shen.lambda-form` in the property vector. Called from boot.ml after `shen.initialise`.

### Task 2: Verify REPL end-to-end ✅

All smoke tests pass: `(+ 1 1)` → `2`, `(value *version*)` → `"41.1"`, `(tc +)` → `true`, `(cons 1 (cons 2 ()))` → `(1 2)`, `(defun f (X) (* X 2))` + `(f 3)` → `6`, `(let X 5 (+ X 1))` → `6`, `trap-error`/`simple-error` → `"boom"`.

## Tasks — in order of priority

### Task 3: Audit primitives against porting guide ✅

The porting guide specifies 46 primitives: **45** registered in `initialise` plus **native `hash`** (before kernel boot). Compare against `../shen-cl/src/primitives.lsp` when that tree is available.

Registered primitives (45):  
intern, +, *, -, set, value, simple-error, tc, =, cons, hd, tl, number?, cons?, string?, vector?, str, >, <, <=, >=, /, cn, pos, tlstr, n->string, string->n, symbol?, boolean?, open, close, read-byte, write-byte, get-time, type, eval-kl, **if**, and, or, absvector, <-address, address->, apply, error, error-to-string  

Plus native **hash** (not in `primitive_metadata_entries` list; `register_hash_fn_metadata` after boot).

Kernel-defined (not needed as OCaml primitives): put, get, not, append, @p, fst, snd, string->symbol, explode, implode

- [x] Verify `if` works correctly as both special form and primitive (`eval_app` short-circuits `(if ...)`; first-class `(let F if (F ...))` uses `pr_if` and evaluates all args — see `test/test_eval.ml`)
- [x] Check whether `trap-error` needs a primitive registration — **no** for `.kl` / REPL: all uses are `(trap-error ...)` special form; no `get_fn "trap-error"` required for shipped kernel
- [x] Verify we have all 46 from the porting guide — **aligned** with 45 + `hash` (previously missing registered `if` despite `pr_if` existing)
- [x] Test edge cases: `(value <unbound>)` → `Error "unbound value:..."`; `(set)` returns a **partial-applied closure** (Shen-style), not a host arity error — covered in `test_eval.ml`
- [x] Compare native overwrites against shen-cl's `overwrite.lsp` for peephole opts — see **Overwrite comparison** below

**Overwrite comparison** (`../../shen-cl/src/overwrite.lsp` vs `src/runtime/primitives.ml`):

- **shen-ocaml** re-binds only **`=`**, **`+`**, **`*`**, **`-`** via `native_overwrite` after `register`, using the same `pr_*` implementations. That mirrors the idea of **stomping** any kernel/KL redefinition so call sites keep the native implementations (hot path). **`hash`** is installed quietly *before* `shen.initialise` via `install_native_hash` to fix modulus/overflow behaviour; metadata is registered after boot.
- **shen-cl** `overwrite.lsp` is mostly **non-primitive** host code: reader speedups (`shen.str->bytes`, `shen.bytes->string`, `shen.rfas-h`, `shen.reader-error-message`), **macroexpand** / **`shen.macroexpand-h`** (EQ fast path before `absequal`), **cond factorization** in `defun`, plus CL integrations (**`hash`** via `sxhash`, dicts as hash tables, `read-file-as-*`, `vector`, `@p`, stream typing, `symbol?`/`variable?`/`atom?`, `vector->`/`<-vector`, etc.). There is **no** direct analogue of re-overwriting `+`, `*`, `-`, `=` in that file; CL compilation handles arithmetic differently.
- **Takeaway**: Overlap is **native `hash`** (different algorithms: bounded `Hashtbl.hash` + positive mod vs `sxhash`) and the **general goal** of faster I/O and expansion. shen-ocaml does **not** yet implement shen-cl’s reader/macroexpand/cond-factorization overrides; if profiling shows bottlenecks there, those are the next peephole targets—not more primitive stomps unless the kernel overwrites additional builtins.

### Task 4: Wire guard types into dune build ✅

Internal library **`shen_guard_types`** in `src/generated/dune` compiles `guard_types.{ml,mli}`. The **`shen`** library depends on it (`src/dune`). **`Interp.Boot`** includes `module _ = Runtime.Guard_types_link` so the witness stays on the boot dependency chain; **`Runtime.Guard_types_link`** calls `Shen_guard_types.Guard_types` builders so API drift fails **Gate 2 (`dune build`)**. See **ARCHITECTURE.md** (“Guard types and the four-gate loop”).

- [x] Add a `(library ...)` stanza in `src/generated/dune` that compiles guard_types
- [x] Have at least one module reference guard_types so changes cause build failures
- [x] Verify Gate 2 (build) now catches guard type regressions
- [x] Document the enforcement chain in ARCHITECTURE.md

### Task 5: Run kernel test suite ✅ — FULL CONFORMANCE (134/0)

**Status (2026-06-08): COMPLETE.** ShenOSKernel-41.1 `kerneltests.shen` runs at
**134 passed / 0 failed** (per-group isolated run, `scripts/run_kernel_suite.py`),
matching the shen-rust test count with zero failures. A bounded in-process
regression gate (`dune test` → `test_kernel_shen_suite`, 31 groups, 119/0) is
always-on. Both committed.

Five root-cause fixes got there (each its own commit, each with a regression test):
1. **`open` of a missing file must unwind** (was returning an `Error` value the
   kernel reader's `read-byte`-until-`-1` loop spun on forever). Fixed the
   cwd-dependent "load hang".
2. **`Value.equal` must equate `Bool b` with the `true`/`false` symbols** (+ `is_true`).
   `true`/`false` evaluate to a `Bool` variant but are *symbols* as data; the type
   checker's literal rule `(boolean? <term>)` (via kernel `boolean?` = `(= true V)`)
   failed on every `... --> boolean` definition. 113/16 → 128/6 (N Queens, search,
   L interpreter, quantifier machine, secd, Prolog interpreter).
3. **`type` primitive is arity 2** (`(type Expr Type) -> Expr`), was arity 1; the
   YACC default-semantics path `(type Out ResultType)` over-applied it. 128/6 → 133/1
   (yacc, montague).
4. **`str` errors on non-atoms** (closures/streams), was lenient; kernel `symbol?`
   falls through to `(shen.analyse-symbol? (str V))`, so `(symbol? <closure>)` was
   true and `fixed-value?` kept lambda cells. 133/1 → **134/0** (spreadsheet).

Tooling stood up: `scripts/run_kernel_suite.py` (full per-group runner, baseline
gate) and `test/test_kernel_shen_suite.ml` (in-process regression gate).

**Remaining Phase A work:**
- ✅ **TCO regression test** (1M-deep direct *and* mutual tail recursion) — added to
  `test_eval.ml`. Both shapes complete without stack growth: the interpreter's apply
  path (`eval → apply_value → closure → apply_user → eval`) stays in tail position
  and OCaml's TCO keeps the stack flat. No trampoline needed.
- ✅ **Number-tower decision: 63-bit native OCaml ints, no zarith (for now).** The
  full kernel suite (incl. `prime*? 1000003`, `count-change 100`) passes at 134/0
  with native ints; an audit found no ≥16-digit literals and no bignum-dependent
  test. zarith is unavailable in the apt sandbox anyway (opam blocked). **Revisit**
  if user code needs arbitrary precision; the prompt's warning that bolting it on
  after AOT is painful is noted — the AOT/specialization design should leave a seam
  for an overflow-check → promote path. Documented as a deviation here.
- **LC-3 integration oracle: BLOCKED (files unavailable).** `lc3.shen`,
  `asmhelp.shen`, `lc3asm.shen` are sibling work not present in this repo or
  container, and the network is restricted, so they cannot be vendored here. Re-do
  on a host that has them: drop under `tests/integration/`, assert byte-identical
  machine code (`Hi!` → `[48 0 224 2 240 34 240 37 0 72 0 105 0 33 0 0]`, loop →
  `R0=10`, `mem[12294]=10`) and matching `prolog?` answers.
- Bug noted while debugging: the **REPL `define` path does not type-check** under
  `(tc +)` (an ill-typed define is accepted at the REPL though `load` rejects it).

#### Historical sub-tasks (all subsumed by the above)

Test files are already in `test/shen/` (copied from ShenOSKernel-41.1). Harness is already patched (no `y-or-n?`).

#### Task 5a: Fix `(load ...)` — the Shen reader hangs

**Status**: File I/O works (open, read-byte, read-file-as-bytelist, read-file-as-string all work). The hang is in the Shen reader/compiler that parses s-expressions from a byte list.

**The bug**: `(read-from-string "(+ 1 1)")` hangs in the REPL. This means `read-file` also hangs (it calls `compile` with `shen.<s-exprs>` on the byte list). The kernel's `load` function uses `read-file`, so `(load ...)` hangs.

**Fixed already**:
- `*home-directory*` set to cwd with trailing `/` at boot (boot.ml)  
- `open` primitive prepends `*home-directory*` to paths (primitives.ml)
- `SHEN_KERNEL_DIR` env var works for running from non-root dirs

**Key insight**: `read-from-string` works when called via OCaml's `eval_kl` directly (test_repl_path.ml passes), but hangs when called via the **kernel's own eval** (REPL path). The REPL types `(read-from-string ...)` → kernel eval → `process-applications` rewrites → something loops.

The test `test_repl_path.ml` builds `KLApp(KLSym "eval", [KLApp(KLSym "hd", [KLApp(KLSym "read-from-string", [KLStr src])])])` and calls `eval_kl` — this works. But the same expression entered in the REPL goes through the kernel's eval → process-applications pipeline first, which may transform arguments incorrectly.

**To diagnose**:
1. Check if the kernel's `process-applications` rewrites `read-from-string` arguments in a way that causes the reader to receive wrong input
2. The string argument `"(+ 1 1)"` may be getting processed/macroexpanded when it shouldn't
3. Try simpler calls: does `(read-from-string "a")` hang? Does `(str 42)` work? Narrow down which kernel eval transformation causes the loop
4. Compare with how the REPL routes input through `bin/main.ml` — it builds the same KLApp structure but via `eval_kl`, bypassing kernel eval's process-applications

**Workaround for `(load ...)`**: Could route `load` through `eval_kl` instead of kernel eval. But fixing the root cause is better.

**Diagnosis (2026-04-06, iteration 2)**:

- **Reproduction**: Piping `(read-from-string "(+ 1 1)")` into `bin/main.exe` under `timeout 8` completes immediately and prints `((+ 1 1))` (one s-expr list). No hang observed.
- **Same path as REPL**: `test_repl_path.ml` already runs `eval_via_kernel` (kernel `eval` → macroexpand → `process-applications` → `shen->kl` → `eval-kl`). An assertion was added that `eval_via_kernel {|(read-from-string "(+ 1 1)")|}` yields `((+ 1 1))` as runtime values — i.e. the inner call is not stuck in the reader (`compile` + `shen.<s-exprs>`) nor in `process-sexprs`.
- **Conclusion**: The “REPL hang” for this form **does not reproduce** on the current tree. If it appeared before, it was likely fixed alongside `fn` / `shen.lambda-form` metadata and the kernel pipeline tests. Remaining `(load ...)` issues (e.g. harness errors) are separate from this nested `read-from-string` case.
- **If a hang returns**, the places to instrument are: `shen.str->bytes` + `shen.+string?` (string chunking), the Yacc-driven `compile`/`shen.<s-exprs>` parser on the byte list, and `shen.process-sexprs` / `shen.process-applications` (non-termination on cyclic or ill-typed intermediate AST).

- [x] Diagnose why `(read-from-string "(+ 1 1)")` hangs but `(+ 1 1)` at the REPL works  
- [x] Fix the reader/compiler hang — **`simple-error` must unwind** (`Value.User_error` + `eval` handlers) so kernel code does not run on bogus values; **KL parser** must not split **`->`** / **`<-`** (leading `-` only starts a number when followed by a digit or `.`), fixing `shen.find-arity` in `reader.kl`. **`read-file` / `read-from-string`** on `(define … X -> …)` complete quickly; **`(load "tiny.shen")`** still fails later (`shen.linearise` during `shen->kl` — separate from the hang).
- [x] Verify `(load "tiny.shen")` works after fix — REPL from `test/shen` loads `tiny.shen` and defines `double`; regression in `test_load_tiny_relative.ml` (`chdir test/shen`).

#### Task 5b: Run the harness + first few test groups

```bash
cd /Users/reuben/projects/shen/shen-ocaml/shen-ocaml/test/shen && \
  SHEN_KERNEL_DIR=/Users/reuben/projects/shen/shen-ocaml/shen-ocaml/kernel \
  printf '(load "harness.shen")\n(report "cartesian product" (load "cartprod.shen") loaded (cartesian-product [1 2 3] [1 2 3]) [[1 1] [1 2] [1 3] [2 1] [2 2] [2 3] [3 1] [3 2] [3 3]])\n' | \
  nix develop /Users/reuben/projects/shen/shen-ocaml/shen-ocaml --command bash -c '/Users/reuben/projects/shen/shen-ocaml/shen-ocaml/_build/default/bin/main.exe' 2>&1 | tail -20
```

- [ ] Test harness `(report ...)` macro works
- [ ] At least one test group passes with "passed" output

#### Task 5c: Run full kerneltests.shen

Only attempt this after 5a and 5b work. Use a timeout because some tests (Einstein's riddle, N-Queens) may be slow:
```bash
cd /Users/reuben/projects/shen/shen-ocaml/shen-ocaml/test/shen && \
  SHEN_KERNEL_DIR=/Users/reuben/projects/shen/shen-ocaml/shen-ocaml/kernel \
  timeout 120 bash -c 'printf "(load \"harness.shen\")\n(load \"kerneltests.shen\")\n" | \
  nix develop /Users/reuben/projects/shen/shen-ocaml/shen-ocaml --command bash -c "/Users/reuben/projects/shen/shen-ocaml/shen-ocaml/_build/default/bin/main.exe"' 2>&1 | \
  tee /Users/reuben/projects/shen/shen-ocaml/shen-ocaml/plans/kernel-test-results.txt | tail -50
```

- [ ] Capture full output to `plans/kernel-test-results.txt`
- [ ] Count passed/failed from output
- [ ] Update STATUS.md with results

#### Task 5d: Fix failures from kernel tests

Only after 5c produces results. For each failure:
1. Identify which test group failed
2. Run that test in isolation to reproduce
3. Diagnose: missing primitive? eval bug? kernel path issue?
4. Fix and re-run

- [ ] Fix at least the most critical failures
- [ ] Re-run full suite and update results

### Task 6: Run real Shen programs

Test the full Shen language surface area beyond kernel smoke tests. Run these in the REPL interactively or piped:

```bash
printf '(define double {number --> number} X -> (* X 2))\n(double 21)\n' | \
  nix develop --command bash -c './_build/default/bin/main.exe'
```

- [ ] Typed define: `(define double {number --> number} X -> (* X 2))` then `(double 21)` → `42`
- [ ] Multi-clause pattern match: `(define fact 0 -> 1 X -> (* X (fact (- X 1))))` then `(fact 10)` → `3628800`
- [ ] List operations: `(map (+ 1) [1 2 3])` → `[2 3 4]`
- [ ] Prolog: `(defprolog mem X [X | _] <--; X [_ | Y] <-- (mem X Y);)` then `(prolog? (mem 2 [1 2 3]))` → `true`
- [ ] YACC: `(defcc <as> a <as> := [a | <as>]; a := [a];)` then `(compile (fn <as>) [a a a])` → `[a a a]`
- [ ] File loading: create a small `test/hello.shen`, load it with `(load "test/hello.shen")`
- [ ] Document what passes and what fails in STATUS.md

### Task 7: Code AOT — compile KL to OCaml function bodies

Currently only "data AOT" (KL as OCaml data literals). True code AOT:

- [ ] Generate `let kl_fname args = ...` with actual OCaml function bodies
- [ ] Handle tail calls (OCaml does TCO for direct recursion)
- [ ] Handle partial application in generated code
- [ ] Test with one kernel file, then scale to all 21
- [ ] Measure boot time improvement vs interpreter

### Task 8: Symbol interning optimization

- [ ] Switch `Sym of string` to `Sym of int` using interned IDs
- [ ] Update equality to use ID comparison (O(1) vs O(n) string compare)
- [ ] Benchmark the improvement
