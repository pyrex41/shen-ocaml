(** Lexically resolved KL for executable backends. Binding identities are local
    to a compilation unit, independent of names and immune to shadowing. *)
open Ast

exception Compile_error of string

type binding = { id : int; name : string }

type expr =
  | Literal of kl_expr
  | Local of binding
  | Let of binding * expr * expr
  | If of expr * expr * expr
  | Lambda of binding list * expr
  | Freeze of expr
  | Thaw of expr
  | Trap of expr * expr
  | Sequence of expr * expr
  | And of expr * expr
  | Or of expr * expr
  | Cond of (expr * expr) list
  | Cons of expr * expr
  | Call of operator * expr list
  | Define of definition
and operator = Named of string | Dynamic of expr
and definition = { name : string; params : binding list; body : expr }

module Ids = Set.Make (Int)

let without params ids =
  List.fold_left (fun ids p -> Ids.remove p.id ids) ids params

let rec free_variables = function
  | Literal _ -> Ids.empty
  | Local p -> Ids.singleton p.id
  | Let (p, value, body) ->
      Ids.union (free_variables value) (Ids.remove p.id (free_variables body))
  | Lambda (params, body) -> without params (free_variables body)
  | Define d -> without d.params (free_variables d.body)
  | If (c, t, f) -> Ids.union (free_variables c)
      (Ids.union (free_variables t) (free_variables f))
  | Freeze body | Thaw body -> free_variables body
  | Trap (a, b) | Sequence (a, b) | And (a, b) | Or (a, b) | Cons (a, b) ->
      Ids.union (free_variables a) (free_variables b)
  | Cond clauses -> List.fold_left (fun ids (c, body) ->
      Ids.union ids (Ids.union (free_variables c) (free_variables body))) Ids.empty clauses
  | Call (op, args) -> List.fold_left (fun ids arg -> Ids.union ids (free_variables arg))
      (match op with Named _ -> Ids.empty | Dynamic op -> free_variables op) args

let parameters = function
  | KLNil -> []
  | KLApp (KLSym name, rest) ->
      name :: List.map (function
        | KLSym name -> name
        | _ -> raise (Compile_error "defun/lambda: non-symbol parameter")) rest
  | KLSym name -> [name]
  | _ -> raise (Compile_error "defun/lambda: invalid parameter list")

let resolve forms =
  let next = ref 0 in
  let fresh name =
    let id = !next in incr next; { id; name }
  in
  let bind env names =
    if List.length (List.sort_uniq String.compare names) <> List.length names then
      raise (Compile_error "duplicate function parameter");
    let params = List.map fresh names in
    params, List.fold_left (fun env (p : binding) -> (p.name, p) :: env) env params
  in
  let rec expression env = function
    | KLSym name as literal -> (match List.assoc_opt name env with
        | Some p -> Local p
        | None -> Literal literal)
    | (KLInt _ | KLFloat _ | KLStr _ | KLBool _ | KLNil | KLVec _) as v -> Literal v
    | KLCons (h, t) -> Cons (expression env h, expression env t)
    | KLLet (name, value, body) -> let_ env name value body
    | KLIf (c, t, f) -> If (expression env c, expression env t, expression env f)
    | KLLambda (name, body) -> lambda env [name] body
    | KLDefun _ -> raise (Compile_error "nested defun is not supported by native compilation")
    | KLApp (KLSym "let", [KLSym name; value; body]) -> let_ env name value body
    | KLApp (KLSym "if", [c; t; f]) ->
        If (expression env c, expression env t, expression env f)
    | KLApp (KLSym "lambda", [params; body]) -> lambda env (parameters params) body
    | KLApp (KLSym "freeze", [body]) -> Freeze (expression env body)
    | KLApp (KLSym "thaw", [body]) -> Thaw (expression env body)
    | KLApp (KLSym "trap-error", [body; handler]) ->
        Trap (expression env body, expression env handler)
    | KLApp (KLSym "do", [first; second]) ->
        Sequence (expression env first, expression env second)
    | KLApp (KLSym "and", [a; b]) -> And (expression env a, expression env b)
    | KLApp (KLSym "or", [a; b]) -> Or (expression env a, expression env b)
    | KLApp (KLSym "cond", clauses) -> Cond (List.map (function
        | KLApp (c, [body]) -> expression env c, expression env body
        | _ -> raise (Compile_error "cond: expected (test expression) clauses")) clauses)
    | KLApp (KLSym "type", [body; _]) -> expression env body
    | KLApp (KLSym ("defun" | "let" | "if" | "lambda" | "freeze" | "thaw"
                    | "trap-error" | "do" | "and" | "or"), _) ->
        raise (Compile_error "invalid or nested native special form")
    | KLApp (f, args) ->
        let op = match f with
          | KLSym name when not (List.mem_assoc name env) -> Named name
          | _ -> Dynamic (expression env f)
        in
        Call (op, List.map (expression env) args)
  and let_ env name value body =
    let value = expression env value in
    let p = fresh name in
    Let (p, value, expression ((name, p) :: env) body)
  and lambda env names body =
    let params, env = bind env names in
    Lambda (params, expression env body)
  in
  List.map (fun form ->
    let definition name names body =
      let params, env = bind [] names in
      Define {name; params; body = expression env body}
    in
    match form with
    | KLDefun (name, names, body) -> definition name names body
    | KLApp (KLSym "defun", [KLSym name; params; body]) ->
        definition name (parameters params) body
    | _ -> expression [] form) forms
