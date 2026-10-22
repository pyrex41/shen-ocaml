# Shen-OCaml architecture

## Execution paths

The default executable uses a **native-code kernel** and a **compiled dynamic
tier** for `eval-kl`. The legacy tree walker remains a comparison backend, not
the default execution engine.

```text
Shen source -> Shen's reader/macros/typechecker/compiler -> KL
                                                          |
                             lexical resolution (Kl.Resolved)
                                         /                \
                 executable host closures             generated OCaml
                   (Interp.Compiled)                 (Codegen.Native_gen)
                          |                                |
                   interactive eval-kl                  ocamlopt
                                                          |
                                               native kernel / KL modules
```

`native_kernel/dune` generates and compiles executable bodies for all 23 vendored
43.1 kernel files. It does **not** embed an AST and interpret it. The old data
embedding tool remains under `aot_kernel/` for its existing tests.

## Resolved IR

`src/kl/resolved.ml` validates special forms, assigns unique lexical binding IDs,
distinguishes named from dynamic calls, and computes free variables. Shadowed or
case-distinct names cannot collide. Compiler-generated OCaml identifiers use IDs,
not the legacy name mangler.

Both executable backends explicitly preserve left-to-right effects. Named call
operands are evaluated in order. Curried dynamic applications also execute each
intermediate application before evaluating the next operand, matching the Scheme
reference. Boolean conditions are checked rather than treating non-booleans as
false. General error-handler expressions are evaluated before the protected body.

## Native backend

`src/codegen/native_gen.ml` emits OCaml function bodies, lexical closures, native
conditionals, and tail calls. There is no interpreter fallback for unsupported
nodes: compilation fails explicitly.

- **Compatible (default):** named calls use stable, mutable function cells.
  Previously compiled callers observe later native or interpreted redefinitions.
- **Sealed (explicit):** saturated calls to unit-local functions become direct
  multi-argument OCaml calls. Selected fixed primitive operations are direct ABI
  calls as well. These calls construct no argument lists. Duplicate definitions
  in a sealed unit are rejected.

Self and mutual recursion stay in tail position. Native callable dispatch also
stays tail-recursive; checks around legacy callables are confined to that boundary.
Vector literals are allocated outside function bodies and retain their identity.

The shipped kernel currently uses **compatible** compilation. Sealed microbenchmark
numbers must not be presented as the speed of ordinary interactive Shen.

`Codegen.Numeric_loop` adds guarded workers for a narrow integer-closed recursive
subset in compatible and sealed modes. All input values must be `Int`; floats and other inputs use
the original boxed native body. Worker arithmetic and recursion keep integers
unboxed inside the loop. Effectful or unsupported bodies and unit-local primitive
shadowing prevent specialization. This preserves existing machine-int overflow;
it does not introduce arbitrary-precision arithmetic or infer that Shen `number`
means integer. Syntactic handler lambdas lower to direct exception handlers rather
than allocating callable wrappers and thunks on every successful `trap-error`.

Compatible workers also guard installed self-callable identity and every used
primitive's canonical identity. Redefinitions, stale references and partials
fall back to the original compatible body. Expected identity refs are published
before metadata callbacks. Hoisted entry guards assume a single-threaded runtime
and a proven callback-free worker; this is not concurrent binding invalidation.

## Dynamic backend

`src/interp/compiled.ml` resolves and compiles a KL expression once to executable
OCaml closures. Function invocations use indexed array frames; closures capture
only free lexical bindings. There is no repeated AST matching or string-based
local-variable lookup during function execution.

This is not a machine-code JIT. Dynamically loaded user definitions run this tier;
they are not automatically native OCaml functions. The restricted explicit native
user-module path below is separate from interactive compilation.

## Shared runtime and ABI

`src/runtime/value.ml` retains safe OCaml variants and the OCaml GC. `Native`
callables carry explicit remaining arity and specialized entry points; zero-arity
callables use a lean `Thunk of (unit -> value)` instead of a native record. Legacy
`Closure` values remain interoperable. `Runtime.Native` implements curry-on-demand,
overapplication and error propagation. Arity 0–8 saturated calls in both executable
backends use specialized entry points without argument lists or repeated name
lookups. Larger arities use a generic list ABI; some primitive adapters still
construct lists internally. Booleans use shared values. Common list/predicate/hash
operations have direct entries; vector equality avoids a per-comparison callback
closure, and scalar hashes avoid structural-hash bookkeeping.
Dynamic compilation reuses slots only across completed lexical scopes, drops
unused parameter/local slots without dropping their evaluation effects, and
specializes one/two captures. Writable invocation frames remain fresh; only proven
read-only capture snapshots may be shared across calls and reentrancy.

