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

(* While compiling one defun body, the (kl-name, arity, ocaml-rec-name) of the
   function being compiled. A *saturated* call to itself compiles to a direct
   OCaml call to the local [let rec] entry instead of [apply_value (Sym name)] —
   skipping the table lookup and currying. This is unconditionally sound: a
   self-reference is lexical within the function's own body, and runtime
   redefinition only swaps the table entry (a running invocation keeps using its
   own body), so no invalidation flag is needed. Under-saturated self-calls
   (partial application) still go through the table. *)
let current_self : (string * int * string) option ref = ref None

(** Node count of a KL expression — a proxy for the OCaml AST depth the native
    compiler must recurse over. Giant kernel defuns (e.g. [shen.use-type-info],
    the type-checker monsters) compile to expressions deep enough to overflow
    [ocamlopt]'s stack at the default limit, so bodies over [max_compile_nodes]
    fall back to the interpreter (the oracle) instead of being AOT-compiled. *)
let rec kl_size = function
  | KLInt _ | KLFloat _ | KLStr _ | KLSym _ | KLBool _ | KLNil -> 1
  | KLCons (a, b) -> 1 + kl_size a + kl_size b
  | KLVec arr -> 1 + Array.fold_left (fun n e -> n + kl_size e) 0 arr
  | KLApp (f, args) -> 1 + kl_size f + List.fold_left (fun n e -> n + kl_size e) 0 args
  | KLLambda (_, b) -> 1 + kl_size b
  | KLLet (_, v, b) -> 1 + kl_size v + kl_size b
  | KLIf (c, t, e) -> 1 + kl_size c + kl_size t + kl_size e
  | KLDefun (_, _, b) -> 1 + kl_size b

