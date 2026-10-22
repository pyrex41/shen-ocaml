(** 
 * src/runtime/value.ml
 * Runtime value type for Shen-OCaml.
 *)

type stream =
  | In_chan of in_channel
  | Out_chan of out_channel

type value =
  | Int of int
  | Float of float
  | Str of string
  | Sym of string
  | Bool of bool
  | Cons of value * value
  | Nil
  | Vec of value array
  | Closure of (value list -> value)
  | Thunk of (unit -> value)
  | Native of native_function
  | Stream of stream
  | Error of string
and native_function = { arity : int; code : native_code; invoke : value list -> value }
and native_code =
  | Function0 of (unit -> value)
  | Function1 of (value -> value)
  | Function2 of (value -> value -> value)
  | Function3 of (value -> value -> value -> value)
  | Function4 of (value -> value -> value -> value -> value)
  | Function5 of (value -> value -> value -> value -> value -> value)
  | Function6 of (value -> value -> value -> value -> value -> value -> value)
  | Function7 of (value -> value -> value -> value -> value -> value -> value -> value)
  | Function8 of (value -> value -> value -> value -> value -> value -> value -> value -> value)
  | Generic

(** Shared boxed booleans: constructing [Bool b] for a dynamic [b] allocates. *)
let true_value = Bool true
let false_value = Bool false
let of_bool b = if b then true_value else false_value

(** Raised by [simple-error]; unwinds until [trap-error] (converted to [Error]) or [eval_kl]. *)
exception User_error of string

(** If [v] is a proper list (chain of [Cons] ending in [Nil]), return its elements. *)
let rec cons_to_proper_list v =
  match v with
  | Nil -> Some []
  | Cons (h, t) -> (
      match cons_to_proper_list t with
      | Some rest -> Some (h :: rest)
      | None -> None)
  | _ -> None

let rec to_string = function
  | Int i -> string_of_int i
  | Float f -> string_of_float f
  | Str s -> "\"" ^ s ^ "\""
  | Sym s -> s
  | Bool true -> "true"
  | Bool false -> "false"
  | Cons (h, t) as cell -> (
      match cons_to_proper_list cell with
      | Some elts ->
          "("
          ^ String.concat " " (List.map to_string elts)
          ^ ")"
      | None -> "(" ^ to_string h ^ " . " ^ to_string t ^ ")")
  | Nil -> "[]"
  | Vec _ -> "<vector>"
  | Closure _ | Thunk _ | Native _ -> "<closure>"
  | Stream _ -> "<stream>"
  | Error s -> "Error: " ^ s

let is_true = function
  | Bool true -> true
  | _ -> false

let is_symbol = function
  | Sym _ -> true
  | _ -> false

let rec equal v1 v2 =
  if v1 == v2 then true
  else
    match (v1, v2) with
    | (Int i1, Int i2) -> i1 = i2
    | (Float f1, Float f2) -> f1 = f2
    | (Int i, Float f) | (Float f, Int i) -> float_of_int i = f
    | (Str s1, Str s2) -> s1 = s2
    | (Sym s1, Sym s2) -> s1 = s2
    | (Bool b1, Bool b2) -> b1 = b2
    | (Nil, Nil) -> true
    | (Cons (h1, t1), Cons (h2, t2)) -> equal h1 h2 && equal t1 t2
    | (Vec v1, Vec v2) ->
        if Array.length v1 <> Array.length v2 then false
        else equal_vector v1 v2 0 (Array.length v1)
    | (Stream (In_chan a), Stream (In_chan b)) -> a == b
    | (Stream (Out_chan a), Stream (Out_chan b)) -> a == b
    | _ -> false

and equal_vector a b index length =
  index = length || (equal a.(index) b.(index) && equal_vector a b (index + 1) length)

(** Bounded structural hashing consistent with numeric equality, including
    numbers nested in list/vector keys and signed zero. Collisions are allowed;
    different buckets for equal values are not. Depth/work limits also prevent
    cyclic mutable vectors from making hashing diverge. *)
let hash_number f = Hashtbl.hash (if f = 0. then 0. else f)
let hash_mix a b = ((a lsl 5) - a) lxor b

let rec hash_walk fuel depth value =
    if depth = 0 || !fuel = 0 then 0
    else (
      decr fuel;
      match value with
       | Int i -> hash_number (float_of_int i)
       | Float f -> hash_number f
      | Cons (h, t) ->
           let h = hash_walk fuel (depth - 1) h in
           let t = hash_walk fuel (depth - 1) t in hash_mix h t
      | Vec items ->
          let result = ref (Array.length items) in
          let i = ref 0 in
          while !i < Array.length items && !fuel > 0 do
             result := hash_mix !result (hash_walk fuel (depth - 1) items.(!i));
            incr i
          done;
          !result
       | _ -> Hashtbl.hash value)

let hash value =
  match value with
  | Int i -> hash_number (float_of_int i)
  | Float f -> hash_number f
  | Cons _ | Vec _ -> hash_walk (ref 256) 16 value land max_int
  | _ -> Hashtbl.hash value
