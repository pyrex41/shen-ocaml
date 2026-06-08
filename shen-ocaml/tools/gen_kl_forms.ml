(** CLI: parse one .kl file and emit an OCaml module of [kl_expr list] (for AOT / CI). *)

let () =
  if Array.length Sys.argv <> 3 then (
    Printf.eprintf "usage: gen_kl_forms <input.kl> <output.ml>\n";
    exit 2);
  Shen.Codegen.Ocaml_gen.compile_kl_to_ocaml Sys.argv.(1) Sys.argv.(2)
