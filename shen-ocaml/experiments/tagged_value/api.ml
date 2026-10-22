module type S = sig
  type t

  val kind : t -> Kind.t
  val same : t -> t -> bool
  val int : int -> t
  val as_int : t -> int
  val nil : t
  val bool : bool -> t
  val as_bool : t -> bool
  val float : float -> t
  val as_float : t -> float
  val symbol : string -> t
  val as_symbol : t -> string
  val cons : t -> t -> t
  val head : t -> t
  val tail : t -> t
  val vector : int -> t -> t
  val vector_length : t -> int
  val vector_get : t -> int -> t
  val vector_set : t -> int -> t -> unit
end
