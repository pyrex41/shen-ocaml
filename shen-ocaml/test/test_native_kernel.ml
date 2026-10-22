open Shen.Runtime.Value

let eval source =
  let expression = Shen.Kl.Ast.KLApp (KLSym "eval", [
    KLApp (KLSym "hd", [KLApp (KLSym "read-from-string", [KLStr source])])]) in
  match Shen.Interp.Eval.eval_kl expression with
  | Error message -> failwith message
  | value -> value

let expect source expected =
  let actual = eval source in
  if not (equal actual expected) then failwith (source ^ ": " ^ to_string actual)

let () =
  Shen.Runtime.Primitives.initialise ();
  Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
  expect "(value *version*)" (Str "43.1");
  expect "(+ 20 22)" (Int 42);
  expect "(let X 21 (+ X X))" (Int 42);
  expect "(tuple? (@p 1 2))" (Bool true);
  expect "(symbol? (/. X X))" (Bool false);
  expect "(trap-error (simple-error \"boom\") (/. E (error-to-string E)))" (Str "boom");
  ignore (eval "(define native-kernel-double X -> (* X 2))");
  expect "(native-kernel-double 21)" (Int 42);
  expect "(load \"fixtures/native_refs.shen\")" (Sym "loaded");
  expect "(tc +)" (Bool true);
  ignore (eval "(define native-kernel-typed { number --> number } X -> (+ X 1))");
  expect "(native-kernel-typed 41)" (Int 42);
  ignore (eval "(define native-kernel-bool { number --> boolean } _ -> true)");
  expect "(native-kernel-bool 41)" (Bool true);
  print_endline "NATIVE_KERNEL_RESULT boot=pass eval=pass define=pass typed_define=pass"
