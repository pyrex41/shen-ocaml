(** Build-time tool: compile all kernel [.kl] files (in boot order) into one OCaml
    module exposing [boot () : unit]. Usage: gen_aot_kernel <kernel_dir> <out.ml> *)

let () =
  match Sys.argv with
  | [| _; kernel_dir; out_path |] ->
      let files =
        List.map
          (fun base ->
            let path = Filename.concat kernel_dir base in
            let forms =
              try Shen.Kl.Parser.parse_file path with
              | Shen.Kl.Parser.Parse_error msg ->
                  failwith (Printf.sprintf "parse %s: %s" path msg)
            in
            (base, forms))
          Shen.Interp.Boot.kernel_files
      in
      let b = Buffer.create (1 lsl 20) in
      Shen.Codegen.Ocaml_compile.compile_kernel_module b files;
      let oc = open_out_bin out_path in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc (Buffer.contents b))
  | _ ->
      prerr_endline "usage: gen_aot_kernel <kernel_dir> <out.ml>";
      exit 2
