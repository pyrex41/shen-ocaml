(** Restricted function-only .shen -> OCaml -> .cmxs compiler.

    Requires an already booted native kernel. Function-only [define] forms,
    standard cons/literal/variable patterns, core KL expression forms, [/ .]
    (spelled [/.]), the explicitly listed runtime calls, and calls to functions
     defined in this file are accepted. No packages, macros, datatypes,
    standalone declarations, arbitrary top-level expressions, or custom pattern hooks.
    Validation precedes translation. Function bodies are never run by compile.
    Untyped translation uses the kernel's non-installing [shen.shen->kl-h], NOT
    [shen.shen->kl], [eval], [load], or interception/replay of [eval-kl]. Typed
    modules use a fork-isolated built-in type theory and [declare]/[shen.typecheck].
     Declare dynamically compiles compiler-owned signature closures via eval-kl
     only in the isolated staging child. Loading installs native signature
     predicates without declare, eval-kl or ambient type hooks; user function
     bodies are always native. [translate] remains strictly untyped;
     [translate_module] returns KL plus (name, type, predicate AST) triples.

    Compatible codegen preserves ordered redefinitions and late-bound calls.
    [compile_file] and [load] are deliberately separate: compilation cost is
    never hidden in a call to a user function. Loading is trusted native code,
    not a sandbox. Plugins must match the host's exact runtime/compiler ABI. *)
open Shen.Runtime.Value
module N = Shen.Runtime.Native
module Registry = Shen.Runtime.Native_artifact

exception Build_error of string
let fail format = Printf.ksprintf (fun message -> raise (Build_error message)) format
let filesystem action =
  try action () with Sys_error message -> fail "native artifact filesystem error: %s" message

type artifact = { key : string; source_path : string; plugin_path : string }
type config = { ocamlopt : string; include_dirs : string list }

let read path =
  filesystem (fun () ->
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel)))

let write path contents =
  filesystem (fun () ->
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents))

let rec list = function
  | Nil -> []
  | Cons (head, tail) -> head :: list tail
  | _ -> fail "restricted native compiler: improper source list"

let as_list values = List.fold_right (fun h t -> Cons (h, t)) values Nil
let variable name = String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z'

let runtime_calls = [
  "+"; "-"; "*"; "/"; "="; "<"; ">"; "<="; ">=";
  "cons"; "hd"; "tl"; "cons?"; "number?"; "string?"; "symbol?";
  "boolean?"; "empty?"; "not"; "simple-error"; "error-to-string";
  "value"; "set"; "str"; "cn"; "n->string"; "string->n"
]

let runtime_arities = [
  "+", 2; "-", 2; "*", 2; "/", 2; "=", 2; "<", 2; ">", 2; "<=", 2; ">=", 2;
  "cons", 2; "hd", 1; "tl", 1; "cons?", 1; "number?", 1; "string?", 1; "symbol?", 1;
  "boolean?", 1; "empty?", 1; "not", 1; "simple-error", 1; "error-to-string", 1;
  "value", 1; "set", 2; "str", 1; "cn", 2; "n->string", 1; "string->n", 1
]

let reserved_forms = ["if"; "and"; "or"; "do"; "let"; "lambda"; "freeze"; "thaw";
  "trap-error"; "cond"; "type"; "define"; "defun"]

let rec pattern = function
  | Sym "{" | Sym "}" -> fail "typed definitions are not supported by the restricted native compiler"
  | Sym _ | Int _ | Float _ | Str _ | Bool _ | Nil -> ()
  | Cons _ as value -> (match list value with
      | [Sym "cons"; h; t] -> pattern h; pattern t
      | _ -> fail "unsupported native function pattern: %s" (to_string value))
  | value -> fail "unsupported native function pattern: %s" (to_string value)

let rec expression arities value =
  let recurse = expression arities in
  let rebuild head args = as_list (head :: List.map recurse args) in
  match value with
  | Sym "{" | Sym "}" -> fail "typed expressions are not supported"
  | Sym _ | Int _ | Float _ | Str _ | Bool _ | Nil -> value
  | Cons _ -> (match list value with
      | [Sym ("lambda" | "/."); Sym parameter; body] when variable parameter ->
          as_list [Sym "lambda"; Sym parameter; recurse body]
      | [Sym "let"; Sym parameter; init; body] when variable parameter ->
          as_list [Sym "let"; Sym parameter; recurse init; recurse body]
       | Sym "cond" :: clauses ->
           let rec lower = function
             | [] -> as_list [Sym "simple-error"; Str "cond: no true clause"]
             | clause :: rest -> (match list clause with
                 | [test; body] -> as_list [Sym "if"; recurse test; recurse body; lower rest]
                 | _ -> fail "cond requires two-element clauses")
           in lower clauses
      | Sym head :: args when List.mem (head, List.length args)
          ["if", 3; "and", 2; "or", 2; "do", 2; "freeze", 1;
           "thaw", 1; "trap-error", 2] -> rebuild (Sym head) args
       | Sym head :: args when List.mem_assoc head arities || List.mem_assoc head runtime_arities ->
           let expected = match List.assoc_opt head arities with
             | Some arity -> arity
             | None -> List.assoc head runtime_arities in
           if List.length args <> expected then
             fail "restricted native compiler requires saturated named calls: %s expects %d arguments (use an explicit lambda for currying)" head expected;
           rebuild (Sym head) args
       | Sym head :: args when variable head ->
          rebuild (Sym head) args
      | (Cons _ as head) :: args -> rebuild (recurse head) args
      | _ -> fail "unsupported native expression (macros are not expanded): %s" (to_string value))
  | _ -> fail "unsupported native expression: %s" (to_string value)

