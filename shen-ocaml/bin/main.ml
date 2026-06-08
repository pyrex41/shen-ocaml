(** Shen-OCaml CLI: kernel boot and REPL using the Shen reader + evaluator. *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Value
open Shen.Runtime.Primitives
open Shen.Interp.Boot

(** Scan [s] for parenthesis depth and whether we end inside a string (after [\]). *)
let paren_scan s =
  let depth = ref 0 in
  let in_str = ref false in
  let esc = ref false in
  let underflow = ref false in
  String.iter
    (fun c ->
      if !esc then esc := false
      else if !in_str then
        match c with
        | '"' -> in_str := false
        | '\\' -> esc := true
        | _ -> ()
      else
        match c with
        | '"' -> in_str := true
        | '(' ->
            incr depth
        | ')' ->
            decr depth;
            if !depth < 0 then underflow := true
        | _ -> ())
    s;
  (!depth, !in_str, !underflow)

(** Read lines until parentheses balance and any string literal is closed. *)
let rec read_balanced_input first acc =
  (if first then print_string "shen> " else print_string "... ");
  flush stdout;
  match read_line () with
  | exception End_of_file ->
      if acc = "" then raise End_of_file
      else (
        print_endline "";
        acc)
  | line ->
      let acc' =
        if acc = "" then line else acc ^ "\n" ^ line
      in
      let depth, in_str, underflow = paren_scan acc' in
      if underflow || depth < 0 then (
        print_endline "Error: unbalanced parentheses";
        read_balanced_input true "")
      else if depth = 0 && not in_str then
        if String.trim acc' = "" then read_balanced_input true ""
        else acc'
      else read_balanced_input false acc'

(** Route user text through [read-from-string] then kernel [eval], which runs
    [macroexpand → process-applications → shen->kl → eval-kl] (see [sys.kl]).
    Using [eval-kl] alone skips that pipeline and breaks [define], macros, etc. *)
let eval_user_source src =
  KLApp
    ( KLSym "eval",
      [
        KLApp
          ( KLSym "hd",
            [ KLApp (KLSym "read-from-string", [ KLStr src ]) ] );
      ] )

let rec repl () =
  match read_balanced_input true "" with
  | exception End_of_file -> print_endline "\nGoodbye."
  | input -> (
      let expr = eval_user_source input in
      (match eval_kl expr with
      | Error msg -> print_endline ("Error: " ^ msg)
      | v -> print_endline (to_string v));
      repl ())

let () =
  print_endline "Shen-OCaml — loading kernel…";
  (* [open Primitives] shadows [Eval.initialise]; eval options must run too. *)
  Shen.Interp.Eval.initialise ();
  initialise ();
  (try
     let kernel_dir = find_kernel_dir () in
     boot_kernel ~kernel_dir;
     print_endline "Kernel ready."
   with Boot_error msg ->
     Printf.eprintf "Kernel boot failed: %s\n" msg;
     exit 1);
  repl ()
