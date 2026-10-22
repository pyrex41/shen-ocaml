open Shen.Runtime.Value
module P = Shen_cli.Native_promote
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env

let expect actual expected =
  if not (equal actual expected) then
    failwith (Printf.sprintf "expected %s, got %s" (to_string expected) (to_string actual))

let rejected action =
  match action () with
  | _ -> failwith "unexpectedly accepted native promotion"
  | exception P.Promote_error _ -> ()

let binding name = Option.get (E.get_fn name)
let unchanged name original =
  if binding name != original then failwith ("unexpected binding change: " ^ name)

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  let state = P.create () in
  (* Chain the actual callback, not eval_kl_from_value_hook (which would recurse).
     Observe only after a successful ordinary installation. *)
  let ordinary = !(E.eval_kl_from_value_ref) in
  E.set_eval_kl_from_value (P.evaluate state ordinary);
  let output_dir = Sys.argv.(1) in
  let config : P.config = { ocamlopt = "ocamlopt"; include_dirs = [
    "_build/default/src/.shen.objs/byte";
    "_build/default/src/.shen.objs/native"
  ] } in
  let source = Shen_cli.Native_cli.source in
  ignore (source {|
    (define promote-test-length [] -> 0 [_ | Xs] -> (+ 1 (promote-test-length Xs)))
    (define promote-test-dup X -> 1)
    (define promote-test-dup X -> (+ X 2))
    (define promote-test-caller X -> (promote-test-dup X))
    (define promote-test-sum N A -> (if (= N 0) A (promote-test-sum (- N 1) (+ A N))))
    (define promote-test-effect X -> (do (set promote-test-marker X) X))
    (defprolog promote-test-member
      X (mode [X | _] -) <--;
      X (mode [_ | Xs] -) <-- (promote-test-member X Xs);)
    (define promote-test-query X Xs -> (prolog? (promote-test-member (receive X) (receive Xs))))
    (set promote-test-load-effect 19)
  |});
  let names = ["promote-test-length"; "promote-test-dup"; "promote-test-caller";
    "promote-test-sum"; "promote-test-effect"; "promote-test-member"; "promote-test-query"] in
  let ps = List.map (fun name -> N.call "ps" [Sym name]) names in
  let userdefs = N.call "userdefs" [] in
  let properties = Option.get (E.get_global "*property-vector*") in
  let lambda_forms = List.map (fun name ->
    N.call "get" [Sym name; Sym "shen.lambda-form"; properties]) names in
  let originals = List.map (fun name -> name, binding name) names in
  let saved_dynamic = binding "promote-test-caller" in
  let artifact = P.prepare state ~config ~names ~output_dir in
  List.iter (fun (name, original) -> unchanged name original) originals;
  (* Promotion must not re-enter eval-kl, translation, metadata, or source load. *)
  let hooks = List.map (fun name -> name, binding name)
    ["put"; "shen.record-kl"; "shen.shen->kl"; "eval"; "load"] in
  let callback = !(E.eval_kl_from_value_ref) in
  Fun.protect ~finally:(fun () ->
    E.set_eval_kl_from_value callback;
    List.iter (fun (name, fn) -> E.set_fn name fn) hooks)
    (fun () ->
      E.set_eval_kl_from_value (fun _ -> failwith "promotion replayed eval-kl");
      List.iter (fun (name, _) -> E.set_fn name (N.function_ 1 (fun _ ->
        failwith ("promotion called " ^ name)))) hooks;
      if P.publish state artifact <> names then failwith "wrong promoted names");
  List.iter (fun name -> match binding name with
    | Native _ -> ()
    | _ -> failwith (name ^ " did not receive a production native body")) names;
  List.iter2 (fun name before ->
    if N.call "ps" [Sym name] != before then failwith "promotion changed source metadata identity") names ps;
  if N.call "userdefs" [] != userdefs then failwith "promotion changed userdefs identity";
  List.iter2 (fun name before ->
    if N.call "get" [Sym name; Sym "shen.lambda-form"; properties] != before then
      failwith "promotion changed lambda-form metadata identity") names lambda_forms;
  expect (N.call "value" [Sym "promote-test-load-effect"]) (Int 19);
  if E.get_global "promote-test-marker" <> None then failwith "promotion ran a user body";
  expect (N.call "promote-test-effect" [Int 42]) (Int 42);
  expect (N.call "promote-test-length" [Cons (Int 1, Cons (Int 2, Nil))]) (Int 2);
  expect (N.call "promote-test-dup" [Int 40]) (Int 42);
  expect (N.call "promote-test-sum" [Int 100000; Int 0]) (Int 5000050000);
  expect (source "(promote-test-query 2 [1 2 3])") (Bool true);
  expect (source "(promote-test-query 4 [1 2 3])") (Bool false);
  (* Saved dynamic/native callables must retain compatible late binding. *)
  let saved_sum = binding "promote-test-sum" in
  ignore (source "(define promote-test-dup X -> (+ X 3)) (define promote-test-sum N A -> 77)");
  expect (N.call "promote-test-caller" [Int 39]) (Int 42);
  expect (N.apply saved_dynamic [Int 39]) (Int 42);
  expect (N.apply saved_sum [Int 2; Int 0]) (Int 77);
  rejected (fun () -> P.publish state artifact);
  (* One stale member must prevent publication of every member. *)
  ignore (source "(define promote-test-group-a X -> X) (define promote-test-group-b X -> X)");
  let group = P.prepare state ~config ~names:["promote-test-group-a"; "promote-test-group-b"] ~output_dir in
  let a = binding "promote-test-group-a" in
  ignore (source "(define promote-test-group-b X -> 99)");
  let b = binding "promote-test-group-b" in
  rejected (fun () -> P.publish state group);
  unchanged "promote-test-group-a" a;
  unchanged "promote-test-group-b" b;
  rejected (fun () -> P.promote state ~config ~names:["promote-test-unobserved"] ~output_dir);
  rejected (fun () -> P.promote state ~config ~names:["promote-test-group-a"; "promote-test-group-a"] ~output_dir);
  (* Mutable literals may already have escaped from the installed function. *)
  let vector_form = Cons (Sym "defun", Cons (Sym "promote-test-vector",
    Cons (Nil, Cons (Vec [|Int 1|], Nil)))) in
  ignore (E.eval_kl_from_value_hook vector_form);
  let vector_fn = binding "promote-test-vector" in
  rejected (fun () -> P.promote state ~config ~names:["promote-test-vector"] ~output_dir);
  unchanged "promote-test-vector" vector_fn;
  (* Metadata reentrancy must never pair the outer KL with a nested callable.
     A nested eval-kl has its own trustworthy receipt and remains promotable. *)
  let put = binding "put" in
  let kl_definition name number =
    Cons (Sym "defun", Cons (Sym name, Cons (Cons (Sym "X", Nil),
      Cons (Int number, Nil)))) in
  let armed = ref true in
  Fun.protect ~finally:(fun () -> E.set_fn "put" put) (fun () ->
    E.set_fn "put" (N.function4 (fun key attr value dict ->
      if equal key (Sym "promote-test-reentrant") && !armed then (
        armed := false;
        ignore (E.eval_kl_from_value_hook (kl_definition "promote-test-reentrant" 99)));
      N.apply put [key; attr; value; dict]));
    ignore (E.eval_kl_from_value_hook (kl_definition "promote-test-reentrant" 11)));
  expect (N.call "promote-test-reentrant" [Int 0]) (Int 99);
  P.promote state ~config ~names:["promote-test-reentrant"] ~output_dir;
  expect (N.call "promote-test-reentrant" [Int 0]) (Int 99);
  (* A replacement without a nested eval receipt is rejected, not compiled from
     the outer source even though its current callable identity is available. *)
  armed := true;
  Fun.protect ~finally:(fun () -> E.set_fn "put" put) (fun () ->
    E.set_fn "put" (N.function4 (fun key attr value dict ->
      if equal key (Sym "promote-test-unobserved-replacement") && !armed then (
        armed := false;
        E.set_fn "promote-test-unobserved-replacement" (N.function1 (fun _ -> Int 123)));
      N.apply put [key; attr; value; dict]));
    ignore (E.eval_kl_from_value_hook (kl_definition "promote-test-unobserved-replacement" 11)));
  rejected (fun () -> P.promote state ~config
    ~names:["promote-test-unobserved-replacement"] ~output_dir);
  expect (N.call "promote-test-unobserved-replacement" [Int 0]) (Int 123);
  (* External compiler failures are explicit, and cannot replace any binding. *)
  rejected (fun () -> P.promote state ~config:{config with ocamlopt = "/usr/bin/false"}
    ~names:["promote-test-group-a"] ~output_dir);
  unchanged "promote-test-group-a" a;
  let observed, promoted = P.counts state in
  if observed < 12 || promoted <> List.length names + 1 then failwith "wrong promotion counters";
  (* No allocating lookups may separate the final identity check and swapping.
     A GC finalizer can redefine a function even in a single-threaded host. *)
  let a_cell = E.function_cell "promote-test-group-a" in
  let replacement = N.function1 (fun _ -> Int 123) in
  let replacements = [a_cell, a, Some replacement] in
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  for _ = 1 to 100_000 do P.validate_replacements replacements done;
  let allocated = Gc.allocated_bytes () -. allocated in
  if allocated > 1024. then failwith "final promotion validation allocates";
  ignore (source "(define promote-test-gc-a X -> 1) (define promote-test-gc-b X -> 2)");
  let gc_a = binding "promote-test-gc-a" and gc_b = binding "promote-test-gc-b" in
  let gc_artifact = P.prepare state ~config
    ~names:["promote-test-gc-a"; "promote-test-gc-b"] ~output_dir in
  let arm_finalizer fired =
    let token = ref 0 in
    Gc.finalise (fun _ -> fired := true; E.set_fn "promote-test-gc-a" replacement) token
  in
  for _ = 1 to 100 do
    E.set_fn "promote-test-gc-a" gc_a;
    E.set_fn "promote-test-gc-b" gc_b;
    let fired = ref false in
    arm_finalizer fired;
    (try ignore (P.publish state gc_artifact) with P.Promote_error _ -> ());
    Gc.full_major (); Gc.full_major ();
    if not !fired then failwith "promotion GC regression finalizer did not run";
    unchanged "promote-test-gc-a" replacement
  done;
  print_endline "NATIVE_PROMOTE_RESULT expanded_prolog=pass native=pass metadata=pass stale_group=pass old_callable=pass reentrant_metadata=pass vector_rejected=pass compile_failure=pass"
