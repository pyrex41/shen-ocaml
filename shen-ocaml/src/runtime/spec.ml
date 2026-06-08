(** Phase C: runtime state for type-specialized (unboxed) call webs.

    A specialized function has two entry points: an unboxed [int] fast path and the
    uniform [value] entry registered in the function table. Internal calls between
    specialized functions go direct (no tag dispatch) *only while [web_valid]*; if
    any member of a specialized web is redefined at runtime ([eval-kl] can redefine
    anything), the web is invalidated and those calls reroute through the table to
    the (possibly new) definition. This keeps the optimization sound.

    v1 is conservative: a single global flag covers all specialized webs, so
    redefining any specialized function invalidates them all. That only ever makes
    things *more* correct (it never keeps a stale direct call), at the cost of
    losing the fast path after a redefinition. *)

let web_valid = ref true

(** Register the redefine hook so any [set_fn name] for a watched name invalidates
    the web. [members] are the specialized function names. *)
let watch (members : string list) =
  let tbl = Hashtbl.create (List.length members) in
  List.iter (fun n -> Hashtbl.replace tbl n ()) members;
  Env.redefine_hook :=
    (fun name -> if Hashtbl.mem tbl name then web_valid := false)
