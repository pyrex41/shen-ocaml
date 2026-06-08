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
  Closure (fun args0 ->
    let rec collect gathered need xs =
      match need, xs with
      | 0, [] -> f (List.rev gathered)
      | 0, _ :: _ -> Error "too many arguments"
      | n, [] -> Closure (fun more -> collect gathered n more)
      | n, y :: ys -> collect (y :: gathered) (n - 1) ys
    in
    collect [] arity args0)

(* Primitive implementations *)
let pr_intern = make_closure 1 (function
  | [Str s] -> Sym s
  | _ -> Error "intern: string expected"
)

let pr_plus = make_closure 2 (function
  | [Int a; Int b] -> Int (a + b)
  | [Float a; Float b] -> Float (a +. b)
  | [Int a; Float b] -> Float (float_of_int a +. b)
  | [Float a; Int b] -> Float (a +. float_of_int b)
  | _ -> Error "+: numbers expected"
)

let pr_mult = make_closure 2 (function
  | [Int a; Int b] -> Int (a * b)
  | [Float a; Float b] -> Float (a *. b)
  | [Int a; Float b] -> Float (float_of_int a *. b)
  | [Float a; Int b] -> Float (a *. float_of_int b)
  | _ -> Error "*: numbers expected"
)

let pr_minus = make_closure 2 (function
  | [Int a; Int b] -> Int (a - b)
  | [Float a; Float b] -> Float (a -. b)
  | [Int a; Float b] -> Float (float_of_int a -. b)
  | [Float a; Int b] -> Float (a -. float_of_int b)
  | _ -> Error "-: numbers expected"
)

let pr_set = make_closure 2 (function
  | [Sym name; v] -> 
      set_global name v;
      v
  | _ -> Error "set: symbol and value expected"
)

let pr_value = make_closure 1 (function
  | [Sym name] -> 
      (match get_global name with
       | Some v -> v
       | None -> Error ("unbound value: " ^ name))
  | _ -> Error "value: symbol expected"
)

