# shen-ocaml

A compiler-first port of [Shen](https://shen-language.github.io/) (kernel 43.1)
to OCaml 5.3: native-code kernel, compiled dynamic `eval-kl`, and explicit
compatible/sealed KL-to-OCaml compilation. Performance reference:
[tizoc/shen-scheme](https://github.com/tizoc/shen-scheme).

The canonical kernel suite passes **154/0** on macOS ARM64. This is an active
rebuild, not yet a fully qualified high-performance release; see [STATUS.md](STATUS.md).

## Prerequisites

- [Nix](https://nixos.org/download/) (provides OCaml 5.3.0, dune 3.20.2, and all dependencies)

## Build and Test

```bash
cd shen-ocaml
nix develop                                        # enter dev shell
dune build                                         # build everything
dune test                                          # run tests
```

Or without entering the shell:

```bash
nix develop --command bash -c 'dune build && dune test'
```

## Run

```bash
nix develop --command dune exec --profile release shen-ocaml
```

This boots the compiled kernel and starts Shen's own REPL. Batch commands:

```
nix develop --command dune exec --profile release shen-ocaml -- eval '(+ 20 22)'
nix develop --command dune exec --profile release shen-ocaml -- script program.shen
```

The old tree-walking executable is retained as `shen-ocaml-legacy`.

## Native user functions

The restricted native user-module path supports **typed or untyped function-only files**, not
arbitrary Shen application loading. Compile and load in separate processes:

```sh
nix develop --command dune exec --profile release shen-ocaml -- \
  compile-native --sealed test/fixtures/native_user_numeric.shen _build/native-user
# Prints the generated shen_user_<digest>.cmxs path. Use that exact path:
nix develop --command dune exec --profile release shen-ocaml -- \
  eval-native /path/printed/above.cmxs '(native-fast-sum 20000 0)'
```

Omit `--sealed` for compatible late-bound calls. `repl-native PLUGIN` loads the
module and enters the REPL. Plugins are trusted executable code and require the
exact host ABI, not a sandbox or portable bytecode. Compile cost is separate from
execution; existing artifacts can be loaded again without recompilation.

Supported: standard cons/literal/variable patterns, core forms and lambdas,
saturated named calls to module functions and a small runtime-call list. Use
explicit lambdas for currying. Typed modules use built-in scalar/list/arrow types
and fork-isolated checking; all definitions in a file must be typed or all untyped.
Native signature predicates load without `eval-kl` or ambient type hooks;
foreign/conflicting declarations are rejected. Packages, custom macros/patterns,
changed macro/source-form registries, arbitrary top-level effects, and unsupported
static calls are rejected, not silently interpreted. The runtime-call list is a
syntactic frontend restriction, **not** a restriction on higher-order callees.

Source-tree builds discover their matching compiler interfaces automatically.
For other hosts, set `SHEN_OCAML_NATIVE_INCLUDE_DIRS` (colon-separated matching
CMI/CMX directories) and optionally `SHEN_OCAML_OCAMLOPT`.

### Experimental post-expansion promotion

```sh
nix develop --command dune exec --profile release shen-ocaml -- \
  eval-promoted test/shen/einsteins-riddle.shen _build/promoted '(prolog? (riddle))'
```

This loads source normally once, then compiles its observed KL definitions and
replaces only their implementations before evaluating the expression. Macro and
Prolog expansion use the actual kernel pipeline, not the restricted source
whitelist. Promotion preserves metadata and late binding; stale definitions and
mutable vector literals are rejected. Compiler failures fail the command, not
silently fall back. This is an explicit, same-process, same-ABI experiment—not
automatic promotion or a reusable compilation cache. Host asynchronous signal
handlers must not mutate function bindings during promotion.

## Compatibility and performance checks

```sh
python3 scripts/check_kernel_suite.py --backend native --timeout 60
python3 scripts/check_scheme_oracle.py /path/to/pinned/upstream/shen-scheme --kernel-suite
python3 scripts/check_native_user.py
python3 scripts/check_native_typed.py /path/to/pinned/upstream/shen-scheme
python3 scripts/check_native_promotion.py
python3 bench/run_applications.py /path/to/pinned/upstream/shen-scheme --runs 5
nix develop --command dune exec --profile release bench/compare_native.exe
```

The canonical suite is opt-in and fails on timeout or nonzero failed totals. See
[bench/README.md](bench/README.md) for measurement boundaries and the oracle pin.
The [latest application scorecard](docs/validation-promotion-2026-10-22.md)
shows substantial remaining default-execution gaps against Chez; native numeric
microbenchmark wins are not application-wide speed claims.

## Emit native OCaml from KL

```sh
nix develop --command dune exec tools/compile_native.exe -- --compatible input.kl output.ml
nix develop --command dune exec tools/compile_native.exe -- --sealed input.kl output.ml
```

Compile the generated module against the `shen` library and call `run ()` after
initializing primitives. Compatible mode observes redefinitions; sealed mode
permits direct local calls. The native kernel and execution tests demonstrate
the Dune generation/build/link pattern. This is not yet a native Shen-file
application builder; ordinary dynamically loaded Shen definitions still use the
compiled tier unless explicitly compiled through the restricted native path above.

## Project Structure

```
shen-ocaml/
├── bin/native_cli.ml        Native-kernel CLI and kernel REPL
├── native_kernel/           Generated, compiled kernel function bodies
├── src/
│   ├── runtime/
│   │   ├── value.ml         Runtime value type
│   │   ├── symbol.ml        Symbol interning
│   │   ├── env.ml           Dual namespace (fn + global tables)
│   │   ├── primitives.ml    Shared KL primitives
│   │   └── native.ml        Native callable ABI
│   ├── kl/
│   │   ├── ast.ml           KL AST types
│   │   ├── parser.ml        S-expression parser
│   │   └── resolved.ml      Executable IR and free-variable analysis
│   ├── interp/
│   │   ├── eval.ml          Tree-walking interpreter
│   │   ├── compiled.ml      Indexed-frame dynamic compiler
│   │   └── boot.ml          Kernel loader
│   └── codegen/
│       ├── ocaml_gen.ml     Legacy KL data emitter
│       └── native_gen.ml    KL→executable OCaml backend
├── kernel/                  ShenOSKernel-43.1 .kl files
├── specs/core.shen          Shen sequent-calculus type specs
├── test/                    Unit and integration tests
└── flake.nix                Nix dev environment
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for design details and [STATUS.md](STATUS.md) for current progress.
