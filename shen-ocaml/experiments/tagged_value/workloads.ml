module Make (V : Api.S) = struct
  (* One algorithm, instantiated for both representations. Remember vector
     pairs for cycle termination. Immutable cons cannot cycle without passing
     through a vector; only vector pairs need the visited table. *)
  let equal a b =
    let rec loop seen a b =
      if V.same a b then true
      else if V.kind a <> V.kind b then false
      else match V.kind a with
        | Kind.Int -> V.as_int a = V.as_int b
        | Kind.Nil -> true
        | Kind.Bool -> V.as_bool a = V.as_bool b
        | Kind.Float -> V.as_float a = V.as_float b
        | Kind.Symbol -> String.equal (V.as_symbol a) (V.as_symbol b)
        | Kind.Cons ->
            loop seen (V.head a) (V.head b)
            && loop seen (V.tail a) (V.tail b)
        | Kind.Vector ->
            if List.exists (fun (x, y) -> V.same a x && V.same b y) seen then true
            else
              let n = V.vector_length a in
              n = V.vector_length b
              && let seen = (a, b) :: seen in
                 let rec items i =
                   i = n || (loop seen (V.vector_get a i) (V.vector_get b i)
                             && items (i + 1))
                 in items 0
    in loop [] a b

  let rec sum n acc =
    if V.as_int n = 0 then acc
    else sum (V.int (V.as_int n - 1))
        (V.int (V.as_int acc + V.as_int n))

  let rec fib n =
    if V.as_int n < 2 then n
    else V.int (V.as_int (fib (V.int (V.as_int n - 1)))
                + V.as_int (fib (V.int (V.as_int n - 2))))

  let rec list n acc =
    if n = 0 then acc else list (n - 1) (V.cons (V.int n) acc)

  let rec list_sum xs acc =
    if V.kind xs = Kind.Nil then V.as_int acc
    else list_sum (V.tail xs) (V.int (V.as_int acc + V.as_int (V.head xs)))

  let integer_sum () = V.as_int (sum (V.int 200_000) (V.int 0))
  let integer_fib () = V.as_int (fib (V.int 26))
  let list_build_sum () = list_sum (list 20_000 V.nil) (V.int 0)
  let retained_list = list 20_000 V.nil
  let list_traverse () = list_sum retained_list (V.int 0)
  let equal_left = list 10_000 V.nil
  let equal_right = list 10_000 V.nil
  let structural_equal () = if equal equal_left equal_right then 1 else 0

  let vector_mutate () =
    let v = V.vector 256 (V.int 0) in
    for i = 1 to 100_000 do
      let k = i land 255 in
      V.vector_set v k (V.int (V.as_int (V.vector_get v k) + 1))
    done;
    let total = ref 0 in
    for i = 0 to 255 do total := !total + V.as_int (V.vector_get v i) done;
    !total

  let mixed () =
    let v = V.vector 6 V.nil in
    V.vector_set v 0 (V.int 17);
    V.vector_set v 1 (V.bool true);
    V.vector_set v 2 (V.symbol "shen");
    V.vector_set v 3 (V.float 2.5);
    V.vector_set v 4 (V.cons (V.int 23) V.nil);
    v

  let mixed_mutate () =
    let v = mixed () in
    for i = 1 to 20_000 do
      V.vector_set v 0 (V.int i);
      V.vector_set v 4 (V.cons (V.int i) V.nil)
    done;
    V.as_int (V.vector_get v 0) + V.as_int (V.head (V.vector_get v 4))

  let cases = [
    "integer-sum", integer_sum, 20_000_100_000;
    "integer-fib", integer_fib, 121_393;
    "list-build-sum", list_build_sum, 200_010_000;
    "list-traverse", list_traverse, 200_010_000;
    "structural-equal", structural_equal, 1;
    "vector-mutate", vector_mutate, 100_000;
    "mixed-mutate", mixed_mutate, 40_000;
  ]

  let rejects f =
    match f () with
    | exception Invalid_argument _ -> ()
    | _ -> failwith "invalid operation accepted"

  let check () =
    let ints = [min_int; min_int + 1; -1; 0; 1; 2; max_int - 1; max_int] in
    List.iter (fun n -> assert (V.kind (V.int n) = Kind.Int);
      assert (V.as_int (V.int n) = n)) ints;
    List.iter (fun f ->
      assert (Int64.bits_of_float (V.as_float (V.float f)) = Int64.bits_of_float f))
      [0.; -0.; infinity; neg_infinity; nan; 0.125];
    let values = [V.int 0; V.int 1; V.nil; V.bool false; V.bool true;
                  V.float 0.; V.symbol ""; V.cons V.nil V.nil; V.vector 0 V.nil] in
    List.iter (fun v ->
      let k = V.kind v in
      if k <> Kind.Int then rejects (fun () -> V.as_int v);
      if k <> Kind.Bool then rejects (fun () -> V.as_bool v);
      if k <> Kind.Float then rejects (fun () -> V.as_float v);
      if k <> Kind.Symbol then rejects (fun () -> V.as_symbol v);
      if k <> Kind.Cons then (rejects (fun () -> V.head v); rejects (fun () -> V.tail v));
      if k <> Kind.Vector then (
        rejects (fun () -> V.vector_length v);
        rejects (fun () -> V.vector_get v 0);
        rejects (fun () -> V.vector_set v 0 V.nil))) values;
    List.iter (fun n -> List.iter (fun v -> assert (not (equal (V.int n) v)))
      [V.nil; V.bool false; V.bool true]) [0; 1];
    assert (not (equal (V.bool false) (V.bool true)));
    rejects (fun () -> V.vector (-1) V.nil);
    let empty = V.vector 0 V.nil in
    rejects (fun () -> V.vector_get empty 0);
    rejects (fun () -> V.vector_set empty (-1) V.nil);
    assert (equal (mixed ()) (mixed ()));
    let changed = mixed () in
    V.vector_set changed 2 (V.symbol "different");
    assert (not (equal (mixed ()) changed));
    let a = V.vector 2 V.nil and b = V.vector 2 V.nil in
    V.vector_set a 0 a; V.vector_set b 0 b;
    V.vector_set a 1 (V.int 7); V.vector_set b 1 (V.int 7);
    assert (equal a b);
    V.vector_set b 1 (V.int 8);
    assert (not (equal a b));
    let c = V.vector 2 V.nil and d = V.vector 2 V.nil in
    V.vector_set c 0 (V.cons (V.int max_int) c);
    V.vector_set d 0 (V.cons (V.int max_int) d);
    V.vector_set c 1 a; V.vector_set d 1 a;
    assert (equal c d);
    V.vector_set d 1 V.nil;
    assert (not (equal c d));
    List.iter (fun (_, f, expected) -> assert (f () = expected)) cases

  let stress () =
    (* Promote the root first, then install fresh young references into old
       arrays: exercises the write barrier, not just nursery scanning. *)
    let roots = V.vector 96 V.nil in
    let boundaries = [| min_int; min_int + 1; -1; 0; 1; 2; max_int - 1; max_int |] in
    let retained = V.vector (Array.length boundaries + 3) V.nil in
    Array.iteri (fun i n -> V.vector_set retained i (V.int n)) boundaries;
    V.vector_set retained 8 V.nil;
    V.vector_set retained 9 (V.bool false);
    V.vector_set retained 10 (V.bool true);
    Gc.full_major ();
    for round = 0 to 191 do
      let child = V.vector 5 V.nil in
      V.vector_set child 0 (V.int round);
      V.vector_set child 1 (V.cons (V.symbol (string_of_int round)) (V.int min_int));
      V.vector_set child 2 child;
      let nested = V.vector 1 child in
      V.vector_set child 3 nested;
      V.vector_set child 4 (V.float (float_of_int round +. 0.5));
      V.vector_set roots (round mod 96) child;
      for j = 0 to 1_000 do
        ignore (Sys.opaque_identity (V.cons (V.int j) (V.symbol "garbage")))
      done;
      Gc.minor ();
      if round mod 8 = 0 then Gc.full_major ();
      if round mod 32 = 0 then Gc.compact ();
      Array.iteri (fun i n ->
        assert (V.kind (V.vector_get retained i) = Kind.Int);
        assert (V.as_int (V.vector_get retained i) = n)) boundaries;
      assert (V.kind (V.vector_get retained 8) = Kind.Nil);
      assert (not (V.as_bool (V.vector_get retained 9)));
      assert (V.as_bool (V.vector_get retained 10));
      for slot = 0 to min round 95 do
        let expected = if slot <= round mod 96 then (round / 96) * 96 + slot else slot in
        let c = V.vector_get roots slot in
        assert (V.as_int (V.vector_get c 0) = expected);
        assert (V.as_symbol (V.head (V.vector_get c 1)) = string_of_int expected);
        assert (V.as_int (V.tail (V.vector_get c 1)) = min_int);
        assert (V.same c (V.vector_get c 2));
        assert (V.same c (V.vector_get (V.vector_get c 3) 0));
        assert (V.as_float (V.vector_get c 4) = float_of_int expected +. 0.5)
      done
    done;
    Gc.compact ();
    assert (V.vector_length roots = 96)
end
