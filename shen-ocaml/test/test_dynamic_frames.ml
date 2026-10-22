open Shen.Runtime.Value
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env
module C = Shen.Interp.Compiled

let eval source = (C.compile (Shen.Kl.Parser.parse_string source)) ()
let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": got " ^ to_string actual)
let check label expected source = expect label expected (eval source)
let raises label message f =
  match f () with
  | _ -> failwith (label ^ ": expected User_error")
  | exception User_error actual when actual = message -> ()

let allocated f =
  for _ = 1 to 100 do ignore (f ()) done;
  Gc.full_major ();
  let before = Gc.allocated_bytes () in
  for _ = 1 to 10000 do ignore (f ()) done;
  (Gc.allocated_bytes () -. before) /. 10000.

let allocation () =
  let zero = eval "(freeze 42)" in
  let ignored = eval "(lambda X 42)" in
  let single = eval "(let X 42 (freeze X))" in
  let multi = eval "(let X 20 (let Y 22 (freeze (if true X Y))))" in
  let dead = eval "(freeze (let X 20 (trap-error 42 (lambda E 0))))" in
  List.iter (fun (label, f) ->
    let bytes = allocated f in
    if bytes > 0.1 then failwith (Printf.sprintf "%s allocated %g bytes/call" label bytes);
    Printf.printf "DYNAMIC_FRAME_ALLOCATION %s=%g\n" label bytes)
    ["zero", (fun () -> N.apply0 zero);
     "ignored_parameter", (fun () -> N.apply1 ignored Nil);
     "single_readonly", (fun () -> N.apply0 single);
     "multi_readonly", (fun () -> N.apply0 multi);
     "unused_bindings", (fun () -> N.apply0 dead)];
  (* Both sides of cons need their let result, but neither let slot survives
     its operand. The two live parameters plus one temporary suffice. *)
  let siblings = eval "(lambda (X Y) (cons (let A X A) (let B Y B)))" in
  let bytes = allocated (fun () -> N.apply2 siblings Nil Nil) in
  let word = float_of_int (Sys.word_size / 8) in
  if bytes > 7. *. word +. 0.1 then
    failwith (Printf.sprintf "sibling slots not reclaimed: %g bytes" bytes);
  Printf.printf "DYNAMIC_FRAME_ALLOCATION sibling_frame_and_cons=%g\n" bytes;
  let factory = eval "(lambda X (lambda Y (cons X Y)))" in
  let bytes = allocated (fun () -> N.apply1 factory Nil) in
  if bytes > 30. *. word +. 0.1 then failwith "single capture allocation regression";
  Printf.printf "DYNAMIC_FRAME_ALLOCATION single_capture_factory=%g\n" bytes;
  let factory2 = eval "(lambda (X Y) (lambda Z (cons X (cons Y Z))))" in
  let bytes = allocated (fun () -> N.apply2 factory2 Nil Nil) in
  if bytes > 32. *. word +. 0.1 then failwith "two capture allocation regression";
  Printf.printf "DYNAMIC_FRAME_ALLOCATION two_capture_factory=%g\n" bytes

