(* AUDIT BOUNDARY: t is abstract in tagged.mli. Only [int] and [heap]
   produce values: OCaml ints, or real, scanned OCaml variant blocks.
   Every heap variant has a payload, including Nil and Bool. No constant
   constructors, raw addresses, custom headers, pointer arithmetic, or
   mutation through Obj are used. Obj.obj is guarded by Obj.is_int.
   All recursive fields and vector elements contain only abstract t values.
   Keep this module closed: adding an unchecked import would break this proof. *)
type t = Obj.t

type block =
  | Nil of unit
  | Bool of bool
  | Float of float
  | Symbol of string
  | Cons of t * t
  | Vector of t array

let heap (b : block) : t = Obj.repr b
let block (v : t) : block =
  if Obj.is_int v then invalid_arg "expected heap value" else Obj.obj v

let kind v =
  if Obj.is_int v then Kind.Int
  else match block v with
    | Nil _ -> Kind.Nil
    | Bool _ -> Kind.Bool
    | Float _ -> Kind.Float
    | Symbol _ -> Kind.Symbol
    | Cons _ -> Kind.Cons
    | Vector _ -> Kind.Vector

let same a b = a == b
let int (n : int) : t = Obj.repr n
let as_int (v : t) : int =
  if Obj.is_int v then Obj.obj v else invalid_arg "as_int"
let nil = heap (Nil ())
let bool b = heap (Bool b)
let as_bool v = match block v with Bool b -> b | _ -> invalid_arg "as_bool"
let float n = heap (Float n)
let as_float v = match block v with Float n -> n | _ -> invalid_arg "as_float"
let symbol s = heap (Symbol s)
let as_symbol v = match block v with Symbol s -> s | _ -> invalid_arg "as_symbol"
let cons h t = heap (Cons (h, t))
let head v = match block v with Cons (h, _) -> h | _ -> invalid_arg "head"
let tail v = match block v with Cons (_, t) -> t | _ -> invalid_arg "tail"
let vector n init = heap (Vector (Array.make n init))
let vector_length v = match block v with Vector a -> Array.length a | _ -> invalid_arg "vector_length"
let vector_get v i = match block v with Vector a -> a.(i) | _ -> invalid_arg "vector_get"
let vector_set v i x = match block v with Vector a -> a.(i) <- x | _ -> invalid_arg "vector_set"
