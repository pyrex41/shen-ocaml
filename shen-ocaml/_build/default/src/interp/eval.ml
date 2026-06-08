(** Tree-walking KL interpreter with lexical environment and special forms. *)

open Kl.Ast
open Runtime.Value
open Runtime.Env

exception Eval_error of string

type local_env = (string * value) list

(** When set (digits only), abort after this many [eval] calls — debugging non-termination. *)
let eval_step_limit : int option ref = ref None
let eval_steps_taken : int ref = ref 0

let bump_eval_step () =
  match !eval_step_limit with
  | None -> ()
  | Some lim ->
      incr eval_steps_taken;
      if !eval_steps_taken > lim then
        raise
          (Eval_error
             ("eval step limit exceeded (" ^ string_of_int lim ^ " steps)"))

let lookup_local (env : local_env) name =
  List.assoc_opt name env

let extend_local env name v = (name, v) :: env

let param_names_of_kl_expr = function
  | KLNil -> []
  | KLSym s -> [ s ]
  | KLApp (KLSym h, rest) ->
      h
      :: List.concat_map
           (function
             | KLSym s -> [ s ]
             | e ->
                 raise
                   (Eval_error
                      ("invalid parameter list element: " ^ Kl.Ast.to_string e)))
           rest
  | e ->
      raise
        (Eval_error ("invalid parameter list: " ^ Kl.Ast.to_string e))

let rec eval (env : local_env) (expr : kl_expr) : value =
  bump_eval_step ();
  match expr with
  | KLInt i -> Int i
  | KLFloat f -> Float f
  | KLStr s -> Str s
  | KLBool b -> Bool b
  | KLNil -> Nil
  | KLSym s -> (
      match lookup_local env s with
      | Some v -> v
      | None ->
          if s = "true" then Bool true
          else if s = "false" then Bool false
          else Sym s)
  | KLCons (a, b) -> Cons (eval env a, eval env b)
  | KLVec arr -> Vec (Array.map (eval env) arr)
  | KLIf (c, t, e) ->
      if is_true (eval env c) then eval env t else eval env e
  | KLLet (x, ve, body) ->
      let v = eval env ve in
      eval (extend_local env x v) body
  | KLLambda (x, body) -> make_user_closure env [ x ] body
  | KLDefun (name, params, body) ->
      let cl = make_user_closure env params body in
      set_fn name cl;
      register_fn_metadata name (List.length params) cl;
      Sym name
  | KLApp (f, args) -> eval_app env f args

and eval_app env f args =
  match f, args with
  | KLSym "defun", [ name_e; plist; body ] -> (
      match name_e with
      | KLSym name ->
          let params = param_names_of_kl_expr plist in
          let cl = make_user_closure env params body in
          set_fn name cl;
          register_fn_metadata name (List.length params) cl;
          Sym name
      | _ -> Error "defun: function name must be a symbol")
  | KLSym "lambda", [ param_desc; body ] ->
      let params = param_names_of_kl_expr param_desc in
      make_user_closure env params body
  | KLSym "let", [ KLSym x; ve; body ] ->
      let v = eval env ve in
      eval (extend_local env x v) body
  | KLSym "let", _ -> Error "let: (let <symbol> <value> <body>)"
  | KLSym "if", [ c; t; e ] ->
      if is_true (eval env c) then eval env t else eval env e
  | KLSym "if", _ -> Error "if: three arguments expected"
  | KLSym "cond", clauses -> eval_cond env clauses
  | KLSym "freeze", [ e ] ->
      Closure (function
        | [] -> eval env e
        | _ -> Error "freeze: invoked with arguments")
  | KLSym "freeze", _ -> Error "freeze: one argument expected"
  | KLSym "thaw", [ e ] -> (
      match eval env e with
      | Closure cl -> cl []
      | _ -> Error "thaw: expected a frozen thunk")
  | KLSym "thaw", _ -> Error "thaw: one argument expected"
  | KLSym "trap-error", [ body_e; handler_e ] -> (
      let r =
        try eval env body_e
        with
        | Eval_error msg -> Error msg
        | User_error msg -> Error msg
        | e -> Error (Printexc.to_string e)
      in
      match r with
      | Error _ as err -> (
          match eval env handler_e with
          | Closure cl -> cl [ err ]
          | _ -> Error "trap-error: handler must be a function")
      | v -> v)
  | KLSym "trap-error", _ -> Error "trap-error: two arguments expected"
  | KLSym "do", [ e1; e2 ] ->
      let _ = eval env e1 in
      eval env e2
  | KLSym "do", _ -> Error "do: two arguments expected"
  | KLSym "and", xs -> eval_and env xs
  | KLSym "or", xs -> eval_or env xs
  | _ ->
      let fval = eval env f in
      let argvals = List.map (eval env) args in
      apply_value fval argvals

