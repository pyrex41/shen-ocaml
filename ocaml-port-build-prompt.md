# OCaml Shen Build Prompt

You are an expert OCaml compiler/runtime engineer. Build a new Shen implementation in OCaml inside this repository.

Create a new project directory named `shen-ocaml/`. This is not a toy interpreter. The goal is a serious, testable, performance-oriented Shen port that boots the real Shen kernel and exposes a usable Shen REPL.

## First: understand the source material

Before writing code, study these references in this repo:

- `cl-source/ShenOSKernel-41.1/README.md`
- `cl-source/ShenOSKernel-41.1/doc/porting.md`
- `cl-source/ShenOSKernel-41.1/klambda/`
- `cl-source/ShenOSKernel-41.1/tests/README`
- `shen-cl/src/compiler.shen`
- `shen-cl/src/primitives.lsp`
- `shen-cl/src/overwrite.lsp`
- `shen-scheme/src/compiler.shen`
- `shen-scheme/src/primitives.scm`
- `shen-go/README.md`
- `thoughts/shen-performance-research.md`

Also use the official Shen site for language semantics and examples:

- `https://shen-language.github.io`

Treat upstream kernel semantics and the working CL/Scheme ports as authoritative. Do not invent new Shen behavior.

## What Shen is

Shen is a self-hosted functional/logic language by Mark Tarver.

Important facts:

- The kernel is written in Shen itself.
- Shen ports target KLambda (`.kl`) plus a host runtime.
- Shen expects:
  - pattern matching
  - macros
  - lazy evaluation via `freeze`/`thaw`
  - optional type checking
  - integrated Prolog
  - higher-order functions and partial application
  - tail-recursive execution
  - dual namespace semantics (functions and globals are distinct)

Do NOT start by writing a native Shen parser as the main bootstrap path. Bootstrap from the existing `.kl` kernel. Once the kernel is up, Shen's own reader/compiler can handle `.shen` source.

## Primary goal

Build a new `shen-ocaml` port for Shen 41.1 using OCaml 5.x and dune.

The architecture should be hybrid:

1. AOT compile the shipped KLambda kernel to native OCaml modules.
2. Also implement a small internal KL evaluator or bytecode engine for runtime `eval-kl` and interactive definitions, because OCaml has no practical built-in native `eval`.
3. The AOT-generated path and the dynamic/interpreted path must share exactly one runtime semantics layer.

This is a performance-first architecture, but correctness comes first.

## Non-negotiable semantic requirements

Preserve these behaviors:

- Shen dual namespace semantics:
  - function bindings and global variable bindings are separate
- symbols as first-class data
- closures and higher-order functions
- `freeze` / `thaw`
- partial application
- `trap-error` / `simple-error`
- lists, vectors, strings, streams, numbers, booleans
- equality semantics compatible with Shen
- REPL behavior and kernel loading behavior
- metadata globals such as:
  - `*language*`
  - `*implementation*`
  - `*port*`
  - `*porters*`

Do not collapse Shen semantics into "whatever is convenient in OCaml" unless the behavior is observably equivalent.

## Performance intent

The current CL and Scheme ports are already good. This port should be structured to plausibly compete with `shen-scheme` and leave room to attack the real hotspots.

Assume the biggest performance issues are:

- dynamic apply / partial application overhead
- Prolog unification and type-checker runtime
- equality dispatch
- dict/property lookup
- symbol representation and intern lookup

Do not build a purely pretty tree-walking interpreter and stop there. The long-term fast path is AOT native OCaml for the kernel and shared runtime primitives.

## Project layout to create

Create at least:

- `shen-ocaml/dune-project`
- `shen-ocaml/README.md`
- `shen-ocaml/ARCHITECTURE.md`
- `shen-ocaml/src/runtime/`
- `shen-ocaml/src/kl/`
- `shen-ocaml/src/interp/`
- `shen-ocaml/src/codegen/`
- `shen-ocaml/src/generated/`
- `shen-ocaml/bin/`
- `shen-ocaml/test/`
- `shen-ocaml/scripts/`

Keep the layout clean and obvious.

## Core architecture requirements

### 1. Symbol system

Implement symbol interning with stable integer IDs.

Requirements:

- symbols must have printable names
- symbol equality must be fast, ideally integer identity
- generated OCaml identifiers must be deterministically mangled from Shen symbol names
- keep mangle/unmangle behavior documented

This is especially important because Shen symbol names include characters that are not valid OCaml identifiers.