let definition_name value = match list value with
  | Sym "define" :: Sym name :: _ when not (variable name) ->
      if List.mem name runtime_calls || List.mem name reserved_forms || String.starts_with ~prefix:"shen." name then
        fail "restricted native compiler cannot redefine reserved function %s" name;
      (match N.call "shen.sysfunc?" [Sym name] with
      | Bool false -> ()
      | _ -> fail "restricted native compiler cannot redefine system function %s" name);
      name
  | _ -> fail "restricted native compiler accepts only untyped define forms: %s" (to_string value)

let validate_definition arities value = match list value with
  | Sym "define" :: Sym name :: rules ->
      let rec loop = function
        | [] -> []
        | (Sym ("->" | "<-") as arrow) :: body :: rest ->
             let body = expression arities body in
            (match rest with
             | Sym "where" :: guard :: rest -> arrow :: body :: Sym "where" :: expression arities guard :: loop rest
            | _ -> arrow :: body :: loop rest)
        | p :: rest -> pattern p; p :: loop rest
      in
      as_list (Sym "define" :: Sym name :: loop rules)
  | _ -> assert false

let check_registries () =
  List.iter (fun (name, baseline) ->
    match Shen.Runtime.Env.get_global name, Shen.Runtime.Env.get_global baseline with
    | Some current, Some initial when current == initial -> ()
    | _ -> fail "restricted native compilation requires the boot-time %s registry (custom macros/source-form handlers are unsupported)" name)
    ["*macros*", "shen-ocaml.*native-macro-baseline*";
     "shen.*source-form-handlers*", "shen-ocaml.*native-source-form-baseline*"];
  List.iter (fun name -> match Shen.Runtime.Env.get_global name with
    | Some (Bool false) -> ()
    | _ -> fail "native compilation requires %s = false" name)
     ["shen.*custom-pattern-compiler*"; "shen.*custom-pattern-reducer*"; "shen.*factorise?*"]

let validated_forms forms =
  let names = List.map definition_name forms in
  let arities = List.map2 (fun name form ->
    let rec count n = function
      | Sym ("->" | "<-") :: _ -> n
      | _ :: rest -> count (n + 1) rest
      | [] -> fail "definition %s has no rule arrow" name
    in
    let rules = match list form with _ :: _ :: rules -> rules | _ -> assert false in
    name, count 0 rules) names forms in
  List.iter (fun (name, arity) ->
    if List.exists (fun (other, count) -> other = name && count <> arity) arities then
      fail "restricted native compiler does not support changing arity of %s within a module" name) arities;
  List.map (validate_definition arities) forms

let translate_validated validated =
  List.map (fun form ->
    let kl = N.call "shen.shen->kl-h" [form] in
    match Shen.Interp.Eval.value_to_kl_expr kl with
    | Shen.Kl.Ast.KLApp (KLSym "defun", _) as form -> form
     | _ -> fail "kernel translation did not produce a defun") validated

let translate_forms forms = translate_validated (validated_forms forms)

(** Historical API: intentionally remains the strictly untyped translator. *)
let translate text =
  check_registries ();
  translate_forms (list (N.call "read-from-string-unprocessed" [Str text]))

(* A deliberately small grammar: no synonyms, datatype predicates, modes or
   arbitrary terms in signatures. Arrows are right-associated by the kernel. *)
let rec check_type value = match value with
  | Sym name when variable name || List.mem name ["number"; "string"; "symbol"; "boolean"] -> ()
  | Cons _ -> (match list value with
      | [Sym "list"; item] -> check_type item
      | first :: Sym "-->" :: rest when rest <> [] ->
          check_type first;
          (match rest with [last] -> check_type last | _ -> check_type (as_list rest))
      | [Sym "-->"; result] -> check_type result
      | _ -> fail "unsupported restricted native type: %s" (to_string value))
  | _ -> fail "unsupported restricted native type: %s" (to_string value)

