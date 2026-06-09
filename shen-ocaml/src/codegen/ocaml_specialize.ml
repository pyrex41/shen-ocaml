(** Phase C: type-directed specialization. Given Shen [define]s whose declared
    signature is monomorphic over [number] and whose body stays in a small
    arithmetic subset, emit unboxed entry points (native OCaml [int] and/or
    [float], native ops, no tag dispatch) alongside the uniform [value] entry. The
    uniform wrapper dispatches all-[Int] args to the int fast path, all-[Float]
    args to the float fast path (whichever exist), and otherwise — mixed types
    (Shen number contagion), non-numbers, or after a redefinition — falls back to
    the uniform path, soundly. Calls between specialized functions of the same
    numeric kind go direct.

    The *only* input is the declared signature (never the body); the [(tc +)]
    proof is the warrant (the build refuses a fast path for code that does not
    type-check). The interpreter is the oracle: results, including 63-bit int
    overflow (native int wraps), must be bit-identical.

    Numeric subset (per kind): [+ - *], comparisons [= < > <= >=], [if], [let], and
    calls to other specialized functions of that kind. Deliberately EXCLUDED:
    - [/]: always returns a float in this port (even int/int) and errors on a zero
      divisor; OCaml [/.] yields [inf] instead, so [/] would diverge — functions
      using it fall back to uniform.
    - floats/symbols/cons/vectors/higher-order/[trap-error]: out of subset.

    Patterns supported in multi-clause defines: literal numbers (→ equality guard)
    and variables (→ binding). The last clause must be total (all variables) so the
    lowered [if]-chain is total. Anything else (cons patterns, [where] guards,
    string/symbol patterns, a non-total final clause) makes the function fall back.

    Out of scope for v1 (recorded in the plan): [/]/rationals, polymorphic and
    list/vector specialization, cross-module specialization, JIT. *)

open Kl.Ast
module SS = Set.Make (String)

let mangle_var = Ocaml_compile.mangle_var
let esc = Ocaml_gen.escaped_string_for_ml
let float_lit = Ocaml_gen.float_literal

(* ------------------------------------------------------------------ *)
(* Parsing single- and multi-clause numeric defines from the flat token list the
   KL parser produces for [(define f { number --> number } P -> BODY ...)]. *)

type clause = { pats : kl_expr list; body : kl_expr }
type defn = { name : string; arity : int; params : string list; body : kl_expr }

(** The [number]-monomorphic arity from a [{ number --> ... --> number }] token run. *)
let number_mono_arity type_tokens =
  let rec go expect = function
    | [ KLSym "number" ] when expect -> Some 0
    | KLSym "number" :: KLSym "-->" :: rest when expect -> (
        match go true rest with Some n -> Some (n + 1) | None -> None)
    | _ -> None
  in
  go true type_tokens

let is_var_pat = function
  | KLSym s -> s <> "" && (s.[0] = '_' || (s.[0] >= 'A' && s.[0] <= 'Z'))
  | _ -> false

let is_lit_num_pat = function KLInt _ | KLFloat _ -> true | _ -> false

(** Split the post-signature tokens into clauses of [arity] patterns then a body. *)
let rec parse_clauses arity acc = function
  | [] -> Some (List.rev acc)
  | toks ->
      let rec take_pats n ps = function
        | KLSym "->" :: body :: rest when n = 0 -> Some (List.rev ps, body, rest)
        | t :: rest when n > 0 -> take_pats (n - 1) (t :: ps) rest
        | _ -> None
      in
      (match take_pats arity [] toks with
       | Some (pats, body, rest) -> parse_clauses arity ({ pats; body } :: acc) rest
       | None -> None)

(** Lower clauses (literal/variable patterns; total final clause) to one body over
    synthetic params [shen_arg_i], or None if the shapes are unsupported. *)
let lower_clauses arity clauses =
  let params = List.init arity (fun i -> Printf.sprintf "shen_arg_%d" i) in
  let supported c =
    List.length c.pats = arity
    && List.for_all (fun p -> is_var_pat p || is_lit_num_pat p) c.pats
  in
  if not (List.for_all supported clauses) then None
  else
    (* final clause must be total (all variables) *)
    match List.rev clauses with
    | [] -> None
    | last :: _ when not (List.for_all is_var_pat last.pats) -> None
    | _ ->
        let lit_of = function
          | KLInt i -> Some (KLInt i)
          | KLFloat f -> Some (KLFloat f)
          | _ -> None
        in
        let clause_expr c =
          (* guard = conjunction of (= param_i lit); bindings = let var_i = param_i *)
          let guards =
            List.fold_right2
              (fun pat pn acc ->
                match lit_of pat with
                | Some lit -> KLApp (KLSym "=", [ KLSym pn; lit ]) :: acc
                | None -> acc)
              c.pats params []
          in
          let body_with_binds =
            List.fold_right2
              (fun pat pn body ->
                if is_var_pat pat then
                  match pat with
                  | KLSym v when v <> pn -> KLApp (KLSym "let", [ KLSym v; KLSym pn; body ])
                  | _ -> body
                else body)
              c.pats params c.body
          in
          (guards, body_with_binds)
        in
        let rec chain = function
          | [] -> None
          | [ c ] ->
              let _, body = clause_expr c in
              Some body (* total final clause: unconditional *)
          | c :: rest -> (
              match chain rest with
              | None -> None
              | Some else_ ->
                  let guards, body = clause_expr c in
                  let cond =
                    match guards with
                    | [] -> KLSym "true"
                    | [ g ] -> g
                    | g :: gs -> List.fold_left (fun a x -> KLApp (KLSym "and", [ a; x ])) g gs
                  in
                  Some (KLApp (KLSym "if", [ cond; body; else_ ])))
        in
        (match chain clauses with Some body -> Some (params, body) | None -> None)

