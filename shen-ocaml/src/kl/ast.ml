(** 
 * src/kl/ast.ml
 * KL AST types for parser and interpreter/code generator.
 *)

type kl_expr =
  | KLInt of int
  | KLFloat of float
  | KLStr of string
  | KLSym of string
  | KLBool of bool
  | KLCons of kl_expr * kl_expr
  | KLNil
  | KLVec of kl_expr array
  | KLApp of kl_expr * kl_expr list
  | KLLambda of string * kl_expr
  | KLLet of string * kl_expr * kl_expr
  | KLIf of kl_expr * kl_expr * kl_expr
  | KLDefun of string * string list * kl_expr

(* [string_of_float 0.0] = "0." and the Shen reader parses a trailing-dot literal
   as an INT (0), which silently changes [(= x 0.0)] into [(= x 0)] on a round-trip
   through [to_string]. Render floats reader-safely (always a digit after the dot). *)
let float_to_string f =
  let s = string_of_float f in
  if String.length s > 0 && s.[String.length s - 1] = '.' then s ^ "0" else s

let rec to_string = function
  | KLInt i -> string_of_int i
  | KLFloat f -> float_to_string f
  | KLStr s -> "\"" ^ s ^ "\""
  | KLSym s -> s
  | KLBool true -> "true"
  | KLBool false -> "false"
  | KLCons (h, t) -> "(" ^ to_string h ^ " . " ^ to_string t ^ ")"
  | KLNil -> "[]"
  | KLVec _ -> "<vector>"
  | KLApp (f, args) -> "(" ^ to_string f ^ " " ^ String.concat " " (List.map to_string args) ^ ")"
  | KLLambda (x, body) -> "(lambda " ^ x ^ " " ^ to_string body ^ ")"
  | _ -> "<kl-expr>"

(* TODO: convert runtime value to kl ast - will use Runtime.Value *)
let of_value _v = KLStr "<value>"