and eval_cond env = function
  | [] -> Nil
  | clause :: rest -> (
      match clause with
      | KLApp (test_e, [ action_e ]) ->
          let tv = eval env test_e in
          if is_true tv then eval env action_e else eval_cond env rest
      | _ -> Error "cond: each clause must be (test action)")
and eval_and env = function
  | [] -> Bool true
  | [ x ] -> eval env x
  | x :: xs ->
      let v = eval env x in
      if is_true v then eval_and env xs else v
and eval_or env = function
  | [] -> Bool false
  | [ x ] -> eval env x
  | x :: xs ->
      let v = eval env x in
      if is_true v then v else eval_or env xs

and make_user_closure (env : local_env) (param_names : string list) (body : kl_expr)
    : value =
  Closure (fun args -> apply_user env param_names body args)

and apply_user env param_names body args =
  let rec step cur_env ps avs =
    match ps, avs with
    | [], [] -> eval cur_env body
    | p :: ptl, a :: atl -> step (extend_local cur_env p a) ptl atl
    | ptl, [] -> Closure (fun more -> step cur_env ptl more)
    | [], _ :: _ -> Error "too many arguments"
  in
  step env param_names args

and apply_value fval argvals =
  let apply_named name =
    match get_fn name with
    | Some (Closure cl) -> cl argvals
    | Some _ -> Error ("not a function: " ^ name)
    | None -> Error ("unbound function: " ^ name)
  in
  match fval with
  | Closure cl -> cl argvals
  | Sym name -> apply_named name
  | Str name -> apply_named name
  | _ -> Error ("not applicable: " ^ to_string fval)

let rec value_to_kl_atom v =
  match v with
  | Int i -> KLInt i
  | Float f -> KLFloat f
  | Str s -> KLStr s
  | Sym s -> KLSym s
  | Bool b -> KLBool b
  | Nil -> KLNil
  | Vec a -> KLVec (Array.map value_to_kl_atom a)
  | Cons _ -> value_to_kl_expr v
  | Closure _ | Stream _ | Error _ ->
      raise (Eval_error "eval-kl: invalid value in kl expression")

and value_to_kl_expr v =
  match v with
  | Cons _ ->
      let rec split seen acc = function
        | Nil -> `Proper (List.rev acc)
        | Cons (h, t) as cell ->
            if List.memq cell seen then
              raise (Eval_error "eval-kl: cyclic cons list")
            else split (cell :: seen) (h :: acc) t
        | last -> `Improper (List.rev acc, last)
      in
      (match split [] [] v with
      | `Proper [] -> KLNil
      | `Proper [ f ] -> KLApp (value_to_kl_expr f, [])
      | `Proper (f :: args) ->
          KLApp (value_to_kl_expr f, List.map value_to_kl_expr args)
      | `Improper (elts, last) ->
          List.fold_right
            (fun h t -> KLCons (value_to_kl_expr h, t))
            elts (value_to_kl_expr last))
  | _ -> value_to_kl_atom v

let eval_top expr = eval [] expr

let eval_kl expr =
  eval_steps_taken := 0;
  try eval [] expr with
  | Eval_error msg -> Error msg
  | User_error msg -> Error msg
  | e -> Error ("eval error: " ^ Printexc.to_string e)

let eval_kl_from_value v =
  eval_steps_taken := 0;
  try eval [] (value_to_kl_expr v) with
  | Eval_error msg -> Error msg
  | User_error msg -> Error msg
  | e -> Error ("eval error: " ^ Printexc.to_string e)

let () = set_eval_kl_from_value eval_kl_from_value

let initialise () =
  eval_step_limit :=
    match Sys.getenv_opt "SHEN_DEBUG_EVAL_STEPS" with
    | Some s -> ( try Some (int_of_string (String.trim s)) with _ -> None)
    | None -> None
