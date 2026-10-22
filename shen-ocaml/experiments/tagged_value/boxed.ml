type t =
  | Int of int
  | Nil of unit
  | Bool of bool
  | Float of float
  | Symbol of string
  | Cons of t * t
  | Vector of t array

let kind = function
  | Int _ -> Kind.Int
  | Nil _ -> Kind.Nil
  | Bool _ -> Kind.Bool
  | Float _ -> Kind.Float
  | Symbol _ -> Kind.Symbol
  | Cons _ -> Kind.Cons
  | Vector _ -> Kind.Vector

let same a b = a == b
let int n = Int n
let as_int = function Int n -> n | _ -> invalid_arg "as_int"
let nil = Nil ()
let bool b = Bool b
let as_bool = function Bool b -> b | _ -> invalid_arg "as_bool"
let float n = Float n
let as_float = function Float n -> n | _ -> invalid_arg "as_float"
let symbol s = Symbol s
let as_symbol = function Symbol s -> s | _ -> invalid_arg "as_symbol"
let cons h t = Cons (h, t)
let head = function Cons (h, _) -> h | _ -> invalid_arg "head"
let tail = function Cons (_, t) -> t | _ -> invalid_arg "tail"
let vector n init = Vector (Array.make n init)
let vector_length = function Vector a -> Array.length a | _ -> invalid_arg "vector_length"
let vector_get v i = match v with Vector a -> a.(i) | _ -> invalid_arg "vector_get"
let vector_set v i x = match v with Vector a -> a.(i) <- x | _ -> invalid_arg "vector_set"
