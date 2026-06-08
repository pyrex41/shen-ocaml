(** Build-time tool: read a Shen source file of single-clause numeric [define]s and
    emit an OCaml module with type-specialized (unboxed int) entry points plus
    uniform fallbacks. Usage: gen_specialize <input.shen> <output.ml> *)

let () =
  match Sys.argv with
  | [| _; src; out |] ->
      let forms =
        try Shen.Kl.Parser.parse_file src with
        | Shen.Kl.Parser.Parse_error msg ->
            failwith (Printf.sprintf "parse %s: %s" src msg)
      in
      let b = Buffer.create (1 lsl 14) in
      let specialized = Shen.Codegen.Ocaml_specialize.compile_forms b forms in
      let oc = open_out_bin out in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc (Buffer.contents b));
      Printf.eprintf "gen_specialize: specialized [%s]\n"
        (String.concat "; " specialized)
  | _ ->
      prerr_endline "usage: gen_specialize <input.shen> <output.ml>";
      exit 2
