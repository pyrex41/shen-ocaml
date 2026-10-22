(** Native backend ABI. Values and primitive implementations are shared with the
    legacy runtime; [Error] results are raised at its boundary, not propagated as
    ordinary successful values. Direct native calls do not construct arg lists. *)
open Value

let checked = function Error message -> raise (User_error message) | value -> value

let boolean = function
  | Bool b -> b
  | _ -> raise (User_error "expected a boolean in if/and/or")

let rec apply fn args =
  match fn with
  | Native f -> f.invoke args
  | Thunk f -> (match args with
      | [] -> f ()
      | _ -> let result = f () in apply result args)
  | Closure f -> checked (f args)
  | Sym name -> call name args
  | _ -> raise (User_error "attempt to apply a non-function")
and call name args =
  match Env.get_fn name with
  | Some ((Closure _ | Thunk _ | Native _) as fn) -> apply fn args
  | Some _ -> raise (User_error ("not a function: " ^ name))
  | None -> raise (User_error ("unbound function: " ^ name))

(** Curry on demand and apply excess arguments to the result. In the saturated
    path [invoke] ends in the generated OCaml call, preserving tail position. *)
let function_ arity invoke =
  if arity = 0 then Thunk (fun () -> invoke []) else
  let rec exact n = function
    | [] -> n = 0
    | _ :: rest -> n > 0 && exact (n - 1) rest
  in
  let rec collect reversed remaining args =
    match remaining, args with
    | 0, [] -> invoke (List.rev reversed)
    | 0, rest -> let result = invoke (List.rev reversed) in apply result rest
    | _, [] -> Native { arity = remaining; code = Generic;
        invoke = (fun more -> collect reversed remaining more) }
    | n, arg :: rest -> collect (arg :: reversed) (n - 1) rest
  in
  Native { arity; code = Generic;
    invoke = (fun args -> if exact arity args then invoke args else collect [] arity args) }

(** A zero-argument callable needs neither an arity record nor a list adapter.
    Keep [Function0] supported below for callers constructing the older ABI. *)
let function0 f = Thunk f

let function1 f =
  let rec value = Native { arity = 1; code = Function1 f; invoke = (function
    | [] -> value
    | [a] -> f a
    | a :: rest -> let result = f a in apply result rest) } in value

let function2 f =
  let rec value = Native { arity = 2; code = Function2 f; invoke = (function
    | [] -> value
    | [a] -> function1 (fun b -> f a b)
    | [a; b] -> f a b
    | a :: b :: rest -> let result = f a b in apply result rest) } in value

let function3 f =
  let rec value = Native { arity = 3; code = Function3 f; invoke = (function
    | [] -> value
    | [a] -> function2 (fun b c -> f a b c)
    | [a; b] -> function1 (fun c -> f a b c)
    | [a; b; c] -> f a b c
    | a :: b :: c :: rest -> let result = f a b c in apply result rest) } in value

let function4 f =
  let rec value = Native { arity = 4; code = Function4 f; invoke = (function
    | [] -> value
    | [a] -> function3 (fun b c d -> f a b c d)
    | [a; b] -> function2 (fun c d -> f a b c d)
    | [a; b; c] -> function1 (fun d -> f a b c d)
    | [a; b; c; d] -> f a b c d
    | a :: b :: c :: d :: rest -> let result = f a b c d in apply result rest) } in value

let function5 f =
  let rec value = Native { arity = 5; code = Function5 f; invoke = (function
    | [] -> value
    | [a] -> function4 (fun b c d e -> f a b c d e)
    | [a; b] -> function3 (fun c d e -> f a b c d e)
    | [a; b; c] -> function2 (fun d e -> f a b c d e)
    | [a; b; c; d] -> function1 (fun e -> f a b c d e)
    | [a; b; c; d; e] -> f a b c d e
    | a :: b :: c :: d :: e :: rest -> let result = f a b c d e in apply result rest) } in value

let function6 f =
  let rec value = Native { arity = 6; code = Function6 f; invoke = (function
    | [] -> value
    | [a] -> function5 (fun b c d e g -> f a b c d e g)
    | [a; b] -> function4 (fun c d e g -> f a b c d e g)
    | [a; b; c] -> function3 (fun d e g -> f a b c d e g)
    | [a; b; c; d] -> function2 (fun e g -> f a b c d e g)
    | [a; b; c; d; e] -> function1 (fun g -> f a b c d e g)
    | [a; b; c; d; e; g] -> f a b c d e g
    | a :: b :: c :: d :: e :: g :: rest -> let result = f a b c d e g in apply result rest) } in value

