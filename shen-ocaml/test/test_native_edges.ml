open Shen.Runtime.Value
module N = Shen.Runtime.Native

let expect expected value =
  if not (equal expected value) then failwith ("unexpected value: " ^ to_string value)

let () =
  Shen.Runtime.Primitives.initialise ();
  ignore (Native_edges.run ());
  expect (Int 1) (N.call "Case" []);
  expect (Int 2) (N.call "case" []);
  expect (Int 42) (N.call "let-shadow" []);
  expect (Int 42) (N.call "zero-test" []);
  let first = N.call "vector-literal" [] in
  let second = N.call "vector-literal" [] in
  if first != second then failwith "vector literal identity changed across invocations";
  expect (Vec [|Sym "literal-symbol"; Cons (Sym "not-a-call", Cons (Int 42, Nil))|]) first;
  let malformed = ["(defun bad (X X) X)"; "(if true 1)";
                   "(let X 1 (defun nested () X))"] in
  List.iter (fun source ->
    match Shen.Codegen.Native_gen.compile (Shen.Kl.Parser.parse_string source) with
    | _ -> failwith ("accepted invalid/unsupported source: " ^ source)
    | exception Shen.Kl.Resolved.Compile_error _ -> ()) malformed;
  let forms = Shen.Kl.Parser.parse_string "(defun f (X) (let X (+ X 1) X))" in
  if Shen.Codegen.Native_gen.compile forms <> Shen.Codegen.Native_gen.compile forms then
    failwith "code generation is nondeterministic";
  List.iter (fun (a, b) ->
    if not (equal a b) || hash a <> hash b then failwith "equal values hash differently") [
      Int 42, Float 42.;
      Float 0., Float (-0.);
      Cons (Int 42, Nil), Cons (Float 42., Nil);
      Vec [|Int 42|], Vec [|Float 42.|];
  ];
  print_endline "NATIVE_EDGE_RESULT literals=pass bindings=pass validation=pass numeric_hash=pass"
