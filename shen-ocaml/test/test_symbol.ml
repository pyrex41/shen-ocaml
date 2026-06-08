(** test/test_symbol.ml - Unit tests for symbol interning *)

open Alcotest
open Shen.Runtime.Symbol

let test_intern () =
  let s1 = intern "foo" in
  let s2 = intern "foo" in
  let s3 = intern "bar" in
  check int "same id for same name" (id s1) (id s2);
  check bool "different names have different ids" (id s1 <> id s3) true;
  check string "name preserved" (to_string s1) "foo"

let test_preinterned () =
  let t = intern "true" in
  check string "true symbol" (to_string t) "true"

let tests = [
  test_case "intern" `Quick test_intern;
  test_case "preinterned symbols" `Quick test_preinterned;
]