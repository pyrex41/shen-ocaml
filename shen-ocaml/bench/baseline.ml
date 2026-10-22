(** Checked, single-process baseline for the legacy interpreter. Parsing is outside
    execution measurements. These are not Scheme comparisons or compatibility gates. *)
open Shen.Runtime.Value

let parse source =
  match Shen.Kl.Parser.parse_string source with
  | [expression] -> expression
  | _ -> failwith "expected one KL expression"

let checked expected expression () =
  let actual = Shen.Interp.Eval.eval_kl expression in
  if not (equal expected actual) then
    failwith ("unexpected result: " ^ to_string actual)

let measure name repetitions f =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () in
  let wall = Unix.gettimeofday () in
  for _ = 1 to repetitions do f () done;
  let wall = Unix.gettimeofday () -. wall in
  let cpu = Sys.time () -. cpu in
  let allocated = Gc.allocated_bytes () -. allocated in
  Printf.printf "RESULT\t%s\t%d\t%.6f\t%.6f\t%.0f\n%!"
    name repetitions wall cpu allocated

let define source =
  match Shen.Interp.Eval.eval_kl (parse source) with
  | Sym _ -> ()
  | value -> failwith ("definition failed: " ^ to_string value)

let () =
  Printf.printf "# ocaml=%s backend=legacy-tree-walker\n" Sys.ocaml_version;
  print_endline "# RESULT name repetitions wall_seconds cpu_seconds allocated_bytes";
  measure "boot" 1 (fun () ->
    Shen.Interp.Eval.initialise ();
    Shen.Runtime.Primitives.initialise ();
    Shen.Interp.Boot.boot_kernel
      ~kernel_dir:(Shen.Interp.Boot.find_kernel_dir ()));
  define "(defun bench.sum (N A) (if (= N 0) A (bench.sum (- N 1) (+ A N))))";
  define "(defun bench.hof (F N A) (if (= N 0) A (bench.hof F (- N 1) (F A))))";
  define "(defun bench.build (N A) (if (= N 0) A (bench.build (- N 1) (cons N A))))";
  define "(defun bench.length (L A) (if (cons? L) (bench.length (tl L) (+ A 1)) A))";
  let cases = [
    "tail-sum", 5, Int 200010000, "(bench.sum 20000 0)";
    "higher-order", 5, Int 20000,
      "(bench.hof (lambda X (+ X 1)) 20000 0)";
    "list-build-traverse", 5, Int 10000,
      "(bench.length (bench.build 10000 ()) 0)";
    "structural-equality", 5, Bool true,
      "(= (bench.build 2000 ()) (bench.build 2000 ()))";
    "shen-reader-eval", 100, Int 42,
      "(eval (hd (read-from-string \"(+ 20 22)\")))";
  ] in
  List.iter (fun (name, repetitions, expected, source) ->
    let run = checked expected (parse source) in
    run ();
    measure name repetitions run) cases
