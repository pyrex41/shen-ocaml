(** 
 * src/kl/parser.ml
 * KL s-expression parser for Shen-OCaml.
 * Parses .kl files into kl_expr AST.
 *)

open Ast

exception Parse_error of string

type input = {
  str : string;
  mutable pos : int;
  len : int;
}

let make_input s = { str = s; pos = 0; len = String.length s }

let peek inp =
  if inp.pos < inp.len then Some inp.str.[inp.pos] else None

let peek_ahead inp off =
  let i = inp.pos + off in
  if i < inp.len then Some inp.str.[i] else None

let advance inp =
  if inp.pos < inp.len then inp.pos <- inp.pos + 1

let parse_err inp msg =
  raise (Parse_error (Printf.sprintf "%s (byte %d)" msg inp.pos))

let skip_whitespace inp =
  while match peek inp with
    | Some c when (c = ' ' || c = '\n' || c = '\t' || c = '\r') -> true
    | _ -> false
  do advance inp done

let parse_symbol inp =
  skip_whitespace inp;
  let buf = Buffer.create 16 in
  let rec loop () =
    match peek inp with
    | Some c when (not (List.mem c ['('; ')'; ' '; '\n'; '\t'; '\r'])) ->
        Buffer.add_char buf c;
        advance inp;
        loop ()
    | _ -> ()
  in
  loop ();
  let s = Buffer.contents buf in
  if s = "" then parse_err inp "expected symbol"
  else KLSym s

let parse_number inp =
  skip_whitespace inp;
  let buf = Buffer.create 16 in
  let rec loop () =
    match peek inp with
    | Some c when (c >= '0' && c <= '9') || c = '.' || c = '-' || c = 'e' || c = 'E' ->
        Buffer.add_char buf c;
        advance inp;
        loop ()
    | _ -> ()
  in
  loop ();
  let s = Buffer.contents buf in
  try 
    if String.contains s '.' || String.contains s 'e' || String.contains s 'E' then
      KLFloat (float_of_string s)
    else
      KLInt (int_of_string s)
  with _ -> KLSym s  (* fallback *)

let parse_string inp =
  skip_whitespace inp;
  match peek inp with
  | Some '"' ->
      advance inp;
      let buf = Buffer.create 32 in
      let rec loop () =
        match peek inp with
        | Some '"' -> advance inp; ()
        | Some '\\' -> 
            advance inp;
            (match peek inp with
             | Some c -> 
                 Buffer.add_char buf (match c with
                   | 'n' -> '\n'
                   | 't' -> '\t'
                   | 'r' -> '\r'
                   | '"' -> '"'
                   | _ -> c);
                 advance inp;
                 loop ()
             | None -> raise (Parse_error "unterminated string"))
        | Some c -> Buffer.add_char buf c; advance inp; loop ()
        | None -> raise (Parse_error "unterminated string")
      in
      loop ();
      KLStr (Buffer.contents buf)
  | _ -> raise (Parse_error "expected string")

let rec parse_expr inp =
  skip_whitespace inp;
  match peek inp with
  | Some '(' ->
      advance inp;
      let rec parse_list acc =
        skip_whitespace inp;
        match peek inp with
        | Some ')' -> 
            advance inp;
            List.rev acc
        | Some _ ->
            let e = parse_expr inp in
            parse_list (e :: acc)
        | None -> raise (Parse_error "unterminated list")
      in
      let items = parse_list [] in
      (match items with
       | [] -> KLNil
       | f :: args -> KLApp (f, args))
  | Some '"' -> parse_string inp
  | Some c when c >= '0' && c <= '9' -> parse_number inp
  | Some '-' -> (
      (* Avoid splitting symbols like [->] into [-] and [>] (breaks reader.kl find-arity). *)
      match peek_ahead inp 1 with
      | Some c when (c >= '0' && c <= '9') || c = '.' -> parse_number inp
      | _ -> parse_symbol inp)
  | Some ')' -> parse_err inp "unexpected ')'"
  | Some _ -> parse_symbol inp
  | None -> raise (Parse_error "unexpected end of input")

let parse_string s =
  let inp = make_input s in
  let rec parse_all acc =
    skip_whitespace inp;
    if inp.pos >= inp.len then List.rev acc
    else 
      let e = parse_expr inp in
      parse_all (e :: acc)
  in
  parse_all []

let parse_file filename =
  let ch = open_in filename in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch;
  parse_string s

(* Conversion helpers *)
let to_value _ = KLStr "<kl-value>"  (* TODO integrate with runtime *)

let from_value _v = KLStr "<value>"

let rec kl_to_string = function
  | KLInt i -> string_of_int i
  | KLFloat f -> string_of_float f
  | KLStr s -> "\"" ^ s ^ "\""
  | KLSym s -> s
  | KLBool true -> "true"
  | KLBool false -> "false"
  | KLCons (h, t) -> "(" ^ kl_to_string h ^ " . " ^ kl_to_string t ^ ")"
  | KLNil -> "()"
  | KLApp (f, args) -> "(" ^ kl_to_string f ^ " " ^ 
      (String.concat " " (List.map kl_to_string args)) ^ ")"
  | _ -> "<expr>" 
