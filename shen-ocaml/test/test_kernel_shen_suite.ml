(** Bounded in-process conformance gate over the ShenOSKernel-41.1 suite.

    The interpreter is the oracle (Phase A). The *full* per-group conformance run
    (all 35 [report] groups, with per-group wall-clock timeouts) lives in the
    committed script [scripts/run_kernel_suite.py] — that is the honest headline
    number tracked in STATUS.md. This dune test is the fast, deterministic
    regression gate: it runs the subset of groups that currently pass cleanly and
    quickly, then asserts the cumulative pass/fail tally has not regressed.

    Why a subset and not the whole file: a few groups still fail (yacc, spreadsheet,
    montague) and "binary number datatype" is order-dependent in-process (see
    STATUS.md); excluding them keeps this gate a clean, fast regression check. The
    full headline number (128/6) comes from scripts/run_kernel_suite.py. (A
    monolithic single-process run of all groups is also currently slow — another
    reason this gate uses a curated fast subset.)

    Mechanism: the harness keeps its [*passed*]/[*failed*] counters under the
    package-prefixed symbol [test-harness.*passed*], so we don't read them
    directly. Instead we redirect this process's stdout to a temp file (the
    kernel's [output] writes there), [(reset)] once, run the clean groups in
    order so the harness counters accumulate, then parse the last
    [passed ... N / failed ... M] line — the cumulative total over the subset. *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
open Shen.Interp.Boot

(** Groups that pass cleanly and finish quickly *when run in one process, in order*
    — the regression set. Names must match the [(report "<name>" ...)] labels in
    kerneltests.shen exactly. (primes / einsteins riddle pass too but are slower;
    left to the full script.)

    "binary number datatype" is intentionally excluded: it passes in isolation but
    not in-process after "Prolog tableau". Root cause (see STATUS.md): tableau's
    [(defprolog complement ...)] gives [complement] arity 6 (its horn-clause
    procedure [define complement P1 P2 B L K C -> ...]); the binary [report] form
    is [shen->kl]-compiled as a unit, so [(complement [1 0])] is compiled to a
    currying lambda (6 > 1 args) *before* the in-group [(load "binary.shen")]
    redefines complement to arity 1, and returns a closure at runtime. This is an
    eval compile-vs-load timing interaction tracked as an open conformance issue. *)
let clean_groups =
  [
    "cartesian product"; "powerset"; "bubble sort"; "semantic nets";
    "Prolog call"; "Prolog cut"; "Prolog naive reverse"; "findall in Prolog";
    "Prolog tableau"; "proplog"; "metaprogramming";
    "calculator"; "structures 1"; "structures 2"; "classes 1"; "classes 2";
    "abstract datatypes"; "proof assistant"; "depth first search";
    "unification"; "total in Prolog"; "Prolog fork"; "yacc"; "montague";
    "N Queens"; "search"; "L interpreter"; "quantifier machine"; "secd";
    "Prolog interpreter"; "spreadsheet";
  ]

(** Expected cumulative passing count across [clean_groups] (baseline 2026-06). *)
let expected_pass = 119

let eval_pipeline src =
  KLApp
    ( KLSym "eval",
      [ KLApp (KLSym "hd", [ KLApp (KLSym "read-from-string", [ KLStr src ]) ]) ]
    )

let eval_via_kernel s =
  match eval_kl (eval_pipeline s) with Error msg -> failwith msg | v -> v

(** Run [thunk] with this process's stdout redirected to [file]; restore after. *)
let with_stdout_to file thunk =
  flush stdout;
  let saved = Unix.dup Unix.stdout in
  let fd = Unix.openfile file [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let finally () =
    flush stdout;
    Unix.dup2 saved Unix.stdout;
    Unix.close saved
  in
  Fun.protect ~finally thunk

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(** Last "<label> ... <int>" value in [text] (the cumulative harness tally). *)
let last_count text label =
  let re = Str.regexp (label ^ " \\.\\.\\. \\([0-9]+\\)") in
  let rec scan pos acc =
    match try Some (Str.search_forward re text pos) with Not_found -> None with
    | None -> acc
    | Some i -> scan (i + 1) (Some (int_of_string (Str.matched_group 1 text)))
  in
  scan 0 None

(** Split [text] into top-level parenthesised forms (string/escape aware). *)
let split_forms text =
  let forms = ref [] and buf = Buffer.create 256 in
  let depth = ref 0 and instr = ref false and esc = ref false in
  String.iter
    (fun c ->
      if !instr then (
        Buffer.add_char buf c;
        if !esc then esc := false
        else if c = '\\' then esc := true
        else if c = '"' then instr := false)
      else
        match c with
        | '"' -> instr := true; Buffer.add_char buf c
        | '(' -> incr depth; Buffer.add_char buf c
        | ')' ->
            decr depth;
            Buffer.add_char buf c;
            if !depth = 0 then (
              forms := Buffer.contents buf :: !forms;
              Buffer.clear buf)
        | c when !depth > 0 -> Buffer.add_char buf c
        | _ -> ())
    text;
  List.rev !forms

let report_name form =
  try
    let i = String.index form '"' in
    let j = String.index_from form (i + 1) '"' in
    Some (String.sub form (i + 1) (j - i - 1))
  with Not_found -> None

let () =
  initialise ();
  let kernel_dir = find_kernel_dir () in
  boot_kernel ~kernel_dir;
  if not (Sys.file_exists "harness.shen") then
    failwith ("expected harness.shen in cwd (got " ^ Sys.getcwd () ^ ")");
  let forms = split_forms (read_file "kerneltests.shen") in
  let by_name =
    List.filter_map
      (fun f -> match report_name f with Some n -> Some (n, f) | None -> None)
      forms
  in
  let out_file = Filename.temp_file "shen_suite" ".out" in
  with_stdout_to out_file (fun () ->
      let _ = eval_via_kernel {|(load "harness.shen")|} in
      let _ = eval_via_kernel "(reset)" in
      List.iter
        (fun name ->
          match List.assoc_opt name by_name with
          | None -> failwith ("group not found in kerneltests.shen: " ^ name)
          | Some form -> ignore (eval_via_kernel form))
        clean_groups);
  let text = read_file out_file in
  (try Sys.remove out_file with _ -> ());
  let passed = Option.value ~default:0 (last_count text "passed") in
  let failed = Option.value ~default:0 (last_count text "failed") in
  Printf.printf
    "kernel suite (clean subset): passed=%d failed=%d across %d groups\n" passed
    failed (List.length clean_groups);
  if failed > 0 then (
    Printf.printf
      "REGRESSION — %d failures in the clean subset; run scripts/run_kernel_suite.py\n"
      failed;
    exit 1);
  if passed < expected_pass then (
    Printf.printf "REGRESSION — passed %d < expected %d\n" passed expected_pass;
    exit 1);
  print_endline "kernel conformance subset: no regressions."
