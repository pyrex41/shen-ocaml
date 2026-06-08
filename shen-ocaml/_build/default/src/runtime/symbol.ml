(** 
 * src/runtime/symbol.ml
 * Symbol interning with integer IDs for fast equality.
 *)

module Interned = struct
  type t = {
    name : string;
    id : int;
  }

  let equal s1 s2 = s1.id = s2.id
  let compare s1 s2 = Int.compare s1.id s2.id
  let hash s = s.id
  let name s = s.name
  let id s = s.id
end

type symbol = Interned.t

module SymbolTbl = Hashtbl.Make(struct
  type t = string
  let equal = String.equal
  let hash = Hashtbl.hash
end)

let intern_table : symbol SymbolTbl.t = SymbolTbl.create 1024
let next_id = ref 0

let intern name =
  match SymbolTbl.find_opt intern_table name with
  | Some sym -> sym
  | None ->
      let id = !next_id in
      incr next_id;
      let sym = { Interned.name; id } in
      SymbolTbl.add intern_table name sym;
      sym

let to_string s = Interned.name s
let id s = Interned.id s
let equal s1 s2 = Interned.equal s1 s2
let compare s1 s2 = Interned.compare s1 s2

(* Pre-intern common symbols *)
let _ =
  List.iter (fun n -> ignore (intern n))
    ["true"; "false"; "shen"; "*"; "+"; "-"; "/"; ">"; "="; "cons"; "nil"]

let is_symbol = function
  | _ -> true (* placeholder *)

let make_symbol name = intern name
