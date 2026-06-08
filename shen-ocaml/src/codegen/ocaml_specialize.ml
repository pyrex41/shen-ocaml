(** Phase C: type-directed specialization. Given Shen [define]s whose declared
    signature is monomorphic over [number] and whose body stays in a small
    arithmetic subset, emit a *second* entry point over unboxed OCaml [int] (native
    ops, no tag dispatch) alongside the uniform [value] entry. The uniform wrapper
    boxes/unboxes at the boundary and dispatches to the fast path only when (a) the
    specialized web is still valid (no member redefined) and (b) the arguments are
    actually ints — a [number] may be a float, which falls back to the uniform path
    soundly. Calls between specialized functions go direct.

    The *only* input is the declared signature (the prompt's rule: never guess from
    the body). The proof warrant is the type checker: the build tool loads the
    source under [(tc +)] and refuses to emit a fast path for anything that does
    not type-check.

    Out of scope for v1 (recorded in the plan): floats, [/], polymorphic or
    list/vector specialization, cross-module specialization, JIT. Anything outside
    the int subset makes the function fall back to the uniform entry, silently. *)

open Kl.Ast
module SS = Set.Make (String)

let mangle_var = Ocaml_compile.mangle_var
let esc = Ocaml_gen.escaped_string_for_ml

(* ------------------------------------------------------------------ *)
(* Parsing a single-clause Shen define from the flat token list the KL parser
   produces for [(define f { number --> number } X -> BODY)]. *)

type defn = { name : string; arity : int; params : string list; body : kl_expr }

(** From the [{ ... }] token run, the [number]-monomorphic arity (params), or None. *)
let number_mono_arity type_tokens =
  (* expect: number ( --> number )*  — all symbols "number" separated by "-->" *)
  let rec go expect_number = function
    | [] -> None
    | [ KLSym "number" ] when expect_number -> Some 0 (* return position *)
    | KLSym "number" :: KLSym "-->" :: rest when expect_number -> (
        match go true rest with Some n -> Some (n + 1) | None -> None)
    | _ -> None
  in
  go true type_tokens

(** Extract a single-clause numeric defn from a parsed [(define ...)] form, or None
    (multi-clause, non-number signature, or no [{ }] — all unspecializable). *)
let parse_define = function
  | KLApp (KLSym "define", KLSym name :: rest) -> (
      (* split off the { ... } type, then params up to ->, then a single body. *)
      match rest with
      | KLSym "{" :: rest -> (
          let rec take_type acc = function
            | KLSym "}" :: more -> Some (List.rev acc, more)
            | tok :: more -> take_type (tok :: acc) more
            | [] -> None
          in
          match take_type [] rest with
          | Some (type_tokens, after_type) -> (
              match number_mono_arity type_tokens with
              | None -> None
              | Some arity -> (
                  let rec take_params ps = function
                    | KLSym "->" :: [ body ] ->
                        Some (List.rev ps, body) (* single clause, single body *)
                    | KLSym "->" :: _ -> None (* multi-clause: not handled *)
                    | KLSym p :: more -> take_params (p :: ps) more
                    | _ -> None
                  in
                  match take_params [] after_type with
                  | Some (params, body) when List.length params = arity ->
                      Some { name; arity; params; body }
                  | _ -> None))
          | None -> None)
      | _ -> None)
  | _ -> None

(* ------------------------------------------------------------------ *)
(* The int subset. compile_int : -> OCaml int expression; compile_bool : -> bool. *)

exception Not_specializable of string

let int_lit i = if i >= 0 then string_of_int i else "(" ^ string_of_int i ^ ")"

let rec compile_int ~specset ~locals e =
  match e with
  | KLInt i -> int_lit i
  | KLSym s when SS.mem s locals -> mangle_var s
  | KLApp (KLSym "+", [ a; b ]) -> bin "+" specset locals a b
  | KLApp (KLSym "-", [ a; b ]) -> bin "-" specset locals a b
  | KLApp (KLSym "*", [ a; b ]) -> bin "*" specset locals a b
  | KLApp (KLSym "if", [ c; t; el ]) ->
      Printf.sprintf "(if %s then %s else %s)"
        (compile_bool ~specset ~locals c)
        (compile_int ~specset ~locals t)
        (compile_int ~specset ~locals el)
  | KLApp (KLSym "let", [ KLSym x; v; body ]) ->
      Printf.sprintf "(let %s = %s in %s)" (mangle_var x)
        (compile_int ~specset ~locals v)
        (compile_int ~specset ~locals:(SS.add x locals) body)
  | KLApp (KLSym g, args) when SS.mem g specset ->
      (* direct specialized call (web validity is gated at the uniform wrapper, so
         within a specialized call tree every member is guaranteed valid). *)
      Printf.sprintf "(%s %s)" (sp_name g)
        (String.concat " "
           (List.map (fun a -> compile_int ~specset ~locals a) args))
  | _ -> raise (Not_specializable (Kl.Ast.to_string e))

and bin op specset locals a b =
  Printf.sprintf "(%s %s %s)"
    (compile_int ~specset ~locals a)
    op
    (compile_int ~specset ~locals b)

