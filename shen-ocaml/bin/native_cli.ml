(** Experimental native-kernel CLI with compiled dynamic eval-kl. *)
open Shen.Runtime.Value
module N = Shen.Runtime.Native

let usage = "shen-ocaml [repl | eval EXPR | script FILE | compile-native [--sealed] FILE DIR | eval-native PLUGIN EXPR | repl-native PLUGIN | eval-promoted FILE DIR EXPR]"

let native_config () : Native_build.config =
  let includes = match Sys.getenv_opt "SHEN_OCAML_NATIVE_INCLUDE_DIRS" with
    | Some paths -> String.split_on_char ':' paths |> List.filter ((<>) "")
    | None ->
        let rec find directory remaining =
          let byte = Filename.concat directory "src/.shen.objs/byte" in
          let native = Filename.concat directory "src/.shen.objs/native" in
          if Sys.file_exists (Filename.concat byte "shen.cmi") && Sys.file_exists native then [byte; native]
          else if remaining = 0 || Filename.dirname directory = directory then []
          else find (Filename.dirname directory) (remaining - 1)
        in
        let executable = if Filename.is_relative Sys.executable_name then
            Filename.concat (Sys.getcwd ()) Sys.executable_name else Sys.executable_name in
        let paths = find (Filename.dirname executable) 5 in
        if paths <> [] then paths else find (Filename.concat (Sys.getcwd ()) "_build/default") 1
  in
  if includes = [] then raise (Native_build.Build_error
    "cannot locate runtime compiler interfaces; set SHEN_OCAML_NATIVE_INCLUDE_DIRS to matching ABI include directories");
  { ocamlopt = Option.value ~default:"ocamlopt" (Sys.getenv_opt "SHEN_OCAML_OCAMLOPT"); include_dirs = includes }

let ensure_output_dir directory =
  if not (Sys.file_exists directory) then
    (try Unix.mkdir directory 0o755 with Unix.Unix_error (error, _, _) ->
      raise (Native_build.Build_error ("cannot create native output directory: " ^ Unix.error_message error)));
  if not (Sys.is_directory directory) then
    raise (Native_build.Build_error "native output path is not a directory")

let compile_native mode input directory =
  ensure_output_dir directory;
  let artifact = Native_build.compile_file ~mode ~config:(native_config ()) ~output_dir:directory input in
  Printf.printf "%s\n%!" artifact.plugin_path

let source text =
  let forms = N.call "read-from-string" [Str text] in
  let rec evaluate = function
    | Nil -> Nil
    | Cons (form, Nil) -> N.call "eval" [form]
    | Cons (form, rest) -> ignore (N.call "eval" [form]); evaluate rest
    | _ -> raise (User_error "reader returned an improper list")
  in evaluate forms

let eval_promoted input directory expression =
  ensure_output_dir directory;
  let module E = Shen.Runtime.Env in
  let module P = Native_promote in
  let observations = P.create () in
  let previous = !(E.eval_kl_from_value_ref) in
  E.set_eval_kl_from_value (P.evaluate observations previous);
  Fun.protect ~finally:(fun () -> E.set_eval_kl_from_value previous) (fun () ->
    (* Ordinary loading performs effects once and expands macros/packages/Prolog.
       Promotion replaces only observed eligible definitions, not source forms. *)
    ignore (N.call "load" [Str input]);
    let names = P.names observations in
    if names = [] then raise (Native_build.Build_error "loading recorded no promotable definitions");
    ignore (P.promote observations ~config:(native_config ()) ~output_dir:directory ~names));
  print_endline (to_string (source expression))

let repl () =
  (* Delegate interactive reading, prompts and evaluation to the Shen kernel. *)
  let read_byte = match Shen.Runtime.Env.get_fn "read-byte" with
    | Some fn -> fn
    | None -> failwith "read-byte is not installed"
  in
  ignore (N.install "read-byte" 1 (N.function_ 1 (fun args ->
    let value = N.apply read_byte args in
    match args, value with
    | [Stream (In_chan input)], Int (-1) when input == stdin -> raise End_of_file
    | _ -> value)));
  try ignore (N.call "shen.repl" []) with End_of_file -> print_newline ()

let run () =
  let arguments = Array.to_list Sys.argv |> List.tl in
  if arguments = ["--help"] then (
    print_endline usage;
    exit 0);
  try
    Shen.Runtime.Primitives.initialise ~verbose:false ();
    Shen.Interp.Boot.boot_native ~install:Shen_native_kernel.Kernel.run;
    (match arguments with
    | [] | ["repl"] -> repl ()
    | ["eval"; expression] -> print_endline (to_string (source expression))
    | ["compile-native"; input; directory] ->
        compile_native Shen.Codegen.Native_gen.Compatible input directory
    | ["compile-native"; "--sealed"; input; directory] ->
        compile_native Shen.Codegen.Native_gen.Sealed input directory
    | ["eval-native"; plugin; expression] ->
        ignore (Native_build.load_file plugin);
        print_endline (to_string (source expression))
    | ["repl-native"; plugin] -> ignore (Native_build.load_file plugin); repl ()
    | ["eval-promoted"; input; directory; expression] ->
        eval_promoted input directory expression
    | ["script"; path] ->
        let input = open_in_bin path in
        let text = Fun.protect ~finally:(fun () -> close_in input)
          (fun () -> really_input_string input (in_channel_length input)) in
        ignore (source text)
    | _ -> prerr_endline ("usage: " ^ usage); exit 2)
  with
  | User_error message | Shen.Interp.Boot.Boot_error message
  | Shen.Kl.Resolved.Compile_error message | Native_build.Build_error message
  | Native_promote.Promote_error message ->
      Printf.eprintf "Error: %s\n%!" message;
      exit 1
