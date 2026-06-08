(** 
 * src/runtime/env.ml
 * Dual namespace environment: functions and globals.
 *)

open Value

let global_table : (string, value) Hashtbl.t = Hashtbl.create 256
let fn_table : (string, value) Hashtbl.t = Hashtbl.create 256

let get_global name =
  try Some (Hashtbl.find global_table name) with Not_found -> None

let set_global name v =
  Hashtbl.replace global_table name v

let get_fn name =
  try Some (Hashtbl.find fn_table name) with Not_found -> None

let set_fn name v =
  Hashtbl.replace fn_table name v

(** After [set_fn], mirror [shen.execute-store-arity] and [shen.set-lambda-form-entry]
    so code from [read-from-string] (which wraps calls as [(fn name) ...]) finds
    [shen.lambda-form] and [arity] on the property dict.
    Skips if [*property-vector*] is not set yet (e.g. while bootstrapping kernel files). *)
let register_fn_metadata name arity cl =
  match get_global "*property-vector*", get_fn "put" with
  | Some pv, Some (Closure put_cl) -> (
      let put attr v =
        match put_cl [ Sym name; Sym attr; v; pv ] with
        | Error msg ->
            failwith ("register_fn_metadata put " ^ name ^ " " ^ attr ^ ": " ^ msg)
        | _ -> ()
      in
      put "arity" (Int arity);
      if arity > 0 then put "shen.lambda-form" cl)
  | _ -> ()

(** Breaks the Primitives ↔ Eval cycle: Primitives calls this hook; Eval registers at load time. *)
let eval_kl_from_value_ref : (value -> value) ref =
  ref (fun _ -> Error "eval-kl: evaluator not initialised")

let set_eval_kl_from_value f = eval_kl_from_value_ref := f

let eval_kl_from_value_hook v = !eval_kl_from_value_ref v

(* Initialize some globals *)
let _ =
  set_global "*version*" (Str "41.1-ocaml");
  set_global "*language*" (Str "OCaml");
  set_global "*implementation*" (Str "shen-ocaml");
  set_global "*tc*" (Bool false)
