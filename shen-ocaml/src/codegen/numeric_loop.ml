(** A deliberately small, fail-closed integer worker specialization for native
    functions. All inputs are guarded as [Int] by the caller; only integer-closed,
    effect-free operations and exact self calls are accepted. OCaml's machine-int
    arithmetic has the same overflow behavior as the existing runtime (which is
    not yet Shen arbitrary-precision arithmetic). No unsafe representation casts. *)
open Kl.Resolved

exception Unsupported

let primitive_names = ["+"; "-"; "*"; "="; "<"; ">"; "<="; ">="]

let emit_with_primitives ~worker ~shadowed ~params body =
  let serial = ref 0 in
  let recursive = ref false in
  let primitives = ref [] in
  let fresh () = let n = !serial in incr serial; "ni" ^ string_of_int n in
  let variable binding = "nv" ^ string_of_int binding.id in
  let primitive name =
    if List.mem name shadowed then false
    else (if not (List.mem name !primitives) then primitives := name :: !primitives; true)
  in
  let rec integer bound = function
    | Literal (Kl.Ast.KLInt value) -> Printf.sprintf "(%d)" value
    | Local binding when List.mem binding.id bound -> variable binding
    | Let (binding, value, body) ->
        let value = integer bound value in
        let body = integer (binding.id :: bound) body in
        "(let " ^ variable binding ^ " = " ^ value ^ " in " ^ body ^ ")"
    | If (condition, yes, no) ->
        let condition = boolean bound condition in
        let yes = integer bound yes in let no = integer bound no in
        "(if " ^ condition ^ " then " ^ yes ^ " else " ^ no ^ ")"
    | Call (Named name, [a; b]) when List.mem name ["+"; "-"; "*"] && primitive name ->
        ordered bound [a; b] (function
          | [a; b] -> "(" ^ a ^ " " ^ name ^ " " ^ b ^ ")"
          | _ -> assert false)
    | Call (Named name, args) when name = fst worker && List.length args = List.length params ->
        recursive := true;
        ordered bound args (fun args -> snd worker ^ " " ^
          (if args = [] then "()" else String.concat " " args))
    | Sequence (a, b) ->
        let a = integer bound a in let b = integer bound b in
        "(let _ = " ^ a ^ " in " ^ b ^ ")"
    | Cond clauses ->
        let rec emit = function
          | [] -> raise Unsupported
          | [(Literal (Kl.Ast.KLBool true | KLSym "true")), body] -> integer bound body
          | (test, body) :: rest ->
              let test = boolean bound test in let body = integer bound body in
              "(if " ^ test ^ " then " ^ body ^ " else " ^ emit rest ^ ")"
        in emit clauses
    | _ -> raise Unsupported
  and boolean bound = function
    | Literal (Kl.Ast.KLBool value) -> string_of_bool value
    | Literal (KLSym "true") -> "true"
    | Literal (KLSym "false") -> "false"
    | Call (Named op, [a; b]) when List.mem op ["="; "<"; ">"; "<="; ">="] && primitive op ->
        ordered bound [a; b] (function
          | [a; b] -> "(" ^ a ^ " " ^ op ^ " " ^ b ^ ")"
          | _ -> assert false)
    | And (a, b) ->
        let a = boolean bound a in let b = boolean bound b in "(" ^ a ^ " && " ^ b ^ ")"
    | Or (a, b) ->
        let a = boolean bound a in let b = boolean bound b in "(" ^ a ^ " || " ^ b ^ ")"
    | If (test, yes, no) ->
        let test = boolean bound test in let yes = boolean bound yes in let no = boolean bound no in
        "(if " ^ test ^ " then " ^ yes ^ " else " ^ no ^ ")"
    | _ -> raise Unsupported
  and ordered bound values finish =
    let rec loop names = function
      | [] -> "(" ^ finish (List.rev names) ^ ")"
      | value :: rest ->
          let value = integer bound value in
          let name = fresh () in
          let rest = loop (name :: names) rest in
          "(let " ^ name ^ " = " ^ value ^ " in " ^ rest ^ ")"
    in loop [] values
  in
  (* Empty-parameter functions provide no numeric loop to unbox. *)
  if params = [] || List.mem (fst worker) primitive_names then None
  else try
    let body = integer (List.map (fun parameter -> parameter.id) params) body in
    if !recursive then Some (List.map variable params, body, List.rev !primitives) else None
  with Unsupported -> None

(* Keep the sealed worker API available to existing producers and tests. *)
let emit ~worker ~shadowed ~params body =
  Option.map (fun (params, body, _) -> params, body)
    (emit_with_primitives ~worker ~shadowed ~params body)
