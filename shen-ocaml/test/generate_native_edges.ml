open Shen.Kl.Ast

let () =
  let vector = KLVec [|KLSym "literal-symbol"; KLApp (KLSym "not-a-call", [KLInt 42])|] in
  let forms = [
    KLDefun ("Case", [], KLInt 1);
    KLDefun ("case", [], KLInt 2);
    KLDefun ("vector-literal", [], vector);
    KLDefun ("let-shadow", [], KLLet ("X", KLInt 41,
      KLLet ("X", KLApp (KLSym "+", [KLSym "X"; KLInt 1]), KLSym "X")));
    KLDefun ("zero-test", [], KLIf (KLApp (KLSym "true-thunk", []), KLInt 42, KLInt 0));
    KLDefun ("true-thunk", [], KLBool true);
  ] in
  let output = open_out_bin Sys.argv.(1) in
  Fun.protect ~finally:(fun () -> close_out output) (fun () ->
    output_string output (Shen.Codegen.Native_gen.compile ~mode:Sealed forms))
