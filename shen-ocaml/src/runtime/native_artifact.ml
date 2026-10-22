(** Native plugins register, but do not execute, their installation thunk.
    This registry is deliberately independent of Dynlink so the runtime library
    remains usable by hosts that do not load plugins. Not thread-safe. *)
let entries : (string, unit -> Value.value) Hashtbl.t = Hashtbl.create 16

let register key run =
  if Hashtbl.mem entries key then
    invalid_arg ("native artifact already registered: " ^ key);
  Hashtbl.add entries key run

let find key = Hashtbl.find_opt entries key

(** Install already-checked native signature predicates without re-entering
    [declare], host demodulation, datatype rules or arbitrary signature closures.
    Existing non-owned declarations and conflicting types fail BEFORE mutation.
    This deliberately does not implement general Shen declaration variancy. *)
type owned_type = { description : Value.value; predicate : Value.value }
let owned_types : (string, owned_type) Hashtbl.t = Hashtbl.create 16

let install_types declarations =
  let open Value in
  let rec lookup name = function
    | Nil -> None
    | Cons (Cons (Sym key, value), rest) -> if key = name then Some value else lookup name rest
    | _ -> raise (User_error "invalid signature table while loading native module")
  in
  let replace name predicate root =
    let restore reversed tail = List.fold_left (fun tail value -> Cons (value, tail)) tail reversed in
    let rec loop reversed = function
      | Nil -> restore reversed (Cons (Cons (Sym name, predicate), Nil))
      | Cons (Cons (Sym key, _), rest) when key = name ->
          restore reversed (Cons (Cons (Sym key, predicate), rest))
      | Cons (entry, rest) -> loop (entry :: reversed) rest
      | _ -> raise (User_error "invalid signature table while loading native module")
    in loop [] root
  in
  let root = Option.value ~default:Nil (Env.get_global "shen.*sigf*") in
  let staged = List.fold_left (fun table (name, description, predicate) ->
    (match predicate with
    | Native { arity = 1; _ } -> ()
    | _ -> raise (User_error "native type predicate must have arity one"));
    (match lookup name root with
    | None -> ()
    | Some existing -> (match Hashtbl.find_opt owned_types name with
        | Some previous when previous.predicate == existing && equal previous.description description -> ()
        | _ -> raise (User_error ("native typed load conflicts with an existing declaration: " ^ name))));
    replace name predicate table) root declarations in
  Env.set_global "shen.*sigf*" staged;
  List.iter (fun (name, description, predicate) ->
    Hashtbl.replace owned_types name {description; predicate}) declarations
