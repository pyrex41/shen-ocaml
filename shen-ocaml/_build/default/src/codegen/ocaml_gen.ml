(** KL AST → OCaml source (constructor literals). Used for AOT scaffolding and
    embedding parsed .kl as data the runtime can load without shipping the .kl. *)

open Kl.Ast

let ocaml_keywords =
  [
    "and";
    "as";
    "assert";
    "asr";
    "begin";
    "class";
    "constraint";
    "do";
    "done";
    "else";
    "end";
    "exception";
    "external";
    "false";
    "for";
    "fun";
    "function";
    "functor";
    "if";
    "in";
    "include";
    "inherit";
    "initializer";
    "land";
    "lazy";
    "lor";
    "lsl";
    "lsr";
    "lxor";
    "match";
    "method";
    "mod";
    "module";
    "mutable";
    "new";
    "object";
    "of";
    "open";
    "or";
    "private";
    "rec";
    "sig";
    "struct";
    "then";
    "true";
    "try";
    "type";
    "val";
    "virtual";
    "when";
    "while";
  ]

let keyword_set =
  let h = Hashtbl.create 64 in
  List.iter (fun k -> Hashtbl.add h k ()) ocaml_keywords;
  h

(** Map a Shen / KL symbol name to a valid OCaml lowercase identifier. *)
let mangle name =
  let buf = Buffer.create (String.length name + 8) in
  Buffer.add_string buf "k_";
  String.iter
    (fun c ->
      let ok =
        match c with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
        | _ -> false
      in
      if ok then Buffer.add_char buf (Char.lowercase_ascii c)
      else Printf.bprintf buf "_u%02X" (Char.code c))
    name;
  let s = Buffer.contents buf in
  if Hashtbl.mem keyword_set s then s ^ "_shen" else s

let escaped_string_for_ml s =
  let b = Buffer.create (String.length s + 8) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 32 || Char.code c > 126 ->
          Printf.bprintf b "\\%03d" (Char.code c)
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let float_literal f =
  let s = Printf.sprintf "%.17g" f in
  if String.contains s '.' || String.contains s 'e' || String.contains s 'E' then s
  else s ^ "."

let rec emit_expr b e =
  match e with
  | KLInt i ->
      (* Unary minus must not sit next to [KLInt]: [(KLInt -1)] parses as subtract. *)
      if i >= 0 then Printf.bprintf b "(KLInt %d)" i
      else Printf.bprintf b "(KLInt (%d))" i
  | KLFloat f ->
      let lit = float_literal f in
      if lit <> "" && lit.[0] = '-' then Printf.bprintf b "(KLFloat (%s))" lit
      else Printf.bprintf b "(KLFloat %s)" lit
  | KLStr s -> Printf.bprintf b "(KLStr %s)" (escaped_string_for_ml s)
  | KLSym s -> Printf.bprintf b "(KLSym %s)" (escaped_string_for_ml s)
  | KLBool true -> Buffer.add_string b "(KLBool true)"
  | KLBool false -> Buffer.add_string b "(KLBool false)"
  | KLNil -> Buffer.add_string b "KLNil"
  | KLCons (h, t) ->
      Buffer.add_string b "(KLCons (";
      emit_expr b h;
      Buffer.add_string b ", ";
      emit_expr b t;
      Buffer.add_string b "))"
  | KLVec arr ->
      Buffer.add_string b "(KLVec [|";
      Array.iteri
        (fun i x ->
          if i > 0 then Buffer.add_string b "; ";
          emit_expr b x)
        arr;
      Buffer.add_string b "|])"
  | KLApp (f, args) ->
      Buffer.add_string b "(KLApp (";
      emit_expr b f;
      Buffer.add_string b ", [";
      List.iteri
        (fun i a ->
          if i > 0 then Buffer.add_string b "; ";
          emit_expr b a)
        args;
      Buffer.add_string b "]))"
  | KLLambda (x, body) ->
      Printf.bprintf b "(KLLambda (%s, " (escaped_string_for_ml x);
      emit_expr b body;
      Buffer.add_string b "))"
  | KLLet (x, ve, body) ->
      Printf.bprintf b "(KLLet (%s, " (escaped_string_for_ml x);
      emit_expr b ve;
      Buffer.add_string b ", ";
      emit_expr b body;
      Buffer.add_string b "))"
  | KLIf (c, t, e') ->
      Buffer.add_string b "(KLIf (";
      emit_expr b c;
      Buffer.add_string b ", ";
      emit_expr b t;
      Buffer.add_string b ", ";
      emit_expr b e';
      Buffer.add_string b "))"
  | KLDefun (name, params, body) ->
      Printf.bprintf b "(KLDefun (%s, [" (escaped_string_for_ml name);
      List.iteri
        (fun i p ->
          if i > 0 then Buffer.add_string b "; ";
          Buffer.add_string b (escaped_string_for_ml p))
        params;
      Buffer.add_string b "], ";
      emit_expr b body;
      Buffer.add_string b "))"

let emit_forms_module b ~source_path forms =
  Printf.bprintf b "(* Generated from %s — do not edit by hand. *)\n" source_path;
  Buffer.add_string b "(* @generated *)\n\n";
  Buffer.add_string b "open Shen.Kl.Ast\n\n";
  Buffer.add_string b "let forms : kl_expr list = [\n";
  List.iter
    (fun e ->
      Buffer.add_string b "  ";
      emit_expr b e;
      Buffer.add_string b ";\n")
    forms;
  Buffer.add_string b "]\n"

let compile_kl_to_ocaml kl_path out_path =
  let forms =
    try Kl.Parser.parse_file kl_path with
    | Kl.Parser.Parse_error msg ->
        failwith (Printf.sprintf "parse %s: %s" kl_path msg)
  in
  let b = Buffer.create 4096 in
  emit_forms_module b ~source_path:kl_path forms;
  let oc = open_out_bin out_path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Buffer.contents b))

(** Emit one module containing every kernel file's top-level forms, in boot order
    (see {!Interp.Boot.kernel_files}). Used for AOT compile-smoke of the full kernel. *)
let emit_kernel_bundle ~kernel_dir basenames out_path =
  let b = Buffer.create (1 lsl 20) in
  Buffer.add_string b
    "(* Generated bundle of kernel KL forms — do not edit by hand. *)\n";
  Buffer.add_string b "(* @generated *)\n\nopen Shen.Kl.Ast\n\n";
  Buffer.add_string b
    "let kernel_files_in_boot_order : (string * kl_expr list) list = [\n";
  List.iter
    (fun base ->
      let path = Filename.concat kernel_dir base in
      let forms =
        try Kl.Parser.parse_file path with
        | Kl.Parser.Parse_error msg ->
            failwith (Printf.sprintf "parse %s: %s" path msg)
      in
      Printf.bprintf b "  (%S, [\n" base;
      List.iter
        (fun e ->
          Buffer.add_string b "    ";
          emit_expr b e;
          Buffer.add_string b ";\n")
        forms;
      Buffer.add_string b "  ]);\n")
    basenames;
  Buffer.add_string b "]\n";
  let oc = open_out_bin out_path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Buffer.contents b))

let test_codegen () =
  let b = Buffer.create 64 in
  emit_expr b (KLApp (KLSym "+", [ KLInt 1; KLInt 2 ]));
  Printf.printf "sample: %s\n" (Buffer.contents b)