let split_signature form = match list form with
  | Sym "define" :: Sym name :: Sym "{" :: rest ->
      let rec split acc = function
        | Sym "}" :: rules ->
            let signature = as_list (List.rev acc) in
            check_type signature;
            Some (name, signature, as_list (Sym "define" :: Sym name :: rules))
        | token :: rest -> split (token :: acc) rest
        | [] -> fail "missing } in native definition %s" name in
      split [] rest
  | _ -> None

(* No rollback over mutable vectors/dicts/closures is reliable. The child owns
   every declaration, prolog allocation and gensym update, including failures.
   Only literal signatures and KL ASTs cross the pipe (never runtime closures).
   This API requires a single-threaded Unix native compiler host. *)
let isolated action =
  let input, output = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close input;
      let channel = Unix.out_channel_of_descr output in
      let result = try Result.Ok (action ()) with exn -> Result.Error (Printexc.to_string exn) in
      (try Marshal.to_channel channel result []; close_out channel; Unix._exit 0
       with _ -> Unix._exit 1)
  | pid ->
      Unix.close output;
      let channel = Unix.in_channel_of_descr input in
      let result = try Some (Marshal.from_channel channel) with _ -> None in
      close_in_noerr channel;
      let rec wait () = try snd (Unix.waitpid [] pid) with
        | Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
      match wait (), result with
      | Unix.WEXITED 0, Some (Result.Ok result) -> result
      | Unix.WEXITED 0, Some (Result.Error message) -> fail "typed native staging failed: %s" message
      | _ -> fail "typed native staging process failed"

let translate_module text =
  check_registries ();
  let forms = list (N.call "read-from-string-unprocessed" [Str text]) in
  let signatures = List.map split_signature forms in
  if List.for_all Option.is_none signatures then translate_forms forms, []
  else isolated (fun () ->
    let entries = List.map (function Some entry -> entry
      | None -> fail "native modules must be wholly typed or wholly untyped") signatures in
    let names = List.map (fun (name, _, _) -> name) entries in
    if List.length (List.sort_uniq String.compare names) <> List.length names then
      fail "typed native modules cannot contain duplicate definitions";
    (* Validate the original names and all bodies BEFORE any declarations. *)
    let bodies = List.map (fun (_, _, body) -> body) entries in
    let normalized = validated_forms bodies in
    let kl = translate_validated normalized in
    let typed_normalized = List.map2 (fun (name, signature, _) body ->
      let rules = match list body with _ :: _ :: rules -> rules | _ -> assert false in
      as_list (Sym "define" :: Sym name :: Sym "{" ::
        (list signature @ (Sym "}" :: rules)))) entries normalized in
    (* Never invoke host datatype rules, synonym hooks or user signature closures.
       Keep the ordinary built-in type theory, independently of host tc mode. *)
    List.iter (fun name -> Shen.Runtime.Env.set_global name Nil)
      ["shen.*datatypes*"; "shen.*synonyms*"; "shen.*extraspecial*"];
    Shen.Runtime.Env.set_global "shen.*demodulation-function*" (N.function1 Fun.id);
    Shen.Runtime.Env.set_global "shen.*spy*" (Bool false);
    Shen.Runtime.Env.set_global "shen.*shen-type-theory-enabled?*" (Bool true);
    ignore (N.call "shen.initialise-signedfuncs" []);
    let metadata = List.map2 (fun original (name, _, _) ->
      match list (N.call "shen.typetable" [original]) with
      | [Sym found; signature] when found = name -> name, signature
      | _ -> fail "kernel did not extract signature for %s" name) forms entries in
    List.iter (fun (name, signature) -> ignore (N.call "declare" [Sym name; signature])) metadata;
    List.iter (fun original ->
      match N.call "shen.typecheck" [original; Sym "A"] with
      | Bool false -> fail "type error in native definition %s" (definition_name original)
      | Error message -> fail "native typecheck failed: %s" message
      | _ -> ()) typed_normalized;
    let predicates = List.map (fun (name, signature) ->
      let predicate = N.call "shen.prolog-abstraction" [signature]
        |> Shen.Interp.Eval.value_to_kl_expr in
      match predicate with
      | Shen.Kl.Ast.KLApp (KLSym "lambda", _) -> name, signature, predicate
      | _ -> fail "kernel did not produce a signature lambda for %s" name) metadata in
    kl, predicates)

