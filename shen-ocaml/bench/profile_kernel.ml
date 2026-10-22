(** Checked application allocation diagnostics. With a positive sampling rate,
    timing and GC counters INCLUDE profiler overhead. Rate zero never starts
    Memprof. Boot, setup and warmup are outside measurement in both modes.
    Memprof disables sampling inside callbacks, so stack samples describe the
    application rather than the profiler's own bookkeeping. *)
open Shen.Runtime.Value
module N = Shen.Runtime.Native

let json text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '"';
  String.iter (function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | c when Char.code c < 32 -> Printf.bprintf buffer "\\u%04x" (Char.code c)
    | c -> Buffer.add_char buffer c) text;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let eval source =
  let forms = N.call "read-from-string" [Str source] in
  let rec run = function
    | Nil -> Nil
    | Cons (form, Nil) -> N.call "eval" [form]
    | Cons (form, rest) -> ignore (N.call "eval" [form]); run rest
    | _ -> failwith "improper reader result"
  in run forms

let symbolizer kernel_dir =
  let forms = List.concat_map (fun name ->
    Shen.Kl.Parser.parse_file (Filename.concat kernel_dir name)) Shen.Interp.Boot.kernel_files in
  let names = Shen.Kl.Resolved.resolve forms |> List.filter_map (function
    | Shen.Kl.Resolved.Define definition -> Some definition.name
    | _ -> None) |> Array.of_list in
  let pattern = Str.regexp "Kernel\\.f\\([0-9]+\\)" in
  fun text -> Str.global_substitute pattern (fun text ->
    let index = int_of_string (Str.matched_group 1 text) in
    if index < Array.length names then "Kernel." ^ names.(index)
    else Str.matched_string text) text

let () =
  let scenario = ref "typecheck" in
  let repetitions = ref 1 in
  let size = ref None in
  let warmup = ref 1 in
  let rate = ref 0.0001 in
  let output = ref "" in
  Arg.parse [
    "--scenario", Arg.Set_string scenario,
      "typecheck, prolog, higher-order-list-pipeline (list), or string-key-dictionary (dictionary)";
    "--repetitions", Arg.Set_int repetitions, "number of checked repetitions";
    "--size", Arg.Int (fun n -> size := Some n), "positive list/dictionary size (defaults 1000/2000)";
    "--warmup", Arg.Set_int warmup, "checked repetitions outside measurement (default 1; 0 disables)";
    "--rate", Arg.Set_float rate, "samples per allocated word (default 0.0001; 0 disables Memprof)";
    "--output", Arg.Set_string output, "write JSON report to this file";
  ] (fun _ -> raise (Arg.Bad "unexpected positional argument")) "profile_kernel [options]";
  if !repetitions < 1 || !warmup < 0 || not (!rate >= 0. && !rate <= 1.) then
    failwith "positive repetitions, nonnegative warmup and finite sampling rate in [0,1] required";
  let application = match !scenario with
    | "higher-order-list-pipeline" | "list" | "list-pipeline" -> Some ("scoreboard.list-pipeline", 1000, 3)
    | "string-key-dictionary" | "dictionary" -> Some ("scoreboard.dictionary", 2000, 1)
    | "typecheck" | "prolog" -> None
    | _ -> failwith "unknown --scenario: expected typecheck, prolog, higher-order-list-pipeline or string-key-dictionary"
  in
  (* Divide the even factor first; reject overflow before multiplication, including
     N + offset. This keeps both the expected answer and all workload partial sums
     within the runtime's integer range. *)
  let application = match application, !size with
    | None, Some _ -> failwith "--size is only supported for list/dictionary scenarios"
    | None, None -> None
    | Some (name, default, offset), requested ->
        let n = Option.value ~default requested in
        if n < 1 || n > max_int - offset then failwith "--size must be positive and its expected sum must fit an OCaml integer";
        let a, b = if n mod 2 = 0 then n / 2, n + offset else n, (n + offset) / 2 in
        if a > max_int / b then failwith "--size expected sum overflows an OCaml integer";
        Some (name, n, a * b)
  in
  Shen.Runtime.Primitives.initialise ~verbose:false ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  let symbolize = if !rate = 0. then Fun.id
    else symbolizer (Shen.Interp.Boot.find_kernel_dir ()) in
  Shen.Runtime.Env.set_global "*hush*" (Bool true);
  let workload = match application with
    | Some (name, n, expected) ->
        ignore (eval "(load \"bench/application_support.shen\")");
        let source = Printf.sprintf "(%s %d)" name n in
        let expected = Int expected in
        fun () ->
          let result = eval source in
          if not (equal result expected) then
            failwith (Printf.sprintf "%s: expected %s, got %s" name
              (to_string expected) (to_string result))
    | None -> (match !scenario with
        | "typecheck" ->
            ignore (eval "(tc +)");
            fun () ->
              let result = eval "(load \"test/shen/prologinterp.shen\")" in
              if not (equal result (Sym "loaded")) then failwith "typechecking load did not complete"
        | "prolog" ->
            ignore (eval "(load \"test/shen/einsteins-riddle.shen\")");
            fun () ->
              let result = eval "(prolog? (riddle))" in
              if not (equal result (Sym "german")) then failwith "wrong Prolog answer"
        | _ -> assert false)
  in
  for _ = 1 to !warmup do workload () done;
  let sites = Hashtbl.create 128 in
  let sampled_words = ref 0 in
  let record (allocation : Gc.Memprof.allocation) =
    let stack = Printexc.raw_backtrace_to_string allocation.callstack in
    let previous = Option.value ~default:0 (Hashtbl.find_opt sites stack) in
    Hashtbl.replace sites stack (previous + allocation.n_samples);
    sampled_words := !sampled_words + allocation.n_samples;
    None
  in
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () in let wall = Unix.gettimeofday () in
  let run () = for _ = 1 to !repetitions do workload () done in
  if !rate = 0. then run ()
  else (
    let profile = Gc.Memprof.start ~sampling_rate:!rate ~callstack_size:10
      { Gc.Memprof.null_tracker with alloc_minor = record; alloc_major = record } in
    Fun.protect ~finally:(fun () -> Gc.Memprof.stop (); Gc.Memprof.discard profile) run);
  let wall = Unix.gettimeofday () -. wall in let cpu = Sys.time () -. cpu in
  let allocated = Gc.allocated_bytes () -. allocated in
  let after = Gc.quick_stat () in
  let ranked = Hashtbl.fold (fun stack samples rows -> (samples, stack) :: rows) sites []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a) in
  let top = List.filteri (fun index _ -> index < 20) ranked in
  let allocators = Hashtbl.create 64 in
  List.iter (fun (samples, stack) ->
    let site = match String.split_on_char '\n' stack with [] -> "unknown" | first :: _ -> first in
    let previous = Option.value ~default:0 (Hashtbl.find_opt allocators site) in
    Hashtbl.replace allocators site (previous + samples)) ranked;
  let top_allocators = Hashtbl.fold (fun site samples rows -> (samples, site) :: rows) allocators []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.filteri (fun index _ -> index < 20) in
  let report = Buffer.create 8192 in
  Printf.bprintf report
    "{\"scenario\":%s,\"repetitions\":%d,\"ocaml\":%s,\"sampling_rate\":%.8g,\"mode\":%s,\"profiler_enabled\":%b,\"warmup_repetitions\":%d,\"setup_and_warmup_included\":false,\"measurement_scope\":\"checked workload including eval/read and result validation\",\"wall_s\":%.6f,\"cpu_s\":%.6f,\"allocated_bytes\":%.0f,"
    (json !scenario) !repetitions (json Sys.ocaml_version) !rate
    (json (if !rate = 0. then "unprofiled" else "memprof")) (!rate > 0.) !warmup wall cpu allocated;
  (* Preserve the original sampled report keys, but never label unsampled data as
     including a profiler. Generic metrics above are available in both modes. *)
  let suffix = if !rate = 0. then "unprofiled" else "including_profiler" in
  Printf.bprintf report "\"wall_s_%s\":%.6f,\"cpu_s_%s\":%.6f,\"allocated_bytes_%s\":%.0f,"
    suffix wall suffix cpu suffix allocated;
  (match application with
   | None -> ()
   | Some (_, n, expected) -> Printf.bprintf report "\"size\":%d,\"expected_answer\":%d," n expected);
  Printf.bprintf report
    "\"minor_collections\":%d,\"major_collections\":%d,\"sampled_words\":%d,\"sites\":["
    (after.minor_collections - before.minor_collections)
    (after.major_collections - before.major_collections) !sampled_words;
  List.iteri (fun index (samples, stack) ->
    if index > 0 then Buffer.add_char report ',';
    Printf.bprintf report "{\"samples\":%d,\"estimated_bytes\":%.0f,\"stack\":%s}"
      samples (float_of_int samples /. !rate *. float_of_int (Sys.word_size / 8))
      (json (symbolize stack))) top;
  Buffer.add_string report "],\"allocators\":[";
  List.iteri (fun index (samples, site) ->
    if index > 0 then Buffer.add_char report ',';
    Printf.bprintf report "{\"samples\":%d,\"share\":%.6f,\"site\":%s}"
      samples (float_of_int samples /. float_of_int (max 1 !sampled_words)) (json (symbolize site))) top_allocators;
  Buffer.add_string report "]}\n";
  if !output = "" then print_string (Buffer.contents report)
  else (
    let channel = open_out_bin !output in
    Fun.protect ~finally:(fun () -> close_out channel)
      (fun () -> output_string channel (Buffer.contents report));
    Printf.printf "PROFILE_RESULT scenario=%s sampled_words=%d sites=%d output=%s\n%!"
      !scenario !sampled_words (Hashtbl.length sites) !output)
