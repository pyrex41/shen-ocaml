(** Explicit, process-local promotion of already installed, post-expansion KL.

    The host wraps its ordinary eval-kl callback with [evaluate].
    Nothing here evaluates source, repeats installation, or writes Shen metadata.
    Like Env and Native_artifact, this API requires a single-threaded host.
    Host signal handlers and other asynchronous callbacks must not mutate function
    bindings during promotion; allocation-free publication is not a general
    signal-masking or concurrent transaction primitive.
    Plugins are trusted code built against the running host's exact ABI; artifacts
    are deliberately fresh, not a persistent or content-addressed cache. *)
open Shen.Runtime.Value
module E = Shen.Runtime.Env
module Registry = Shen.Runtime.Native_artifact

exception Promote_error of string
let fail format = Printf.ksprintf (fun message -> raise (Promote_error message)) format

type config = Native_build.config = { ocamlopt : string; include_dirs : string list }
type observation = {
  original : value;
  definition : (Shen.Kl.Ast.kl_expr, string) result;
}

type t = {
  definitions : (string, observation) Hashtbl.t;
  mutable recorded : int;
  mutable promoted : int;
}

let create () = { definitions = Hashtbl.create 32; recorded = 0; promoted = 0 }
let counts state = state.recorded, state.promoted
let names state = Hashtbl.to_seq_keys state.definitions |> List.of_seq |> List.sort String.compare

(* Vectors are mutable literal objects in the already installed dynamic body.
   Serializing them would silently change identity, contents and aliasing. *)
let rec immutable = function
  | Vec _ -> false
  | Cons (head, tail) -> immutable head && immutable tail
  | _ -> true

let record_installed state name original form =
  let definition : (Shen.Kl.Ast.kl_expr, string) result =
    if not (immutable form) then Error "mutable vector literals cannot be promoted"
    else
      try Ok (Shen.Interp.Eval.value_to_kl_expr form)
      with Shen.Interp.Eval.Eval_error message -> Error message in
  Hashtbl.replace state.definitions name { original; definition };
  state.recorded <- state.recorded + 1

(** Capture the actual top-level callable BEFORE N.install can run metadata.
    First-match capture matters: a metadata callback may recursively eval-kl a
    different defun with the same name. The nested wrapper owns that observation;
    the outer wrapper must never associate its original KL with the nested body.
    Restore the observer even when evaluation raises. No source effects replay. *)
let evaluate state evaluator form =
  match form with
  | Cons (Sym "defun", Cons (Sym name, _)) ->
      let previous = !(Shen.Interp.Compiled.definition_observer) in
      let candidate = ref None in
      let result = Fun.protect
        ~finally:(fun () -> Shen.Interp.Compiled.definition_observer := previous)
        (fun () ->
          Shen.Interp.Compiled.definition_observer := (fun found callable ->
            if found = name && Option.is_none !candidate then candidate := Some callable;
            previous found callable);
          evaluator form) in
      (match result with
      | Error _ -> ()
      | _ ->
          match !candidate, E.get_fn name with
          | Some original, Some current when original == current ->
              record_installed state name original form
          | _, Some current ->
              (* Preserve a valid nested observation, otherwise retain a clear
                 reason instead of silently falling back or compiling wrong KL. *)
              (match Hashtbl.find_opt state.definitions name with
              | Some observation when observation.original == current -> ()
              | _ ->
                  let reason = match !candidate with
                    | None -> "evaluator did not report the installed callable"
                    | Some _ -> "definition was replaced during installation metadata" in
                  Hashtbl.replace state.definitions name
                    { original = current; definition = Error reason })
          | _, None -> ());
      result
  | _ -> evaluator form

type artifact = {
  key : string;
  source_path : string;
  plugin_path : string;
  targets : (string * observation) list;
}

let validate targets =
  List.iter (fun (name, observation) ->
    match E.get_fn name with
    | Some current when current == observation.original -> ()
    | _ -> fail "native promotion rejected stale definition: %s" name) targets

(* Successful final validation and publication must allocate nothing: even a
   single-threaded OCaml host can run a reentrant GC finalizer at allocation.
   All cells, expected values and replacement options were collected beforehand. *)