let emit_file ?(mode = Shen.Codegen.Native_gen.Compatible) ~output_dir input =
  let output_dir = if Filename.is_relative output_dir then Filename.concat (Sys.getcwd ()) output_dir else output_dir in
  if not (Sys.file_exists output_dir && Sys.is_directory output_dir) then
    fail "native output directory does not exist: %s" output_dir;
   let forms, types = translate_module (read input) in
  let generated = Shen.Codegen.Native_gen.compile ~mode forms in
  let metadata = Buffer.create 4096 in
  Buffer.add_string metadata "\n(* Compiler-owned signature predicates are native closures, not eval-kl. *)\n";
  List.iteri (fun index (_, _, predicate) ->
    Printf.bprintf metadata "module Native_signature_%d = struct\n%s\nend\n" index
      (Shen.Codegen.Native_gen.compile [predicate])) types;
  Buffer.add_string metadata
     "\n(* KL below is source metadata for ps, never an execution fallback. *)\nlet install_bodies = run\nlet run () =\n";
  if types <> [] then (
    Buffer.add_string metadata "  let _ = Shen.Runtime.Native_artifact.install_types [\n";
    List.iteri (fun index (name, signature, _) ->
      Printf.bprintf metadata "    (%S, (let open Shen.Kl.Ast in Shen.Interp.Compiled.literal " name;
      Shen.Codegen.Ocaml_gen.emit_expr metadata (Shen.Interp.Eval.value_to_kl_expr signature);
      Printf.bprintf metadata "), Native_signature_%d.run ());\n" index) types;
    Buffer.add_string metadata "  ] in\n");
   Buffer.add_string metadata "  let result = install_bodies () in\n";
  List.iter (fun form ->
    let name = match form with
      | Shen.Kl.Ast.KLApp (KLSym "defun", KLSym name :: _) -> name
      | _ -> assert false in
    Printf.bprintf metadata "  let _ = N.call \"shen.record-kl\" [Sym %S; (let open Shen.Kl.Ast in Shen.Interp.Compiled.literal " name;
    Shen.Codegen.Ocaml_gen.emit_expr metadata form;
    Buffer.add_string metadata ")] in\n") forms;
  Buffer.add_string metadata "  result\n";
  let generated = generated ^ Buffer.contents metadata in
  let key = Digest.to_hex (Digest.string generated) in
  let stem = "shen_user_" ^ key in
  let source_path = Filename.concat output_dir (stem ^ ".ml") in
  let plugin_path = Filename.concat output_dir (stem ^ ".cmxs") in
  write source_path (generated ^ Printf.sprintf
    "\nlet () = Shen.Runtime.Native_artifact.register %S run\n" key);
  { key; source_path; plugin_path }

let command program arguments =
  let argv = Array.of_list (program :: arguments) in
  let pid = try Unix.create_process program argv Unix.stdin Unix.stdout Unix.stderr
    with Unix.Unix_error (error, _, _) ->
      fail "cannot execute native compiler %s: %s" program (Unix.error_message error) in
  let rec wait () = try snd (Unix.waitpid [] pid) with
    | Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  match wait () with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> fail "native compiler %s exited with status %d" program code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> fail "native compiler %s interrupted by signal %d" program signal

let compile_file ?mode ~config ~output_dir input =
  if config.include_dirs = [] then fail "native compilation requires explicit runtime include directories";
  List.iter (fun path -> if not (Sys.file_exists path && Sys.is_directory path) then
    fail "native runtime include directory does not exist: %s" path) config.include_dirs;
  let artifact = emit_file ?mode ~output_dir input in
  let includes = List.concat_map (fun path -> ["-I"; path]) config.include_dirs in
  command config.ocamlopt (includes @ ["-shared"; "-o"; artifact.plugin_path; artifact.source_path]);
  if not (Sys.file_exists artifact.plugin_path) then fail "native compiler produced no plugin: %s" artifact.plugin_path;
  artifact

let load artifact =
  if not Dynlink.is_native then fail "native artifacts require a native-code host";
  let run = match Registry.find artifact.key with
    | Some run -> run
    | None ->
        (try Dynlink.loadfile (Dynlink.adapt_filename artifact.plugin_path) with
        | Dynlink.Error error -> fail "cannot load native artifact %s: %s" artifact.plugin_path (Dynlink.error_message error));
        match Registry.find artifact.key with
        | Some run -> run
        | None -> fail "plugin did not register expected native artifact %s" artifact.key
  in
  run ()

(** Reopen a previously compiled artifact in a freshly booted native host.
    Keep the generated content-qualified basename when moving plugins. *)
let load_file plugin_path =
  let basename = Filename.basename plugin_path in
  let prefix = "shen_user_" and suffix = ".cmxs" in
  if not (String.starts_with ~prefix basename && String.ends_with ~suffix basename)
     || String.length basename <> String.length prefix + 32 + String.length suffix then
    fail "expected a content-qualified shen_user_<digest>.cmxs artifact: %s" plugin_path;
  let key = String.sub basename (String.length prefix) 32 in
  if not (String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) key) then
    fail "invalid native artifact digest: %s" plugin_path;
  load { key; plugin_path; source_path = Filename.chop_extension plugin_path ^ ".ml" }
