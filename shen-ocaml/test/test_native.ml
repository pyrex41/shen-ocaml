open Shen.Runtime.Value
module N = Shen.Runtime.Native

let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": got " ^ to_string actual)

let () =
  Shen.Runtime.Primitives.initialise ();
  let dynamic_forms = Shen.Kl.Parser.parse_file "fixtures/native.kl" in
  expect "dynamic corpus" (Bool true) ((Shen.Interp.Compiled.compile dynamic_forms) ());
  expect "dynamic deep tail recursion" (Int 500000500000)
    (N.call "test.sum" [Int 1000000; Int 0]);
  expect "compatible corpus" (Bool true) (Native_compatible.run ());
  expect "ABI partial application" (Int 42)
    (N.apply (N.call "test.add" [Int 20]) [Int 22]);
  expect "ABI overapplication" (Int 42)
    (N.call "test.factory" [Int 20; Int 22]);
  expect "compatible deep tail recursion" (Int 500000500000)
    (N.call "test.sum" [Int 1000000; Int 0]);
  expect "compatible mutual tail recursion" (Bool true)
    (N.call "test.even" [Int 1000000]);
  (* A compiled caller must see a subsequent interpreted redefinition. *)
  let redefine = Shen.Kl.Parser.parse_string "(defun test.helper (X) (+ X 100))" in
  List.iter (fun e -> ignore (Shen.Interp.Eval.eval_kl e)) redefine;
  expect "compatible redefinition" (Int 101) (N.call "test.caller" [Int 1]);
  expect "sealed corpus" (Bool true) (Native_sealed.run ());
  List.iter (fun e -> ignore (Shen.Interp.Eval.eval_kl e)) redefine;
  expect "sealed binding" (Int 2) (N.call "test.caller" [Int 1]);
  expect "sealed deep tail recursion" (Int 500000500000)
    (N.call "test.sum" [Int 1000000; Int 0]);
  (match N.call "test.sum" [Float 1000.; Int 0] with
  | Float result when result = 500500. -> ()
  | value -> failwith ("numeric worker did not preserve float fallback: " ^ to_string value));
  expect "sealed mutual tail recursion" (Bool true)
    (N.call "test.even" [Int 1000000]);
  let native_id = N.function_ 1 (function [v] -> v | _ -> assert false) in
  Shen.Runtime.Env.set_fn "test.native-id" native_id;
  let expr = List.hd (Shen.Kl.Parser.parse_string "(test.native-id 42)") in
  expect "legacy calls native" (Int 42) (Shen.Interp.Eval.eval_kl expr);
  let count = List.fold_left (fun count -> function
    | Shen.Kl.Ast.KLApp (KLSym "test.expect", _) -> count + 1
    | _ -> count) 0 dynamic_forms in
  Printf.printf "NATIVE_RESULT corpus=%d modes=3 tail_depth=1000000 redefinition=pass\n" count
