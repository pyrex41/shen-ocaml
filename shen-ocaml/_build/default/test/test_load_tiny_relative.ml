(** Task 5a: [(load "tiny.shen")] with cwd [test/shen] (same resolution as harness). *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
open Shen.Runtime.Value
open Shen.Interp.Boot

let eval_kernel_pipeline src =
  KLApp
    ( KLSym "eval",
      [
        KLApp
          ( KLSym "hd",
            [ KLApp (KLSym "read-from-string", [ KLStr src ]) ] );
      ] )

let eval_via_kernel s =
  match eval_kl (eval_kernel_pipeline s) with
  | Error msg -> failwith msg
  | v -> v

let () =
  initialise ();
  let kernel_dir = find_kernel_dir () in
  boot_kernel ~kernel_dir;
  let cwd = Sys.getcwd () in
  if not (Sys.file_exists "tiny.shen") then
    failwith
      ("expected tiny.shen in cwd (chdir test/shen); got cwd " ^ cwd);
  (match eval_via_kernel {|(load "tiny.shen")|} with
  | Sym "loaded" -> ()
  | v ->
      failwith
        ("(load \"tiny.shen\"): expected symbol loaded, got " ^ to_string v));
  match eval_via_kernel "(double 4)" with
  | Int 8 -> ()
  | v ->
      failwith ("(double 4) after load: expected Int 8, got " ^ to_string v)