let function7 f =
  let rec value = Native { arity = 7; code = Function7 f; invoke = (function
    | [] -> value
    | [a] -> function6 (fun b c d e g h -> f a b c d e g h)
    | [a; b] -> function5 (fun c d e g h -> f a b c d e g h)
    | [a; b; c] -> function4 (fun d e g h -> f a b c d e g h)
    | [a; b; c; d] -> function3 (fun e g h -> f a b c d e g h)
    | [a; b; c; d; e] -> function2 (fun g h -> f a b c d e g h)
    | [a; b; c; d; e; g] -> function1 (fun h -> f a b c d e g h)
    | [a; b; c; d; e; g; h] -> f a b c d e g h
    | a :: b :: c :: d :: e :: g :: h :: rest -> let result = f a b c d e g h in apply result rest) } in value

let function8 f =
  let rec value = Native { arity = 8; code = Function8 f; invoke = (function
    | [] -> value
    | [a] -> function7 (fun b c d e g h i -> f a b c d e g h i)
    | [a; b] -> function6 (fun c d e g h i -> f a b c d e g h i)
    | [a; b; c] -> function5 (fun d e g h i -> f a b c d e g h i)
    | [a; b; c; d] -> function4 (fun e g h i -> f a b c d e g h i)
    | [a; b; c; d; e] -> function3 (fun g h i -> f a b c d e g h i)
    | [a; b; c; d; e; g] -> function2 (fun h i -> f a b c d e g h i)
    | [a; b; c; d; e; g; h] -> function1 (fun i -> f a b c d e g h i)
    | [a; b; c; d; e; g; h; i] -> f a b c d e g h i
    | a :: b :: c :: d :: e :: g :: h :: i :: rest -> let result = f a b c d e g h i in apply result rest) } in value

let apply0 fn = match fn with
  | Thunk f | Native {code = Function0 f; _} -> f ()
  | _ -> apply fn []
let apply1 fn a = match fn with Native {code = Function1 f; _} -> f a | _ -> apply fn [a]
let apply2 fn a b = match fn with Native {code = Function2 f; _} -> f a b | _ -> apply fn [a; b]
let apply3 fn a b c = match fn with Native {code = Function3 f; _} -> f a b c | _ -> apply fn [a; b; c]
let apply4 fn a b c d = match fn with Native {code = Function4 f; _} -> f a b c d | _ -> apply fn [a; b; c; d]
let apply5 fn a b c d e = match fn with Native {code = Function5 f; _} -> f a b c d e | _ -> apply fn [a; b; c; d; e]
let apply6 fn a b c d e g = match fn with Native {code = Function6 f; _} -> f a b c d e g | _ -> apply fn [a; b; c; d; e; g]
let apply7 fn a b c d e g h = match fn with Native {code = Function7 f; _} -> f a b c d e g h | _ -> apply fn [a; b; c; d; e; g; h]
let apply8 fn a b c d e g h i = match fn with Native {code = Function8 f; _} -> f a b c d e g h i | _ -> apply fn [a; b; c; d; e; g; h; i]

let unbound cell = raise (User_error ("unbound function: " ^ cell.Env.name))
let call_cell cell args = match cell.Env.binding with Some fn -> apply fn args | None -> unbound cell
let call0 cell = match cell.Env.binding with Some fn -> apply0 fn | None -> unbound cell
let call1 cell a = match cell.Env.binding with Some fn -> apply1 fn a | None -> unbound cell
let call2 cell a b = match cell.Env.binding with Some fn -> apply2 fn a b | None -> unbound cell
let call3 cell a b c = match cell.Env.binding with Some fn -> apply3 fn a b c | None -> unbound cell
let call4 cell a b c d = match cell.Env.binding with Some fn -> apply4 fn a b c d | None -> unbound cell
let call5 cell a b c d e = match cell.Env.binding with Some fn -> apply5 fn a b c d e | None -> unbound cell
let call6 cell a b c d e g = match cell.Env.binding with Some fn -> apply6 fn a b c d e g | None -> unbound cell
let call7 cell a b c d e g h = match cell.Env.binding with Some fn -> apply7 fn a b c d e g h | None -> unbound cell
let call8 cell a b c d e g h i = match cell.Env.binding with Some fn -> apply8 fn a b c d e g h i | None -> unbound cell

let install name arity fn =
  Env.set_fn name fn;
  Env.register_fn_metadata name arity fn;
  Sym name

let protect body handler =
  (* The handler value is evaluated before entering the protected expression.
     Do not catch exceptions raised by applying the handler itself. *)
  match body () with
  | value -> value
  | exception User_error message -> apply handler [Error message]

let add a b = match a, b with
  | Int a, Int b -> Int (a + b)
  | Float a, Float b -> Float (a +. b)
  | Int a, Float b -> Float (float_of_int a +. b)
  | Float a, Int b -> Float (a +. float_of_int b)
  | _ -> raise (User_error "+: numbers expected")

