(** 
 * src/kl/ir.ml
 * Shared Intermediate Representation for KL with tail-position annotations.
 * Used by both interpreter and AOT OCaml code generator.
 *)

open Ast

type tail_pos = bool

type ir_expr =
  | IRIConst of kl_expr  (* constant from AST *)
  | IRVar of string
  | IRApp of ir_expr * ir_expr list * tail_pos
  | IRLambda of string * ir_expr
  | IRLet of string * ir_expr * ir_expr * tail_pos
  | IRIf of ir_expr * ir_expr * ir_expr * tail_pos
  | IRDefun of string * string list * ir_expr
  | IRPrim of string * ir_expr list * tail_pos

(* Convert KL AST to IR, annotating tail positions *)
let rec lower ?(tail = false) (e : kl_expr) : ir_expr =
  match e with
  | KLInt _ | KLFloat _ | KLStr _ | KLSym _ | KLBool _ | KLNil ->
      IRIConst e
  | KLCons _ -> IRIConst e  (* or handle specially *)
  | KLVec _ -> IRIConst e
  | KLApp (f, args) ->
      let f' = lower ~tail:false f in
      let args' = List.map (lower ~tail:false) args in
      IRApp (f', args', tail)
  | KLLambda (x, body) ->
      IRLambda (x, lower ~tail body)
  | KLLet (x, v, body) ->
      IRLet (x, lower ~tail:false v, lower ~tail body, tail)
  | KLIf (cond, then_, else_) ->
      IRIf (lower ~tail:false cond, 
            lower ~tail then_, 
            lower ~tail else_, 
            tail)
  | KLDefun (name, params, body) ->
      IRDefun (name, params, lower ~tail:true body)

let rec ir_to_string = function
  | IRIConst e -> Ast.to_string e
  | IRVar v -> v
  | IRApp (f, args, t) -> 
      let tail_str = if t then "[tail]" else "" in
      "(" ^ ir_to_string f ^ " " ^ 
      String.concat " " (List.map ir_to_string args) ^ ")" ^ tail_str
  | IRLambda (x, b) -> "(lambda " ^ x ^ " " ^ ir_to_string b ^ ")"
  | IRLet (x, v, b, _) -> "(let " ^ x ^ " = " ^ ir_to_string v ^ " in " ^ ir_to_string b ^ ")"
  | IRIf (c, th, el, _) -> "(if " ^ ir_to_string c ^ " then " ^ ir_to_string th ^ " else " ^ ir_to_string el ^ ")"
  | IRDefun (n, ps, b) -> "(defun " ^ n ^ " (" ^ String.concat " " ps ^ ") " ^ ir_to_string b ^ ")"
  | IRPrim (p, args, _) -> "prim:" ^ p ^ "(" ^ String.concat "," (List.map ir_to_string args) ^ ")"

(* TODO: add conversion from value to ir_expr *)
let of_value _ = IRIConst KLNil
