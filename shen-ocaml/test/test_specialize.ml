(** Phase C soundness tests (written before trusting the optimizer). The type
    checker is the warrant and the interpreter is the oracle:

    1. The fixture type-checks under [(tc +)] — the proof that licenses a fast path.
    2. Specialized results are bit-identical to the interpreter on every input,
       including 63-bit overflow (both paths use native OCaml ints, so wrap the
       same) and float arguments (which must fall back to the uniform path).
    3. Redefinition safety: redefining a web member at runtime invalidates the
       specialized web; a function that called it observes the new definition.
    4. A number-typed function whose body leaves the int subset (usescons) is not
       specialized and still works. *)

open Shen.Kl.Ast
open Shen.Interp.Eval
open Shen.Runtime.Primitives
open Shen.Runtime.Value
open Shen.Interp.Boot

let eval_via_kernel s =
  let expr =
    KLApp (KLSym "eval",
      [ KLApp (KLSym "hd", [ KLApp (KLSym "read-from-string", [ KLStr s ]) ]) ])
  in
  match eval_kl expr with Error m -> failwith ("eval " ^ s ^ ": " ^ m) | v -> v

let () =
  Shen.Interp.Eval.initialise ();
  initialise ();
  let kernel_dir = find_kernel_dir () in
  boot_kernel ~kernel_dir;
  let fixture =
    match Sys.getenv_opt "SPEC_FIXTURE" with
    | Some p -> p
    | None -> failwith "SPEC_FIXTURE not set"
  in
  let src =
    let ic = open_in_bin fixture in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in

  (* (1) Warrant: every define type-checks under (tc +). *)
  let _ = eval_via_kernel "(tc +)" in
  Shen.Kl.Parser.parse_string src
  |> List.iter (fun form ->
         match form with
         | KLApp (KLSym "define", KLSym name :: _) ->
             let s = Shen.Kl.Ast.to_string form in
             (match eval_kl (KLApp (KLSym "eval",
                [ KLApp (KLSym "hd", [ KLApp (KLSym "read-from-string", [ KLStr s ]) ]) ])) with
              | Error m -> failwith ("warrant: " ^ name ^ " failed tc+: " ^ m)
              | _ -> ())
         | _ -> ());
  let _ = eval_via_kernel "(tc -)" in

  (* Interpreter oracle: the fixture is now defined (interpreted) in the table. *)
  let inputs = [ 0; 1; 2; 5; 10; 20; 1000; 100000 ] in
  let oracle_lcg = List.map (fun n -> eval_via_kernel (Printf.sprintf "(lcg 0 %d)" n)) inputs in
  let oracle_sumto = List.map (fun n -> eval_via_kernel (Printf.sprintf "(sumto 0 %d)" n)) inputs in
  let oracle_fibo = List.map (fun n -> eval_via_kernel (Printf.sprintf "(fibo %d)" (min n 28))) inputs in
  let oracle_usesum = List.map (fun n -> eval_via_kernel (Printf.sprintf "(usesum %d)" n)) inputs in
  let oracle_usescons = eval_via_kernel "(usescons 7)" in
  (* float argument must fall back to uniform and stay correct *)
  let oracle_lcg_float = eval_via_kernel "(sumto 0.5 4)" in

  (* (2) Register specialized entries (overwrites the table). *)
  Shen_typed_numeric.Specialized.register ();

  let check name oracle f =
    List.iter2
      (fun n exp ->
        let got = f n in
        if not (equal exp got) then
          failwith (Printf.sprintf "%s %d: oracle=%s specialized=%s" name n
                      (to_string exp) (to_string got)))
      inputs oracle
  in
  check "lcg" oracle_lcg (fun n -> eval_via_kernel (Printf.sprintf "(lcg 0 %d)" n));
  check "sumto" oracle_sumto (fun n -> eval_via_kernel (Printf.sprintf "(sumto 0 %d)" n));
  check "fibo" oracle_fibo (fun n -> eval_via_kernel (Printf.sprintf "(fibo %d)" (min n 28)));
  check "usesum" oracle_usesum (fun n -> eval_via_kernel (Printf.sprintf "(usesum %d)" n));
  (* fallback: number-typed but non-subset body still works *)
  if not (equal oracle_usescons (eval_via_kernel "(usescons 7)")) then
    failwith "usescons fallback diverged";
  (* float argument falls back soundly *)
  if not (equal oracle_lcg_float (eval_via_kernel "(sumto 0.5 4)")) then
    failwith "float fallback diverged";

  (* (3) Redefinition safety: redefine sumto, web invalidates, usesum follows it. *)
  let before = eval_via_kernel "(usesum 5)" in
  (match before with Int 30 -> () | v -> failwith ("usesum 5 (spec) = " ^ to_string v));
  (* redefine sumto to a constant (defun) — trips the redefine hook via set_fn *)
  let _ =
    eval_kl
      (KLApp (KLSym "defun",
         [ KLSym "sumto"; KLApp (KLSym "Acc", [ KLSym "N" ]); KLInt 0 ]))
  in
  if !Shen.Runtime.Spec.web_valid then failwith "web should be invalid after redefinition";
  (match eval_via_kernel "(usesum 5)" with
   | Int 0 -> ()  (* now 2 * (sumto 0 5) = 2 * 0 = 0 *)
   | v -> failwith ("usesum 5 after redefining sumto = " ^ to_string v ^ " (expected 0)"));

  print_endline "  Phase C specialization: sound (bit-identical, fallback, redefinition)."
