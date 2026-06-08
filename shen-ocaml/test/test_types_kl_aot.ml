(** Full kernel [.kl] set emitted as OCaml literals and compiled with [shen] (AOT smoke). *)

let () =
  let xs = Shen_aot_kernel.Kernel_bundle.kernel_files_in_boot_order in
  assert (List.length xs = List.length Shen.Interp.Boot.kernel_files);
  List.iter
    (fun (name, forms) ->
      let n = List.length forms in
      assert (n > 0);
      Printf.printf "AOT %s: %d top-level forms\n" name n)
    xs;
  Printf.printf "AOT kernel bundle: %d files (compiled)\n" (List.length xs)