and compile_bool ~specset ~locals e =
  let cmp op a b =
    Printf.sprintf "(%s %s %s)"
      (compile_int ~specset ~locals a)
      op
      (compile_int ~specset ~locals b)
  in
  match e with
  | KLApp (KLSym "=", [ a; b ]) -> cmp "=" a b
  | KLApp (KLSym "<", [ a; b ]) -> cmp "<" a b
  | KLApp (KLSym ">", [ a; b ]) -> cmp ">" a b
  | KLApp (KLSym "<=", [ a; b ]) -> cmp "<=" a b
  | KLApp (KLSym ">=", [ a; b ]) -> cmp ">=" a b
  | KLApp (KLSym "and", [ a; b ]) ->
      Printf.sprintf "(%s && %s)"
        (compile_bool ~specset ~locals a)
        (compile_bool ~specset ~locals b)
  | KLApp (KLSym "or", [ a; b ]) ->
      Printf.sprintf "(%s || %s)"
        (compile_bool ~specset ~locals a)
        (compile_bool ~specset ~locals b)
  | _ -> raise (Not_specializable ("condition: " ^ Kl.Ast.to_string e))

and sp_name name =
  "sp_"
  ^ String.map
      (fun c ->
        match c with 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> c | _ -> '_')
      name
  ^ "_"
  (* trailing _ avoids clashing with OCaml keywords *)

(** Does [d] compile in the int subset given that [specset] names are callable? *)
let body_ok ~specset d =
  let locals = List.fold_left (fun s p -> SS.add p s) SS.empty d.params in
  try
    ignore (compile_int ~specset ~locals d.body);
    true
  with Not_specializable _ -> false

(** Fixpoint: the largest set of number-mono defns whose bodies stay in the subset
    using only each other (and arithmetic). Start optimistic, drop failures until
    stable. *)
let specializable_set defns =
  let names = List.fold_left (fun s d -> SS.add d.name s) SS.empty defns in
  let rec fix candidates =
    let candidates' =
      List.fold_left
        (fun acc d ->
          if SS.mem d.name acc && body_ok ~specset:acc d then acc
          else SS.remove d.name acc)
        candidates defns
    in
    if SS.equal candidates candidates' then candidates' else fix candidates'
  in
  fix names

(* ------------------------------------------------------------------ *)
(* Emit the module. *)

let emit b defns =
  let specset = specializable_set defns in
  let spec_defns = List.filter (fun d -> SS.mem d.name specset) defns in
  Buffer.add_string b "(* @generated Phase C specialization — do not edit. *)\n\n";
  Buffer.add_string b "open Shen.Runtime.Value\n";
  Buffer.add_string b "module E = Shen.Interp.Eval\n";
  Buffer.add_string b "module Env = Shen.Runtime.Env\n";
  Buffer.add_string b "module Spec = Shen.Runtime.Spec\n";
  Buffer.add_string b "let mkcl = Shen.Runtime.Primitives.make_closure\n\n";
  (* specialized unboxed entries, mutually recursive *)
  (match spec_defns with
  | [] -> ()
  | first :: rest ->
      let emit_sp kw d =
        let locals = List.fold_left (fun s p -> SS.add p s) SS.empty d.params in
        let args =
          String.concat " "
            (List.map (fun p -> Printf.sprintf "(%s : int)" (mangle_var p)) d.params)
        in
        Printf.bprintf b "%s %s %s : int =\n  %s\n" kw (sp_name d.name) args
          (compile_int ~specset ~locals d.body)
      in
      emit_sp "let rec" first;
      List.iter (emit_sp "and") rest;
      Buffer.add_string b "\n");
  (* uniform (Phase B) entries for every defn — the sound fallback path *)
  List.iter
    (fun d ->
      Printf.bprintf b "let uniform_%s = %s\n" (sp_name d.name)
        (Ocaml_compile.compile_closure d.params d.body))
    defns;
  Buffer.add_string b "\n";
  (* registration: wrappers dispatch int args (and a valid web) to the fast path.
     [Spec.watch] is installed *after* the initial set_fns so registering the
     wrappers themselves does not trip the redefinition hook. *)
  Buffer.add_string b "let register () : unit =\n";
  List.iter
    (fun d ->
      let pats =
        String.concat "; " (List.map (fun p -> "Int " ^ mangle_var p) d.params)
      in
      let sp_args =
        String.concat " " (List.map (fun p -> mangle_var p) d.params)
      in
      let wrapper =
        if SS.mem d.name specset then
          Printf.sprintf
            "(mkcl %d (function [%s] when !Spec.web_valid -> Int (%s %s) | args -> (match uniform_%s with Closure c -> c args | _ -> Error \"spec\")))"
            d.arity pats (sp_name d.name) sp_args (sp_name d.name)
        else Printf.sprintf "uniform_%s" (sp_name d.name)
      in
      Printf.bprintf b "  (let c = %s in Env.set_fn %s c; Env.register_fn_metadata %s %d c);\n"
        wrapper (esc d.name) (esc d.name) d.arity)
    defns;
  Printf.bprintf b "  Spec.watch [%s];\n  ()\n"
    (String.concat "; " (List.map (fun d -> esc d.name) defns));
  spec_defns

(** Compile a list of parsed top-level forms: pick out specializable defines, emit
    the module, and return the list of names that got a fast path (for reporting). *)
let compile_forms b forms =
  let defns = List.filter_map parse_define forms in
  let spec = emit b defns in
  List.map (fun d -> d.name) spec