### 2. Value representation

Use an explicit runtime `value` representation.

Likely categories include:

- integers
- floats
- strings
- symbols
- booleans or a boolean-compatible fast path
- cons cells
- vectors / absvectors
- closures
- primitive functions
- streams
- dynamic user-defined functions / callable handles
- Prolog variables or pvars, if needed explicitly

Do not hide the runtime behind over-abstracted layers. Keep the representation explicit and low-overhead.

### 3. Dual namespaces

Preserve Shen's dual namespace model directly:

- one table or structure for global values
- one table or structure for function bindings

Function and global names must not clobber each other.

Compiled functions should register themselves into the function table with explicit arity metadata.

### 4. Calling convention

This is critical.

Do NOT fully curry everything by default.

Preferred approach:

- known static calls compile to direct multi-argument OCaml functions
- dynamic or higher-order calls go through a runtime `apply` path
- under-application and over-application are handled by curry-on-demand or explicit arity-specialized wrappers
- keep arity metadata everywhere

The fast path should be direct OCaml calls. The slow path should still be correct.

### 5. Tail calls

Static tail calls should compile to ordinary OCaml tail calls whenever possible.

If dynamic apply would destroy TCO, introduce a trampoline only where necessary, not for the entire system.

Do not pessimize all calls in order to handle a small subset of dynamic cases.

### 6. Errors and control

Implement Shen errors as explicit OCaml exceptions.

Support:

- `simple-error`
- `trap-error`
- `error-to-string`

The behavior should match Shen semantics, not generic OCaml exception formatting.

### 7. Primitives

Implement the KL primitive surface carefully, based on the porting guide and working ports.

This includes things like:

- `if`, `and`, `or`
- `set`, `value`
- `cons`, `hd`, `tl`, `cons?`
- `intern`
- `absvector`, `absvector?`
- `<-address`, `address->`
- string operations like `pos`, `tlstr`, `cn`
- stream operations like `open`, `close`, `read-byte`, `write-byte`
- time and environment primitives
- equality and type predicates
- property table / dictionary support

Do not guess primitive semantics. Mirror the current CL/Scheme behavior.

### 8. Equality

Specialize equality by type:

- symbols by identity
- strings by contents
- numbers by numeric equality
- lists structurally
- vectors structurally

Avoid generic OCaml polymorphic compare in hot paths.

### 9. Prolog / type-checker runtime

Plan from the beginning for efficient unification runtime.

Use imperative data structures where appropriate:

- mutable arrays
- mutable records
- trails / binding stacks
- compact pvar representation

Do not implement the hot Prolog/typechecker path in the most allocation-heavy style if a clearer imperative layout is available.

## Compiler and interpreter requirements

### 1. KL parser

Build a parser for `.kl` files.

Requirements:

- parse the kernel KL files
- produce a clear AST
- support symbols, strings, numbers, lists, applications, and malformed-input errors
- add tests for parser correctness

### 2. Shared IR

Lower KL into a shared internal IR that both the interpreter and the AOT backend use.

The IR should make it easy to reason about:

- tail position
- static vs dynamic application
- primitive vs user call
- arity
- closure creation
- error handling

Do not fork semantics between interpreter and AOT codegen.

### 3. AOT OCaml code generation

Generate readable, deterministic OCaml source for kernel `.kl` files.

Requirements:

- direct OCaml function definitions for kernel functions
- registration code for the runtime function table
- reuse the shared runtime primitives
- generated code should be inspectable and debuggable
- keep codegen deterministic so rebuilds are stable

Prefer straightforward code generation over an unnecessarily fancy compiler pipeline.

### 4. `eval-kl`

OCaml does not give you a simple native `eval`, so implement `eval-kl` via the internal interpreter or bytecode engine initially.

This is acceptable:

- shipped kernel code is AOT native
- runtime-generated KL from user interaction is interpreted

What is NOT acceptable:

- depending on a nonexistent host eval
- blocking the whole port on a perfect native runtime compiler

If later it becomes clean to add `Dynlink` or an external compile-and-load flow, treat that as an optimization, not a prerequisite.

### 5. Bootstrapping strategy

Bootstrap from the existing 41.1 KL kernel.

Important notes:

