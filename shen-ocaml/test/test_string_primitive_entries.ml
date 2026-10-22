open Shen.Runtime.Value
module N = Shen.Runtime.Native
module P = Shen.Runtime.Primitives

let expect label expected actual =
  if not (equal expected actual) then
    failwith (label ^ ": got " ^ to_string actual)

let raises label message f =
  match f () with
  | _ -> failwith (label ^ ": expected User_error " ^ message)
  | exception User_error actual when actual = message -> ()

let expr source = List.hd (Shen.Kl.Parser.parse_string source)

let entries =
  ["str", P.pr_str, [Int 42], Str "42";
   "cn", P.pr_cn, [Str "a"; Str "b"], Str "ab";
   "pos", P.pr_pos, [Str "ab"; Int 1], Str "b";
   "tlstr", P.pr_tlstr, [Str "ab"], Str "b";
   "n->string", P.pr_n_to_string, [Int 65], Str "A";
   "string->n", P.pr_string_to_n, [Str "A"], Int 65]

let semantics () =
  List.iter (fun (name, fn, args, result) ->
    if N.apply0 fn != fn then failwith (name ^ ": zero arguments changed identity");
    expect (name ^ " saturated") result (N.apply fn args);
    let curried = List.fold_left N.apply1 fn args in
    expect (name ^ " curried") result curried;
    raises (name ^ " excess") "attempt to apply a non-function"
      (fun () -> N.apply fn (args @ [Nil]));
    let legacy = Closure (fun args -> N.apply fn args) in
    expect (name ^ " legacy adapter") result (N.apply legacy args);
    List.iter (fun eval ->
      let source = "(" ^ name ^ " " ^ String.concat " " (List.map to_string args) ^ ")" in
      expect (name ^ " evaluator") result (eval (expr source)))
      [Shen.Interp.Eval.eval_kl; Shen.Interp.Compiled.eval_kl]) entries;
  List.iter (fun (_, fn, _, _) -> match fn with
    | Native {code = Function1 _; _} | Native {code = Function2 _; _} -> ()
    | _ -> failwith "missing scalar direct entry") entries;
  expect "str error value" (Str (to_string (Error "x"))) (N.apply1 P.pr_str (Error "x"));
  List.iter (fun value ->
    expect "str display" (Str (to_string value)) (N.apply1 P.pr_str value))
    [Nil; Bool true; Float 1.25; Sym "key"; Str "quoted"; Cons (Int 1, Nil);
     Vec [|Int 1|]; Closure (fun _ -> Nil); P.pr_cn];
  expect "empty cn" (Str "") (N.apply2 P.pr_cn (Str "") (Str ""));
  expect "single tlstr" (Str "") (N.apply1 P.pr_tlstr (Str "x"));
  List.iter (fun n ->
    let byte = Str (String.make 1 (Char.chr n)) in
    expect "byte encoding" byte (N.apply1 P.pr_n_to_string (Int n));
    expect "byte decoding" (Int n) (N.apply1 P.pr_string_to_n byte)) [0; 127; 128; 255];
  let multibyte = Str "\195\169" in
  expect "pos first UTF-8 byte" (Str "\195") (N.apply2 P.pr_pos multibyte (Int 0));
  expect "pos second UTF-8 byte" (Str "\169") (N.apply2 P.pr_pos multibyte (Int 1));
  expect "tlstr byte semantics" (Str "\169") (N.apply1 P.pr_tlstr multibyte);
  List.iter (fun (message, f) -> raises message message f)
    ["cn: two strings expected", (fun () -> N.apply2 P.pr_cn Nil (Str ""));
     "cn: two strings expected", (fun () -> N.apply2 P.pr_cn (Str "") Nil);
     "pos: string and integer expected", (fun () -> N.apply2 P.pr_pos Nil (Int 0));
     "pos: string and integer expected", (fun () -> N.apply2 P.pr_pos (Str "x") (Float 0.));
     "pos: index out of bounds", (fun () -> N.apply2 P.pr_pos (Str "x") (Int (-1)));
     "pos: index out of bounds", (fun () -> N.apply2 P.pr_pos (Str "x") (Int 1));
     "pos: index out of bounds", (fun () -> N.apply2 P.pr_pos (Str "") (Int 0));
     "tlstr: empty string", (fun () -> N.apply1 P.pr_tlstr (Str ""));
     "tlstr: string expected", (fun () -> N.apply1 P.pr_tlstr Nil);
     "n->string: byte 0..255 expected", (fun () -> N.apply1 P.pr_n_to_string (Int (-1)));
     "n->string: byte 0..255 expected", (fun () -> N.apply1 P.pr_n_to_string (Int 256));
     "n->string: integer expected", (fun () -> N.apply1 P.pr_n_to_string (Float 65.));
     "string->n: single-character string expected", (fun () -> N.apply1 P.pr_string_to_n (Str ""));
     "string->n: single-character string expected", (fun () -> N.apply1 P.pr_string_to_n multibyte);
     "string->n: string expected", (fun () -> N.apply1 P.pr_string_to_n Nil);
     "message", (fun () -> N.apply1 P.pr_simple_error (Str "message"));
     "symbol-message", (fun () -> N.apply1 P.pr_simple_error (Sym "symbol-message"));
     "simple-error: string expected", (fun () -> N.apply1 P.pr_simple_error Nil);
     "message", (fun () -> N.apply P.pr_simple_error [Str "message"; Nil])];
  if N.apply0 P.pr_simple_error != P.pr_simple_error then failwith "simple-error zero";
  (match Shen.Interp.Eval.eval_kl (expr "(cn 1 2)") with
   | Error "cn: two strings expected" -> ()
   | _ -> failwith "legacy error boundary");
  List.iter (fun eval ->
    expect "trap simple-error" (Str "message")
      (eval (expr "(trap-error (simple-error \"message\") (lambda E (error-to-string E)))")))
    [Shen.Interp.Eval.eval_kl; Shen.Interp.Compiled.eval_kl]

