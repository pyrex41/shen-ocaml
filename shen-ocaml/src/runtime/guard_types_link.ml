(** Witness: [shen] depends on generated [Guard_types] so Gate 2 (dune build)
    fails if shengen output changes shape without updating call sites. *)

let () =
  match Shen_guard_types.Guard_types.make_kl_value 0. with
  | Error _ -> ()
  | Ok _kl ->
      (match Shen_guard_types.Guard_types.make_valid_kl_ast "" with
      | Error _ -> ()
      | Ok ast ->
          match Shen_guard_types.Guard_types.make_eval_kl_safe ast with
          | Ok _ | Error _ -> ())