let rec validate_replacements = function
  | [] -> ()
  | (cell, expected, _) :: rest ->
      (match cell.E.binding with
      | Some current when current == expected -> validate_replacements rest
      | _ -> fail "native promotion rejected stale definition: %s" cell.E.name)

let rec publish_replacements = function
  | [] -> ()
  | (cell, _, binding) :: rest ->
      cell.E.binding <- binding;
      publish_replacements rest

let build action =
  try action () with Native_build.Build_error message -> fail "%s" message

(** Compile without installing anything. Keeping preparation separate also lets
    callers explicitly test stale-artifact rejection. There is no load-file API:
    the original callable identities belong to this process alone. *)
let prepare state ~config ~names ~output_dir =
  if names = [] then fail "native promotion requires at least one function";
  if List.length names <> List.length (List.sort_uniq String.compare names) then
    fail "native promotion requires unique requested names";
  let targets = List.map (fun name ->
    match Hashtbl.find_opt state.definitions name with
    | Some observation -> name, observation
    | None -> fail "native promotion has no observed installed KL for %s" name) names in
  validate targets;
  let forms = List.map (fun (name, observation) ->
    match observation.definition with
    | Ok form -> form
    | Error message -> fail "cannot promote %s: %s" name message) targets in
  let generated = Shen.Codegen.Native_gen.compile_factories forms in
  if config.include_dirs = [] then fail "native promotion requires explicit matching-ABI include directories";
  List.iter (fun path ->
    if not (Sys.file_exists path && Sys.is_directory path) then
      fail "native promotion include directory does not exist: %s" path) config.include_dirs;
  let output_dir = if Filename.is_relative output_dir then Filename.concat (Sys.getcwd ()) output_dir else output_dir in
  if not (Sys.file_exists output_dir && Sys.is_directory output_dir) then
    fail "native promotion output directory does not exist: %s" output_dir;
  let source_path = build (fun () -> Native_build.filesystem (fun () ->
    Filename.temp_file ~temp_dir:output_dir "shen_promote_" ".ml")) in
  let key = "promotion:" ^ Digest.to_hex (Digest.string (source_path ^ generated)) in
  let plugin_path = Filename.chop_extension source_path ^ ".cmxs" in
  build (fun () ->
    Native_build.write source_path (generated ^ Printf.sprintf
      "\nlet () = Shen.Runtime.Native_artifact.register %S run\n" key);
    let includes = List.concat_map (fun directory -> ["-I"; directory]) config.include_dirs in
    Native_build.command config.ocamlopt (includes @ ["-shared"; "-o"; plugin_path; source_path]));
  if not (Sys.file_exists plugin_path) then fail "native compiler produced no promotion plugin: %s" plugin_path;
  { key; source_path; plugin_path; targets }

let publish state artifact =
  if not Dynlink.is_native then fail "native promotion requires a native-code host";
  validate artifact.targets;
  let run = match Registry.find artifact.key with
    | Some run -> run
    | None ->
        (try Dynlink.loadfile (Dynlink.adapt_filename artifact.plugin_path) with
        | Dynlink.Error error -> fail "cannot load native promotion %s: %s"
            artifact.plugin_path (Dynlink.error_message error));
        match Registry.find artifact.key with
        | Some run -> run
        | None -> fail "native promotion plugin did not register %s" artifact.key in
  validate artifact.targets;
  let exported = run () in
  let rec bindings targets exported = match targets, exported with
    | [], Nil -> []
    | (name, observation) :: rest, Cons (Cons (Sym found, ((Native _ | Thunk _) as callable)), tail)
        when name = found ->
        (* Allocate options and list cells BEFORE the final identity check. *)
        let binding = E.function_cell name, observation.original, Some callable in
        binding :: bindings rest tail
    | _ -> fail "native promotion plugin returned an invalid callable registry" in
  let replacements = bindings artifact.targets exported in
  validate_replacements replacements;
  (* No user callbacks, metadata, allocation, or validation in this publication
     loop. In particular, never call N.install then try to roll it back. *)
  publish_replacements replacements;
  state.promoted <- state.promoted + List.length replacements;
  List.map fst artifact.targets

let promote state ~config ~names ~output_dir =
  ignore (publish state (prepare state ~config ~names ~output_dir))
