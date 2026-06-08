(** A true KL → OCaml compiler (Phase B).

    Unlike {!Ocaml_gen}, which emits the KL AST back as OCaml *data*, this module
    compiles each KL [defun] into a native OCaml closure over the uniform [value]
    type. The interpreter ({!Interp.Eval}) stays the oracle; compiled code must
    produce bit-identical results.

    Design (v1, deliberately conservative for correctness):
    - Every global function call compiles to a call *through the function table*
      ([Eval.apply_value (Sym name) args]), so [eval-kl] redefinition at runtime
      and free interop with interpreter-defined functions both Just Work. (Direct
      OCaml calls within a unit are a later optimisation — redefinition makes them
      unsound in general.) Self/mutual tail recursion stays stack-flat because each
      hop — compiled body → [apply_value] → registered closure → compiled body — is
      an OCaml tail call, exactly as the interpreter already does.
    - KL [if]/[let]/[lambda]/[cond]/[and]/[or]/[do]/[freeze]/[thaw]/[trap-error]
      map to native OCaml control flow, matching {!Interp.Eval.eval_app} exactly
      (including the variadic [and]/[or] returning the offending value, and
      [trap-error] catching both exceptions and [Error] result values).
    - Argument evaluation is A-normalised (one [let] per subexpression, callee
      first then args left-to-right) so observable side-effect order matches the
      interpreter — OCaml's own argument order is unspecified/right-to-left.
    - A [defun] registers [make_closure arity body] (same currying / partial-
      application semantics the primitives use) plus [register_fn_metadata], i.e.
      precisely what [Eval]'s [KLDefun] does.
    - Non-[defun] top-level forms (booting effects, [declare], etc.) are not hot;
      they are emitted as embedded data and run once via [eval_kl], preserving
      exact file/form order. *)

open Kl.Ast

module SS = Set.Make (String)

let esc = Ocaml_gen.escaped_string_for_ml
let float_lit = Ocaml_gen.float_literal

(** KL local variable → OCaml identifier (case-preserving; [l_] keeps it lowercase-initial). *)
let mangle_var name =
  let b = Buffer.create (String.length name + 2) in
  Buffer.add_string b "l_";
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> Buffer.add_char b c
      | _ -> Printf.bprintf b "_u%02X" (Char.code c))
    name;
  Buffer.contents b

let counter = ref 0
let fresh () = incr counter; "__t" ^ string_of_int !counter

(** Parameter names from a defun/lambda parameter descriptor (KLApp/KLSym/KLNil). *)
let param_names = function
  | KLNil -> []
  | KLSym s -> [ s ]
  | KLApp (KLSym h, rest) ->
      h
      :: List.map
           (function
             | KLSym s -> s
             | e -> failwith ("invalid parameter: " ^ Kl.Ast.to_string e))
           rest
  | e -> failwith ("invalid parameter list: " ^ Kl.Ast.to_string e)

(** A literal/atom needing no evaluation order control. *)
let is_trivial = function
  | KLInt _ | KLFloat _ | KLStr _ | KLSym _ | KLBool _ | KLNil -> true
  | _ -> false

