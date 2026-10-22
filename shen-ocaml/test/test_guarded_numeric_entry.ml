open Shen.Runtime.Value
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env
module G = Shen.Runtime.Guarded

let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": expected " ^ to_string expected ^ ", got " ^ to_string actual)

let bound name = match E.get_fn name with Some fn -> fn | None -> failwith name
let sum n a = N.call2 (E.function_cell "guarded.sum") n a
let all n a = N.call2 (E.function_cell "guarded.all") n a
let with_binding name replacement test =
  let cell = E.function_cell name in
  let previous = cell.binding in
  cell.binding <- replacement;
  Fun.protect ~finally:(fun () -> cell.binding <- previous) test

let allocation label call =
  let before = Gc.allocated_bytes () in
  for _ = 1 to 10 do expect label (Int 200010000) (call ()) done;
  let allocated = Gc.allocated_bytes () -. before in
  if allocated > 4096. then failwith (label ^ ": worker allocated inside its loop");
  allocated

let metadata callback test =
  let previous = E.get_global "*property-vector*" in
  E.set_global "*property-vector*" (Vec [||]);
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> E.set_global "*property-vector*" value
    | None -> Hashtbl.remove E.global_table "*property-vector*") (fun () ->
    with_binding "put" (Some (N.function4 callback)) test)

