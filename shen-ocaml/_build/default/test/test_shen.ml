(** test/test_shen.ml - Basic unit tests for Shen OCaml *)

open Shen.Runtime.Symbol
open Shen.Kl.Parser

let test_symbol () =
  print_endline "Testing symbol interning...";
  let s1 = intern "test-sym" in
  let s2 = intern "test-sym" in
  let s3 = intern "other" in
  assert (id s1 = id s2);
  assert (id s1 <> id s3);
  assert (Shen.Runtime.Symbol.to_string s1 = "test-sym");
  print_endline "  Symbol tests passed."

let test_parser () =
  print_endline "Testing KL parser...";
  let exprs = parse_string "(+ 1 2)" in
  assert (List.length exprs = 1);
  (match List.hd exprs with
   | Shen.Kl.Ast.KLApp (Shen.Kl.Ast.KLSym "+", [Shen.Kl.Ast.KLInt _; Shen.Kl.Ast.KLInt _]) -> ()
   | _ -> failwith "parse failed");
  print_endline "  Parser tests passed."

let () =
  print_endline "\n=== Running Shen-OCaml Unit Tests ===";
  test_symbol ();
  test_parser ();
  Test_eval.run ();
  print_endline "\n✅ All tests passed!";
  print_endline "dune test successful."