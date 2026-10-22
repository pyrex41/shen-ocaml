let () =
  let mode, input, output = match Array.to_list Sys.argv with
    | [_; "--compatible"; input; output] -> Shen.Codegen.Native_gen.Compatible, input, output
    | [_; "--sealed"; input; output] -> Shen.Codegen.Native_gen.Sealed, input, output
    | _ ->
        prerr_endline "usage: compile_native (--compatible|--sealed) input.kl output.ml";
        exit 2
  in
  try Shen.Codegen.Native_gen.compile_file ~mode input output with
  | Shen.Kl.Resolved.Compile_error message
  | Shen.Kl.Parser.Parse_error message -> prerr_endline message; exit 1