(** Extract a specializable numeric defn from a parsed [(define ...)] form, or None. *)
let parse_define = function
  | KLApp (KLSym "define", KLSym name :: KLSym "{" :: rest) -> (
      let rec take_type acc = function
        | KLSym "}" :: more -> Some (List.rev acc, more)
        | tok :: more -> take_type (tok :: acc) more
        | [] -> None
      in
      match take_type [] rest with
      | None -> None
      | Some (type_tokens, after) -> (
          match number_mono_arity type_tokens with
          | None -> None
          | Some arity -> (
              match parse_clauses arity [] after with
              | None | Some [] -> None
              | Some [ { pats; body } ] when List.for_all is_var_pat pats
                && List.length pats = arity ->
                  (* fast path: single all-variable clause keeps source names *)
                  let params = List.map (function KLSym s -> s | _ -> assert false) pats in
                  Some { name; arity; params; body }
              | Some clauses -> (
                  match lower_clauses arity clauses with
                  | Some (params, body) -> Some { name; arity; params; body }
                  | None -> None))))
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Numeric kinds and the subset compiler. *)

type kind = KInt | KFloat

let ml_type = function KInt -> "int" | KFloat -> "float"
let box_ctor = function KInt -> "Int" | KFloat -> "Float"

let arith_op kind op =
  match (kind, op) with
  | KInt, "+" -> Some "+" | KInt, "-" -> Some "-" | KInt, "*" -> Some "*"
  | KFloat, "+" -> Some "+." | KFloat, "-" -> Some "-." | KFloat, "*" -> Some "*."
  | _ -> None (* "/" excluded for both kinds (see header) *)

exception Not_specializable of string

let int_lit i = if i >= 0 then string_of_int i else "(" ^ string_of_int i ^ ")"

let lit kind = function
  | KLInt i -> ( match kind with
      | KInt -> int_lit i
      (* An int literal is NOT sound in the float subset: the interpreter compares
         it structurally (e.g. [(= 0.0 0)] is false, [(- 5.0 1)] coerces) — a body
         comparing a float against an int literal never terminates on float args
         there. So a function with any int literal is int-only; float-specializable
         functions must use float literals (e.g. [0.0]). *)
      | KFloat -> raise (Not_specializable "int literal in float subset"))
  | KLFloat f -> ( match kind with
      | KFloat -> let l = float_lit f in if l <> "" && l.[0] = '-' then "(" ^ l ^ ")" else l
      | KInt -> raise (Not_specializable "float literal in int subset"))
  | e -> raise (Not_specializable (Kl.Ast.to_string e))

let sp_name kind name =
  let k = match kind with KInt -> "int" | KFloat -> "flt" in
  "sp_" ^ k ^ "_"
  ^ String.map (fun c -> match c with 'a'..'z'|'A'..'Z'|'0'..'9' -> c | _ -> '_') name
  ^ "_"

let rec compile_num kind ~specset ~locals e =
  match e with
  | KLInt _ | KLFloat _ -> lit kind e
  | KLSym s when SS.mem s locals -> mangle_var s
  | KLApp (KLSym op, [ a; b ]) when arith_op kind op <> None ->
      let o = Option.get (arith_op kind op) in
      Printf.sprintf "(%s %s %s)" (compile_num kind ~specset ~locals a) o
        (compile_num kind ~specset ~locals b)
  | KLApp (KLSym "if", [ c; t; el ]) ->
      Printf.sprintf "(if %s then %s else %s)"
        (compile_bool kind ~specset ~locals c)
        (compile_num kind ~specset ~locals t)
        (compile_num kind ~specset ~locals el)
  | KLApp (KLSym "let", [ KLSym x; v; body ]) ->
      Printf.sprintf "(let %s = %s in %s)" (mangle_var x)
        (compile_num kind ~specset ~locals v)
        (compile_num kind ~specset ~locals:(SS.add x locals) body)
  | KLApp (KLSym g, args) when SS.mem g specset ->
      Printf.sprintf "(%s %s)" (sp_name kind g)
        (String.concat " " (List.map (compile_num kind ~specset ~locals) args))
  | _ -> raise (Not_specializable (Kl.Ast.to_string e))

