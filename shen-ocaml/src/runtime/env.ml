(** 
 * src/runtime/env.ml
 * Dual namespace environment: functions and globals.
 *)

open Value

let global_table : (string, value) Hashtbl.t = Hashtbl.create 256
type function_cell = { name : string; mutable binding : value option }

let fn_table : (string, function_cell) Hashtbl.t = Hashtbl.create 256

let function_cell name =
  match Hashtbl.find_opt fn_table name with
  | Some cell -> cell
  | None ->
      let cell = { name; binding = None } in
      Hashtbl.add fn_table name cell;
      cell

let get_global name =
  try Some (Hashtbl.find global_table name) with Not_found -> None

let set_global name v =
  Hashtbl.replace global_table name v

let get_fn name =
  match Hashtbl.find_opt fn_table name with
  | Some cell -> cell.binding
  | None -> None

let set_fn name v =
  (function_cell name).binding <- Some v

(** Native installs a specialized reference factory at module initialization.
    Keeping the hook here avoids an Env -> Native -> Env module cycle. A saved
    [fn] value must resolve the current binding even after partial application. *)
let fn_reference_factory : (string -> int -> value) ref =
  ref (fun _ _ -> failwith "native function-reference factory is not initialized")

let set_fn_reference_factory factory = fn_reference_factory := factory

(** After [set_fn], mirror [shen.execute-store-arity] and [shen.set-lambda-form-entry]
    so code from [read-from-string] (which wraps calls as [(fn name) ...]) finds
    [shen.lambda-form] and [arity] on the property dict.
    Skips if [*property-vector*] is not set yet (e.g. while bootstrapping kernel files). *)
let register_fn_metadata name arity _cl =
  match get_global "*property-vector*", get_fn "put" with
  | Some pv, Some ((Closure _ | Native _) as put_fn) -> (
      let put_cl args = match put_fn with
        | Closure f -> f args
        | Native f -> f.invoke args
        | _ -> assert false
      in
      let put attr v =
        match put_cl [ Sym name; Sym attr; v; pv ] with
        | Error msg ->
            failwith ("register_fn_metadata put " ^ name ^ " " ^ attr ^ ": " ^ msg)
        | _ -> ()
      in
      put "arity" (Int arity);
       if arity > 0 then put "shen.lambda-form" (!fn_reference_factory name arity))
  | _ -> ()

(** Breaks the Primitives ↔ Eval cycle: Primitives calls this hook; Eval registers at load time. *)
let eval_kl_from_value_ref : (value -> value) ref =
  ref (fun _ -> Error "eval-kl: evaluator not initialised")

let set_eval_kl_from_value f = eval_kl_from_value_ref := f

let eval_kl_from_value_hook v = !eval_kl_from_value_ref v

(* Initialize some globals *)
let _ =
  set_global "*version*" (Str "43.1-ocaml");
  set_global "*language*" (Str "OCaml");
  set_global "*implementation*" (Str "shen-ocaml");
  set_global "*tc*" (Bool false)