let contains text fragment =
  let rec loop i =
    i + String.length fragment <= String.length text &&
    (String.sub text i (String.length fragment) = fragment || loop (i + 1))
  in loop 0

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  ignore (Guarded_numeric_entry.run ());
  expect "integer" (Int 6) (sum (Int 3) (Int 0));
  expect "float counter" (Float 6.) (sum (Float 3.) (Int 0));
  expect "float accumulator" (Float 6.5) (sum (Int 3) (Float 0.5));
  expect "max_int wrap" (Int min_int) (sum (Int 1) (Int max_int));
  expect "min_int wrap" (Int (min_int + 3)) (sum (Int 2) (Int min_int));
  expect "multiply wrap" (Int 0) (all (Int 1) (Int max_int));
  expect "negate min_int" (Int min_int) (all (Int 0) (Int min_int));
  expect "all comparisons" (Int 6) (all (Int 2) (Int 0));
  expect "float comparison fallback" (Float 6.) (all (Float 2.) (Float 0.));
  ignore (N.call2 (E.function_cell "guarded.effect") (Int 3) (Int 0));
  expect "effects preserved" (Int 1) (N.value (Sym "guarded.observed"));
  let n = Int 20000 and a = Int 0 in
  let allocated = allocation "compatible loop" (fun () -> sum n a) in

  (* Every primitive used by either proof must guard its actual canonical
     closure, including a redefinition to a different Function2 closure. *)
  List.iter (fun (name, implementation, call, expected) ->
    List.iter (fun shape ->
      let calls = ref 0 in
      let invoke a b = incr calls; implementation a b in
      let replacement = match shape with
        | 0 -> N.function2 invoke
        | 1 -> N.function_ 2 (function [a; b] -> invoke a b | _ -> assert false)
        | _ -> Closure (function [a; b] -> invoke a b | _ -> assert false) in
      with_binding name (Some replacement) (fun () ->
        expect ("redefined " ^ name) expected (call ());
        if !calls = 0 then failwith ("guard missed primitive " ^ name))) [0; 1; 2]) [
    "+", N.add, (fun () -> sum (Int 3) (Int 0)), Int 6;
    "-", N.sub, (fun () -> sum (Int 3) (Int 0)), Int 6;
    "=", N.eq, (fun () -> sum (Int 3) (Int 0)), Int 6;
    "*", N.mul, (fun () -> all (Int 2) (Int 0)), Int 6;
    "<", N.lt, (fun () -> all (Int 2) (Int 0)), Int 6;
    ">", N.gt, (fun () -> all (Int 2) (Int 0)), Int 6;
    "<=", N.lte, (fun () -> all (Int 2) (Int 0)), Int 6;
    ">=", N.gte, (fun () -> all (Int 2) (Int 0)), Int 6;
  ];
  List.iter (fun replacement -> with_binding "+" replacement (fun () ->
    match sum (Int 1) (Int 0) with
    | exception User_error _ -> ()
    | _ -> failwith "missing/non-callable primitive did not fail closed")) [None; Some (Int 0)];
  let saved = bound "guarded.sum" in
  let partial = N.apply1 saved (Int 3) in
  let symbolic = !(E.fn_reference_factory) "guarded.sum" 2 in
  let symbolic_partial = N.apply1 symbolic (Int 3) in
  with_binding "guarded.sum" (Some (N.function2 (fun _ _ -> Int 99))) (fun () ->
    expect "old reference self lookup" (Int 99) (N.apply2 saved (Int 3) (Int 0));
    expect "old reference base case" (Int 7) (N.apply2 saved (Int 0) (Int 7));
    expect "old partial self lookup" (Int 99) (N.apply1 partial (Int 0));
    expect "symbolic partial" (Int 99) (N.apply1 symbolic_partial (Int 0)));
  with_binding "guarded.sum" None (fun () ->
    match N.apply2 saved (Int 1) (Int 0) with
    | exception User_error _ -> ()
    | _ -> failwith "old callable ignored missing self binding");
  ignore (Guarded_numeric_entry.run ());
  expect "reinstall old reference" (Int 6) (N.apply2 saved (Int 3) (Int 0));
  ignore (allocation "reinstalled old reference" (fun () -> N.apply2 saved n a));

  (* A noncanonical primitive already present at installation is not evidence
     that it implements arithmetic. *)
  with_binding "+" (Some (N.function2 (fun _ _ -> Int 77))) (fun () ->
    ignore (Guarded_numeric_entry.run ());
    expect "noncanonical at install" (Int 77) (sum (Int 3) (Int 0)));
  with_binding "+" (E.get_fn "+") (fun () ->
    ignore (Guarded_numeric_primitive.run ());
    expect "compiled primitive definition before self" (Int 77)
      (N.value (Sym "guarded.shadow-first"));
    expect "compiled primitive definition after self" (Int 88)
      (N.call2 (E.function_cell "guarded.shadow") (Int 3) (Int 0)));

  let metadata_entries = ref 0 in
  metadata (fun name attr _ _ ->
    (match name, attr with
    | Sym "guarded.sum", Sym "arity" ->
        incr metadata_entries;
        ignore (allocation "metadata entry" (fun () -> sum n a))
    | _ -> ()); Nil) (fun () -> ignore (Guarded_numeric_entry.run ()));
  if !metadata_entries <> 1 then failwith "metadata entry test did not run";
  let metadata_old = ref None in
  metadata (fun name attr _ _ ->
    (match name, attr with
    | Sym "guarded.sum", Sym "arity" ->
        metadata_old := Some (bound "guarded.sum");
        E.set_fn "guarded.sum" (N.function2 (fun _ _ -> Int 88));
        expect "metadata self replacement" (Int 88)
          (N.apply2 (Option.get !metadata_old) (Int 3) (Int 0))
    | _ -> ()); Nil) (fun () -> ignore (Guarded_numeric_entry.run ()));
  expect "metadata replacement retained" (Int 88) (sum (Int 3) (Int 0));

  let duplicates = ref [] in
  metadata (fun name attr _ _ ->
    (match name, attr with
    | Sym "guarded.duplicate", Sym "arity" ->
        duplicates := bound "guarded.duplicate" :: !duplicates
    | _ -> ()); Nil) (fun () -> ignore (Guarded_numeric_duplicate.run ()));
  (match !duplicates with
  | [second; first] ->
      expect "last duplicate installed" (Int 300) (N.apply2 second (Int 3) (Int 0));
      expect "old duplicate self lookup" (Int 102) (N.apply2 first (Int 2) (Int 0))
  | _ -> failwith "duplicate metadata not captured");
  ignore (Guarded_numeric_duplicate.run ());
  (match List.rev !duplicates with
  | first :: _ -> expect "repeated duplicate run" (Int 102) (N.apply2 first (Int 2) (Int 0))
  | _ -> assert false);
  let canonical = N.function2 N.add in
  with_binding "+" (Some canonical) (fun () ->
    if not (G.primitive (E.function_cell "+") N.add) then failwith "canonical primitive rejected");
  List.iter (fun source ->
    let generated = Shen.Codegen.Native_gen.compile
      (Shen.Kl.Parser.parse_string source) in
    if contains generated "numeric_f" then failwith "unsupported proof did not fail closed") [
    "(defun loop (N A) (if (= N 0) A (do (set observed N) (loop (- N 1) (+ A N)))))";
    "(defun loop (N A) (if (= N 0) A (loop (- N 1) (/ A 2))))";
    "(defun loop (N A) (if (= N 0) A (loop (- N 1) (+ A 0.5))))";
    "(defun loop (N A) (if (= N 0) A (loop (- N 1) (unknown A))))";
    "(defun loop (N A) (if (= N 0) true (loop (- N 1) A)))";
    "(defun < (N A) (if (= N 0) A (< (- N 1) A)))";
  ];
  Printf.printf "GUARDED_NUMERIC_RESULT primitives=8 shapes=3 redefinitions=pass metadata=pass duplicates=pass loop_alloc_bytes=%.0f\n" allocated