and compile_bool kind ~specset ~locals e =
  let cmp op a b =
    Printf.sprintf "(%s %s %s)" (compile_num kind ~specset ~locals a) op
      (compile_num kind ~specset ~locals b)
  in
  match e with
  | KLSym "true" -> "true"
  | KLSym "false" -> "false"
  | KLApp (KLSym "=", [ a; b ]) -> cmp "=" a b
  | KLApp (KLSym "<", [ a; b ]) -> cmp "<" a b
  | KLApp (KLSym ">", [ a; b ]) -> cmp ">" a b
  | KLApp (KLSym "<=", [ a; b ]) -> cmp "<=" a b
  | KLApp (KLSym ">=", [ a; b ]) -> cmp ">=" a b
  | KLApp (KLSym "and", [ a; b ]) ->
      Printf.sprintf "(%s && %s)" (compile_bool kind ~specset ~locals a)
        (compile_bool kind ~specset ~locals b)
  | KLApp (KLSym "or", [ a; b ]) ->
      Printf.sprintf "(%s || %s)" (compile_bool kind ~specset ~locals a)
        (compile_bool kind ~specset ~locals b)
  | _ -> raise (Not_specializable ("condition: " ^ Kl.Ast.to_string e))

let body_ok kind ~specset d =
  let locals = List.fold_left (fun s p -> SS.add p s) SS.empty d.params in
  try ignore (compile_num kind ~specset ~locals d.body); true
  with Not_specializable _ -> false

(** Fixpoint: largest set of defns whose bodies compile in [kind]'s subset using
    only each other. *)
let specializable_set kind defns =
  let names = List.fold_left (fun s d -> SS.add d.name s) SS.empty defns in
  let rec fix cands =
    let cands' =
      List.fold_left
        (fun acc d ->
          if SS.mem d.name acc && body_ok kind ~specset:acc d then acc
          else SS.remove d.name acc)
        cands defns
    in
    if SS.equal cands cands' then cands' else fix cands'
  in
  fix names

(* ------------------------------------------------------------------ *)

let emit b defns =
  let int_set = specializable_set KInt defns in
  let flt_set = specializable_set KFloat defns in
  Buffer.add_string b "(* @generated Phase C specialization — do not edit. *)\n\n";
  Buffer.add_string b "open Shen.Runtime.Value\n";
  Buffer.add_string b "module E = Shen.Interp.Eval\n";
  Buffer.add_string b "module Env = Shen.Runtime.Env\n";
  Buffer.add_string b "module Spec = Shen.Runtime.Spec\n";
  Buffer.add_string b "let mkcl = Shen.Runtime.Primitives.make_closure\n\n";
  let emit_group kind set =
    let group = List.filter (fun d -> SS.mem d.name set) defns in
    match group with
    | [] -> ()
    | first :: rest ->
        let emit_one kw d =
          let locals = List.fold_left (fun s p -> SS.add p s) SS.empty d.params in
          let args =
            String.concat " "
              (List.map (fun p -> Printf.sprintf "(%s : %s)" (mangle_var p) (ml_type kind)) d.params)
          in
          Printf.bprintf b "%s %s %s : %s =\n  %s\n" kw (sp_name kind d.name) args
            (ml_type kind) (compile_num kind ~specset:set ~locals d.body)
        in
        emit_one "let rec" first;
        List.iter (emit_one "and") rest;
        Buffer.add_string b "\n"
  in
  emit_group KInt int_set;
  emit_group KFloat flt_set;
  (* uniform (Phase B) fallback entries for every defn *)
  List.iter
    (fun d ->
      Printf.bprintf b "let uniform_%s = %s\n"
        (sp_name KInt d.name) (Ocaml_compile.compile_closure d.params d.body))
    defns;
  Buffer.add_string b "\nlet register () : unit =\n";
  List.iter
    (fun d ->
      let pnames = List.map mangle_var d.params in
      let pats ctor = String.concat "; " (List.map (fun p -> ctor ^ " " ^ p) pnames) in
      let call kind = sp_name kind d.name ^ " " ^ String.concat " " pnames in
      let branches = Buffer.create 64 in
      if SS.mem d.name int_set then
        Printf.bprintf branches "[%s] when !Spec.web_valid -> Int (%s) | " (pats "Int") (call KInt);
      if SS.mem d.name flt_set then
        Printf.bprintf branches "[%s] when !Spec.web_valid -> Float (%s) | " (pats "Float") (call KFloat);
      let wrapper =
        if SS.mem d.name int_set || SS.mem d.name flt_set then
          Printf.sprintf
            "(mkcl %d (function %sargs -> (match uniform_%s with Closure c -> c args | _ -> Error \"spec\")))"
            d.arity (Buffer.contents branches) (sp_name KInt d.name)
        else Printf.sprintf "uniform_%s" (sp_name KInt d.name)
      in
      Printf.bprintf b "  (let c = %s in Env.set_fn %s c; Env.register_fn_metadata %s %d c);\n"
        wrapper (esc d.name) (esc d.name) d.arity)
    defns;
  Printf.bprintf b "  Spec.watch [%s];\n  ()\n"
    (String.concat "; " (List.map (fun d -> esc d.name) defns));
  List.filter (fun d -> SS.mem d.name int_set || SS.mem d.name flt_set) defns
  |> List.map (fun d -> d.name)

let compile_forms b forms =
  let defns = List.filter_map parse_define forms in
  emit b defns
