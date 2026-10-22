open Shen.Runtime.Value

let cases = [
  "tail-sum", Int 200010000, "(bench.sum 20000 0)";
  "higher-order", Int 20000, "(bench.run-hof)";
  "list-build-traverse", Int 10000, "(bench.length (bench.build 10000 ()) 0)";
  "structural-equality", Bool true, "(= (bench.build 2000 ()) (bench.build 2000 ()))";
]

let repetitions = ref 20

let measure mode (name, expected, source) =
  let expression = List.hd (Shen.Kl.Parser.parse_string source) in
  let run () =
    (* The small outer invocation stays in the interpreter for all modes. The
       registered workload bodies execute in the selected backend. *)
    let actual = Shen.Interp.Eval.eval_kl expression in
    if not (equal actual expected) then failwith (mode ^ "/" ^ name ^ ": " ^ to_string actual)
  in
  run ();
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () in
  let wall = Unix.gettimeofday () in
  for _ = 1 to !repetitions do run () done;
  let wall = Unix.gettimeofday () -. wall in
  let cpu = Sys.time () -. cpu in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf "RESULT\t%s\t%s\t%d\t%.6f\t%.6f\t%.0f\n%!"
    mode name !repetitions wall cpu allocated

let () =
  let source = ref "bench/workloads.kl" in
  let selected = ref "" in
  let seed = ref (-1) in
  Arg.parse ["--mode", Arg.Set_string selected, "run one backend";
             "--seed", Arg.Set_int seed, "shuffle backend order reproducibly";
             "--repetitions", Arg.Set_int repetitions, "checked repetitions per workload"]
    (fun value -> source := value) "compare_native [options] [workloads.kl]";
  if !repetitions < 1 then invalid_arg "positive repetitions required";
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Printf.printf "# ocaml=%s\n# RESULT mode workload repetitions wall_s cpu_s allocated_bytes\n"
    Sys.ocaml_version;
  let forms = Shen.Kl.Parser.parse_file !source in
  let modes = Array.of_list (List.filter (fun (name, _) -> !selected = "" || name = !selected) [
    "legacy", (fun () -> List.iter (fun e -> match Shen.Interp.Eval.eval_kl e with
      | Error msg -> failwith msg | _ -> ()) forms);
    "dynamic-compiled", (fun () -> ignore ((Shen.Interp.Compiled.compile forms) ()));
    "native-compatible", (fun () -> ignore (Workloads_compatible.run ()));
    "native-sealed", (fun () -> ignore (Workloads_sealed.run ()));
  ]) in
  if Array.length modes = 0 then invalid_arg "unknown backend";
  if !seed >= 0 then (
    let state = Random.State.make [|!seed|] in
    for i = Array.length modes - 1 downto 1 do
      let j = Random.State.int state (i + 1) in
      let saved = modes.(i) in modes.(i) <- modes.(j); modes.(j) <- saved
    done);
  Printf.printf "# order=%s\n%!" (String.concat "," (Array.to_list (Array.map fst modes)));
  Array.iter (fun (name, install) -> install (); List.iter (measure name) cases) modes