(** Bodies above this many nodes are interpreted, not compiled (keeps the native
    compiler's recursion within the default OS stack). Overridable via env. *)
let max_compile_nodes =
  match Sys.getenv_opt "AOT_MAX_NODES" with
  | Some s -> ( try int_of_string (String.trim s) with _ -> 220)
  | None -> 220

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
  (* Evaluate callee first, then args left-to-right. Trivial subexpressions
     (literals / variables / symbols) have no side effects and no observable
     evaluation order, so inline them directly instead of binding a temp — this
     keeps the generated AST shallow (deep ANF nesting overflows the OCaml
     compiler on large kernel defuns). Only non-trivial subexpressions get a
     [let] temp, in left-to-right order. *)
  let bindings = ref [] in
  let operand e =
    if is_trivial e then compile locals e
    else (
      let t = fresh () in
      bindings := (t, compile locals e) :: !bindings;
      t)
  in
  (* Saturated self-call → direct call to the local [let rec] entry. *)
  let self_direct =
    match (f, !current_self) with
    | KLSym name, Some (sname, sarity, raw)
      when name = sname && (not (SS.mem name locals)) && List.length args = sarity ->
        Some raw
    | _ -> None
  in
  let core =
    match self_direct with
    | Some raw ->
        let arg_ts = List.map operand args in
        Printf.sprintf "%s %s" raw (String.concat " " arg_ts)
    | None ->
        let callee = operand f in
        let arg_ts = List.map operand args in
        Printf.sprintf "E.apply_value %s [%s]" callee (String.concat "; " arg_ts)
  in
  List.fold_left
    (fun acc (t, e) -> Printf.sprintf "(let %s = %s in %s)" t (paren e) acc)
    core !bindings

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

(** Emit a registration statement for a top-level [defun] (mirrors [Eval]'s KLDefun).
    For [arity > 0] the body is compiled into a local [let rec] entry so saturated
    self-calls become direct OCaml calls (no table lookup / currying); the curried
    [make_closure] wrapper around it preserves partial-application semantics. *)
let compile_toplevel_defun ~b name params body =
  let arity = List.length params in
  if arity = 0 then
    Printf.bprintf b
      "  (let c = %s in Env.set_fn %s c; Env.register_fn_metadata %s %d c);\n"
      (compile_closure params body) (esc name) (esc name) arity
  else begin
    let raw = fresh () ^ "_self" in
    let locals = List.fold_left (fun s p -> SS.add p s) SS.empty params in
    let mp = List.map mangle_var params in
    current_self := Some (name, arity, raw);
    let body_src = compile locals body in
    current_self := None;
    Printf.bprintf b
      "  (let rec %s %s = %s in\n   let c = mkcl %d (function [%s] -> %s %s | _ -> Error \"arity\") in\n   Env.set_fn %s c; Env.register_fn_metadata %s %d c);\n"
      raw (String.concat " " mp) body_src arity (String.concat "; " mp) raw
      (String.concat " " mp) (esc name) (esc name) arity
  end

let emit_preamble b =
  Buffer.add_string b "(* @generated — do not edit by hand. *)\n\n";
  Buffer.add_string b "open Shen.Runtime.Value\n";
  Buffer.add_string b "module E = Shen.Interp.Eval\n";
  Buffer.add_string b "module Env = Shen.Runtime.Env\n";
  Buffer.add_string b "let mkcl = Shen.Runtime.Primitives.make_closure\n";
  Buffer.add_string b "let eval_form = E.eval_kl\n\n"

(** Emit [let <fn_name> () : unit = <stmts>] running [forms] in order: [defun]s
    register compiled closures (mirroring [Eval]'s KLDefun); every other form is
    embedded as data and run once via [eval_kl] (matching [boot.ml], including
    raising on an [Error] result). [source_path] only labels error messages. *)
let emit_boot_fn b ~fn_name ~source_path forms =
  Printf.bprintf b "let %s () : unit =\n" fn_name;
  let emitted = ref false in
  let emit_other other =
    let data = Buffer.create 64 in
    Ocaml_gen.emit_expr data other;
    Printf.bprintf b
      "  (match eval_form %s with Error m -> failwith (%s ^ m) | _ -> ());\n"
      (Buffer.contents data)
      (esc (source_path ^ ": form error: "))
  in
  let emit_defun name params body form =
    if kl_size body > max_compile_nodes then emit_other form
    else compile_toplevel_defun ~b name params body
  in
  List.iter
    (fun form ->
      emitted := true;
      match form with
      | KLDefun (name, params, body) -> emit_defun name params body form
      | KLApp (KLSym "defun", [ KLSym name; pdesc; body ]) ->
          emit_defun name (param_names pdesc) body form
      | other -> emit_other other)
    forms;
  ignore !emitted;
  (* Always end the sequence with [()] — each statement above ends in [;], so a
     bare trailing [;] would make the following [let boot_<file>] parse as a local
     let-binding and swallow the rest of the file. *)
  Buffer.add_string b "  ()\n\n"

(** One [.kl] file → a module with [boot () : unit]. *)
let compile_file_module b ~source_path forms =
  counter := 0;
  Printf.bprintf b "(* Compiled from %s *)\n" source_path;
  emit_preamble b;
  emit_boot_fn b ~fn_name:"boot" ~source_path forms

(** All kernel files → one module with a [boot_<file> ()] per file (bounded size)
    and a [boot ()] that calls them in the given (boot) order. *)
let compile_kernel_module b (files : (string * kl_expr list) list) =
  counter := 0;
  Printf.bprintf b "(* Compiled kernel (%d files) *)\n" (List.length files);
  emit_preamble b;
  let fn_of base =
    "boot_"
    ^ String.map
        (fun c -> match c with 'a' .. 'z' | '0' .. '9' -> c | _ -> '_')
        (Filename.remove_extension base)
  in
  List.iter
    (fun (base, forms) ->
      Printf.bprintf b "(* --- %s --- *)\n" base;
      emit_boot_fn b ~fn_name:(fn_of base) ~source_path:base forms)
    files;
  Buffer.add_string b "let boot () : unit =\n";
  List.iter (fun (base, _) -> Printf.bprintf b "  %s ();\n" (fn_of base)) files;
  Buffer.add_string b "  ()\n"
