(** 
 * src/runtime/primitives.ml
 * KL primitive functions for Shen-OCaml.
 * Implements the porting-guide primitive set: 45 registered here plus native [hash]
 * (see [install_native_hash]) = 46 total.
 *)

open Value
open Env

(* Curried primitive: fewer args than arity yields a closure collecting the rest. *)
let make_closure arity f =
  let invoke args = Native.checked (f args) in
  match arity with
  | 0 -> Native.function0 (fun () -> invoke [])
  | 1 -> Native.function1 (fun a -> invoke [a])
  | 2 -> Native.function2 (fun a b -> invoke [a; b])
  | 3 -> Native.function3 (fun a b c -> invoke [a; b; c])
  | 4 -> Native.function4 (fun a b c d -> invoke [a; b; c; d])
  | 5 -> Native.function5 (fun a b c d e -> invoke [a; b; c; d; e])
  | 6 -> Native.function6 (fun a b c d e f -> invoke [a; b; c; d; e; f])
  | 7 -> Native.function7 (fun a b c d e f g -> invoke [a; b; c; d; e; f; g])
  | 8 -> Native.function8 (fun a b c d e f g h -> invoke [a; b; c; d; e; f; g; h])
  | _ -> Native.function_ arity invoke

(* Primitive implementations *)
let intern_decimal = Str.regexp "^[0-9]+\\(\\.[0-9]*\\)?\\([eE][+-]?[0-9]+\\)?$"

let pr_intern = Native.function1 (function
  | Str "true" -> true_value
  | Str "false" -> false_value
  | Str s when String.length s > 1 && Str.string_match intern_decimal s 0 ->
      (match int_of_string_opt s with
      | Some i -> Int i
      | None -> (match float_of_string_opt s with
          | Some f -> Float f
          | None -> Sym s))
  | Str s -> Sym s
  | _ -> raise (User_error "intern: string expected")
)

let pr_plus = Native.function2 Native.add

let pr_mult = Native.function2 Native.mul

let pr_minus = Native.function2 Native.sub

let pr_set = Native.function2 Native.set

let pr_value = Native.function1 Native.value

let pr_simple_error = Native.function1 (function
  | Str msg -> raise (User_error msg)
  | Sym s -> raise (User_error s)
  | _ -> raise (User_error "simple-error: string expected")
)

let pr_tc = make_closure 1 (function
  | [Sym "+" ] -> 
      set_global "*tc*" (Bool true);
      Bool true
  | [Sym "-"] -> 
      set_global "*tc*" (Bool false);
      Bool false
  | _ -> Error "tc: + or - expected"
)

let pr_equal = Native.function2 Native.eq

let pr_cons = Native.function2 Native.cons

let pr_hd = Native.function1 Native.hd

let pr_tl = Native.function1 Native.tl

let pr_numberp = Native.function1 (function
  | Int _ | Float _ -> true_value
  | _ -> false_value
)

let pr_consq = Native.function1 Native.consp

let pr_stringp = Native.function1 (function
  | Str _ -> true_value
  | _ -> false_value
)

let pr_vectorp = Native.function1 (function
  | Vec _ -> true_value
  | _ -> false_value
)

(** Kernel [vector?] is redefined in [sys.kl] using [absvector?]. The KL sources
    never define [absvector?]; it must be a primitive (same discriminant as
    [absvector] / [@p] tuples). *)
let pr_absvectorp = pr_vectorp

let pr_absvector = Native.function1 (function
  | Int n when n >= 0 -> Vec (Array.make n Nil)
  | Int _ -> raise (User_error "absvector: non-negative integer expected")
  | _ -> raise (User_error "absvector: integer expected")
)

let pr_str = Native.function1 (fun v -> Str (to_string v))

let pr_gt = Native.function2 Native.gt

let pr_lt = Native.function2 Native.lt

let pr_lte = Native.function2 Native.lte

let pr_gte = Native.function2 Native.gte

let pr_div = make_closure 2 (function
  | [Int a; Int b] ->
      if b = 0 then Error "/: division by zero"
      else Float (float_of_int a /. float_of_int b)
  | [Float a; Float b] ->
      if b = 0. then Error "/: division by zero" else Float (a /. b)
  | [Int a; Float b] ->
      if b = 0. then Error "/: division by zero"
      else Float (float_of_int a /. b)
  | [Float a; Int b] ->
      if b = 0 then Error "/: division by zero"
      else Float (a /. float_of_int b)
  | _ -> Error "/: numbers expected"
)

let pr_cn = Native.function2 (fun a b -> match a, b with
  | Str a, Str b -> Str (a ^ b)
  | _ -> raise (User_error "cn: two strings expected")
)

let pr_pos = Native.function2 (fun s i -> match s, i with
  | Str s, Int i ->
      if i < 0 || i >= String.length s then raise (User_error "pos: index out of bounds")
      else Str (String.make 1 s.[i])
  | _ -> raise (User_error "pos: string and integer expected")
)

let pr_tlstr = Native.function1 (function
  | Str s ->
      if s = "" then raise (User_error "tlstr: empty string")
      else Str (String.sub s 1 (String.length s - 1))
  | _ -> raise (User_error "tlstr: string expected")
)

