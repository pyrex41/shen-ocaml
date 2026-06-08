(** Phase B: boot the kernel from native AOT-compiled code (no .kl interpretation)
    and verify it behaves like the interpreted boot on smoke cases — same kernel
    [eval] pipeline (read-from-string → macroexpand → process-applications →
    shen->kl → eval-kl) over AOT-registered functions. *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
open Shen.Runtime.Value

let eval_via_kernel s =
  let expr =
    KLApp
      ( KLSym "eval",
        [ KLApp (KLSym "hd", [ KLApp (KLSym "read-from-string", [ KLStr s ]) ]) ]
      )
  in
  match eval_kl expr with Error msg -> failwith ("eval: " ^ s ^ ": " ^ msg) | v -> v

let () =
  Shen.Interp.Eval.initialise ();
  initialise ();
  Shen_aot_kernel_compiled.Aot_boot.boot_kernel_aot ();
  let check s expect =
    let v = eval_via_kernel s in
    if not (equal v expect) then
      failwith (Printf.sprintf "%s = %s (expected %s)" s (to_string v) (to_string expect))
  in
  check "(+ 1 1)" (Int 2);
  check "(value *version*)" (Str "41.1");
  check "(cons 1 (cons 2 ()))" (Cons (Int 1, Cons (Int 2, Nil)));
  check "(append [1 2] [3 4])" (Cons (Int 1, Cons (Int 2, Cons (Int 3, Cons (Int 4, Nil)))));
  check "(map (+ 1) [1 2 3])" (Cons (Int 2, Cons (Int 3, Cons (Int 4, Nil))));
  check "(tc +)" (Bool true);
  check "(tc -)" (Bool false);
  check "(boolean? (intern \"true\"))" (Bool true);
  (* the type checker (mostly interpreted-fallback giants) must still work over AOT
     funcs; a typed define returns the typecheck artifact, so just check it runs. *)
  let _ = eval_via_kernel "(tc +)" in
  let _ = eval_via_kernel "(define aotdbl {number --> number} X -> (* X 2))" in
  check "(aotdbl 21)" (Int 42);
  let _ = eval_via_kernel "(tc -)" in
  (* untyped multi-clause define + pattern match through AOT kernel *)
  let _ = eval_via_kernel "(define aotfact 0 -> 1 X -> (* X (aotfact (- X 1))))" in
  check "(aotfact 5)" (Int 120);
  print_endline "  AOT kernel boot smoke passed."
