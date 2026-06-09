# Flambda and the Phase C numbers

## This sandbox is non-flambda

```
$ ocamlopt -config | grep -i flambda
flambda: false
```

The apt OCaml 4.14 toolchain used in this environment is **not** built with the
flambda optimizer (there is no nix and no opam — `opam.ocaml.org` is network-
blocked — so the canonical 5.3 + flambda toolchain from `flake.nix` cannot be
installed here). Every number in `BENCHMARKS.md` and
`bench/typed_vs_erased/README.md` is therefore a **non-flambda floor**, not the
ceiling.

## Why flambda matters for the tag-erasure thesis

Phase C consumes a `(tc +)` signature to emit unboxed OCaml `int`/`float` instead
of tagged `value`. On the non-flambda build the measured win over an *inlined
tagged* baseline is only ~1.4–2.0× — essentially the cost of one heap-boxed `Int`
per loop iteration. The larger wins the thesis targets (order-of-10×) come from
optimizations that **only the flambda middle-end performs once the values are
unboxed**:

- aggressive cross-function inlining of the small numeric kernels,
- unboxing propagation / scalar replacement (keeping `int`/`float` in registers),
- loop-invariant code motion and, on suitable bodies, autovectorization.

Without flambda these do not fire, so the unboxed code wins only by avoiding the
per-iteration allocation. The dispatch-elision win (vs the full uniform path,
127–261×) is real but orthogonal — it is what *any* AOT compilation buys and is
reported separately so it is never confused with tag erasure.

## Reproducing the canonical numbers on a flambda host

1. Get a flambda OCaml. Either:
   - **nix** (canonical): `nix develop` using the repo `flake.nix` (OCaml 5.3 +
     flambda), or
   - **opam**: `opam switch create 5.3.0+flambda` (or
     `opam switch create . ocaml-variants.5.3.0+options ocaml-option-flambda`).
   Confirm: `ocamlopt -config | grep flambda` → `flambda: true`.
2. Build the benchmark with the optimizing profile and run it:
   ```
   bash scripts/bench_flambda.sh
   ```
   The script detects flambda, builds `bench/typed_vs_erased/bench_main.exe` with
   `dune build --profile flambda` (`-O3 -inline 1000 -unsafe`, defined in the root
   `dune`'s `(env (flambda ...))`), runs it, and prints the toolchain banner so the
   numbers are self-labeling.
3. The benchmark prints three columns per workload — **unboxed**,
   **inlined-tagged**, **uniform** — so the flambda run is directly comparable to
   the non-flambda table in `BENCHMARKS.md`. The honest claim to verify on flambda
   is whether the *unboxed vs inlined-tagged* ratio grows toward the order-of-10×
   target. **Do not quote a flambda figure until it has actually been measured on a
   flambda toolchain.**

## A vs-shen-cl/SBCL comparison

Also unmeasured here: the same typed source on shen-cl/SBCL. `shen-cl` is not
installable in this sandbox (it needs SBCL + the Shen build, and the package hosts
are blocked). Run it on a host that has shen-cl to close the loop on the
"beats SBCL on typed numeric code" claim.
