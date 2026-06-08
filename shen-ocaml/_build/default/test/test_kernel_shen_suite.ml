(** Load ShenOSKernel-41.1 [kerneltests.shen] (and [harness.shen]) from [test/shen].
    Requires cwd to be [test/shen] so [(load "...")] resolves paths (see dune [chdir]). *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
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
  if not (Sys.file_exists "harness.shen") then
    failwith
      ("expected harness.shen in cwd for kernel Shen tests (got " ^ cwd ^ ")");
  let _ = eval_via_kernel {|(load "harness.shen")|} in
  match eval_via_kernel {|(load "kerneltests.shen")|} with
  | _ -> ()