Globals and function bindings remain separate. Runtime symbols are still strings;
integrating the existing symbol intern table is outstanding. Numeric values are
still OCaml machine integers/floats, not an arbitrary-precision number system.
Native arithmetic currently inherits the machine-integer overflow limitation.

Primitive error results are converted to Shen exceptions at the native boundary.
Unexpected OCaml exceptions are not silently caught as successful Shen values.
Numeric structural equality and bounded hashing agree across integer/float keys,
including keys containing lists/vectors and signed zero.

## Bootstrap and CLI

`Interp.Boot.boot_native` selects compiled dynamic `eval-kl` before initialization,
installs compiled kernel definitions, sets host metadata,
installs host hashing and `symbol?`, runs `shen.initialise`, and registers primitive
metadata. Thus bootstrap-generated definitions also use the dynamic compiler.
Saved `fn` values and partial applications use late-bound function-cell wrappers,
not snapshots of an installed callable.

`bin/native_cli.ml` provides `eval`, `script` and the kernel's actual REPL. Interactive
stdin EOF unwinds the REPL rather than spinning forever. The old host REPL remains
available as `shen-ocaml-legacy`.

## Restricted native user modules

`bin/native_build.ml` reads unprocessed source, validates the supported function-only
function subset, calls non-installing `shen.shen->kl-h`, generates native bodies,
and invokes `ocamlopt -shared` with argv (no shell interpolation). It does not
capture/replay `eval-kl` calls or execute function bodies during compilation.
Custom macro/source-form registries and custom pattern hooks fail closed.

Modules must be wholly untyped or wholly typed. Typed signatures are limited to
base scalar, list and arrow types. Checking uses the same normalized bodies as
translation (`/.` becomes `lambda`; core `cond` becomes `if`), not arbitrary macro
expansion. A fork-isolated, single-threaded Unix staging child resets custom
datatype/synonym/signature state and uses built-in declarations/typechecking.
Only KL and literal type/predicate AST metadata return to the parent; successful
and failed staging leave host bindings and declaration state unchanged.

The compiler also generates native signature predicates. Loading checks all
declaration conflicts before changing the signature table, without calling
`declare`, `eval-kl`, ambient demodulation or foreign signature closures. Matching
native-owned types may be reinstalled; foreign/conflicting declarations are
rejected. This narrow registration path does not implement general declaration
variancy. Function/metadata installation as a whole is not a transactional loader.

Native plugins register an installation thunk in `Runtime.Native_artifact`.
Loading invokes that thunk, installs real native functions, and records source
metadata for `ps`/`userdefs`. Stored KL is metadata, never an execution fallback.
Content-qualified unit names permit distinct modules in one host. These are
trusted same-ABI plugins, with explicit include-directory configuration; there is
no automatic ABI-aware compilation cache or standalone application builder yet.

Supporting general typed applications, programmable patterns, macro staging, packages
and top-level initialization semantics remains future work, not an interpreter
fallback hidden behind a native-compilation command.

## Explicit post-expansion promotion

`bin/native_promote.ml` wraps the ordinary `eval-kl` callback after boot. A
definition observer reports the exact created callable before metadata callbacks;
receipts pair that identity with its original post-expansion KL. Nested metadata
redefinitions cannot associate an outer body with a nested replacement.

`Native_gen.compile_factories` generates compatible callable factories, not
installation actions. Promotion validates all original identities, compiles/loads
a fresh trusted same-ABI plugin, constructs replacement callables, then checks
precollected stable cells and publishes preallocated bindings without allocating
lookups or metadata callbacks. User bodies, source effects and type/arity/source
metadata are not replayed. Mutable vector literals fail closed to preserve escaped
literal identity. Compiler failures are explicit; observation/promotion counts are
available. The host is single-threaded and asynchronous host handlers must not
mutate bindings during promotion; this is not a concurrent transaction primitive.

`eval-promoted FILE DIR EXPR` and the native-ceiling benchmark expose this explicit
experiment. Normal execution does not automatically promote. Persistent ABI-aware
cache validation, promotion thresholds, memory budgets and standalone native
applications remain future work.

## Verification

- Generated modules are compiled by Dune and executed in tests, in both modes.
- The shared KL corpus is also executable on pinned upstream `tizoc/shen-scheme`.
- Canonical tests have an explicit opt-in runner with a hard timeout, saved logs,
  nonzero failure exit, and totals captured before the suite's final reset.
- One-million-deep self/mutual calls, redefinition, literal identity, malformed
  source, CLI evaluation, typed definitions and REPL EOF have regression tests.

The previous design description is retained in `docs/legacy-architecture.md`.