let sub a b = match a, b with
  | Int a, Int b -> Int (a - b)
  | Float a, Float b -> Float (a -. b)
  | Int a, Float b -> Float (float_of_int a -. b)
  | Float a, Int b -> Float (a -. float_of_int b)
  | _ -> raise (User_error "-: numbers expected")

let mul a b = match a, b with
  | Int a, Int b -> Int (a * b)
  | Float a, Float b -> Float (a *. b)
  | Int a, Float b -> Float (float_of_int a *. b)
  | Float a, Int b -> Float (a *. float_of_int b)
  | _ -> raise (User_error "*: numbers expected")

let eq a b = of_bool (equal a b)
let gt a b = match a, b with
  | Int a, Int b -> of_bool (a > b)
  | Float a, Float b -> of_bool (a > b)
  | Int a, Float b -> of_bool (float_of_int a > b)
  | Float a, Int b -> of_bool (a > float_of_int b)
  | _ -> raise (User_error ">: numbers expected")
let lt a b = match a, b with
  | Int a, Int b -> of_bool (a < b)
  | Float a, Float b -> of_bool (a < b)
  | Int a, Float b -> of_bool (float_of_int a < b)
  | Float a, Int b -> of_bool (a < float_of_int b)
  | _ -> raise (User_error "<: numbers expected")
let lte a b = match a, b with
  | Int a, Int b -> of_bool (a <= b)
  | Float a, Float b -> of_bool (a <= b)
  | Int a, Float b -> of_bool (float_of_int a <= b)
  | Float a, Int b -> of_bool (a <= float_of_int b)
  | _ -> raise (User_error "<=: numbers expected")
let gte a b = match a, b with
  | Int a, Int b -> of_bool (a >= b)
  | Float a, Float b -> of_bool (a >= b)
  | Int a, Float b -> of_bool (float_of_int a >= b)
  | Float a, Int b -> of_bool (a >= float_of_int b)
  | _ -> raise (User_error ">=: numbers expected")
let cons a b = Cons (a, b)
let hd = function
  | Cons (h, _) -> h
  | _ -> raise (User_error "hd: cons expected")
let tl = function
  | Cons (_, t) -> t
  | Nil -> Nil
  | _ -> raise (User_error "tl: cons or nil expected")
let consp = function Cons _ -> Bool true | _ -> Bool false

let set name value = match name with
  | Sym name -> Env.set_global name value; value
  | _ -> raise (User_error "set: symbol expected")

let value = function
  | Sym name -> (match Env.get_global name with
      | Some value -> value
      | None -> raise (User_error ("unbound value: " ^ name)))
  | _ -> raise (User_error "value: symbol expected")

let address_get array index = match array, index with
  | Vec items, Int i when i >= 0 && i < Array.length items -> items.(i)
  | Vec _, Int _ -> raise (User_error "address out of bounds")
  | _ -> raise (User_error "<-address: vector and integer expected")

let address_set array index value = match array, index with
  | Vec items, Int i when i >= 0 && i < Array.length items -> items.(i) <- value; array
  | Vec _, Int _ -> raise (User_error "address out of bounds")
  | _ -> raise (User_error "address->: vector, integer and value expected")

(** These bindings are only used by explicitly sealed compilation, and only if
    the unit does not itself define the primitive name. *)
let primitive = function
  | "+", 2 -> Some "N.add"
  | "-", 2 -> Some "N.sub"
  | "*", 2 -> Some "N.mul"
  | "=", 2 -> Some "N.eq"
  | ">", 2 -> Some "N.gt"
  | "<", 2 -> Some "N.lt"
  | "<=", 2 -> Some "N.lte"
  | ">=", 2 -> Some "N.gte"
  | "cons", 2 -> Some "N.cons"
  | "hd", 1 -> Some "N.hd"
  | "tl", 1 -> Some "N.tl"
  | "cons?", 1 -> Some "N.consp"
  | "set", 2 -> Some "N.set"
  | "value", 1 -> Some "N.value"
  | "<-address", 2 -> Some "N.address_get"
  | "address->", 3 -> Some "N.address_set"
  | _ -> None

let () = Env.set_fn_reference_factory (fun name arity ->
  let cell = Env.function_cell name in
  match arity with
  | 0 -> function0 (fun () -> call0 cell)
  | 1 -> function1 (fun a -> call1 cell a)
  | 2 -> function2 (fun a b -> call2 cell a b)
  | 3 -> function3 (fun a b c -> call3 cell a b c)
  | 4 -> function4 (fun a b c d -> call4 cell a b c d)
  | 5 -> function5 (fun a b c d e -> call5 cell a b c d e)
  | 6 -> function6 (fun a b c d e f -> call6 cell a b c d e f)
  | 7 -> function7 (fun a b c d e f g -> call7 cell a b c d e f g)
  | 8 -> function8 (fun a b c d e f g h -> call8 cell a b c d e f g h)
  | _ -> function_ arity (fun args -> call_cell cell args))
