(** Native ceiling experiment: run the ordinary source pipeline once, then
    optionally replace its observed definitions with compatible native bodies.
    No source effects or metadata installation are replayed by promotion. *)
open Shen.Runtime.Value
module E = Shen.Runtime.Env
module N = Shen.Runtime.Native
module P = Shen_cli.Native_promote

let eval source =
  let forms = N.call "read-from-string" [Str source] in
  let rec run = function
    | Nil -> Nil
    | Cons (form, Nil) -> N.call "eval" [form]
    | Cons (form, rest) -> ignore (N.call "eval" [form]); run rest
    | _ -> failwith "improper source forms"
  in run forms

let prepare source =
  match N.call "read-from-string" [Str source] with
  | Cons (form, Nil) ->
      let kl = N.call "shen.shen->kl" [form] |> Shen.Interp.Eval.value_to_kl_expr in
      Shen.Interp.Compiled.compile [kl]
  | _ -> failwith "expected one benchmark expression"

let () =
  let mode = ref "dynamic" and case = ref "list" and output_dir = ref "" in
  let repetitions = ref 0 and size = ref 0 in
  Arg.parse [
    "--mode", Arg.Set_string mode, "dynamic or promoted";
    "--case", Arg.Set_string case, "list, dictionary, or prolog";
    "--output-dir", Arg.Set_string output_dir, "existing native artifact directory";
    "--repetitions", Arg.Set_int repetitions, "checked work repetitions";
    "--size", Arg.Set_int size, "list/dictionary input size";
  ] (fun _ -> raise (Arg.Bad "unexpected argument")) "application_native [options]";
  if not (List.mem !mode ["dynamic"; "promoted"]) then failwith "unknown mode";
  if !size < 0 || !repetitions < 0 then failwith "sizes and repetitions must be nonnegative";
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  E.set_global "*hush*" true_value;
  let observations = P.create () in
  let previous = !(E.eval_kl_from_value_ref) in
  E.set_eval_kl_from_value (P.evaluate observations previous);
  ignore (eval "(load \"bench/application_support.shen\")");
  let default_repetitions, body, answer = match !case with
    | "list" ->
        let n = if !size = 0 then 1000 else !size in
        if n > 1_000_000 then failwith "size exceeds checked benchmark limit";
        5000, Printf.sprintf "(scoreboard.list-pipeline %d)" n, string_of_int (n * (n + 3) / 2)
    | "dictionary" ->
        let n = if !size = 0 then 2000 else !size in
        if n > 1_000_000 then failwith "size exceeds checked benchmark limit";
        100, Printf.sprintf "(scoreboard.dictionary %d)" n, string_of_int (n * (n + 1) / 2)
    | "prolog" ->
        ignore (eval "(load \"test/shen/einsteins-riddle.shen\")");
        20, "(prolog? (riddle))", "german"
    | _ -> failwith "unknown application case"
  in
  let repetitions = if !repetitions = 0 then default_repetitions else !repetitions in
  let names = P.names observations in
  if names = [] then failwith "source observation recorded no definitions";
  let promotion_start = Unix.gettimeofday () in
  if !mode = "promoted" then (
    if !output_dir = "" then failwith "promoted mode requires --output-dir";
    ignore (P.promote observations ~config:(Shen_cli.Native_cli.native_config ())
      ~output_dir:!output_dir ~names));
  let promotion_wall = Unix.gettimeofday () -. promotion_start in
  let run = prepare (Printf.sprintf "(scoreboard.repeat %d (freeze %s) %s native-ceiling)"
    repetitions body answer) in
  if not (equal (run ()) true_value) then failwith "warmup failed";
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () and wall = Unix.gettimeofday () in
  if not (equal (run ()) true_value) then failwith "work failed";
  let cpu = Sys.time () -. cpu and wall = Unix.gettimeofday () -. wall in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf "CEILING_RESULT\t%s\t%s\t%d\t%d\t%.6f\t%.6f\t%.0f\t%.6f\n%!"
    !mode !case repetitions (List.length names) cpu wall allocated promotion_wall
