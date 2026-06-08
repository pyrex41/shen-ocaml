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
  | Stream of stream
  | Error of string

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
  | Closure _ -> "<closure>"
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
    | (Str s1, Str s2) -> s1 = s2
    | (Sym s1, Sym s2) -> s1 = s2
    | (Bool b1, Bool b2) -> b1 = b2
    | (Nil, Nil) -> true
    | (Cons (h1, t1), Cons (h2, t2)) -> equal h1 h2 && equal t1 t2
    | (Vec v1, Vec v2) ->
        if Array.length v1 <> Array.length v2 then false
        else Array.for_all2 equal v1 v2
    | (Stream (In_chan a), Stream (In_chan b)) -> a == b
    | (Stream (Out_chan a), Stream (Out_chan b)) -> a == b
    | _ -> false