(* Keep the algorithms identical: the baseline is exactly the old list adapter,
   while bare calls establish the legitimate allocation cost of each result. *)
let allocation () =
  let iterations = 100000 in
  let sink = ref Nil in
  let measure f =
    Gc.full_major ();
    let before = Gc.allocated_bytes () in
    for _ = 1 to iterations do sink := Sys.opaque_identity (f ()) done;
    let bytes = Gc.allocated_bytes () -. before in
    ignore (Sys.opaque_identity !sink);
    bytes /. float_of_int iterations
  in
  let compare name cells bare direct old expected =
    expect (name ^ " baseline result") expected (old ());
    expect (name ^ " direct result") expected (direct ());
    let bare_bytes = measure bare in
    let direct_bytes = measure direct in
    let old_bytes = measure old in
    let saved = float_of_int (cells * 3 * (Sys.word_size / 8)) in
    if abs_float (direct_bytes -. bare_bytes) > 0.01 then
      failwith (name ^ ": direct entry allocated beyond its output");
    if abs_float (old_bytes -. direct_bytes -. saved) > 0.01 then
      failwith (Printf.sprintf "%s: adapter saving expected %g, got %g"
        name saved (old_bytes -. direct_bytes));
    Printf.printf "STRING_ALLOCATION %s bare=%g direct=%g old=%g saved=%g bytes/call\n%!"
      name bare_bytes direct_bytes old_bytes (old_bytes -. direct_bytes)
  in
  let str v = Str (to_string v) in
  let cn a b = match a, b with Str a, Str b -> Str (a ^ b) | _ -> assert false in
  let old_str = P.make_closure 1 (function [v] -> str v | _ -> assert false) in
  let old_cn = P.make_closure 2 (function [a; b] -> cn a b | _ -> assert false) in
  let number = Sys.opaque_identity (Int 42) in
  let left = Sys.opaque_identity (Str "dictionary-") in
  let right = Sys.opaque_identity (Str "key") in
  compare "str" 1 (fun () -> str number)
    (fun () -> N.apply1 P.pr_str number) (fun () -> N.apply1 old_str number) (Str "42");
  compare "cn" 2 (fun () -> cn left right)
    (fun () -> N.apply2 P.pr_cn left right) (fun () -> N.apply2 old_cn left right)
    (Str "dictionary-key");
  List.iter (fun (name, call, bare) ->
    let actual = measure call in
    let expected = measure bare in
    if abs_float (actual -. expected) > 0.01 then
      failwith (Printf.sprintf "%s: direct=%g bare=%g" name actual expected))
    ["pos", (fun () -> N.apply2 P.pr_pos left (Int 0)),
       (fun () -> match left with Str s -> Str (String.make 1 s.[0]) | _ -> assert false);
     "tlstr", (fun () -> N.apply1 P.pr_tlstr left),
       (fun () -> match left with Str s -> Str (String.sub s 1 (String.length s - 1)) | _ -> assert false);
     "n->string", (fun () -> N.apply1 P.pr_n_to_string number),
       (fun () -> match number with Int n -> Str (String.make 1 (Char.chr n)) | _ -> assert false);
     "string->n", (fun () -> N.apply1 P.pr_string_to_n (Str "A")),
       (fun () -> Int (Char.code (Sys.opaque_identity "A").[0]))]

let () =
  P.initialise ~verbose:false ();
  semantics ();
  allocation ();
  print_endline "STRING_PRIMITIVE_ENTRIES_RESULT pass"
