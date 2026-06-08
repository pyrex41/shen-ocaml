# Benchmarks

All numbers are reproduced by committed scripts. Honesty rules (see the build
prompt): pinned workloads, ≥5 iterations, reported spread, and a note on the
machine. **These were measured on the apt OCaml 4.14 sandbox** (no nix/flambda;
see `plans/implementation_plan.md` "Deviation"), so they are a *lower bound* on
what a flambda 5.3 build will show — treat them as directional until re-run on the
canonical toolchain.

## Boot time: interpreted vs AOT (Phase B)

Booting the kernel by interpreting the 21 `.kl` files vs linking the
AOT-compiled module and running `shen.initialise`.

| mode        | min     | median  | mean    |
|-------------|---------|---------|---------|
| interpreted | 117.5ms | 123.3ms | 124.1ms |
| AOT         |  22.8ms |  24.6ms |  24.7ms |

**Median speedup: 5.0×.** (7 runs each; process start → `Kernel ready`.)

Reproduce:

```
dune build
python3 - <<'PY'
import subprocess, time, statistics, os
BIN="./_build/default/bin/main.exe"
def bench(env, n=7):
    ts=[]
    for _ in range(n):
        t0=time.perf_counter()
        subprocess.run([BIN], input="", capture_output=True, text=True,
                       env={**os.environ, **env})
        ts.append(time.perf_counter()-t0)
    return sorted(ts)
for name, env in [("interpreted", {"SHEN_KERNEL_DIR":"kernel"}), ("AOT", {"SHEN_AOT":"1"})]:
    ts=bench(env)
    print(f"{name:12} median={statistics.median(ts)*1000:.1f}ms")
PY
```

## Type-directed specialization: typed vs erased (Phase C)

The *same* Shen source (`bench/typed_vs_erased/typed_numeric.shen`) compiled with
its `{number --> ...}` signature **consumed** (unboxed OCaml `int`, native ops, no
tags) vs **ignored**. Three reference points, reported honestly:

- **inlined-tagged** = direct OCaml recursion over boxed `value` (no table lookup),
  i.e. *this port's own inlined baseline* — isolates the cost of **tags/boxing
  alone**. This is the honest yardstick.
- **uniform** = the full tagged path: per-call function-table lookup + currying +
  boxing (this port's Phase B AOT). The unboxed/uniform ratio is dominated by
  **dispatch**, not tags — it is an end-to-end number, **not** a "tags cost" claim.

Run: `dune exec bench/typed_vs_erased/bench_main.exe` (apt OCaml 4.14, no flambda).

| workload (N=10M, fib 32) | unboxed | inlined-tagged | uniform |
|--------------------------|---------|----------------|---------|
| lcg (loop-carried)       | 12.2ms  | 21.3ms (1.8×)  | 2972ms (245×) |
| loopsum (sumto)          |  9.4ms  | 18.4ms (2.0×)  | 2452ms (261×) |
| fibo 32 (tree recursion) | 11.3ms  | 15.9ms (1.4×)  | 1429ms (127×) |

**Honest reading.** Dropping tags buys **~1.4–2.0×** here (avoiding a per-iteration
`Int` heap box). That is **below** the order-of-10× the thesis targets — because the
big wins (autovectorization, unboxing propagation once tags are gone) require
**flambda**, which the apt 4.14 sandbox does not have. On the canonical 5.3/flambda
build these numbers should grow; treat 1.4–2.0× as a floor for the tag-erasure win
on this toolchain. The 127–261× vs uniform is real but is mostly the cost of table
dispatch + currying that *any* AOT call elides, not tag erasure — so it is reported
separately and not quoted as the specialization headline.

**Not yet measured (needs other toolchains):** vs shen-cl/SBCL on the same typed
source (shen-cl not installable in this sandbox); the flambda 5.3 numbers.

## Conformance wall-time

`python3 scripts/run_kernel_suite.py` runs the 35 ShenOSKernel-41.1 groups, each
in its own process. Both modes report **134 passed / 0 failed**. Run the AOT
variant with `SHEN_AOT=1` prefixed.

## What didn't work / honesty notes

- A monolithic single-process run of all 35 groups is slow (>200s) even though
  every group is fast in isolation and none hang — cross-group state
  accumulation. The per-group script is the conformance oracle; this is a
  perf/state item, not a correctness one.
- AOT vs interpreted *execution* speed (not boot) is not yet benchmarked here:
  calls still go through the function table, so the win is the absence of AST
  re-walking + native control flow, not devirtualization. A loop-carried
  numeric benchmark (`bench/typed_vs_erased`) belongs to Phase C and is not yet
  written — do not quote an execution speedup until it exists.
