module B = Workloads.Make (Boxed)
module T = Workloads.Make (Tagged)

type sample = { seconds : float; words : float }

let allocated s = s.Gc.minor_words +. s.Gc.major_words -. s.Gc.promoted_words

let measure repeats expected f =
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let start = Unix.gettimeofday () in
  for _ = 1 to repeats do
    let result = Sys.opaque_identity (f ()) in
    if result <> expected then failwith "benchmark checksum mismatch"
  done;
  let elapsed = Unix.gettimeofday () -. start in
  (* OCaml 5 quick_stat is sampled at collection boundaries. Flush the
     nursery OUTSIDE the timed region, or allocations below one nursery
     would disappear from the reported totals. Small harness allocations
     are deliberately not subtracted and are identical on both sides. *)
  Gc.minor ();
  let after = Gc.quick_stat () in
  { seconds = elapsed /. float repeats;
    words = (allocated after -. allocated before) /. float repeats }

let median xs =
  let a = Array.of_list xs in
  Array.sort Float.compare a;
  a.(Array.length a / 2)

let report name side samples =
  let times = List.map (fun s -> s.seconds *. 1e6) samples in
  Printf.printf "%s,%s,%.3f,%.3f,%.3f,%.1f\n%!" name side
    (median times) (List.fold_left min infinity times)
    (List.fold_left max 0. times) (median (List.map (fun s -> s.words) samples))

let () =
  let check_only = Array.exists (( = ) "--check") Sys.argv in
  let gc = Gc.get () in
  Gc.set { gc with minor_heap_size = 32_768 };
  B.check (); T.check (); B.stress (); T.stress ();
  Printf.printf "Checks and minor/full/compaction stress: PASS (both)\n%!";
  if not check_only then begin
    (* Reproducible benchmark GC configuration, separate from stress. *)
    Gc.set { gc with minor_heap_size = 262_144 };
    Printf.printf "OCaml %s; word_size=%d; minor_heap_words=262144; samples=9; repeats=20\n"
      Sys.ocaml_version Sys.word_size;
    Printf.printf "workload,representation,median_us,min_us,max_us,allocated_words_per_call\n%!";
    List.iter2 (fun (name, bf, expected) (tn, tf, te) ->
      assert (name = tn && expected = te);
      for _ = 1 to 3 do assert (bf () = expected); assert (tf () = expected) done;
      let bs = ref [] and ts = ref [] in
      for round = 0 to 8 do
        let b () = bs := measure 20 expected bf :: !bs in
        let t () = ts := measure 20 expected tf :: !ts in
        if round mod 2 = 0 then (b (); t ()) else (t (); b ())
      done;
      report name "boxed" !bs; report name "tagged" !ts) B.cases T.cases
  end
