(** KL -> executable OCaml. [Compatible] observes function redefinition;
    [Sealed] binds saturated unit-local calls directly, including mutual tail
    calls. Neither backend falls back to interpreting AST nodes. *)
open Kl.Resolved

type mode = Compatible | Sealed

let generate ~mode ~factories forms =
  let forms = resolve forms in
  let definitions = List.filter_map (function Define d -> Some d | _ -> None) forms in
  let indexed = List.mapi (fun i d -> d.name, ("f" ^ string_of_int i, d)) definitions in
  if factories && List.length definitions <> List.length forms then
    raise (Compile_error "native factories accept only top-level definitions");
  if factories && List.length (List.sort_uniq String.compare (List.map fst indexed))
      <> List.length indexed then
    raise (Compile_error "native factories require unique function definitions");
  if mode = Sealed && List.length (List.sort_uniq String.compare (List.map fst indexed))
      <> List.length indexed then
    raise (Compile_error "sealed compilation requires unique function definitions");
  let serial = ref 0 in
  let fresh () = let i = !serial in incr serial; "t" ^ string_of_int i in
  let variable p = "v" ^ string_of_int p.id in
  let rec literal = function
    | Kl.Ast.KLInt n -> Printf.sprintf "(Int (%d))" n
    | KLFloat f -> Printf.sprintf "(Float (%s))" (Ocaml_gen.float_literal f)
    | KLStr s -> Printf.sprintf "(Str %S)" s
    | KLSym "true" | KLBool true -> "(Bool true)"
    | KLSym "false" | KLBool false -> "(Bool false)"
    | KLSym s -> Printf.sprintf "(Sym %S)" s
    | KLNil -> "Nil"
    | KLCons (h, t) -> Printf.sprintf "(Cons (%s, %s))" (literal h) (literal t)
    | KLApp (h, args) ->
        List.fold_right (fun h t -> Printf.sprintf "(Cons (%s, %s))" (literal h) t)
          (h :: args) "Nil"
    | KLVec values -> "(Vec [|" ^ String.concat "; "
          (List.map literal (Array.to_list values)) ^ "|])"
    | _ -> raise (Compile_error "unsupported literal")
  in
  (* Vector literals are values, not expressions. Allocate once per literal site,
     outside function bodies, preserving their identity across invocations. *)
  let constants = ref [] in
  let cells = Hashtbl.create 128 in
  let cell_bindings = ref [] in
  let cell name = match Hashtbl.find_opt cells name with
    | Some binding -> binding
    | None ->
        let binding = fresh () in
        Hashtbl.add cells name binding;
        cell_bindings := (binding, name) :: !cell_bindings;
        binding
  in
  let rec emit = function
    | Literal (Kl.Ast.KLVec _ as value) ->
        let name = fresh () in
        constants := (name, literal value) :: !constants;
        name
    | Literal value -> literal value
    | Local p -> variable p
    | Let (p, value, body) ->
        let value = emit value in
        let body = emit body in
        Printf.sprintf "(let %s = %s in %s)" (variable p) value body
    | If (c, t, f) ->
        let c = emit c in let t = emit t in let f = emit f in
        Printf.sprintf "(if N.boolean %s then %s else %s)" c t f
    | Lambda (params, body) -> wrapper params (emit body)
    | Freeze body -> wrapper [] (emit body)
    | Thaw body -> ordered [body] (function
        | [body] -> "N.apply0 " ^ body
        | _ -> assert false)
    | Trap (body, Lambda ([parameter], handler)) ->
        (* A syntactic handler lambda has no construction-time effects. Emit
           the guard directly instead of allocating a Native callable plus a
           protected-body thunk on every successful predicate invocation. *)
        let body = emit body in let handler_body = emit handler in
        let message = fresh () in
        let handler_body = if Ids.mem parameter.id (free_variables handler) then
            "let " ^ variable parameter ^ " = Error " ^ message ^ " in " ^ handler_body
          else handler_body in
        "(try " ^ body ^ " with User_error " ^ message ^ " -> " ^ handler_body ^ ")"
    | Trap (body, handler) ->
        let body = emit body in let handler = emit handler in
        let name = fresh () in
        "(let " ^ name ^ " = " ^ handler ^ " in N.protect (fun () -> " ^ body ^ ") " ^ name ^ ")"
    | Sequence (a, b) -> let a = emit a in let b = emit b in
        "(let _ = " ^ a ^ " in " ^ b ^ ")"
    | And (a, b) -> let a = emit a in let b = emit b in
        "(if N.boolean " ^ a ^ " then of_bool (N.boolean " ^ b ^ ") else false_value)"
    | Or (a, b) -> let a = emit a in let b = emit b in
        "(if N.boolean " ^ a ^ " then true_value else of_bool (N.boolean " ^ b ^ "))"
    | Cond clauses ->
        let rec clauses_ = function
          | [] -> "raise (User_error \"cond: no true clause\")"
          | (test, body) :: rest ->
              let test = emit test in let body = emit body in
              "(if N.boolean " ^ test ^ " then " ^ body ^ " else " ^ clauses_ rest ^ ")"
        in clauses_ clauses
    | Cons (h, t) -> ordered [h; t] (function
        | [h; t] -> "Cons (" ^ h ^ ", " ^ t ^ ")"
        | _ -> assert false)
    | Call (Named name, args) ->
        "(" ^ ordered args (fun values -> named_call name values) ^ ")"
    | Call (Dynamic op, args) ->
        let op_value = emit op in
        let op_name = fresh () in
        let rec apply_args fn = function
          | [] -> "N.apply0 " ^ fn
          | [arg] ->
              let value = emit arg in
              let name = fresh () in
              "(let " ^ name ^ " = " ^ value ^ " in N.apply1 " ^ fn ^ " " ^ name ^ ")"
          | arg :: rest ->
              let value = emit arg in
              let name = fresh () in let next = fresh () in
              let rest = apply_args next rest in
              "(let " ^ name ^ " = " ^ value ^ " in let " ^ next ^ " = N.apply1 " ^
                fn ^ " " ^ name ^ " in " ^ rest ^ ")"
        in
        "(let " ^ op_name ^ " = " ^ op_value ^ " in " ^ apply_args op_name args ^ ")"
    | Define _ -> raise (Compile_error "unexpected nested definition")
  and ordered expressions finish =
    (* Bind every operand in source order; never rely on OCaml's operand or tuple
       evaluation order. The resulting call remains in tail position. *)
    let rec loop names = function
      | [] -> finish (List.rev names)
      | expression :: rest ->
          let name = fresh () in
          let value = emit expression in
          let rest = loop (name :: names) rest in
          "(let " ^ name ^ " = " ^ value ^ " in " ^ rest ^ ")"
    in loop [] expressions
  and named_call name values =
    let arity = List.length values in
    let direct fn = fn ^ " " ^ (if arity = 0 then "()" else String.concat " " values) in
    let fallback () =
      let binding = cell name in
      if arity <= 8 then "N.call" ^ string_of_int arity ^ " " ^ binding ^
        (if arity = 0 then "" else " " ^ String.concat " " values)
      else Printf.sprintf "N.call_cell %s [%s]" binding (String.concat "; " values)
    in
    match mode, List.assoc_opt name indexed with
    | Sealed, Some (fn, d) when List.length d.params = arity -> direct fn
    | Sealed, Some (fn, d) ->
        let args = if d.params = [] then "()" else String.concat " " (List.map variable d.params) in
        "N.apply " ^ wrapper d.params (fn ^ " " ^ args) ^ " [" ^ String.concat "; " values ^ "]"
    | Sealed, None -> (match Runtime.Native.primitive (name, arity) with
        | Some fn -> direct fn
        | None -> fallback ())
    | _ -> fallback ()
  and wrapper params body =
    let arity = List.length params in
    if arity <= 8 then
      Printf.sprintf "(N.function%d (fun %s -> %s))" arity
        (if arity = 0 then "()" else String.concat " " (List.map variable params)) body
    else Printf.sprintf "(N.function_ %d (function [%s] -> %s | _ -> assert false))"
      arity (String.concat "; " (List.map variable params)) body
  in
  let workers = ref [] in
  let guarded = ref [] in
  let bodies = List.map (fun (_, (fn, d)) ->
    let params = if d.params = [] then "()" else String.concat " " (List.map variable d.params) in
    let body = emit d.body in
    let body =
      let worker_name = "numeric_" ^ fn in
      match Numeric_loop.emit_with_primitives ~worker:(d.name, worker_name)
              ~shadowed:(if mode = Sealed then List.map fst indexed else [])
              ~params:d.params d.body with
      | None -> body
      | Some (integer_params, integer_body, primitives) ->
          workers := (worker_name ^ " " ^ String.concat " " integer_params ^ " = " ^ integer_body) :: !workers;
          let guard = match mode with
            | Sealed -> ""
            | Compatible ->
                let expected = "guarded_" ^ fn in
                guarded := (fn, expected) :: !guarded;
                let self = "G.binding " ^ cell d.name ^ " !" ^ expected in
                let primitives = List.map (fun name ->
                  match Runtime.Native.primitive (name, 2) with
                  | Some implementation -> "G.primitive " ^ cell name ^ " " ^ implementation
                  | None -> "false") primitives in
                " when " ^ String.concat " && " (self :: primitives)
          in
          let values = String.concat ", " (List.map variable d.params) in
          let pattern = String.concat ", " (List.map (fun name -> "Int " ^ name) integer_params) in
          "(match (" ^ values ^ ") with (" ^ pattern ^ ")" ^ guard ^ " -> Int (" ^ worker_name ^ " " ^
            String.concat " " integer_params ^ ") | _ -> " ^ body ^ ")"
    in
    fn ^ " " ^ params ^ " = " ^ body) indexed in
  let bodies = bodies @ List.rev !workers in
  let remaining = ref indexed in
  let actions = List.map (function
    | Define d ->
        let fn = match !remaining with
          | (_, (fn, _)) :: rest -> remaining := rest; fn
          | [] -> assert false
        in
        let args = if d.params = [] then "()" else String.concat " " (List.map variable d.params) in
        let install = match List.assoc_opt fn !guarded with
          | None -> "N.install"
          | Some expected -> "G.install " ^ expected in
        Printf.sprintf "%s %S %d %s" install d.name (List.length d.params)
          (wrapper d.params (fn ^ " " ^ args))
    | expression -> emit expression) forms in
  let rec sequence = function
    | [] -> "Nil"
    | [action] -> action
    | action :: rest -> "let _ = " ^ action ^ " in\n" ^ sequence rest
  in
  let run = if not factories then sequence actions else (
    (* A promotion factory constructs native callables without installation,
       metadata callbacks or user-body execution. The caller must validate the
       entire old binding group before publishing any replacements. *)
    let exports = List.map (fun (_, (fn, d)) ->
      let name = "export_" ^ fn in
      let args = if d.params = [] then "()" else String.concat " " (List.map variable d.params) in
      name, d, wrapper d.params (fn ^ " " ^ args), List.assoc_opt fn !guarded) indexed in
    String.concat "" (List.map (fun (name, _, callable, _) ->
      "let " ^ name ^ " = " ^ callable ^ " in\n") exports) ^
    String.concat "" (List.filter_map (fun (name, _, _, expected) ->
      Option.map (fun expected -> "let () = " ^ expected ^ " := Some " ^ name ^ " in\n") expected) exports) ^
    List.fold_right (fun (name, d, _, _) tail ->
      Printf.sprintf "Cons (Cons (Sym %S, %s), %s)" d.name name tail) exports "Nil") in
  "(* Generated executable KL; no interpreter fallback. *)\n" ^
  "[@@@warning \"-26-27-32-33-39\"]\n" ^
  "open Shen.Runtime.Value\nmodule N = Shen.Runtime.Native\nmodule G = Shen.Runtime.Guarded\n" ^
  String.concat "\n" (List.map (fun (_, expected) -> "let " ^ expected ^ " = ref None")
    (List.rev !guarded)) ^ "\n" ^
  String.concat "\n" (List.map (fun (binding, name) ->
    Printf.sprintf "let %s = Shen.Runtime.Env.function_cell %S" binding name)
    (List.rev !cell_bindings)) ^ "\n" ^
  String.concat "\n" (List.map (fun (name, value) -> "let " ^ name ^ " = " ^ value)
    (List.rev !constants)) ^ "\n" ^
  (match bodies with [] -> "" | first :: rest -> "let rec " ^ first ^
    String.concat "" (List.map (fun body -> "\nand " ^ body) rest) ^ "\n") ^
  "let run () =\n" ^ run ^ "\n"

let compile ?(mode = Compatible) forms = generate ~mode ~factories:false forms

(** Return an association list of native callables, without installing anything.
    Only compatible binding is allowed for implementation-only promotion. *)
let compile_factories forms = generate ~mode:Compatible ~factories:true forms

let compile_file ?mode input output =
  let source = compile ?mode (Kl.Parser.parse_file input) in
  let channel = open_out_bin output in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel source)