let rec compile (locals : SS.t) (e : kl_expr) : string =
  match e with
  | KLInt i -> if i >= 0 then Printf.sprintf "(Int %d)" i else Printf.sprintf "(Int (%d))" i
  | KLFloat f ->
      let l = float_lit f in
      if l <> "" && l.[0] = '-' then Printf.sprintf "(Float (%s))" l
      else Printf.sprintf "(Float %s)" l
  | KLStr s -> Printf.sprintf "(Str %s)" (esc s)
  | KLBool b -> Printf.sprintf "(Bool %b)" b
  | KLNil -> "Nil"
  | KLVec arr ->
      "(Vec [| "
      ^ String.concat "; " (Array.to_list (Array.map (compile locals) arr))
      ^ " |])"
  | KLCons (h, t) -> Printf.sprintf "(Cons (%s, %s))" (compile locals h) (compile locals t)
  | KLSym s ->
      if SS.mem s locals then mangle_var s
      else if s = "true" then "(Bool true)"
      else if s = "false" then "(Bool false)"
      else Printf.sprintf "(Sym %s)" (esc s)
  (* Dedicated AST nodes (constructed directly, not from the parser) — same shapes. *)
  | KLIf (c, t, el) -> compile_if locals c t el
  | KLLet (x, v, body) -> compile_let locals x v body
  | KLLambda (x, body) -> compile_lambda locals [ x ] body
  | KLDefun (name, params, body) ->
      compile_defun_expr locals name params body
  | KLApp (KLSym "if", [ c; t; el ]) -> compile_if locals c t el
  | KLApp (KLSym "let", [ KLSym x; v; body ]) -> compile_let locals x v body
  | KLApp (KLSym "lambda", [ pdesc; body ]) -> compile_lambda locals (param_names pdesc) body
  | KLApp (KLSym "cond", clauses) -> compile_cond locals clauses
  | KLApp (KLSym "and", xs) -> compile_and locals xs
  | KLApp (KLSym "or", xs) -> compile_or locals xs
  | KLApp (KLSym "do", [ a; b ]) ->
      Printf.sprintf "(let _ = %s in %s)" (compile locals a) (compile locals b)
  | KLApp (KLSym "freeze", [ e1 ]) ->
      Printf.sprintf
        "(Closure (function [] -> %s | _ -> Error \"freeze: invoked with arguments\"))"
        (compile locals e1)
  | KLApp (KLSym "thaw", [ e1 ]) ->
      Printf.sprintf
        "(match %s with Closure cl -> cl [] | _ -> Error \"thaw: expected a frozen thunk\")"
        (compile locals e1)
  | KLApp (KLSym "trap-error", [ body; handler ]) -> compile_trap locals body handler
  | KLApp (KLSym "defun", [ KLSym name; pdesc; body ]) ->
      compile_defun_expr locals name (param_names pdesc) body
  | KLApp (f, args) -> compile_app locals f args

and compile_if locals c t el =
  Printf.sprintf "(if is_true %s then %s else %s)" (paren (compile locals c))
    (compile locals t) (compile locals el)