let observer () =
  let previous = !(C.definition_observer) in
  let observed = ref [] in
  let old = N.function1 (fun _ -> Int 10) in
  E.set_fn "frames.observed" old;
  Fun.protect ~finally:(fun () -> C.definition_observer := previous) (fun () ->
    C.definition_observer := (fun name callable ->
      if name = "frames.observed" then begin
        expect "observer runs before install" (Int 10) (N.call name [Nil]);
        (* Reentrant compilation must not replace the outer definition's value. *)
        ignore (eval "(defun frames.nested-observer (X) 11)");
        observed := callable :: !observed
      end);
    ignore (eval "(defun frames.observed (X) 42)");
    match !observed with
    | [callable] ->
        expect "observer exact callable" (Int 42) (N.apply1 callable Nil);
        (match E.get_fn "frames.observed" with
         | Some installed when installed == callable -> ()
         | _ -> failwith "observer did not receive installed callable")
    | _ -> failwith "observer was not called exactly once");
  let saved_put = E.get_fn "put" in
  let saved_properties = E.get_global "*property-vector*" in
  Fun.protect ~finally:(fun () ->
    C.definition_observer := previous;
    (E.function_cell "put").binding <- saved_put;
    match saved_properties with
    | Some value -> E.set_global "*property-vector*" value
    | None -> Hashtbl.remove E.global_table "*property-vector*") (fun () ->
      let observed = ref Nil in
      C.definition_observer := (fun name callable ->
        if name = "frames.metadata" then observed := callable);
      E.set_global "*property-vector*" Nil;
      E.set_fn "put" (N.function4 (fun name _ value _ ->
        if equal name (Sym "frames.metadata") then begin
          expect "observer precedes metadata" (Int 42) (N.apply1 !observed Nil);
          E.set_fn "frames.metadata" (N.function1 (fun _ -> Int 99))
        end;
        value));
      ignore (eval "(defun frames.metadata (X) 42)");
      expect "metadata redefinition" (Int 99) (N.call "frames.metadata" [Nil]);
      expect "observed callable survives redefinition" (Int 42) (N.apply1 !observed Nil))

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  check "unused binding effects" (Int 42)
    "(let X (set frames.effect 42) (value frames.effect))";
  check "shadowed binding" (Int 42)
    "(let X 10 (let F (freeze X) (let X 32 (+ (thaw F) X))))";
  check "branch slots" (Cons (Int 20, Int 22))
    "(cons (if true (let A 20 A) (let B 90 B)) (let C 22 C))";
  check "cond slots" (Int 42)
    "(cond ((let A false A) 90) ((let B true B) (let C 42 C)))";
  check "sibling escaped capture" (Cons (Int 20, Int 22))
    "(let F (let X 20 (freeze X)) (let G (let Y 22 (freeze Y)) (cons (thaw F) (thaw G))))";
  let factory = eval "(lambda X (freeze (let Y X (lambda Z (+ Y Z)))))" in
  let first = N.apply1 factory (Int 10) in
  let second = N.apply1 factory (Int 30) in
  let escaped = N.apply0 first in
  ignore (N.apply0 second);
  expect "escaped after second call" (Int 42) (N.apply1 escaped (Int 32));
  expect "repeat frozen invocation" (Int 42) (N.apply1 (N.apply0 first) (Int 32));
  let captures = eval "(let A 10 (let B 20 (let C 30 (lambda X (+ (+ A B) (+ C X))))))" in
  expect "many captures" (Int 65) (N.apply1 captures (Int 5));
  expect "many captures repeated" (Int 66) (N.apply1 captures (Int 6));
  let two = eval "(let A 10 (let B 20 (lambda X (+ A (+ B X)))))" in
  expect "two captures" (Int 42) (N.apply1 two (Int 12));
  expect "two captures repeated" (Int 43) (N.apply1 two (Int 13));
  (* Native callbacks reenter the very same compiled function before its outer
     invocation reads X again. A recycled mutable frame corrupts this result. *)
  let reentrant = ref Nil in
  E.set_fn "frames.callback" (N.function1 (function
    | Int 0 -> Int 0
    | _ -> N.apply1 !reentrant (Int 0)));
  reentrant := eval "(lambda X (do (frames.callback X) X))";
  expect "reentrant parameter" (Int 42) (N.apply1 !reentrant (Int 42));
  let frozen = ref Nil and entered = ref false in
  E.set_fn "frames.reenter" (N.function0 (fun () ->
    if !entered then Int 7 else begin
      entered := true;
      ignore (N.apply0 !frozen);
      entered := false;
      Int 42
    end));
  frozen := eval "(freeze (let X (frames.reenter) (do (if (= X 42) (frames.reenter) 0) X)))";
  expect "reentrant let" (Int 42) (N.apply0 !frozen);
  check "unused error binding" (Int 42)
    "(trap-error (simple-error \"ignored\") (lambda E 42))";
  check "escaped handler error" (Str "first")
    "(let F (trap-error (simple-error \"first\") (lambda E (freeze (error-to-string E))))
       (do (trap-error (simple-error \"second\") (lambda E 0)) (thaw F)))";
  raises "handler escapes trap" "handler" (fun () ->
    eval "(trap-error (simple-error \"body\") (lambda E (simple-error \"handler\")))");
  check "handler evaluation first" (Int 42)
    "(do (set frames.order 0)
       (trap-error (do (set frames.order (+ (value frames.order) 2)) (simple-error \"body\"))
         (do (set frames.order 40) (lambda E (value frames.order)))))";
  check "curried intermediate effects" (Int 42)
    "(do (set frames.order 0)
       ((lambda X (do (set frames.order X) (lambda Y (+ (value frames.order) Y))))
        20 (do (set frames.order (+ (value frames.order) 1)) 21)))";
  check "left to right arguments" (Int 42)
    "(+ (do (set frames.order 20) 20) (do (set frames.order (+ (value frames.order) 2)) (value frames.order)))";
  check "sparse parameters" (Int 42)
    "((lambda (A B C D E F G H I) (+ B I)) 0 20 0 0 0 0 0 0 22)";
  for arity = 1 to 9 do
    let params = List.init arity (fun i -> "P" ^ string_of_int i) in
    let args = List.init arity (fun i -> string_of_int (i + 1)) in
    let source = Printf.sprintf "((lambda (%s) %s) %s)"
      (String.concat " " params) (List.nth params (arity - 1)) (String.concat " " args) in
    check ("sparse native arity " ^ string_of_int arity) (Int arity) source
  done;
  ignore (eval "(defun frames.helper (X) X) (defun frames.caller (X) (frames.helper X))
    (defun frames.tail (N) (if (= N 0) 42 (frames.tail (- N 1))))");
  expect "million tail calls" (Int 42) (N.call "frames.tail" [Int 1000000]);
  ignore (eval "(defun frames.helper (X) (+ X 1))");
  expect "redefinition" (Int 42) (N.call "frames.caller" [Int 41]);
  observer ();
  allocation ();
  print_endline "DYNAMIC_FRAMES_RESULT pass"
