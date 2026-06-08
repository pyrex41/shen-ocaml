(** REPL paths: kernel [eval] (process-applications / fn metadata) and direct
    [eval-kl] (must apply user defuns). *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
open Shen.Runtime.Value
open Shen.Interp.Boot

(** Same as [Main.eval_user_source]: full macroexpand / process-applications pipeline. *)
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

let eval_user_source src =
  KLApp
    ( KLSym "eval-kl",
      [
        KLApp (KLSym "hd", [ KLApp (KLSym "read-from-string", [ KLStr src ]) ]);
      ] )

let eval_src s =
  match eval_kl (eval_user_source s) with
  | Error msg -> failwith msg
  | v -> v

let () =
  initialise ();
  let kernel_dir = find_kernel_dir () in
  boot_kernel ~kernel_dir;
  (match eval_via_kernel "(+ 1 1)" with
  | Int 2 -> ()
  | v -> failwith ("kernel eval (+ 1 1): expected Int 2, got " ^ to_string v));
  (match eval_via_kernel "(value *version*)" with
  | Str s when s <> "" -> ()
  | v ->
      failwith
        ("kernel eval (value *version*): expected non-empty string, got "
        ^ to_string v));
  (match eval_via_kernel "(cons 1 ())" with
  | Cons (Int 1, Nil) -> ()
  | v ->
      failwith
        ("kernel eval (cons 1 ()): expected cons with hd 1, got " ^ to_string v));
  (* Task 5a: nested read-from-string must complete through kernel eval (same
     path as typing [(read-from-string "(+ 1 1)")] at the REPL). *)
  (match
     eval_via_kernel {|(read-from-string "(+ 1 1)")|}
   with
  | Cons (Cons (Sym "+", Cons (Int 1, Cons (Int 1, Nil))), Nil) -> ()
  | v ->
      failwith
        ("kernel eval (read-from-string \"(+ 1 1)\"): expected ((+ 1 1)), got "
        ^ to_string v));
  (* Before [(tc +)]: untyped [(load "tiny.shen")] uses the non-typechecked load path. *)
  (match eval_via_kernel {|(tuple? (@p 1 2))|} with
  | Bool true -> ()
  | v ->
      failwith
        ("kernel eval (tuple? (@p 1 2)): expected true, got " ^ to_string v));
  (match eval_via_kernel {|(load "test/shen/tiny.shen")|} with
  | Sym "loaded" -> ()
  | v ->
      failwith
        ("kernel eval (load tiny.shen): expected symbol loaded, got "
        ^ to_string v));
  (match eval_via_kernel "(double 4)" with
  | Int 8 -> ()
  | v ->
      failwith
        ("after loading tiny.shen, (double 4): expected Int 8, got "
        ^ to_string v));
  (match eval_via_kernel "(tc +)" with
  | Bool true -> ()
  | v -> failwith ("kernel eval (tc +): expected Bool true, got " ^ to_string v));
  (match
     eval_via_kernel
       "(trap-error (simple-error \"boom\") (lambda E (error-to-string E)))"
   with
  | Str "boom" -> ()
  | v ->
      failwith
        ("kernel eval trap-error: expected Str boom, got " ^ to_string v));
  let _ = eval_src "(defun __bootreplf (X) (* X 2))" in
  match eval_src "(__bootreplf 3)" with
  | Int 6 -> ()
  | v -> failwith ("expected Int 6, got " ^ to_string v)
