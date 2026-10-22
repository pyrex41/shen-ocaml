(** Load the vendored [kerneltests.shen] (and [harness.shen]) from [test/shen].
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
  (match Sys.getenv_opt "SHEN_TEST_DIR" with
  | Some directory -> Sys.chdir directory
  | None -> ());
  initialise ();
  (match Sys.getenv_opt "SHEN_KERNEL_BACKEND" with
  | Some "native" ->
      boot_native ~install:Shen_native_kernel.Kernel.run
  | _ -> boot_kernel ~kernel_dir:(find_kernel_dir ()));
  Printf.printf "KERNEL_STAGE booted\n%!";
  let cwd = Sys.getcwd () in
  if not (Sys.file_exists "harness.shen") then
    failwith
      ("expected harness.shen in cwd for kernel Shen tests (got " ^ cwd ^ ")");
  let _ = eval_via_kernel {|(load "harness.shen")|} in
  Printf.printf "KERNEL_STAGE harness-loaded\n%!";
  ignore (eval_via_kernel "(reset)");
  Printf.printf "KERNEL_STAGE counters-reset\n%!";
  let count name = match Shen.Runtime.Env.get_global name with
    | Some (Int n) -> n
    | _ -> failwith ("missing suite counter: " ^ name)
  in
  let totals () = count "test-harness.*passed*", count "test-harness.*failed*" in
  (* The canonical script resets its counters as its final form. Snapshot them
     before that reset rather than reporting its final zeros as success. *)
  let saved = ref None in
  let reset = match Shen.Runtime.Env.get_fn "reset" with
    | Some fn -> fn
    | None -> failwith "reset not installed by harness"
  in
  Shen.Runtime.Env.set_fn "reset"
    (Shen.Runtime.Native.function_ 0 (fun _ ->
       saved := Some (totals ()); Shen.Runtime.Native.apply reset []));
  ignore (eval_via_kernel {|(load "kerneltests.shen")|});
  let passed, failed = match !saved with Some totals -> totals | None -> totals () in
  Printf.printf "\nKERNEL_RESULT passed=%d failed=%d\n%!" passed failed;
  if failed <> 0 || passed = 0 then exit 1
