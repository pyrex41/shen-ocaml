(** Unit tests for the KL interpreter and primitive dispatch (no kernel). *)

open Shen.Kl.Parser
open Shen.Interp.Eval
open Shen.Runtime.Value

let eval_one s =
  match parse_string s with
  | [ e ] -> eval_kl e
  | _ -> failwith ("expected exactly one expression: " ^ s)

let run () =
  print_endline "Testing KL interpreter...";
  Shen.Runtime.Primitives.initialise ();
  assert (eval_kl (Shen.Kl.Ast.KLInt 42) = Int 42);
  assert (eval_one "(let X 5 X)" = Int 5);
  assert (eval_one "((lambda X X) 42)" = Int 42);
  let _ = eval_one "(defun __eval_f (X) (+ X 1))" in
  assert (eval_one "(__eval_f 5)" = Int 6);
  let _ = eval_one "(defun __eval_g (X Y) (+ X Y))" in
  assert (eval_one "(__eval_g 3 4)" = Int 7);
  assert (eval_one "(thaw (freeze (+ 1 2)))" = Int 3);
  assert (
    eval_one
      "(trap-error (simple-error \"boom\") (lambda E (error-to-string E)))"
    = Str "boom");
  assert (eval_one "(do (set __eval_x 10) (value __eval_x))" = Int 10);
  assert (
    match eval_one "(value __surely_unbound_symbol_xyz_)" with
    | Error msg -> String.starts_with ~prefix:"unbound value:" msg
    | _ -> false);
  (* Primitives use uniform partial application: bare (set) is a closure, not an arity error. *)
  assert (
    match eval_one "(set)" with
    | Closure _ -> true
    | _ -> false);
  assert (eval_one "(cond (false 1) (true 2))" = Int 2);
  assert (eval_one "(if false 1 2)" = Int 2);
  assert (eval_one "(if true 3 4)" = Int 3);
  (* if special form short-circuits; first-class [if] evaluates all arguments first. *)
  assert (eval_one "(if false (+ 1 \"bad\") 0)" = Int 0);
  assert (
    match eval_one "(let F if (F true (+ 1 \"bad\") 0))" with
    | Error msg -> String.starts_with ~prefix:"+:" msg
    | _ -> false);
  (* and / or are special forms: must short-circuit (second expr would error). *)
  assert (eval_one "(and false (+ 1 \"bad\"))" = Bool false);
  assert (eval_one "(or true (+ 1 \"bad\"))" = Bool true);
  assert (eval_one "(and true true)" = Bool true);
  assert (eval_one "(or false false)" = Bool false);
  (* partial application on primitives and user defuns *)
  assert (eval_one "((+ 1) 2)" = Int 3);
  let _ = eval_one "(defun __eval_pa (X Y) (+ X Y))" in
  assert (eval_one "((__eval_pa 1) 2)" = Int 3);
  assert (eval_one "(< 1 2)" = Bool true);
  assert (eval_one "(<= 2 2)" = Bool true);
  assert (eval_one "(>= 3 2)" = Bool true);
  assert (eval_one "(/ 4 2)" = Float 2.);
  assert (eval_one "(cn \"a\" \"b\")" = Str "ab");
  assert (eval_one "(pos \"abc\" 1)" = Str "b");
  assert (eval_one "(tlstr \"ab\")" = Str "b");
  assert (eval_one "(n->string 65)" = Str "A");
  assert (eval_one "(string->n \"B\")" = Int 66);
  assert (eval_one "(symbol? foo)" = Bool true);
  assert (eval_one "(boolean? true)" = Bool true);
  (* Bool/Sym(true,false) interchangeability — the fix that unblocked the type
     checker (literal true/false in a define body are symbols, not Bool). *)
  assert (equal (Bool true) (Sym "true"));
  assert (equal (Sym "false") (Bool false));
  assert (not (equal (Bool true) (Sym "false")));
  assert (is_true (Sym "true"));
  assert (eval_one "(= true (intern \"true\"))" = Bool true);
  assert (eval_one "(= false (intern \"false\"))" = Bool true);
  assert (eval_one "(boolean? (intern \"true\"))" = Bool true);
  assert (eval_one "(boolean? (intern \"false\"))" = Bool true);
  assert (eval_one "(if (intern \"true\") 1 2)" = Int 1);
  assert (eval_one "(type 42 number)" = Int 42);
  assert (eval_one "(eval-kl (cons + (cons 1 (cons 2 ()))))" = Int 3);
  assert (
    match eval_one "(get-time unix)" with
    | Float _ -> true
    | _ -> false);
  let _ = eval_one "(defun __replf (X) (* X 2))" in
  assert (eval_one "(__replf 3)" = Int 6);
  print_endline "  Interpreter tests passed."
