open Shen.Runtime.Value
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env
module P = Shen.Runtime.Primitives

let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": got " ^ to_string actual)

let raises label message f =
  match f () with
  | _ -> failwith (label ^ ": expected User_error")
  | exception User_error actual when actual = message -> ()

let expr source = List.hd (Shen.Kl.Parser.parse_string source)

let check_backend label install eval =
  ignore (install ());
  expect (label ^ " zero") (Int 42) (N.call "thunk-lean.zero" []);
  expect (label ^ " excess") (Int 42)
    (N.apply1 (N.call "thunk-lean.factory" [Int 20]) (Int 22));
  expect (label ^ " trap") (Str "trapped") (N.call "thunk-lean.trap" []);
  raises (label ^ " error") "thunk-lean failure" (fun () -> N.call "thunk-lean.fail" []);
  let first = N.call "thunk-lean.capture" [Int 10] in
  let second = N.call "thunk-lean.capture" [Int 30] in
  let first_fn = N.apply0 first in
  ignore (N.apply0 second);
  expect (label ^ " escaping captures") (Int 42) (N.apply1 first_fn (Int 32));
  expect (label ^ " repeated thaw") (Int 42) (N.apply1 (N.apply0 first) (Int 32));
  expect (label ^ " nested freeze") (Int 41)
    (N.apply0 (N.apply0 (N.call "thunk-lean.nested" [Int 20])));
  expect (label ^ " legacy call") (Int 42)
    (Shen.Interp.Eval.eval_kl (expr "(thunk-lean.zero)"));
  expect (label ^ " eval freeze") (Int 42) (eval (expr "(thaw (freeze 42))"));
  expect (label ^ " thunk handler") (Str "trapped")
    (eval (expr "(trap-error (simple-error \"trapped\") (freeze (lambda E (error-to-string E))))"))

let allocation () =
  let slots = Array.make 10000 Nil in
  let callback () = Int 42 in
  let measure make =
    Gc.full_major ();
    let before = Gc.allocated_bytes () in
    for i = 0 to Array.length slots - 1 do slots.(i) <- make callback done;
    (Gc.allocated_bytes () -. before) /. float_of_int (Array.length slots)
  in
  let lean = measure N.function0 in
  let old = measure (fun f ->
    Native { arity = 0; code = Function0 f;
      invoke = (function [] -> f () | args -> N.apply (f ()) args) }) in
  if lean > float_of_int (3 * (Sys.word_size / 8)) || old < lean *. 3. then
    failwith (Printf.sprintf "thunk allocation regression: lean=%g old=%g" lean old);
  let thunk = N.function0 callback in
  let before = Gc.allocated_bytes () in
  for _ = 1 to 100000 do ignore (N.apply0 thunk) done;
  let calls = Gc.allocated_bytes () -. before in
  if calls > 256. then failwith "apply0 allocated";
  Printf.printf "THUNK_ALLOCATION lean_bytes=%g old_bytes=%g apply0_bytes=%g\n" lean old calls

