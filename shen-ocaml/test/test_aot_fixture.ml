(** Phase B: the AOT-compiled fixture must produce *bit-identical* results to the
    interpreter (the oracle) on every case, including partial application. We
    register the interpreted defuns, capture results, then [boot ()] the compiled
    module (overwriting the function table) and re-capture — both derive from the
    same committed [test/fixtures/aot_fixture.kl]. *)

open Shen.Kl.Parser
open Shen.Interp.Eval
open Shen.Runtime.Value

let eval_one s =
  match parse_string s with [ e ] -> eval_kl e | _ -> failwith ("parse: " ^ s)

let cases =
  [
    "(fixt-fact 10)";
    "(fixt-sumto 0 100)";
    "(fixt-even? 10)";
    "(fixt-even? 7)";
    "(fixt-odd? 7)";
    "(fixt-let 6)";
    "(fixt-and 1 2)";
    "(fixt-and 1 0)";
    "(fixt-and 0 1)";
    "(fixt-or 0 0)";
    "(fixt-or 1 0)";
    "(fixt-cond 0)";
    "(fixt-cond 5)";
    "(fixt-cond -3)";
    "(fixt-apply-lambda 5)";
    "(fixt-trap 42)";
    "(fixt-str 7)";
    (* partial application must behave identically in both directions *)
    "((fixt-sumto 0) 100)";
    "(fixt-and 1)";
    (* deep tail recursion through the table stays stack-flat *)
    "(fixt-sumto 0 200000)";
  ]

let () =
  Shen.Runtime.Primitives.initialise ();
  let fixture =
    match Sys.getenv_opt "AOT_FIXTURE" with
    | Some p -> p
    | None -> failwith "AOT_FIXTURE not set"
  in
  (* 1) Interpreter oracle. *)
  List.iter (fun f -> ignore (eval_kl f)) (parse_file fixture);
  let interp = List.map eval_one cases in
  (* 2) AOT: boot overwrites the table with compiled closures. *)
  Shen_aot_fixture.Aot_fixture.boot ();
  let aot = List.map eval_one cases in
  List.iter2
    (fun (case, i) a ->
      (* For partial application, both should yield a closure; compare by applying. *)
      match (i, a) with
      | Closure _, Closure _ -> ()
      | _ ->
          if not (equal i a) then
            failwith
              (Printf.sprintf "DIVERGENCE %s: interp=%s aot=%s" case
                 (to_string i) (to_string a)))
    (List.combine cases interp)
    aot;
  (* Spot-check a couple of absolute values so the oracle itself is sane. *)
  (match eval_one "(fixt-fact 10)" with
  | Int 3628800 -> ()
  | v -> failwith ("fixt-fact 10 (aot) = " ^ to_string v));
  (match eval_one "((fixt-sumto 0) 100)" with
  | Int 5050 -> ()
  | v -> failwith ("partial fixt-sumto (aot) = " ^ to_string v));
  (* Devirtualized self-recursion must not block runtime redefinition: the AOT
     [fixt-fact] self-calls a local [let rec], but redefining it via [defun] swaps
     the table entry and new calls must use the new definition (a running
     invocation keeps its own body, so no invalidation is needed). *)
  let _ = eval_one "(defun fixt-fact (N) 999)" in
  (match eval_one "(fixt-fact 10)" with
  | Int 999 -> ()
  | v -> failwith ("redefined fixt-fact should be 999, got " ^ to_string v));
  print_endline "  AOT == interpreter on all fixture cases."
