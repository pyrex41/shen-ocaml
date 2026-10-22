# Legacy baseline

From `shen-ocaml/`:

```sh
nix develop --command dune exec --profile release bench/baseline.exe
```

`RESULT` rows contain aggregate wall time, process CPU time and OCaml allocated
bytes. Every workload checks its answer; errors exit nonzero. Boot is cold within
the process (not a cold OS cache); execution cases have one untimed warmup, exclude
KL parsing, and include result validation. Repeat whole-process runs to assess
noise. This measures the existing interpreter, **not** a completed fast port.

No Scheme speed ratio is established by this runner. A comparative harness must
run identical workloads, validate both answers, pin source revisions and kernel
hashes, and distinguish dynamic execution from native application compilation.

## Default application scorecard

```sh
python3 bench/run_applications.py /path/to/pinned/upstream/shen-scheme --runs 5
# Optional capcov datatype sources (not an entire capcov modelcheck run):
python3 bench/run_applications.py /path/to/pinned/upstream/shen-scheme --runs 5 --capcov /path/to/capcov
# Separate, untimed macOS CPU sampling:
python3 bench/run_applications.py /path/to/pinned/upstream/shen-scheme --runs 1 \
  --case prolog-einstein --cpu-profile ocaml-default --profile-seconds 5
```

Both ports run the same checked Shen program in fresh processes. Jobs are
interleaved with a recorded random seed. Reports include input/driver hashes,
separate setup/work CPU and wall clocks, external process wall time, and logs.
Typed loads also test rejection of poisoned input. Input drift fails the run.
Work includes result checks and the shared Shen repeat loop; external wall also
includes boot, driver loading, setup, checks and output. This track contains no
sealed/native-file compilation results. CPU samples and Memprof runs are separate
diagnostics, never included in timing medians. The CPU runner verifies a nonempty
sample file and saves sampler command output rather than trusting its exit code.

See [current results](../docs/validation-applications-2026-10-21.md).

## Post-expansion native ceiling

```sh
python3 bench/run_native_ceiling.py --runs 5
```

This separate track loads ordinary Shen source through the kernel, observes its
actual installed KL definitions, and optionally promotes those definitions to
compatible native bodies. It compares checked list/dictionary/Prolog work in
fresh processes with randomized order and one full untimed warmup. Reports include
work CPU/wall/allocation and promotion wall time. Work excludes source setup and
compilation; external wall includes the Nix launcher. It is **explicit promotion**,
not automatic default execution, an ABI-aware cache, or a sealed/native-application
comparison against Chez. Unsupported promotion fails rather than silently using
the dynamic tier.

## Executable backend comparison

```sh
nix develop --command dune exec --profile release bench/compare_native.exe
```

This runs the same checked workload bodies in four modes: legacy tree walker,
compiled dynamic tier, native-compatible, and native-sealed. Generated OCaml is
compiled and linked by Dune. Parsing and definition installation are excluded;
the tiny outer invocation and result check are included in every mode. There
are 20 timed repetitions after one warmup per workload. This is a local backend
comparison, not a Chez ratio or an end-to-end application benchmark.

Repeat whole-process runs and record samples/medians/source identity:

```sh
python3 bench/run_comparison.py --runs 7 --seed 431
python3 bench/run_scheme.py /path/to/pinned/upstream/shen-scheme --runs 7
```

Reports are saved in `_build/qualification/`. The Scheme runner compiles the
same KL workload definitions, installs arity metadata, checks results and times
the same repetitions. Its Shen repeat-loop overhead is included; the OCaml
runner uses a host loop. Neither measurement includes source compilation or
boot. Do not infer sealed-app performance for Scheme from this dynamic test.
The OCaml runner shuffles backend order reproducibly and records each order.
`compare_native.exe` also accepts `--mode`, `--seed`, and `--repetitions`.

## Targeted allocation diagnostics

```sh
nix develop --command dune exec --profile release bench/compare_wide.exe
nix develop --command dune exec --profile release bench/profile_kernel.exe -- \
  --scenario typecheck --rate 0.001 --output _build/qualification/typecheck-profile.json
nix develop --command dune exec --profile release bench/profile_kernel.exe -- \
  --scenario prolog --repetitions 5 --rate 0.001 --output _build/qualification/prolog-profile.json
nix develop --command dune exec --profile release bench/profile_kernel.exe -- \
  --scenario list --size 1000 --repetitions 5000 --rate 0 --output _build/qualification/list-unsampled.json
nix develop --command dune exec --profile release bench/profile_kernel.exe -- \
  --scenario dictionary --size 2000 --repetitions 100 --rate 0.001 --output _build/qualification/dictionary-profile.json
```

`compare_wide` runs identical compiled functions through specialized entries and a
generic-list-ABI control, checking answers and that specialization removes argument
allocation. It is not a historical wall-time comparison. The Memprof runner
attributes sampled allocations, symbolizing generated kernel names. Its time and
GC allocation counters **include profiler overhead** and are not speed benchmarks.
Per-site estimates are statistical, not exact allocation totals.
`--rate 0` skips Memprof entirely and labels unprofiled metrics explicitly.
`--warmup` defaults to one checked repetition outside measurement. List/dictionary
sizes are configurable and expected answers are overflow-checked. This diagnostic
includes per-repetition reader/eval work; its totals differ from the prepared-
expression native-ceiling runner and shared-loop application scoreboard.

Reference discovered on 2026-10-21:

- Repository: https://github.com/tizoc/shen-scheme
- Branch: `master`
- Commit: `8d261518db17fbfec32d1b268b40ed216b925c74`
- Release: v0.52 plus unreleased byte-string/Unicode fixes; S43.1 kernel.

This reference is upstream, not the sibling `pyrex41/shen-scheme` fork. Kernel
provenance must be reconciled before attributing typechecker speedups to a host
implementation rather than kernel changes.
