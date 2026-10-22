(** Entry guards for compatible integer workers. The runtime is single-threaded:
    a proven worker has no callbacks or mutation, so these checks remain valid
    throughout the worker. Concurrent binding mutation would invalidate that
    assumption and requires a different synchronization protocol.

    Stable cells and physical callable identity avoid wrapping epoch counters.
    Primitive proof is against the canonical implementation closure, NEVER an
    arbitrary binding observed when a generated module is first loaded. *)
open Value

let binding cell expected =
  match cell.Env.binding, expected with
  | Some actual, Some expected -> actual == expected
  | _ -> false

let primitive cell canonical =
  match cell.Env.binding with
  | Some (Native { code = Function2 implementation; _ }) -> implementation == canonical
  | _ -> false

(** Publish the expected callable before installation: metadata registration can
    call user code, including the newly installed function. That code still
    checks the actual cell, so metadata redefinitions immediately fail closed.
    Repeated installs may replace [expected] safely: each reference belongs to
    just one generated definition, with the same body on every run. *)
let install expected name arity fn =
  expected := Some fn;
  Native.install name arity fn
