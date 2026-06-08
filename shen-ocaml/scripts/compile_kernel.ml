(** 
 * scripts/compile_kernel.ml
 * Script to AOT compile .kl files to OCaml modules using the codegen.
 * Run with: dune exec scripts/compile_kernel.exe or ocaml
 *)

#use "topfind";;
#require "str";;

open Shen.Codegen.Ocaml_gen  (* will need adjustment *)

let kernel_files = [
  "kernel/core.kl";
  "kernel/toplevel.kl";
  "kernel/sys.kl";
  "kernel/reader.kl";
  "kernel/prolog.kl";
  "kernel/load.kl";
  "kernel/writer.kl";
  "kernel/macros.kl";
  "kernel/declarations.kl";
  "kernel/types.kl";
  "kernel/t-star.kl";
  "kernel/sequent.kl";
  "kernel/track.kl";
  "kernel/dict.kl";
  "kernel/compiler.kl";
  "kernel/stlib.kl";
  "kernel/init.kl";
  "kernel/extension-features.kl";
  "kernel/extension-expand-dynamic.kl";
  "kernel/extension-launcher.kl";
  "kernel/yacc.kl"
]

let () =
  print_endline "=== Shen Kernel AOT Compiler (stub) ===";
  List.iter (fun kl ->
    let base = Filename.chop_extension (Filename.basename kl) in
    let out = Printf.sprintf "src/generated/%s.ml" base in
    print_endline ("Compiling " ^ kl ^ " -> " ^ out);
    Shen.Codegen.Ocaml_gen.compile_kl_to_ocaml kl out;
  ) kernel_files;
  print_endline "Kernel compilation stub completed.";
  print_endline "Next: implement full codegen for registration and function bodies."