- derive module load order from the existing ports and build scripts
- do not assume the order
- the 39.x order in `shen-go/README.md` is a clue, but use the actual 41.1 sources and existing ports for the real order
- expect files like:
  - `toplevel.kl`
  - `core.kl`
  - `sys.kl`
  - `reader.kl`
  - `prolog.kl`
  - `load.kl`
  - `writer.kl`
  - `macros.kl`
  - `declarations.kl`
  - `t-star.kl`
  - `types.kl`
  - and 41.1-specific extras such as `init`, `dict`, `stlib`, and extensions

Once the kernel is running, use Shen's own reader/compiler pipeline for `.shen` files.

## Implementation phases

### Phase 0: research and architecture

Before major coding:

- read the listed references
- write `shen-ocaml/ARCHITECTURE.md`

In `ARCHITECTURE.md`, explain:

- runtime `value` representation
- symbol intern table design
- dual namespace model
- call convention and partial-application strategy
- tail-call strategy
- `eval-kl` plan without host eval
- AOT vs interpreted split
- expected hotspots and optimization strategy

Then proceed to implementation. Do not stop at planning.

### Phase 1: runtime skeleton + KL parser + minimal interpreter

Build:

- dune project scaffolding
- runtime skeleton
- symbol table
- minimal primitive set
- KL parser
- minimal interpreter able to run hand-written KL examples and simple definitions

Add unit tests for:

- symbols
- values
- primitives
- parser
- interpreter basics

### Phase 2: AOT backend for kernel subset

Build:

- code generator
- shared IR lowering
- generated OCaml modules for a small subset of the kernel

Verify:

- direct calls
- globals
- closures
- errors
- equality
- primitive operations

Do not skip tests.

### Phase 3: full kernel boot

Compile enough of the 41.1 kernel to boot a Shen REPL.

Build a CLI binary:

- `shen-ocaml`
- `shen-ocaml script <file>`
- `shen-ocaml eval <expr>`

Ensure:

- boot metadata is correct
- `load` works
- the REPL can evaluate basic Shen programs

### Phase 4: compatibility and test suite

Run the kernel tests and representative Shen programs.

At minimum verify:

- `(value *version*)`
- `(tc +)`
- definition of a simple typed function
- applying that function
- loading test programs from the 41.1 test suite

Compare behavior against `shen-scheme` or `shen-cl` on representative cases.

### Phase 5: optimization pass

After correctness:

- profile the OCaml port
- prioritize:
  - dynamic apply / partial application
  - unification / deref
  - equality
  - dict lookup
  - property lookup
  - symbol hot paths

Add native OCaml hot-path implementations analogous in spirit to `overwrite.lsp`, but keep them documented and isolated.

Optional later optimization direction:

- an offline "freeze image" or codegen tool that compiles additional loaded KL/Shen code into generated OCaml modules and rebuilds a faster boot image

## Deliverables

Produce:

- a buildable `shen-ocaml/` project
- `README.md` with exact build and run instructions
- `ARCHITECTURE.md`
- a working CLI binary
- parser/runtime/interpreter/codegen tests
- integration tests or scripts for kernel boot and sample Shen programs
- a short `STATUS.md` or equivalent section documenting:
  - what works
  - what is partial
  - current blockers
  - obvious next optimization steps

## Concrete validation targets

At the end, the project should be able to demonstrate something like:

- native build succeeds with `dune build`
- the binary starts a Shen REPL
- it can evaluate:
  - `(value *version*)`
  - `(tc +)`
  - `(define f { number --> number } X -> (* X 2))`
  - `(f 3)`
- it can load and run a meaningful subset of the standard test programs
- ideally it runs the full kernel test suite; if not, document exactly what remains broken

## Technical guidance

Prefer:

- `Hashtbl`, arrays, bytes, and mutable records in hot runtime code
- deterministic source generation
- explicit arity metadata
- explicit closure and callable representations
- direct OCaml calls on the static path
- minimal dependencies

Avoid:

- OCaml objects for runtime values
- polymorphic compare in hot code
- overusing functors or ppx-heavy abstractions
- building a handwritten Shen parser first
- assuming runtime host eval exists
- leaving the system as only a slow interpreter
- multicore/parallelism in the first pass

If you use host booleans internally, ensure Shen-visible semantics remain correct.

## Working style

Proceed incrementally.

After every major phase:

- run tests
- update docs
- summarize what now works

When choosing between two correct implementations, prefer the one that keeps future performance work easier.

Be explicit about blockers. Do not fake correctness.

Start now by:

1. reading the listed references
2. creating `shen-ocaml/`
3. writing `ARCHITECTURE.md`
4. scaffolding the dune project
5. implementing Phase 1