let () =
  P.initialise ~verbose:false ();
  let answer = N.function0 (fun () -> Int 42) in
  (match answer with Thunk _ -> () | _ -> failwith "function0 is not lean");
  let generic = N.function_ 0 (fun _ -> N.function1 Fun.id) in
  (match generic with Thunk _ -> () | _ -> failwith "generic zero is not lean");
  expect "generic zero excess" (Int 42) (N.apply1 generic (Int 42));
  expect "display" (Str "<closure>") (Str (to_string answer));
  if not (equal answer answer) || equal answer (N.function0 (fun () -> Int 42)) then
    failwith "thunk identity equality";
  let result = N.function_ 8 (fun values -> List.fold_left N.add (Int 0) values) in
  let factory = N.function0 (fun () -> result) in
  List.iter (fun (n, call) ->
    let result = call factory in
    expect ("apply fallback " ^ string_of_int n) (Int n)
      (if n = 8 then result else N.apply result (List.init (8 - n) (fun _ -> Int 0))))
    [1, (fun f -> N.apply1 f (Int 1));
     2, (fun f -> N.apply2 f (Int 1) (Int 1));
     3, (fun f -> N.apply3 f (Int 1) (Int 1) (Int 1));
     4, (fun f -> N.apply4 f (Int 1) (Int 1) (Int 1) (Int 1));
     5, (fun f -> N.apply5 f (Int 1) (Int 1) (Int 1) (Int 1) (Int 1));
     6, (fun f -> N.apply6 f (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1));
     7, (fun f -> N.apply7 f (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1));
     8, (fun f -> N.apply8 f (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1) (Int 1))];
  let old = Native {arity = 0; code = Function0 (fun () -> Int 42);
    invoke = (fun _ -> Int 42)} in
  expect "old Function0" (Int 42) (N.apply0 old);
  expect "old Closure" (Int 42) (N.apply0 (Closure (fun _ -> Int 42)));
  raises "nonfunction excess" "attempt to apply a non-function"
    (fun () -> N.apply1 answer Nil);
  let factory = N.function0 (fun () -> N.function1 Fun.id) in
  E.set_fn "thunk-lean.primitive" factory;
  expect "primitive apply thunk" (Int 42) (N.apply2 P.pr_apply factory (Int 42));
  expect "primitive apply symbol" (Int 42)
    (N.apply2 P.pr_apply (Sym "thunk-lean.primitive") (Int 42));
  let reference = !(E.fn_reference_factory) "thunk-lean.primitive" 0 in
  E.set_fn "thunk-lean.primitive" answer;
  expect "live zero reference" (Int 42) (N.apply0 reference);
  (match Shen.Interp.Eval.eval_kl_from_value answer with
   | Error _ -> () | _ -> failwith "eval-kl admitted a thunk atom");
  raises "dynamic source rejects thunk" "eval-kl: invalid value in kl expression"
    (fun () -> Shen.Interp.Compiled.eval_value answer);
  let saved_metadata = E.get_global "*property-vector*" in
  let saved_put = E.get_fn "put" in
  let metadata = ref [] in
  E.set_global "*property-vector*" Nil;
  E.set_fn "put" (N.function4 (fun name attr value _ ->
    metadata := (name, attr, value) :: !metadata; value));
  ignore (N.install "thunk-lean.metadata" 0 answer);
  if not (List.exists (fun (name, attr, value) ->
    equal name (Sym "thunk-lean.metadata") && equal attr (Sym "arity") && equal value (Int 0))
    !metadata) then failwith "zero-argument metadata missing";
  (match saved_metadata with Some v -> E.set_global "*property-vector*" v
   | None -> Hashtbl.remove E.global_table "*property-vector*");
  (match saved_put with Some v -> E.set_fn "put" v
   | None -> (E.function_cell "put").binding <- None);
  let forms = Shen.Kl.Parser.parse_file "fixtures/thunk_lean.kl" in
  check_backend "legacy" (fun () -> List.fold_left (fun _ e -> Shen.Interp.Eval.eval_kl e) Nil forms)
    Shen.Interp.Eval.eval_kl;
  expect "legacy million thaw tail" (Int 42) (N.call "thunk-lean.tail" [Int 1000000]);
  check_backend "dynamic" (Shen.Interp.Compiled.compile forms) Shen.Interp.Compiled.eval_kl;
  expect "dynamic million thaw tail" (Int 42) (N.call "thunk-lean.tail" [Int 1000000]);
  expect "dynamic million overapplication tail" (Int 42)
    (N.call "thunk-lean.factory-tail" [Int 1000000]);
  check_backend "compatible" Thunk_lean_compatible.run Shen.Interp.Compiled.eval_kl;
  expect "native million thaw tail" (Int 42) (N.call "thunk-lean.tail" [Int 1000000]);
  expect "native million overapplication tail" (Int 42)
    (N.call "thunk-lean.factory-tail" [Int 1000000]);
  check_backend "sealed" Thunk_lean_sealed.run Shen.Interp.Compiled.eval_kl;
  expect "sealed million thaw tail" (Int 42) (N.call "thunk-lean.tail" [Int 1000000]);
  allocation ();
  print_endline "THUNK_LEAN_RESULT modes=4 tail_depth=1000000 pass"
