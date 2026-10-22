open Shen.Runtime.Value
module B = Shen_cli.Native_build
module N = Shen.Runtime.Native

let expect actual expected =
  if not (equal actual expected) then
    failwith (Printf.sprintf "expected %s, got %s" (to_string expected) (to_string actual))

let rejected text =
  match B.translate text with
  | _ -> failwith ("unexpectedly accepted: " ^ text)
  | exception B.Build_error _ -> ()

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--load-only" then (
    Shen.Runtime.Env.set_eval_kl_from_value (fun _ -> failwith "eval-kl used while loading native artifact");
    ignore (B.load_file Sys.argv.(2));
    expect (N.call "native-slice-caller" [Int 40]) (Int 42);
    expect (N.call "native-slice-sum" [Int 100000; Int 0]) (Int 5000050000);
    print_endline "NATIVE_USER_FRESH_HOST_RESULT load=pass execution=pass no_eval_kl=pass";
    exit 0);
  let output_dir = Sys.argv.(1) in
  let config : B.config = { ocamlopt = "ocamlopt"; include_dirs = [
    "_build/default/src/.shen.objs/byte";
    "_build/default/src/.shen.objs/native"
  ] } in
  (* Even compiler-side eval-kl is forbidden: translation must return KL data,
     not execute/install user functions or compile arbitrary lambdas. *)
  Shen.Runtime.Env.set_eval_kl_from_value (fun _ -> failwith "eval-kl used during native compilation");
  let before = Unix.gettimeofday () in
  let artifact = B.compile_file ~config ~output_dir "test/fixtures/native_user_slice.shen" in
  let compile_seconds = Unix.gettimeofday () -. before in
  if Shen.Runtime.Env.get_fn "native-slice-sum" <> None then failwith "compile installed a function";
  if Shen.Runtime.Env.get_global "native-slice-marker" <> None then failwith "compile ran a body";
  ignore (B.load artifact);
  List.iter (fun name -> match Shen.Runtime.Env.get_fn name with
    | Some (Native _) -> ()
    | _ -> failwith (name ^ " is not native"))
    ["native-slice-sum"; "native-slice-length"; "native-slice-increment"; "native-slice-caller"];
  let before = Unix.gettimeofday () in
  expect (N.call "native-slice-sum" [Int 100000; Int 0]) (Int 5000050000);
  expect (N.call "native-slice-length" [Cons (Int 1, Cons (Int 2, Nil))]) (Int 2);
  expect (N.call "native-slice-caller" [Int 40]) (Int 42);
  expect (N.call "native-slice-lambda" [Int 40]) (Int 42);
  expect (N.call "arity" [Sym "native-slice-sum"]) (Int 2);
  (match N.call "ps" [Sym "native-slice-sum"] with
  | Cons (Sym "defun", Cons (Sym "native-slice-sum", _)) -> ()
  | _ -> failwith "native source metadata not recorded");
  (match cons_to_proper_list (N.call "userdefs" []) with
  | Some definitions when List.exists (equal (Sym "native-slice-sum")) definitions -> ()
  | _ -> failwith "native userdefs metadata not recorded");
  expect (N.call "native-slice-effect" [Int 42]) (Int 42);
  expect (N.call "value" [Sym "native-slice-marker"]) (Int 42);
  let execution_seconds = Unix.gettimeofday () -. before in
  let saved_fn = N.call "fn" [Sym "native-slice-increment"] in
  ignore (N.install "native-slice-increment" 1 (N.function1 (fun x -> N.add x (Int 3))));
  expect (N.call "native-slice-caller" [Int 39]) (Int 42);
  expect (N.apply saved_fn [Int 39]) (Int 42);
  ignore (N.install "native-slice-reference" 2 (N.function2 N.add));
  let partial_fn = N.apply (N.call "fn" [Sym "native-slice-reference"]) [Int 1] in
  ignore (N.install "native-slice-reference" 2 (N.function2 (fun _ _ -> Int 99)));
  expect (N.apply partial_fn [Int 2]) (Int 99);
  ignore (B.load artifact);
  expect (N.call "native-slice-caller" [Int 40]) (Int 42);
  expect (N.apply (N.call "fn" [Sym "native-slice-increment"]) [Int 40]) (Int 42);
  List.iter rejected [
    "(set native-slice-must-not-run 42)";
    "(define native-slice-ok X -> X) (set native-slice-must-not-run 42)";
    "(package example [] (define example-id X -> X))";
    "(defmacro native-slice-macro X -> X)";
    "(datatype native-slice-type X : native-slice-type;)";
    "(define native-slice-typed { number --> number } X -> X)";
    "(define native-slice-macro-body X -> (time X))";
    "(define native-slice-nested X -> (define nope Y -> Y))"
    ; "(define native-slice-partial X -> (+ X))"
    ; "(define native-slice-add X Y -> (+ X Y)) (define native-slice-partial X -> (native-slice-add X))"
    ; "(define native-slice-changing X -> X) (define native-slice-changing X Y -> X)"
    ; "(define if X -> X)"
  ];
  if Shen.Runtime.Env.get_global "native-slice-must-not-run" <> None then failwith "rejected top-level effect ran";
  let macros = Option.get (Shen.Runtime.Env.get_global "*macros*") in
  Fun.protect ~finally:(fun () -> Shen.Runtime.Env.set_global "*macros*" macros)
    (fun () ->
      Shen.Runtime.Env.set_global "*macros*" (Cons (Sym "changed", macros));
      rejected "(define native-slice-custom-macros X -> (+ X 1))");
  Printf.printf "NATIVE_USER_RESULT native=pass compile_s=%.6f execution_s=%.6f redefinition=pass metadata=pass fail_closed=pass\n%!"
    compile_seconds execution_seconds
