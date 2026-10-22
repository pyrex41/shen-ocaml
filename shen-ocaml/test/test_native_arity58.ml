open Shen.Runtime.Value
module N = Shen.Runtime.Native
module E = Shen.Runtime.Env

let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": got " ^ to_string actual)

let args n = List.init n (fun i -> Int (i + 1))
let list values = List.fold_right (fun a b -> Cons (a, b)) values Nil

let specialized n result = match n with
  | 5 -> N.function5 (fun a b c d e -> result [a; b; c; d; e])
  | 6 -> N.function6 (fun a b c d e f -> result [a; b; c; d; e; f])
  | 7 -> N.function7 (fun a b c d e f g -> result [a; b; c; d; e; f; g])
  | 8 -> N.function8 (fun a b c d e f g h -> result [a; b; c; d; e; f; g; h])
  | _ -> assert false

let specialized_first = function
  | 5 -> N.function5 (fun a _ _ _ _ -> a)
  | 6 -> N.function6 (fun a _ _ _ _ _ -> a)
  | 7 -> N.function7 (fun a _ _ _ _ _ _ -> a)
  | 8 -> N.function8 (fun a _ _ _ _ _ _ _ -> a)
  | _ -> assert false

let apply_specialized fn = function
  | [a; b; c; d; e] -> N.apply5 fn a b c d e
  | [a; b; c; d; e; f] -> N.apply6 fn a b c d e f
  | [a; b; c; d; e; f; g] -> N.apply7 fn a b c d e f g
  | [a; b; c; d; e; f; g; h] -> N.apply8 fn a b c d e f g h
  | _ -> assert false

let call_specialized cell = function
  | [a; b; c; d; e] -> N.call5 cell a b c d e
  | [a; b; c; d; e; f] -> N.call6 cell a b c d e f
  | [a; b; c; d; e; f; g] -> N.call7 cell a b c d e f g
  | [a; b; c; d; e; f; g; h] -> N.call8 cell a b c d e f g h
  | _ -> assert false

let check_abi n =
  let values = args n in
  let fn = specialized n list in
  expect "specialized apply" (list values) (apply_specialized fn values);
  assert (N.apply fn [] == fn);
  for split = 0 to n do
    let first = List.filteri (fun i _ -> i < split) values in
    let rest = List.filteri (fun i _ -> i >= split) values in
    let result = N.apply fn first in
    expect "every partial split" (list values) (if rest = [] then result else N.apply result rest)
  done;
  let factory = specialized n (fun values -> N.function1 (fun last -> list (values @ [last]))) in
  expect "overapplication" (list (values @ [Int 9])) (N.apply factory (values @ [Int 9]));
  let cell = E.function_cell "arity58.abi" in
  E.set_fn "arity58.abi" fn;
  expect "specialized cell" (list values) (call_specialized cell values);
  E.set_fn "arity58.abi" (Closure list);
  expect "legacy cell replacement" (list values) (call_specialized cell values);
  E.set_fn "arity58.abi" (N.function_ n list);
  expect "generic cell replacement" (list values) (call_specialized cell values);
  let first = specialized_first n in
  E.set_fn "arity58.abi" first;
  let before = Gc.allocated_bytes () in
  for _ = 1 to 100000 do
    ignore (Sys.opaque_identity (apply_specialized first values));
    ignore (Sys.opaque_identity (call_specialized cell values))
  done;
  assert (Gc.allocated_bytes () -. before < 1024.)

let check_mode label run sealed =
  ignore (run ());
  for n = 5 to 8 do
    let values = args n in
    expect (label ^ " specialized definition") (list values)
      (N.call ("arity58.f" ^ string_of_int n) values);
    expect (label ^ " deep tail call") (Int 200000)
      (N.call ("arity58.tail" ^ string_of_int n)
        (Int 200000 :: Int 0 :: List.init (n - 2) (fun _ -> Nil)))
  done;
  E.set_global "arity58.order" (Int 0);
  expect "ordered arguments" (list (args 8)) (N.call "arity58.ordered" []);
  expect "argument effects" (Int 12345678) (N.value (Sym "arity58.order"));
  List.iter (fun (a, b) ->
    assert (N.call "arity58.and" [of_bool a; of_bool b] == of_bool (a && b));
    assert (N.call "arity58.or" [of_bool a; of_bool b] == of_bool (a || b)))
    [false, false; false, true; true, false; true, true];
  expect "and short circuit" false_value (N.call "arity58.and" [false_value; Int 1]);
  expect "or short circuit" true_value (N.call "arity58.or" [true_value; Int 1]);
  List.iter (fun (name, values) ->
    match N.call name values with
    | _ -> failwith "nonboolean operand accepted"
    | exception User_error _ -> ())
    ["arity58.and", [true_value; Int 1]; "arity58.or", [false_value; Int 1]];
  E.set_fn "arity58.f8" (Closure (fun _ -> Int 99));
  expect "caller redefinition" (if sealed then list (args 8) else Int 99)
    (N.call "arity58.caller" (args 8));
  E.set_fn "=" (N.function2 (fun _ _ -> false_value));
  expect "predicate redefinition" (of_bool sealed) (N.call "arity58.pred" [Int 1; Int 1]);
  E.set_fn "=" Shen.Runtime.Primitives.pr_equal

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  for n = 5 to 8 do check_abi n done;
  let forms = Shen.Kl.Parser.parse_file "fixtures/native_arity58.kl" in
  check_mode "dynamic" (Shen.Interp.Compiled.compile forms) false;
  check_mode "compatible" Native_arity58_compatible.run false;
  check_mode "sealed" Native_arity58_sealed.run true;
  for i = 0 to 100 do
    let a = Int i in
    assert (N.eq a a == true_value);
    assert (N.eq a (Int (i + 1)) == false_value);
    List.iter (fun name -> assert (N.call name [a; a] == of_bool (name = "<=" || name = ">=")))
      ["<"; ">"; "<="; ">="]
  done;
  List.iter (fun compare ->
    List.iter (fun (a, b, result) -> assert (compare a b == of_bool result))
      [Int 1, Float 2., true; Float 1., Int 2, true;
       Float nan, Int 2, false; Int 2, Float nan, false];
    match compare Nil Nil with
    | _ -> failwith "non-numeric comparison accepted"
    | exception User_error _ -> ()) [N.lt; N.lte];
  let ints = Array.init 2 (fun i -> Int i) in
  let less = E.function_cell "<" in
  let before = Gc.allocated_bytes () in
  for i = 1 to 100000 do
    ignore (Sys.opaque_identity (of_bool (i land 1 = 0)));
    ignore (Sys.opaque_identity (N.eq ints.(i land 1) ints.(0)));
    ignore (Sys.opaque_identity (N.call2 less ints.(i land 1) ints.(0)))
  done;
  let allocated = Gc.allocated_bytes () -. before in
  assert (allocated < 1024.);
  Printf.printf "ARITY58_RESULT modes=3 arities=5-8 tail_depth=200000 bool_alloc_bytes=%.0f\n" allocated
