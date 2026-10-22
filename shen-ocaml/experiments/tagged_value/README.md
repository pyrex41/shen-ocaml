# Isolated immediate-integer value experiment

**Recommendation: a bounded, reversible larger trial is justified to measure
allocation pressure, not a production representation migration yet.** The
integer allocation reduction is substantial, but checked extraction/dispatch
costs remain: retained-list traversal consistently regressed, and mutation
timings are not consistently better. These are synthetic microbenchmarks,
**not a Shen port speedup claim**. Nothing here is integrated into production.

## Scope and representation audit

This directory is self-contained and uses only OCaml's standard library and
`unix`. It does not import the changing production runtime or benchmark code.
Both implementations expose the same abstract `Api.S` through `.mli` files.

- `boxed.ml`: ordinary variant with a heap `Int of int` wrapper.
- `tagged.ml`: native OCaml integers as immediate values; **all** other cases
  are real OCaml variant blocks with payloads, including `Nil of unit` and
  `Bool of bool`. Nil/false/true cannot alias integer 0 or 1.
- Noninteger cases deliberately have the same shapes on both sides, including
  the heap singleton Nil, to isolate the integer representation change. This
  is a controlled boxed reference, not a claim that it is the most optimized
  possible boxed interpreter (which could use a constant Nil constructor).
- The entire `Obj` boundary is confined to `tagged.ml`: `Obj.repr` wraps native
  ints and ordinary allocated `block` variants; `Obj.is_int` separates those
  two sets; guarded `Obj.obj` decodes exactly those sets. No other module uses
  Obj. Abstract types prevent clients from injecting arbitrary objects.
- No forged pointers, header writes, custom GC, magic tags, custom blocks,
  address arithmetic, or Obj-based field mutation. Vector writes are ordinary
  checked OCaml array writes with the standard generational write barrier.
- Constructors accept already-typed OCaml payloads / abstract values; every
  extractor checks the kind, and arrays check indices and negative sizes.
  Wrong kinds raise `Invalid_argument` (messages need not be identical).
  Integer operations use OCaml's native signed integer range/overflow rules.

This is a small, auditable unsafe boundary, **not a formal safety proof**.
Adding an unchecked import, Marshal decoding, FFI conversion, or alternate
representation would require a new audit. This is not a complete Shen value
implementation: functions, closures, streams, exceptions, numeric coercion,
serialization, and runtime integration are deliberately absent.

## Equivalent workloads and measurement

`Workloads.Make` contains the single shared implementation of all algorithms
and is instantiated for each API. There are no allocating view wrappers on
either side, no special unboxed arithmetic worker, no boxed-only conversion
pass, and no change in algorithm between the two representations. Accessor
checks remain in both sides; the actual cost of these checks may differ.

| Workload | Work per measured call | Verified result |
| --- | --- | ---: |
| integer-sum | Tail-recursive value-level sum 200,000 down to 1 | 20,000,100,000 |
| integer-fib | Recursive value-level Fibonacci(26) | 121,393 |
| list-build-sum | Construct 20,000 integer cons cells, traverse with value accumulator | 200,010,000 |
| list-traverse | Traverse a retained, prebuilt 20,000-element list | 200,010,000 |
| structural-equal | Compare two distinct retained 10,000-element integer lists | 1 |
| vector-mutate | Create 256-element vector; perform 100,000 read/add/write updates; sum it | 100,000 |
| mixed-mutate | Build mixed vector; replace integer and fresh integer-cons fields 20,000 times | 40,000 |

Equality is shared, structural, and cycle-terminating: only mutable vector
pairs need a visited set, since immutable cons cycles must pass through a
vector. It uses the same physical-identity fast path on both sides; immediate
integers naturally benefit from that path. Cyclic equality is tested but not
part of the timed list-equality workload. Float equality is OCaml `(=)` after
the identity fast path, not a specification of Shen's float/NaN semantics.

Each run checks both implementations, executes GC stress, then performs three
warmup calls and nine timed samples of 20 calls per workload/representation.
Order alternates boxed/tagged then tagged/boxed to reduce ordering bias.
Every timed result is checked against an independently specified expected
answer and passed through `Sys.opaque_identity`. A full major collection
precedes each sample outside the timing interval. Timing uses wall-clock
`Unix.gettimeofday`, includes automatic GC, and excludes explicit setup GC.

Allocation is total allocated words (headers included), not retained heap:
`minor_words + major_words - promoted_words`. An explicit **minor collection
after stopping the timer** publishes the final nursery allocations before
reading `Gc.quick_stat` on OCaml 5. Without this step, its sampled counters
would undercount short trials. Small common harness allocations are included,
not subtracted (about 1.2 words/call in otherwise allocation-free cases).
Allocation counts are approximate and divided over the repeated calls.
Prebuilt lists are excluded from timed allocation but remain live on both
sides throughout. The benchmark minor heap is explicitly 262,144 words;
remaining GC settings are inherited defaults. No timing threshold gates tests.

