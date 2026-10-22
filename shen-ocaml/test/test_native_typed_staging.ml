open Shen.Runtime.Value
module B = Shen_cli.Native_build
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env

let expect actual expected =
  if not (equal actual expected) then
    failwith (Printf.sprintf "expected %s, got %s" (to_string expected) (to_string actual))

let rejected source =
  match B.translate_module source with
  | _ -> failwith ("unexpected acceptance: " ^ source)
  | exception B.Build_error _ -> ()

let metadata_unchanged action =
  let globals = List.map (fun key -> key, E.get_global key)
    ["shen.*sigf*"; "shen.*userdefs*"; "*property-vector*";
     "shen.*infs*"; "shen.*prologvectors*"] in
  Fun.protect ~finally:(fun () -> List.iter (fun (key, old) ->
    match old, E.get_global key with
    | None, None -> ()
    | Some before, Some after when before == after -> ()
    | _ -> failwith ("staging leaked " ^ key)) globals) action

let verify () =
  expect (N.call "native-typed-call" [Int 40]) (Int 42);
  expect (N.call "native-typed-length" [Cons (Int 1, Cons (Int 2, Nil))]) (Int 2);
  expect (N.call "native-typed-even" [Int 100]) (Bool true);
  expect (N.call "native-typed-zero" []) (Int 42);
  expect (N.apply (N.call "native-typed-lambda" [Int 42]) [Int 17]) (Int 17);
  expect (N.call "arity" [Sym "native-typed-zero"]) (Int 0);
  expect (N.call "arity" [Sym "native-typed-length"]) (Int 1);
  (match N.call "ps" [Sym "native-typed-length"] with
   | Cons (Sym "defun", _) -> () | _ -> failwith "missing ps");
  (match cons_to_proper_list (N.call "userdefs" []) with
   | Some names when List.exists (equal (Sym "native-typed-length")) names -> ()
   | _ -> failwith "missing userdefs");
  expect (N.call "shen.typecheck"
    [Cons (Sym "native-typed-add", Cons (Str "bad", Nil)); Sym "number"]) (Bool false);
  (match N.call "native-typed-effect" [Int 42] with
   | _ -> failwith "expected body error"
   | exception User_error "typed body was executed" -> ())

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  if Array.length Sys.argv = 3 && Sys.argv.(1) = "--load-only" then (
    ignore (B.load_file Sys.argv.(2)); verify ();
    print_endline "NATIVE_TYPED_FRESH_HOST pass"; exit 0);
  let output_dir = Sys.argv.(1) in
  let config : B.config = { ocamlopt = "ocamlopt"; include_dirs = [
    "_build/default/src/.shen.objs/byte"; "_build/default/src/.shen.objs/native"] } in
  let artifact = metadata_unchanged (fun () ->
    B.compile_file ~config ~output_dir "test/fixtures/native_typed_staging.shen") in
  if E.get_fn "native-typed-add" <> None then failwith "staging installed user function";
  if E.get_global "native-typed-staging-marker" <> None then failwith "staging ran user body";
  metadata_unchanged (fun () -> List.iter rejected [
    "(define native-typed-bad { number --> number } X -> true)";
    "(define native-typed-bad { number --> number } X -> (+ X true))";
    "(define native-typed-bad { number --> number } X -> (+ X \"bad\"))";
    "(define native-typed-bad { number --> number } X -> X) (set forbidden 1)";
    "(define native-typed-bad { number --> number } X -> X) (define untyped X -> X)";
    "(define native-typed-bad { mystery --> mystery } X -> X)";
    "(define native-typed-bad { number --> number } X -> (time X))";
    "(define native-typed-bad { number --> number } X -> X) (define native-typed-bad { number --> number } X -> X)";
    "(package typed [] (define typed-id { number --> number } X -> X))";
    "(declare native-typed-bad [number --> number])";
    "(datatype native-typed-bad X : native-typed-bad;)";
  ]);
  let prior = N.function1 Fun.id in
  ignore (N.install "native-typed-existing" 1 prior);
  metadata_unchanged (fun () -> ignore (B.translate_module
    "(define native-typed-existing { number --> number } X -> (+ X 1))"));
  (match E.get_fn "native-typed-existing" with
   | Some current when current == prior -> ()
   | _ -> failwith "staging replaced existing host binding");
  let macros = Option.get (E.get_global "*macros*") in
  Fun.protect ~finally:(fun () -> E.set_global "*macros*" macros) (fun () ->
    E.set_global "*macros*" (Cons (Sym "changed", macros));
    rejected "(define native-typed-custom { number --> number } X -> X)");
  let signatures = Option.get (E.get_global "shen.*sigf*") in
  Fun.protect ~finally:(fun () -> E.set_global "shen.*sigf*" signatures) (fun () ->
    E.set_global "shen.*sigf*" (Cons (Cons (Sym "native-typed-lambda",
      N.function1 (fun _ -> failwith "foreign signature was invoked")), signatures));
    let before = Option.get (E.get_global "shen.*sigf*") in
    (match B.load artifact with
    | _ -> failwith "native load overwrote a foreign declaration"
    | exception User_error _ -> ());
    if Option.get (E.get_global "shen.*sigf*") != before then failwith "failed load partially changed type table";
    if E.get_fn "native-typed-add" <> None then failwith "failed type registration installed functions");
  let old_demodulation = Option.get (E.get_global "shen.*demodulation-function*") in
  E.set_eval_kl_from_value (fun _ -> failwith "typed native load used eval-kl");
  Fun.protect ~finally:(fun () -> E.set_global "shen.*demodulation-function*" old_demodulation)
    (fun () ->
      E.set_global "shen.*demodulation-function*" (N.function1 (fun value ->
        E.set_global "native-typed-load-hook-ran" true_value; value));
      ignore (B.load artifact));
  if E.get_global "native-typed-load-hook-ran" <> None then failwith "native type load invoked host demodulation";
  List.iter (fun name -> match E.get_fn name with
    | Some (Native _) -> () | _ -> failwith (name ^ " is not native"))
    ["native-typed-add"; "native-typed-call"; "native-typed-length"; "native-typed-even"];
  verify ();
  ignore (B.load artifact);
  expect (N.call "native-typed-call" [Int 40]) (Int 42);
  (* Signature predicates and user bodies are both native; loading and calls
     must not execute eval-kl or ambient declaration hooks. *)
  E.set_eval_kl_from_value (fun _ -> failwith "user call used eval-kl");
  expect (N.call "native-typed-call" [Int 40]) (Int 42);
  expect (N.call "native-typed-zero" []) (Int 42);
  Printf.printf "NATIVE_TYPED_STAGING pass plugin=%s\n%!" artifact.plugin_path