let pr_simple_error = make_closure 1 (function
  | [Str msg] -> raise (User_error msg)
  | [Sym s] -> raise (User_error s)
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

let pr_equal = make_closure 2 (function
  | [v1; v2] -> Bool (Value.equal v1 v2)
  | _ -> Error "=: two arguments expected"
)

let pr_cons = make_closure 2 (function
  | [h; t] -> Cons (h, t)
  | _ -> Error "cons: two args expected"
)

let pr_hd = make_closure 1 (function
  | [Cons (h, _)] -> h
  | _ -> Error "hd: cons expected"
)

let pr_tl = make_closure 1 (function
  | [Cons (_, t)] -> t
  | [Nil] -> Nil
  | _ -> Error "tl: cons or nil expected"
)

let pr_numberp = make_closure 1 (function
  | [Int _] -> Bool true
  | [Float _] -> Bool true
  | _ -> Bool false
)

let pr_consq = make_closure 1 (function
  | [Cons _] -> Bool true
  | _ -> Bool false
)

let pr_stringp = make_closure 1 (function
  | [Str _] -> Bool true
  | _ -> Bool false
)

let pr_vectorp = make_closure 1 (function
  | [Vec _] -> Bool true
  | _ -> Bool false
)

(** Kernel [vector?] is redefined in [sys.kl] using [absvector?]. The KL sources
    never define [absvector?]; it must be a primitive (same discriminant as
    [absvector] / [@p] tuples). *)
let pr_absvectorp = make_closure 1 (function
  | [Vec _] -> Bool true
  | _ -> Bool false
)

let pr_absvector = make_closure 1 (function
  | [Int n] when n >= 0 -> Vec (Array.make n Nil)
  | [Int _] -> Error "absvector: non-negative integer expected"
  | _ -> Error "absvector: integer expected"
)

let pr_str = make_closure 1 (function
  | [v] -> Str (to_string v)
  | _ -> Error "str: one argument expected"
)

let pr_gt = make_closure 2 (function
  | [Int a; Int b] -> Bool (a > b)
  | [Float a; Float b] -> Bool (a > b)
  | [Int a; Float b] -> Bool (float_of_int a > b)
  | [Float a; Int b] -> Bool (a > float_of_int b)
  | _ -> Error ">: numbers expected"
)

let pr_lt = make_closure 2 (function
  | [Int a; Int b] -> Bool (a < b)
  | [Float a; Float b] -> Bool (a < b)
  | [Int a; Float b] -> Bool (float_of_int a < b)
  | [Float a; Int b] -> Bool (a < float_of_int b)
  | _ -> Error "<: numbers expected"
)

let pr_lte = make_closure 2 (function
  | [Int a; Int b] -> Bool (a <= b)
  | [Float a; Float b] -> Bool (a <= b)
  | [Int a; Float b] -> Bool (float_of_int a <= b)
  | [Float a; Int b] -> Bool (a <= float_of_int b)
  | _ -> Error "<=: numbers expected"
)

let pr_gte = make_closure 2 (function
  | [Int a; Int b] -> Bool (a >= b)
  | [Float a; Float b] -> Bool (a >= b)
  | [Int a; Float b] -> Bool (float_of_int a >= b)
  | [Float a; Int b] -> Bool (a >= float_of_int b)
  | _ -> Error ">=: numbers expected"
)

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

let pr_cn = make_closure 2 (function
  | [Str a; Str b] -> Str (a ^ b)
  | _ -> Error "cn: two strings expected"
)

let pr_pos = make_closure 2 (function
  | [Str s; Int i] ->
      if i < 0 || i >= String.length s then Error "pos: index out of bounds"
      else Str (String.make 1 s.[i])
  | _ -> Error "pos: string and integer expected"
)

let pr_tlstr = make_closure 1 (function
  | [Str s] ->
      if s = "" then Error "tlstr: empty string"
      else Str (String.sub s 1 (String.length s - 1))
  | _ -> Error "tlstr: string expected"
)

let pr_n_to_string = make_closure 1 (function
  | [Int n] ->
      if n < 0 || n > 255 then Error "n->string: byte 0..255 expected"
      else Str (String.make 1 (Char.chr n))
  | _ -> Error "n->string: integer expected"
)

let pr_string_to_n = make_closure 1 (function
  | [Str s] ->
      if String.length s <> 1 then
        Error "string->n: single-character string expected"
      else Int (Char.code s.[0])
  | _ -> Error "string->n: string expected"
)

let pr_symbolp = make_closure 1 (function
  | [Sym _] -> Bool true
  | _ -> Bool false
)

let pr_booleanp = make_closure 1 (function
  | [Bool _] -> Bool true
  | _ -> Bool false
)

let pr_open = make_closure 2 (function
  | [Str path; Sym dir] when dir = "in" || dir = "out" ->
    let home = match get_global "*home-directory*" with
      | Some (Str s) -> s
      | _ -> ""
    in
    let full_path = home ^ path in
    (* A failed [open] must *unwind* (like [simple-error]), not return an [Error]
       value: the kernel reader loops [read-byte] until [-1], and an [Error] value
       is never [-1], so returning it spins forever. Matches shen-cl, where
       [open] of a missing file signals an error trappable by [trap-error]. *)
    (try
      if dir = "in" then Stream (In_chan (open_in_bin full_path))
      else Stream (Out_chan (open_out_bin full_path))
    with Sys_error msg -> raise (User_error ("open: " ^ msg)))
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

let pr_write_byte = make_closure 2 (function
  | [Int b; Stream (Out_chan ch)] ->
      if b < 0 || b > 255 then Error "write-byte: byte 0..255 expected"
      else (
        output_byte ch b;
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
  | [Bool a; Bool b] -> Bool (a && b)
  | _ -> Bool false
)

let pr_or = make_closure 2 (function
  | [Bool a; Bool b] -> Bool (a || b)
  | _ -> Bool false
)

let pr_address_get = make_closure 2 (function
  | [Vec v; Int i] ->
      if i >= 0 && i < Array.length v then v.(i) else Error "address out of bounds"
  | _ -> Error "<-address: vector and integer expected"
)

let pr_address_set = make_closure 3 (function
  | [Vec v; Int i; x] ->
      if i >= 0 && i < Array.length v then 
        (v.(i) <- x; Vec v) 
      else Error "address out of bounds"
  | _ -> Error "address->: vector, integer and value expected"
)

let pr_apply = make_closure 2 (function
  | [Closure cl; arg] -> cl [arg]
  | [Sym name; arg] ->
      (match get_fn name with
       | Some (Closure cl) -> cl [arg]
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
  make_closure 2 (function
    | [Sym s; Int m] when m > 0 ->
        let h = Hashtbl.hash s in
        let r = pos_mod h m in
        Int (if r = 0 then 1 else r)
    | [Str s; Int m] when m > 0 ->
        let h = Hashtbl.hash s in
        let r = pos_mod h m in
        Int (if r = 0 then 1 else r)
    | _ -> Error "hash: symbol/string and positive modulus expected")

let install_native_hash () =
  native_overwrite_quiet "hash" (make_native_hash ())

let register_hash_fn_metadata () =
  match get_fn "hash" with
  | Some h -> register_fn_metadata "hash" 2 h
  | None -> ()

let initialise () =
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
  native_overwrite "=" pr_equal;  (* optimized equality *)
  native_overwrite "+" pr_plus;   (* optimized arithmetic *)
  native_overwrite "*" pr_mult;
  native_overwrite "-" pr_minus;
  (* add more for apply, cons etc. *)
  print_endline "Primitives initialised."

(* Called from main.ml and tests. No top-level execution to avoid duplicate prints. *)
