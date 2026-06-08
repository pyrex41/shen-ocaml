let () =
  Shen.Runtime.Primitives.initialise ();
  let kernel_dir = Shen.Interp.Boot.find_kernel_dir () in
  try Shen.Interp.Boot.boot_kernel ~kernel_dir with
  | Shen.Interp.Boot.Boot_error msg ->
      Printf.eprintf "KERNEL BOOT FAILED: %s\n" msg;
      exit 1
