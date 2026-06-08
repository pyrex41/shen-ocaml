(** Parse every kernel [.kl] in {!Shen.Interp.Boot.kernel_files} order and emit one OCaml module. *)

let () =
  if Array.length Sys.argv <> 3 then (
    Printf.eprintf "usage: gen_all_kernel_forms <kernel_dir> <output.ml>\n";
    exit 2);
  let kernel_dir = Sys.argv.(1) in
  let out_path = Sys.argv.(2) in
  Shen.Codegen.Ocaml_gen.emit_kernel_bundle ~kernel_dir
    Shen.Interp.Boot.kernel_files out_path
