(** Isolate exact wide-call ABI cost. The control installs the same compiled
    function behind the generic list ABI, not a different algorithm or AST. *)
open Shen.Runtime.Value
module N = Shen.Runtime.Native

let measure name arity mode =
  let args = List.init arity (fun i ->
    if i = 0 then Int 20000 else if i = arity - 1 then Int 42 else Int i) in
  let run () =
    match N.call name args with
    | Int 42 -> ()
    | value -> failwith ("wrong wide-call result: " ^ to_string value)
  in
  run ();
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () in let wall = Unix.gettimeofday () in
  for _ = 1 to 20 do run () done;
  let wall = Unix.gettimeofday () -. wall in let cpu = Sys.time () -. cpu in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf "WIDE_RESULT\t%s\t%d\t20\t%.6f\t%.6f\t%.0f\n%!"
    mode arity wall cpu allocated;
  allocated

let () =
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  ignore (Wide_native.run ());
  for arity = 5 to 8 do
    let name = "bench.wide" ^ string_of_int arity in
    let specialized = match Shen.Runtime.Env.get_fn name with
      | Some value -> value
      | None -> failwith "missing generated workload"
    in
    let direct_allocated = measure name arity "specialized" in
    Shen.Runtime.Env.set_fn name (N.function_ arity (fun args -> N.apply specialized args));
    let generic_allocated = measure name arity "generic-abi-control" in
    Shen.Runtime.Env.set_fn name specialized;
    if direct_allocated >= generic_allocated then
      failwith "specialized wide-call ABI did not remove argument-list allocations"
  done
