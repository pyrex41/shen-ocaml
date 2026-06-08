(** Codegen: mangle, emit KL as OCaml literals, and full-file emit via temp paths. *)

let read_all path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let () =
  print_endline "Testing KL→OCaml codegen…";
  assert (Shen.Codegen.Ocaml_gen.mangle "+" = "k__u2B");
  assert (Shen.Codegen.Ocaml_gen.mangle "foo-bar" = "k_foo_u2Dbar");
  let e =
    match Shen.Kl.Parser.parse_string "(+ 1 2)" with
    | [ x ] -> x
    | _ -> assert false
  in
  let b = Buffer.create 64 in
  Shen.Codegen.Ocaml_gen.emit_expr b e;
  assert (
    Buffer.contents b
    = "(KLApp ((KLSym \"+\"), [(KLInt 1); (KLInt 2)]))");
  (* KLCons emission must be balanced parentheses *)
  let b2 = Buffer.create 32 in
  Shen.Codegen.Ocaml_gen.emit_expr b2
    (Shen.Kl.Ast.KLCons (Shen.Kl.Ast.KLInt 1, Shen.Kl.Ast.KLInt 2));
  assert (Buffer.contents b2 = "(KLCons ((KLInt 1), (KLInt 2)))");
  let kl_tmp = Filename.temp_file "tiny" ".kl" in
  let ml_tmp = Filename.temp_file "kl_emit" ".ml" in
  Fun.protect
    ~finally:(fun () ->
      Sys.remove kl_tmp;
      Sys.remove ml_tmp)
    (fun () ->
      let oc = open_out_bin kl_tmp in
      output_string oc "(+ 1 2)\n";
      close_out oc;
      Shen.Codegen.Ocaml_gen.compile_kl_to_ocaml kl_tmp ml_tmp;
      let src = read_all ml_tmp in
      assert (String.length src > 50);
      assert (
        try
          ignore (Str.search_forward (Str.regexp_string "KLInt 1") src 0);
          ignore (Str.search_forward (Str.regexp_string "KLInt 2") src 0);
          true
        with Not_found -> false));
  print_endline "  Codegen tests passed."