let pr_n_to_string = Native.function1 (function
  | Int n ->
      if n < 0 || n > 255 then raise (User_error "n->string: byte 0..255 expected")
      else Str (String.make 1 (Char.chr n))
  | _ -> raise (User_error "n->string: integer expected")
)

let pr_string_to_n = Native.function1 (function
  | Str s ->
      if String.length s <> 1 then
        raise (User_error "string->n: single-character string expected")
      else Int (Char.code s.[0])
  | _ -> raise (User_error "string->n: string expected")
)

let pr_symbolp = Native.function1 (function
  | Sym _ -> true_value
  | _ -> false_value
)

let pr_booleanp = Native.function1 (function
  | Bool _ -> true_value
  | _ -> false_value
)

let pr_open = make_closure 2 (function
  | [Str path; Sym dir] when dir = "in" || dir = "out" ->
    let home = match get_global "*home-directory*" with
      | Some (Str s) -> s
      | _ -> ""
    in
    let full_path = home ^ path in
    (try
      if dir = "in" then Stream (In_chan (open_in_bin full_path))
      else Stream (Out_chan (open_out_bin full_path))
    with Sys_error msg -> Error ("open: " ^ msg))
  | _ -> Error "open: filename and direction in|out expected"
)

let pr_close = make_closure 1 (function
  | [Stream (In_chan ch)] ->
      close_in ch;
      Nil
  | [Stream (Out_chan ch)] ->
      close_out ch;
      Nil
  | _ -> Error "close: stream expected"
)

let pr_read_byte = make_closure 1 (function
  | [Stream (In_chan ch)] -> (
      try Int (input_byte ch) with End_of_file -> Int (-1))
  | _ -> Error "read-byte: input stream expected"
)

(* ShenOSKernel 43.1 uses the public character-stream hooks. OCaml's port
   currently exposes byte streams, so the capability is false and the
   character operations remain callable with an explicit error. *)
let pr_char_stream = make_closure 1 (fun _ -> Bool false)

let pr_read_unit_string = make_closure 1 (fun _ ->
  Error "read-unit-string: character streams unsupported")

let pr_write_string = make_closure 2 (fun _ ->
  Error "write-string: character streams unsupported")

let pr_write_byte = make_closure 2 (function
  | [Int b; Stream (Out_chan ch)] ->
      if b < 0 || b > 255 then Error "write-byte: byte 0..255 expected"
      else (
        output_byte ch b;
        if ch == stdout || ch == stderr then flush ch;
        Int b)
  | _ -> Error "write-byte: byte and output stream expected"
)

let pr_get_time = make_closure 1 (function
  | [Sym "unix"] -> Float (Unix.gettimeofday ())
  | [Sym "run"] -> Float (Sys.time ())
  | _ -> Error "get-time: unix or run expected"
)

let pr_type = make_closure 1 (function
  | [x] -> x
  | _ -> Error "type: one argument expected"
)

let pr_eval_kl = make_closure 1 (function
  | [v] -> eval_kl_from_value_hook v
  | _ -> Error "eval-kl: one argument expected"
)

let pr_if = make_closure 3 (function
  | [cond; thn; els] ->
      if Value.is_true cond then thn else els
  | _ -> Error "if: 3 arguments expected"
)

let pr_and = make_closure 2 (function
  | [Bool a; Bool b] -> of_bool (a && b)
  | _ -> Bool false
)

let pr_or = make_closure 2 (function
  | [Bool a; Bool b] -> of_bool (a || b)
  | _ -> Bool false
)

let pr_address_get = Native.function2 Native.address_get

let pr_address_set = Native.function3 Native.address_set

let pr_apply = make_closure 2 (function
  | [Closure cl; arg] -> cl [arg]
  | [Native fn; arg] -> fn.invoke [arg]
  | [Thunk _ as fn; arg] -> Native.apply1 fn arg
  | [Sym name; arg] ->
      (match get_fn name with
       | Some (Closure cl) -> cl [arg]
        | Some (Native fn) -> fn.invoke [arg]
        | Some (Thunk _ as fn) -> Native.apply1 fn arg
       | Some v -> v
       | None -> Error ("unbound function: " ^ name))
  | _ -> Error "apply: function and argument expected"
)

let pr_error = make_closure 1 (function
  | [Str msg] -> Error msg
  | [v] -> Error (to_string v)
  | _ -> Error "error: argument expected"
)

let pr_error_to_string = make_closure 1 (function
  | [Error msg] -> Str msg
  | _ -> Error "error-to-string: error value expected"
)

let register name prim =
  set_fn name prim

(** Names and arities of functions installed by [initialise]. After kernel boot,
    [register_fn_metadata] can populate [*property-vector*] so [(fn name)] works. *)
