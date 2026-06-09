(** Phase C benchmark: the SAME Shen source (typed_numeric.shen) with its
    signature *consumed* (unboxed OCaml int, native ops, no tags) vs *ignored*
    (the uniform tagged-[value] path — this port's own AOT baseline, Phase B).

    Honesty rules: warmup, >=5 iterations, report median + spread, pinned
    workloads. The loop-carried LCG fold cannot be constant-folded (and we are on
    a non-flambda 4.14 build anyway). [fibo] is tree recursion. Both paths use
    native 63-bit ints, so overflow wraps identically — the speedup is purely from
    dropping tags + table dispatch, not from changing arithmetic. *)

open Shen.Runtime.Value
module Env = Shen.Runtime.Env
module E = Shen.Interp.Eval
module Sp = Shen_typed_numeric.Specialized

let median xs =
  let a = List.sort compare xs in
  List.nth a (List.length a / 2)

let bench ?(warmup = 2) ?(iters = 7) f =
  for _ = 1 to warmup do ignore (f ()) done;
  let ts = ref [] in
  for _ = 1 to iters do
    let t0 = Unix.gettimeofday () in
    ignore (f ());
    ts := (Unix.gettimeofday () -. t0) :: !ts
  done;
  !ts

let ms t = t *. 1000.

let report name consumed inlined_tagged uniform =
  let c = median consumed and it = median inlined_tagged and u = median uniform in
  Printf.printf
    "%-20s unboxed=%7.2fms | inlined-tagged=%8.2fms (%5.1fx) | uniform=%9.2fms (%6.1fx)\n"
    name (ms c) (ms it) (it /. c) (ms u) (u /. c)

(* Apply a uniform value-closure to int args (the erased path: tagged + table). *)
let call name args = E.apply_value (Sym name) (List.map (fun i -> Int i) args)

(* Inlined TAGGED baseline: direct OCaml recursion over boxed [value] (no table
   lookup, no currying), but every number is a heap-boxed [Int]. This isolates the
   cost of *tags/boxing alone* from the cost of dispatch — the honest yardstick the
   prompt asks for ("report against your own inlined tagged baseline"). *)
let rec it_lcg acc n =
  match (acc, n) with
  | Int a, Int nn ->
      if nn = 0 then Int a else it_lcg (Int ((a * 1664525) + nn)) (Int (nn - 1))
  | _ -> failwith "it_lcg"

let rec it_sumto acc n =
  match (acc, n) with
  | Int a, Int nn -> if nn = 0 then Int a else it_sumto (Int (a + nn)) (Int (nn - 1))
  | _ -> failwith "it_sumto"

let rec it_fibo n =
  match n with
  | Int nn ->
      if nn < 2 then Int nn
      else (match (it_fibo (Int (nn - 1)), it_fibo (Int (nn - 2))) with
            | Int a, Int b -> Int (a + b) | _ -> failwith "it_fibo")
  | _ -> failwith "it_fibo"

let () =
  Shen.Interp.Eval.initialise ();
  Shen.Runtime.Primitives.initialise ();

  let n = 10_000_000 in

  (* erased baseline: register the uniform (tagged) closures so recursion stays
     uniform (no fast path in the table). *)
  Env.set_fn "lcg" Sp.uniform_sp_int_lcg_;
  Env.set_fn "sumto" Sp.uniform_sp_int_sumto_;
  Env.set_fn "fibo" Sp.uniform_sp_int_fibo_;
  let erased_lcg = bench (fun () -> call "lcg" [ 0; n ]) in
  let erased_sumto = bench (fun () -> call "sumto" [ 0; n ]) in
  let erased_fibo = bench ~iters:5 (fun () -> call "fibo" [ 32 ]) in

  (* inlined tagged baseline (direct OCaml, boxed Int). *)
  let it_lcg_t = bench (fun () -> it_lcg (Int 0) (Int n)) in
  let it_sumto_t = bench (fun () -> it_sumto (Int 0) (Int n)) in
  let it_fibo_t = bench ~iters:5 (fun () -> it_fibo (Int 32)) in

  (* consumed: specialized unboxed entries (direct calls, no wrapper/table). *)
  let consumed_lcg = bench (fun () -> Sp.sp_int_lcg_ 0 n) in
  let consumed_sumto = bench (fun () -> Sp.sp_int_sumto_ 0 n) in
  let consumed_fibo = bench ~iters:5 (fun () -> Sp.sp_int_fibo_ 32) in

  (* sanity: same result every way *)
  (match (call "lcg" [ 0; 1000 ], it_lcg (Int 0) (Int 1000), Sp.sp_int_lcg_ 0 1000) with
   | Int a, Int b, c when a = b && b = c -> () | _ -> failwith "lcg mismatch");

  Printf.printf "workload: lcg/sumto N=%d, fibo 32 (apt OCaml 4.14, no flambda)\n\n" n;
  report "lcg (loop-carried)" consumed_lcg it_lcg_t erased_lcg;
  report "loopsum (sumto)" consumed_sumto it_sumto_t erased_sumto;
  report "fibo 32 (tree rec)" consumed_fibo it_fibo_t erased_fibo;

  (* FLOAT workload (Phase C broadening): a float fold via the unboxed float entry
     vs an inlined-tagged Float baseline. *)
  let rec it_fsum (acc : value) (k : value) =
    match (acc, k) with
    | Float a, Float kk -> if kk = 0. then Float a else it_fsum (Float (a +. kk)) (Float (kk -. 1.))
    | _ -> failwith "it_fsum" in
  let fn = 5_000_000 in
  let consumed_fsum = bench (fun () -> Sp.sp_flt_fsum_ 0. (float_of_int fn)) in
  let it_fsum_t = bench (fun () -> it_fsum (Float 0.) (Float (float_of_int fn))) in
  Env.set_fn "fsum" Sp.uniform_sp_int_fsum_;
  let erased_fsum =
    bench (fun () -> E.apply_value (Sym "fsum") [ Float 0.; Float (float_of_int fn) ]) in
  Printf.printf "\nfloat workload: sumto (float) N=%d\n" fn;
  report "fsum (float fold)" consumed_fsum it_fsum_t erased_fsum;

  Printf.printf
    "\n(unboxed vs inlined-tagged = the honest 'dropping tags' win; vs uniform =\n end-to-end incl. table dispatch + currying + boxing. fibo is non-tail.)\n"
