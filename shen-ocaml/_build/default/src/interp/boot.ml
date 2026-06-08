(** Load KLambda kernel files and run [shen.initialise]. *)

(* Keep generated guard types on the boot path so Gate 2 always typechecks them. *)
module _ = Runtime.Guard_types_link

open Kl.Ast
open Kl.Parser
open Runtime.Env
open Runtime.Value
open Eval

exception Boot_error of string

let kernel_files =
  [
    "core.kl";
    "toplevel.kl";
    "sys.kl";
    "reader.kl";
    "prolog.kl";
    "load.kl";
    "writer.kl";
    "macros.kl";
    "declarations.kl";
    "types.kl";
    "t-star.kl";
    "sequent.kl";
    "track.kl";
    "dict.kl";
    "compiler.kl";
    "stlib.kl";
    "init.kl";
    "extension-features.kl";
    "extension-expand-dynamic.kl";
    "extension-launcher.kl";
    "yacc.kl";
  ]

let set_port_metadata () =
  set_global "*language*" (Str "OCaml");
  set_global "*implementation*" (Str "shen-ocaml");
  set_global "*port*" (Str "0.1.0-ocaml");
  set_global "*porters*" (Str "Shen-OCaml port")

let expr_index = ref 0

let load_kl_file path =
  expr_index := 0;
  let forms =
    try parse_file path with
    | Parse_error msg ->
        raise (Boot_error (Printf.sprintf "%s: parse error: %s" path msg))
  in
  List.iter
    (fun expr ->
      incr expr_index;
      let r = eval_kl expr in
      match r with
      | Error msg ->
          raise
            (Boot_error
               (Printf.sprintf "%s: form %d: %s" path !expr_index msg))
      | _ -> ())
    forms

let boot_kernel ~kernel_dir =
  set_port_metadata ();
  (* Set *home-directory* to cwd so (load ...) resolves relative paths. *)
  let cwd = Sys.getcwd () in
  let home = if cwd = "" then "" else cwd ^ "/" in
  set_global "*home-directory*" (Str home);
  List.iter
    (fun base ->
      let path = Filename.concat kernel_dir base in
      if not (Sys.file_exists path) then
        raise (Boot_error ("kernel file not found: " ^ path));
      load_kl_file path)
    kernel_files;
  (* Native [hash] before [shen.initialise] so *property-vector* buckets stay consistent. *)
  Runtime.Primitives.install_native_hash ();
  let init_expr = KLApp (KLSym "shen.initialise", []) in
  (match eval_kl init_expr with
  | Error msg -> raise (Boot_error ("shen.initialise: " ^ msg))
  | _ -> ());
  Runtime.Primitives.register_hash_fn_metadata ();
  Runtime.Primitives.register_all_metadata ()

let find_kernel_dir () =
  let ok d = Sys.file_exists (Filename.concat d "core.kl") in
  let from_env () =
    match Sys.getenv_opt "SHEN_KERNEL_DIR" with
    | Some d when ok d -> Some d
    | _ -> None
  in
  let rec walk_parents dir depth =
    if depth <= 0 then None
    else
      let kernel_dir = Filename.concat dir "kernel" in
      if ok kernel_dir then Some kernel_dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then None else walk_parents parent (depth - 1)
  in
  match from_env () with
  | Some d -> d
  | None ->
      let cwd = Sys.getcwd () in
      let candidates =
        [
          Filename.concat cwd "kernel";
          Filename.concat cwd "shen-ocaml/kernel";
          Filename.concat (Filename.dirname cwd) "shen-ocaml/kernel";
        ]
      in
      match walk_parents cwd 12 with
      | Some d -> d
      | None -> (
          match List.find_opt ok candidates with
          | Some d -> d
          | None ->
              raise
                (Boot_error
                   "could not find kernel/ with core.kl (set SHEN_KERNEL_DIR or \
                    run from shen-ocaml project root)"))
