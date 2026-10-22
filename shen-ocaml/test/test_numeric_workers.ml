open Shen.Runtime.Value
module N = Shen.Runtime.Native

let result name args =
  match N.call name args with
  | Int n -> `Int n
  | Float n -> `Float n
  | value -> failwith ("numeric worker returned " ^ to_string value)

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  ignore (Numeric_compatible.run ());
  let cases = List.concat_map (fun n -> [
    "numeric.sum", [Int n; Int 3];
    "numeric.sum", [Float (float_of_int n); Int 3];
    "numeric.sum", [Int n; Float 3.5];
    "numeric.mul", [Int n; Int 7; Int 3];
    "numeric.subtract", [Int n; Int min_int; Int 17];
    "numeric.let", [Int n; Int max_int];
  ]) [0; 1; 2; 10; 50; 100] in
  let expected = List.map (fun (name, args) -> result name args) cases in
  ignore (Numeric_sealed.run ());
  List.iter2 (fun (name, args) expected ->
    if result name args <> expected then failwith ("numeric specialization changed " ^ name)) cases expected;
  ignore (N.call "numeric.effect" [Int 5]);
  (match N.value (Sym "numeric.observed") with
  | Int 1 -> () | _ -> failwith "effectful function was incorrectly specialized");
  let cell = Shen.Runtime.Env.function_cell "numeric.sum" in
  let n = Int 20000 and accumulator = Int 0 in
  let before = Gc.allocated_bytes () in
  for _ = 1 to 10 do
    match N.call2 cell n accumulator with
    | Int 200010000 -> ()
    | _ -> failwith "wrong specialized sum"
  done;
  let allocated = Gc.allocated_bytes () -. before in
  if allocated > 4096. then failwith "integer worker allocates inside its loop";
  let forms = Shen.Kl.Parser.parse_string "(defun loop (N A) (if (= N 0) A (loop (- N 1) (+ A N))))" in
  let definition = match Shen.Kl.Resolved.resolve forms with
    | [Define definition] -> definition | _ -> assert false in
  List.iter (fun shadowed ->
    match Shen.Codegen.Numeric_loop.emit ~worker:("loop", "worker") ~shadowed
            ~params:definition.params definition.body with
    | None -> ()
    | Some _ -> failwith "numeric worker ignored a shadowed primitive") [["+"]; ["-"]; ["="]];
  Printf.printf "NUMERIC_WORKER_RESULT cases=%d float_fallback=pass overflow_preserved=pass effects=pass loop_alloc_bytes=%.0f\n"
    (List.length cases) allocated
