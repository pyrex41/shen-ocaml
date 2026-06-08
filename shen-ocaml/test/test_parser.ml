(** test/test_parser.ml - Unit tests for KL parser *)

open Alcotest
open Shen.Kl.Ast
open Shen.Kl.Parser

let test_parse_simple () =
  let exprs = parse_string "(+ 1 2)" in
  check int "one expression" (List.length exprs) 1;
  match List.hd exprs with
  | KLApp (KLSym "+", [KLInt 1; KLInt 2]) -> ()
  | _ -> fail "expected (+ 1 2)"

let test_parse_nested () =
  let exprs = parse_string "(defun inc (x) (+ x 1))" in
  check int "one defun" (List.length exprs) 1;
  match List.hd exprs with
  | KLApp (KLSym "defun", [KLSym "inc"; _; _]) -> ()
  | _ -> fail "expected defun structure"

let test_parse_string () =
  let exprs = parse_string "(str \"hello\")" in
  check int "parsed string expr" (List.length exprs) 1

let test_parse_arrow_symbol () =
  let exprs = parse_string "(= (hd X) ->)" in
  check int "one expr" (List.length exprs) 1;
  match List.hd exprs with
  | KLApp (KLSym "=", [KLApp (KLSym "hd", [KLSym "X"]); KLSym "->"]) -> ()
  | _ -> fail "expected (= (hd X) ->), not -> split into - and >"

let test_parse_negative_int () =
  let exprs = parse_string "(+ -1 2)" in
  check int "one expr" (List.length exprs) 1;
  match List.hd exprs with
  | KLApp (KLSym "+", [KLInt (-1); KLInt 2]) -> ()
  | _ -> fail "expected (+ -1 2) with negative literal"

let tests = [
  test_case "parse simple expression" `Quick test_parse_simple;
  test_case "parse nested defun" `Quick test_parse_nested;
  test_case "parse string literal" `Quick test_parse_string;
  test_case "parse -> as one symbol" `Quick test_parse_arrow_symbol;
  test_case "parse negative integer" `Quick test_parse_negative_int;
]