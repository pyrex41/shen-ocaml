(** Boot the kernel from native AOT-compiled code instead of interpreting the 21
    [.kl] files. [Aot_kernel_compiled.boot ()] registers every compiled defun (and
    runs the few interpreted fallback forms) in boot order; the surrounding
    [shen.initialise] / metadata steps are shared with the interpreted path via
    {!Shen.Interp.Boot.boot_with}. *)

let boot_kernel_aot () =
  Shen.Interp.Boot.boot_with ~load:(fun () -> Aot_kernel_compiled.boot ())
