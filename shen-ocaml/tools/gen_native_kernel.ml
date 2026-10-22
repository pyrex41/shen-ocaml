let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: gen_native_kernel kernel_dir output.ml";
    exit 2);
  let forms = List.concat_map (fun name ->
    Shen.Kl.Parser.parse_file (Filename.concat Sys.argv.(1) name))
    Shen.Interp.Boot.kernel_files in
  let source = Shen.Codegen.Native_gen.compile forms in
  let channel = open_out_bin Sys.argv.(2) in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel source)