and compile_let locals x v body =
  let locals' = SS.add x locals in
  Printf.sprintf "(let %s = %s in %s)" (mangle_var x) (paren (compile locals v))
    (compile locals' body)

and compile_lambda locals params body =
  let locals' = List.fold_left (fun s p -> SS.add p s) locals params in
  let n = List.length params in
  let pats = String.concat "; " (List.map mangle_var params) in
  Printf.sprintf "(mkcl %d (function [%s] -> %s | _ -> Error \"lambda: arity\"))" n
    pats (compile locals' body)

and compile_cond locals clauses =
  let rec go = function
    | [] -> "Nil"
    | KLApp (test, [ action ]) :: rest ->
        Printf.sprintf "(if is_true %s then %s else %s)"
          (paren (compile locals test)) (compile locals action) (go rest)
    | _ :: _ -> "(Error \"cond: each clause must be (test action)\")"
  in
  go clauses

and compile_and locals = function
  | [] -> "(Bool true)"
  | [ x ] -> compile locals x
  | x :: xs ->
      Printf.sprintf "(let v = %s in if is_true v then %s else v)"
        (paren (compile locals x)) (compile_and locals xs)

and compile_or locals = function
  | [] -> "(Bool false)"
  | [ x ] -> compile locals x
  | x :: xs ->
      Printf.sprintf "(let v = %s in if is_true v then v else %s)"
        (paren (compile locals x)) (compile_or locals xs)

and compile_trap locals body handler =
  Printf.sprintf
    "(let r = (try %s with E.Eval_error m -> Error m | User_error m -> Error m | e -> Error (Printexc.to_string e)) in match r with Error _ as err -> (match %s with Closure cl -> cl [err] | _ -> Error \"trap-error: handler must be a function\") | v -> v)"
    (compile locals body) (compile locals handler)

and compile_app locals f args =
  (* A-normal form: evaluate callee first (if non-trivial), then args left-to-right. *)
  let bindings = ref [] in
  let bind e =
    let t = fresh () in
    bindings := !bindings @ [ (t, compile locals e) ];
    t
  in
  let callee =
    match f with
    | KLSym s when SS.mem s locals -> mangle_var s
    | KLSym _ | KLInt _ | KLFloat _ | KLStr _ | KLBool _ | KLNil -> compile locals f
    | _ -> bind f
  in
  let arg_ts = List.map bind args in
  let core =
    Printf.sprintf "E.apply_value %s [%s]" callee (String.concat "; " arg_ts)
  in
  List.fold_right
    (fun (t, e) acc -> Printf.sprintf "(let %s = %s in %s)" t (paren e) acc)
    !bindings core

and compile_defun_expr locals name params body =
  (* Nested/expression-position defun: register and return [Sym name]. *)
  let _ = locals in
  Printf.sprintf "(let c = %s in Env.set_fn %s c; Env.register_fn_metadata %s %d c; Sym %s)"
    (compile_closure params body) (esc name) (esc name) (List.length params) (esc name)

and compile_closure params body =
  let locals = List.fold_left (fun s p -> SS.add p s) SS.empty params in
  let n = List.length params in
  let pats = String.concat "; " (List.map mangle_var params) in
  if n = 0 then
    Printf.sprintf "(mkcl 0 (function [] -> %s | _ -> Error \"%s\"))" (compile locals body) "arity"
  else
    Printf.sprintf "(mkcl %d (function [%s] -> %s | _ -> Error \"arity\"))" n pats
      (compile locals body)

and paren s = "(" ^ s ^ ")"

(** Emit a registration statement for a top-level [defun] (mirrors [Eval]'s KLDefun). *)
let compile_toplevel_defun ~b name params body =
  Printf.bprintf b
    "  (let c = %s in\n   Env.set_fn %s c; Env.register_fn_metadata %s %d c);\n"
    (compile_closure params body) (esc name) (esc name) (List.length params)

(** Emit a [boot ()] that runs all forms in order: [defun]s register compiled
    closures; every other form is embedded as data and run via [eval_kl] (matching
    [boot.ml] semantics, including raising on an [Error] result). *)
let compile_file_module b ~source_path forms =
  counter := 0;
  Printf.bprintf b "(* Compiled from %s — do not edit by hand. *)\n" source_path;
  Buffer.add_string b "(* @generated *)\n\n";
  Buffer.add_string b "open Shen.Runtime.Value\n";
  Buffer.add_string b "module E = Shen.Interp.Eval\n";
  Buffer.add_string b "module Env = Shen.Runtime.Env\n";
  Buffer.add_string b "let mkcl = Shen.Runtime.Primitives.make_closure\n";
  Buffer.add_string b "let eval_form = E.eval_kl\n\n";
  Buffer.add_string b "let boot () : unit =\n";
  let emitted = ref false in
  let emit_other other =
    let data = Buffer.create 64 in
    Ocaml_gen.emit_expr data other;
    Printf.bprintf b
      "  (match eval_form %s with Error m -> failwith (%s ^ m) | _ -> ());\n"
      (Buffer.contents data)
      (esc (source_path ^ ": form error: "))
  in
  List.iter
    (fun form ->
      emitted := true;
      match form with
      | KLDefun (name, params, body) ->
          compile_toplevel_defun ~b name params body
      | KLApp (KLSym "defun", [ KLSym name; pdesc; body ]) ->
          compile_toplevel_defun ~b name (param_names pdesc) body
      | other -> emit_other other)
    forms;
  if not !emitted then Buffer.add_string b "  ()\n"