let primitive_metadata_entries : (string * int) list =
  [
    ("intern", 1);
    ("+", 2);
    ("*", 2);
    ("-", 2);
    ("set", 2);
    ("value", 1);
    ("simple-error", 1);
    ("tc", 1);
    ("=", 2);
    ("cons", 2);
    ("hd", 1);
    ("tl", 1);
    ("number?", 1);
    ("cons?", 1);
    ("string?", 1);
    ("vector?", 1);
    ("absvector?", 1);
    ("str", 1);
    (">", 2);
    ("<", 2);
    ("<=", 2);
    (">=", 2);
    ("/", 2);
    ("cn", 2);
    ("pos", 2);
    ("tlstr", 1);
    ("n->string", 1);
    ("string->n", 1);
    ("symbol?", 1);
    ("boolean?", 1);
    ("open", 2);
    ("close", 1);
    ("read-byte", 1);
    ("char-stream?", 1);
    ("read-unit-string", 1);
    ("write-string", 2);
    ("write-byte", 2);
    ("get-time", 1);
    ("type", 1);
    ("eval-kl", 1);
    ("if", 3);
    ("and", 2);
    ("or", 2);
    ("absvector", 1);
    ("<-address", 2);
    ("address->", 3);
    ("apply", 2);
    ("error", 1);
    ("error-to-string", 1);
  ]

let register_all_metadata () =
  List.iter
    (fun (name, arity) ->
      match get_fn name with
      | Some v -> register_fn_metadata name arity v
      | None -> ())
    primitive_metadata_entries

let native_overwrite name prim =
  set_fn name prim;
  print_endline ("Native overwrite registered for: " ^ name)

let native_overwrite_quiet name prim = set_fn name prim

(** The kernel implements [hash] via [shen.mod] and [shen.multiples], which doubles
    [hd] until [hd > key]. Large [shen.hashkey] values make multiplying [hd] by 2
    overflow on 63-bit ints; [hd] becomes negative and the comparison never succeeds,
    causing non-termination. Use bounded native [mod] instead.

    Must run [install_native_hash] before [shen.initialise]: [*property-vector*] is a
    hash table; if we swap [hash] after the kernel fills the dict, buckets no longer
    match and [(fn get)], [(fn trap-error)], etc. see missing [shen.lambda-form] entries.

    After init, call [register_hash_fn_metadata] so [(fn hash)] works like other fns. *)
let make_native_hash () =
  let pos_mod h m =
    let r = h mod m in
    if r < 0 then r + m else r
  in
  Native.function2 (fun value modulus -> match modulus with
    | Int m when m > 0 ->
        let h = Value.hash value in
        let r = pos_mod h m in
        Int (if r = 0 then 1 else r)
    | _ -> raise (User_error "hash: value and positive modulus expected"))

let install_native_hash () =
  native_overwrite_quiet "hash" (make_native_hash ())

let register_hash_fn_metadata () =
  match get_fn "hash" with
  | Some h -> register_fn_metadata "hash" 2 h
  | None -> ()

let initialise ?(verbose = true) () =
  set_global "*stinput*" (Stream (In_chan stdin));
  set_global "*stoutput*" (Stream (Out_chan stdout));
  register "intern" pr_intern;
  register "+" pr_plus;
  register "*" pr_mult;
  register "-" pr_minus;
  register "set" pr_set;
  register "value" pr_value;
  register "simple-error" pr_simple_error;
  register "tc" pr_tc;
  register "=" pr_equal;
  register "cons" pr_cons;
  register "hd" pr_hd;
  register "tl" pr_tl;
  register "number?" pr_numberp;
  register "cons?" pr_consq;
  register "string?" pr_stringp;
  register "vector?" pr_vectorp;
  register "absvector?" pr_absvectorp;
  register "str" pr_str;
  register ">" pr_gt;
  register "<" pr_lt;
  register "<=" pr_lte;
  register ">=" pr_gte;
  register "/" pr_div;
  register "cn" pr_cn;
  register "pos" pr_pos;
  register "tlstr" pr_tlstr;
  register "n->string" pr_n_to_string;
  register "string->n" pr_string_to_n;
  register "symbol?" pr_symbolp;
  register "boolean?" pr_booleanp;
  register "open" pr_open;
  register "close" pr_close;
  register "read-byte" pr_read_byte;
  register "char-stream?" pr_char_stream;
  register "read-unit-string" pr_read_unit_string;
  register "write-string" pr_write_string;
  register "write-byte" pr_write_byte;
  register "get-time" pr_get_time;
  register "type" pr_type;
  register "eval-kl" pr_eval_kl;
  register "if" pr_if;
  register "and" pr_and;
  register "or" pr_or;
  register "absvector" pr_absvector;
  register "<-address" pr_address_get;
  register "address->" pr_address_set;
  register "apply" pr_apply;
  register "error" pr_error;
  register "error-to-string" pr_error_to_string;
  (* Native overwrites for hot paths *)
  let overwrite = if verbose then native_overwrite else native_overwrite_quiet in
  overwrite "=" pr_equal;  (* optimized equality *)
  overwrite "+" pr_plus;
  overwrite "*" pr_mult;
  overwrite "-" pr_minus;
  (* add more for apply, cons etc. *)
  if verbose then print_endline "Primitives initialised."

(* Called from main.ml and tests. No top-level execution to avoid duplicate prints. *)
