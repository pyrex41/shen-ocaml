(** Build-time tool: compile a KL [.kl] file to an OCaml [.ml] module (Phase B).

    Usage: gen_aot <input.kl> <output.ml>
    The emitted module exposes [boot () : unit] which registers every [defun] as a
    compiled closure and runs any other top-level form once via the interpreter. *)

let () =
  match Sys.argv with
  | [| _; kl_path; out_path |] ->
      let forms =
        try Shen.Kl.Parser.parse_file kl_path with
        | Shen.Kl.Parser.Parse_error msg ->
            failwith (Printf.sprintf "parse %s: %s" kl_path msg)
      in
      let b = Buffer.create (1 lsl 16) in
      Shen.Codegen.Ocaml_compile.compile_file_module b ~source_path:kl_path forms;
      let oc = open_out_bin out_path in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc (Buffer.contents b))
  | _ ->
      prerr_endline "usage: gen_aot <input.kl> <output.ml>";
      exit 2
