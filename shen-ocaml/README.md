# shen-ocaml

A port of [Shen](https://shen-language.github.io/) (kernel 41.1) to OCaml 5.3.

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
nix develop --command bash -c './_build/default/bin/main.exe'
```

This boots the Shen kernel (loads 21 .kl files, calls `shen.initialise`) and starts a REPL:

```
Shen-OCaml — loading kernel…
Kernel ready.
shen> (+ 1 1)
2
shen> (value *version*)
"41.1"
shen> (cons 1 (cons 2 ()))
(1 2)
```

## Project Structure

```
shen-ocaml/
├── bin/main.ml              CLI and REPL
├── src/
│   ├── runtime/
│   │   ├── value.ml         Runtime value type
│   │   ├── symbol.ml        Symbol interning
│   │   ├── env.ml           Dual namespace (fn + global tables)
│   │   └── primitives.ml    44 KL primitives
│   ├── kl/
│   │   ├── ast.ml           KL AST types
│   │   ├── parser.ml        S-expression parser
│   │   └── ir.ml            IR with tail annotations
│   ├── interp/
│   │   ├── eval.ml          Tree-walking interpreter
│   │   └── boot.ml          Kernel loader
│   └── codegen/
│       └── ocaml_gen.ml     KL→OCaml literal emitter
├── kernel/                  ShenOSKernel-41.1 .kl files
├── specs/core.shen          Shen sequent-calculus type specs
├── test/                    Unit and integration tests
└── flake.nix                Nix dev environment
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for design details and [STATUS.md](STATUS.md) for current progress.
