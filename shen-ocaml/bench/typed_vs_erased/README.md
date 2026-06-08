# Typed vs erased — the thesis made visible (Phase C/D)

Every existing Shen port type-checks under `(tc +)` and then **throws the proof
away**, running tagged dynamic values. This example shows shen-ocaml doing the
thing no other port does: **using the declared type to drive code generation** —
the same Shen source, with its signature *consumed* vs *ignored*.

## 1. The source (one function shown; full file: `typed_numeric.shen`)

```shen
(define lcg
  { number --> number --> number }
  Acc N -> (if (= N 0) Acc (lcg (+ (* Acc 1664525) N) (- N 1))))
```

It is a loop-carried LCG fold (each `Acc` depends multiplicatively on the
previous one and wraps on 63-bit overflow), so it cannot be reduced to a closed
form. **The `{ number --> number --> number }` signature is the only input to
specialization** — never the body — and the `tc +` proof is the warrant
(`test_specialize` refuses to trust anything that doesn't type-check).

## 2. The two generated entry points (checked in below; live copy in
`_build/.../specialized.ml`)

**Signature consumed → unboxed native `int`, no tags, no dispatch:**

```ocaml
let rec sp_lcg_ (l_Acc : int) (l_N : int) : int =
  (if (l_N = 0) then l_Acc else (sp_lcg_ ((l_Acc * 1664525) + l_N) (l_N - 1)))
```

**Signature ignored → uniform tagged `value`, every op boxed, every call through
the function table** (this is the Phase B AOT — already faster than a tree-walker,
but still tagged):

```ocaml
let uniform_sp_lcg_ = mkcl 2 (function
  | [l_Acc; l_N] ->
    if is_true (E.apply_value (Sym "=") [l_N; Int 0]) then l_Acc
    else
      let __t2 = E.apply_value (Sym "*") [l_Acc; Int 1664525] in
      let __t1 = E.apply_value (Sym "+") [__t2; l_N] in
      let __t3 = E.apply_value (Sym "-") [l_N; Int 1] in
      E.apply_value (Sym "lcg") [__t1; __t3]
  | _ -> Error "arity")
```

A uniform **wrapper** is what gets registered in the function table; it dispatches
`Int` arguments (and only while the specialized web is valid) to `sp_lcg_`, and
falls back to `uniform_sp_lcg_` for floats / after any redefinition — so the fast
path is **sound**, never observed to differ from the interpreter.

## 3. The measured ladder

`dune exec bench/typed_vs_erased/bench_main.exe` (apt OCaml 4.14, **no flambda**):

| workload (N=10M, fib 32) | unboxed | inlined-tagged | uniform (table) |
|--------------------------|---------|----------------|-----------------|
| lcg (loop-carried)       | 12.2ms  | 21.3ms (1.8×)  | 2972ms (245×)   |
| loopsum (sumto)          |  9.4ms  | 18.4ms (2.0×)  | 2452ms (261×)   |
| fibo 32 (tree recursion) | 11.3ms  | 15.9ms (1.4×)  | 1429ms (127×)   |

- **unboxed vs inlined-tagged (1.4–2.0×)** is the honest *tag-erasure* win on this
  toolchain: it removes one heap-boxed `Int` per iteration. The order-of-10× the
  thesis targets needs flambda's autovectorization/unboxing propagation, which the
  4.14 sandbox lacks — so read 1.4–2.0× as a **floor**, not the ceiling.
- **unboxed vs uniform (127–261×)** is end-to-end, but most of it is table dispatch
  + currying that *any* AOT elides — **not** tag erasure. Reported separately so the
  headline stays honest.

## 4. Where types *don't* help (honesty checks)

`usescons` has a `{ number --> number }` signature but its body uses `cons`/`hd`,
so it leaves the int subset and is **not specialized** — it gets only the uniform
entry, silently and correctly (`test_specialize` checks this). The kernel test
suite headline (134/0) is **untyped KL**, so specialization does nothing there —
that is expected, and stated rather than hidden.

## Scope (v1)

Single-clause `number`-monomorphic functions over `{+,-,*}`, comparisons, `if`,
`let`, and calls to other specialized functions. Out of scope, recorded in
`plans/implementation_plan.md`: floats/`/`, polymorphic and list/vector
specialization, cross-module specialization, JIT profiling, and direct-call
devirtualization of the uniform path.
