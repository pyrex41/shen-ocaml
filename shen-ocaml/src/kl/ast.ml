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

let rec to_string = function
  | KLInt i -> string_of_int i
  | KLFloat f -> string_of_float f
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
