(** Low-latency dynamic backend: resolve names and compile expressions to host
    closures once. Invocation uses compact indexed frames and captures only free
    lexical bindings. No AST dispatch or association-list lookup at runtime. *)
open Kl.Resolved
open Runtime.Value
module N = Runtime.Native

(* Observe the exact definition value before metadata callbacks can redefine
   its name. This hook is installation-only, never on the invocation path. *)
let definition_observer : (string -> Runtime.Value.value -> unit) ref =
  ref (fun _ _ -> ())

let rec literal = function
  | Kl.Ast.KLInt n -> Int n
  | KLFloat n -> Float n
  | KLStr s -> Str s
  | KLSym "true" | KLBool true -> Bool true
  | KLSym "false" | KLBool false -> Bool false
  | KLSym s -> Sym s
  | KLNil -> Nil
  | KLVec values -> Vec (Array.map literal values)
  | KLCons (a, b) -> Cons (literal a, literal b)
  | KLApp (f, args) -> List.fold_right (fun x rest -> Cons (literal x, rest)) (f :: args) Nil
  | _ -> raise (Compile_error "invalid literal")

let compile forms =
  let forms = resolve forms in
  let slot env id = match List.assoc_opt id env with
    | Some index -> index
    | None -> raise (Compile_error "unresolved lexical slot")
  in
  let allocate (next, high) =
    let index = !next in incr next; high := max !high !next; index
  in
  (* Expression-local slots die when evaluation returns. Returned closures have
     already copied their captures, so siblings (including branches) may use the
     same slots. Only the lexical bindings in [env] remain live. *)
  let rec emit env ((current, _) as next) expression =
    let saved = !current in
    let code = emit_scoped env next expression in
    current := saved;
    code
  and emit_scoped env next = function
    | Literal atom -> let value = literal atom in fun _ -> value
    | Local p -> let index = slot env p.id in fun frame -> frame.(index)
    | Let (p, value, body) ->
        let value = emit env next value in
        if not (Ids.mem p.id (free_variables body)) then
          let body = emit env next body in
          fun frame -> ignore (value frame); body frame
        else
          let index = allocate next in
          let body = emit ((p.id, index) :: env) next body in
          fun frame -> let value = value frame in frame.(index) <- value; body frame
    | If (c, t, f) ->
        let c = emit env next c in let t = emit env next t in let f = emit env next f in
        fun frame -> if N.boolean (c frame) then t frame else f frame
    | Lambda (params, body) -> lambda env params body
    | Freeze body -> lambda env [] body
    | Thaw body -> let body = emit env next body in fun frame -> N.apply0 (body frame)
    | Sequence (a, b) -> let a = emit env next a in let b = emit env next b in
        fun frame -> ignore (a frame); b frame
    | And (a, b) -> let a = emit env next a in let b = emit env next b in
        fun frame -> of_bool (N.boolean (a frame) && N.boolean (b frame))
    | Or (a, b) -> let a = emit env next a in let b = emit env next b in
        fun frame -> of_bool (N.boolean (a frame) || N.boolean (b frame))
    | Cons (a, b) -> let a = emit env next a in let b = emit env next b in
        fun frame -> let a = a frame in let b = b frame in Cons (a, b)
    | Trap (body, Lambda ([parameter], handler)) ->
        let body = emit env next body in
        let uses_error = Ids.mem parameter.id (free_variables handler) in
        let index = if uses_error then allocate next else -1 in
        let handler_env = if uses_error then (parameter.id, index) :: env else env in
        let handler_code = emit handler_env next handler in
        fun frame ->
          (try body frame with User_error message ->
            if uses_error then frame.(index) <- Error message;
            handler_code frame)
    | Trap (body, handler) ->
        let body = emit env next body in let handler = emit env next handler in
        fun frame -> let handler = handler frame in N.protect (fun () -> body frame) handler
    | Cond clauses ->
        let clauses = List.map (fun (c, body) -> emit env next c, emit env next body) clauses in
        let rec run frame = function
          | [] -> raise (User_error "cond: no true clause")
          | (c, body) :: rest -> if N.boolean (c frame) then body frame else run frame rest
        in fun frame -> run frame clauses
    | Call (Named name, args) ->
        let args = List.map (emit env next) args in
        let cell = Runtime.Env.function_cell name in
        (match args with
        | [] -> fun _ -> N.call0 cell
        | [a] -> fun frame -> let a = a frame in N.call1 cell a
        | [a; b] -> fun frame -> let a = a frame in let b = b frame in N.call2 cell a b
        | [a; b; c] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in N.call3 cell a b c
        | [a; b; c; d] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in let d = d frame in
             N.call4 cell a b c d
        | [a; b; c; d; e] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in let d = d frame in
            let e = e frame in N.call5 cell a b c d e
        | [a; b; c; d; e; f] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in let d = d frame in
            let e = e frame in let f = f frame in N.call6 cell a b c d e f
        | [a; b; c; d; e; f; g] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in let d = d frame in
            let e = e frame in let f = f frame in let g = g frame in N.call7 cell a b c d e f g
        | [a; b; c; d; e; f; g; h] -> fun frame ->
            let a = a frame in let b = b frame in let c = c frame in let d = d frame in
            let e = e frame in let f = f frame in let g = g frame in let h = h frame in
            N.call8 cell a b c d e f g h
        | _ -> fun frame ->
            let values = List.map (fun arg -> arg frame) args in N.call_cell cell values)
    | Call (Dynamic op, args) ->
        let op = emit env next op in
        let args = List.map (emit env next) args in
        let rec run frame fn = function
          | [] -> N.apply0 fn
          | [arg] -> let arg = arg frame in N.apply1 fn arg
          | arg :: rest -> let arg = arg frame in let fn = N.apply1 fn arg in run frame fn rest
        in fun frame -> let fn = op frame in run frame fn args
    | Define d ->
        let fn = lambda env d.params d.body in
        fun frame ->
          let callable = fn frame in
          !definition_observer d.name callable;
          N.install d.name (List.length d.params) callable
  and lambda outer_env params body =
    let used = free_variables body in
    let free = Ids.elements (without params used) in
    let capture_indices = Array.of_list (List.map (slot outer_env) free) in
    let arity = List.length params in
    let live_params = List.filter (fun p -> Ids.mem p.id used) params in
    let parameter_count = List.length live_params in
    let ids = List.map (fun p -> p.id) live_params @ free in
    let env = List.mapi (fun index id -> id, index) ids in
    let parameter_slots = Array.of_list (List.map (fun p ->
      if Ids.mem p.id used then slot env p.id else -1) params) in
    let set frame parameter value =
      let index = parameter_slots.(parameter) in
      if index >= 0 then frame.(index) <- value
    in
    let next = ref (List.length ids), ref (List.length ids) in
    let body = emit env next body in
    let frame_size = !(snd next) in
    let frames =
      if parameter_count = 0 && frame_size = Array.length capture_indices then
        (* No writes, including to parameters: this private capture snapshot is
           immutable. Sharing it is safe even across escape and reentrancy. *)
        if frame_size = 0 then
          let empty = [||] in let frame () = empty in fun _ -> frame
        else fun outer ->
          let captures = Array.map (Array.get outer) capture_indices in
          fun () -> captures
      else match Array.to_list capture_indices with
      | [] ->
          let frame () = Array.make frame_size Nil in fun _ -> frame
      | [index] -> fun outer ->
          let capture = outer.(index) in
          fun () ->
            let frame = Array.make frame_size Nil in
            frame.(parameter_count) <- capture;
            frame
      | [first; second] -> fun outer ->
          let a = outer.(first) and b = outer.(second) in
          fun () ->
            let frame = Array.make frame_size Nil in
            frame.(parameter_count) <- a;
            frame.(parameter_count + 1) <- b;
            frame
      | _ -> fun outer ->
          let captures = Array.map (Array.get outer) capture_indices in
          fun () ->
            let frame = Array.make frame_size Nil in
            Array.blit captures 0 frame parameter_count (Array.length captures);
            frame
    in
    fun outer ->
      let frame = frames outer in
      match arity with
      | 0 -> N.function0 (fun () -> body (frame ()))
      | 1 -> N.function1 (fun a -> let frame = frame () in set frame 0 a; body frame)
      | 2 -> N.function2 (fun a b ->
          let frame = frame () in set frame 0 a; set frame 1 b; body frame)
      | 3 -> N.function3 (fun a b c ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c; body frame)
      | 4 -> N.function4 (fun a b c d ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c;
          set frame 3 d; body frame)
      | 5 -> N.function5 (fun a b c d e ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c;
          set frame 3 d; set frame 4 e; body frame)
      | 6 -> N.function6 (fun a b c d e f ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c;
          set frame 3 d; set frame 4 e; set frame 5 f; body frame)
      | 7 -> N.function7 (fun a b c d e f g ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c;
          set frame 3 d; set frame 4 e; set frame 5 f; set frame 6 g; body frame)
      | 8 -> N.function8 (fun a b c d e f g h ->
          let frame = frame () in set frame 0 a; set frame 1 b; set frame 2 c;
          set frame 3 d; set frame 4 e; set frame 5 f; set frame 6 g;
          set frame 7 h; body frame)
      | _ -> N.function_ arity (fun args ->
          let frame = frame () in
          List.iteri (set frame) args;
          body frame)
  in
  let next = ref 0, ref 0 in
  let actions = List.map (emit [] next) forms in
  let frame_size = !(snd next) in
  let rec run frame = function
    | [] -> Nil
    | [action] -> action frame
    | action :: rest -> ignore (action frame); run frame rest
  in
  fun () -> run (Array.make frame_size Nil) actions

let eval_kl expression = (compile [expression]) ()
let eval_value value =
  try eval_kl (Eval.value_to_kl_expr value) with
  | Compile_error message | Eval.Eval_error message -> raise (User_error message)
let install () = Runtime.Env.set_eval_kl_from_value eval_value