## Correctness and GC stress

Both implementations passed all checks, including:

- Round trips of `min_int`, `min_int + 1`, -1, 0, 1, 2, `max_int - 1`, and
  `max_int`; kind checks and explicit 0/1 versus Nil/false/true inequality.
- Every extractor against every incompatible representative kind; negative
  vector length and out-of-bounds accesses/mutations.
- Float bit-preserving round trips including negative zero, infinities, and
  NaN; mixed vectors containing integers, booleans, symbols, floats, cons, Nil.
- Equal and unequal lists/mixed vectors; self-cyclic vectors and vector/cons
  cycles, including a differing field after a cycle.
- A 32,768-word stress nursery, 192 explicit minor collections, repeated full
  major collections and compactions. An old root vector receives fresh young
  children each round, exercising old-to-young writes. Up to 96 retained
  children hold nested vectors, self-references, vector-to-vector cycles,
  cons/symbol payloads, integers, and floats. Contents/identity are checked
  after each round. A separate retained vector preserves every boundary
  integer and the three singleton cases across these collections.

GC stress is empirical evidence, not evidence of compatibility with every
compiler/runtime or future OCaml optimization. Only native OCaml 5.3.0 on
64-bit macOS was exercised; not multicore mutation, bytecode, or 32-bit OCaml.

## Results (2026-10-21)

Apple M5, 32 GiB RAM, OCaml 5.3.0, Dune 3.20.2, Nix development shell,
default Dune development profile, native executable. The machine was not
reserved or CPU-pinned; other work may cause contention. Final run below;
microseconds are median **[minimum–maximum]** of the nine sample means.

| Workload | Boxed µs/call | Tagged µs/call | Boxed words/call | Tagged words/call |
| --- | ---: | ---: | ---: | ---: |
| integer-sum | 843.3 [764.1–957.3] | 654.9 [613.7–945.1] | 800,005.2 | 1.2 |
| integer-fib | 1,745.7 [1,303.8–2,085.7] | 1,328.4 [1,057.7–1,668.3] | 1,178,505.2 | 1.2 |
| list-build-sum | 272.9 [208.1–422.4] | 147.2 [130.1–221.7] | 140,003.2 | 60,001.2 |
| list-traverse | 74.7 [74.1–119.4] | 82.7 [82.6–109.7] | 40,003.2 | 1.2 |
| structural-equal | 111.3 [93.8–184.2] | 80.2 [76.0–145.0] | 6.2 | 6.2 |
| vector-mutate | 488.6 [486.4–1,155.9] | 517.2 [483.9–680.8] | 200,262.2 | 260.2 |
| mixed-mutate | 164.7 [163.1–196.9] | 152.7 [151.8–216.6] | 140,022.9 | 60,019.1 |

Two preceding corrected-sampler runs confirmed the allocation pattern but
show timing variability: boxed/tagged integer-sum medians were 813/687 and
801/675 µs; list-traverse 72/80 and 72/81; vector-mutate 476/485 and 562/545;
mixed-mutate 157/146 and 166/169. Do not read the final table's ratios as
precise general performance estimates or a statistically established win.

The larger trial should preserve a boxed fallback, audit every production
value boundary, run the full semantic suite and GC tests, and measure end-to-
end mixed Shen programs (allocation, retained memory, throughput, latency)
on a quiet machine. It should explicitly include numeric and nonnumeric
programs and investigate accessor dispatch costs before adoption. It might
also compare a safe specialized numeric-worker approach: reducing boxes does
not require changing every interpreter value representation.

## Reproduce without building in the shared tree

The actual runs used a source copy rooted at
`/private/var/folders/1_/dpmffg5j371662md64zvsktm0000gp/T/opencode/tagged-value.pyK03s/`,
created by rsync excluding **all `.git` and `_build` directories**. Only this
experiment target was built. No production file was changed by this lane.

From the repository root, make another private copy:

```sh
scratch=$(mktemp -d /private/var/folders/1_/dpmffg5j371662md64zvsktm0000gp/T/opencode/tagged-value.XXXXXX)
rsync -a --exclude=.git --exclude=_build ./ "$scratch/"
cd "$scratch/shen-ocaml"
nix develop . --command dune build @experiments/tagged_value/runtest
nix develop . --command dune exec ./experiments/tagged_value/experiment.exe
```

The scoped alias runs checks and stress only; the executable additionally
runs the repeated, checksum-checked measurements and emits CSV-style rows.
