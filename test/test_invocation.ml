(* RF.2: invocation-owned state over a reusable evaluation context. *)

open Jacquard

let prelude_dir = "../prelude"
let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let fresh_root =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let root =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-invocation-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    at_exit (fun () -> try remove_tree root with Unix.Unix_error _ | Sys_error _ -> ());
    root

(* One prepared program: a store with the prelude and [declarations], and a context over it. *)
let prepared label declarations =
  let store, ctx =
    expect_ok "open session" (Frontend.open_session ~prelude_dir ~root:(fresh_root label))
  in
  expect_ok "declarations"
    (Frontend.walk ~syntax:Frontend.Auto ~file:"program.jac" store declarations);
  (store, ctx)

let expression store source =
  let tops, _ =
    expect_ok "parse"
      (Frontend.parse_tops ~syntax:Frontend.Auto ~names:(Store.names_view store) ~file:"e.jac"
         source)
  in
  match List.map (fun top -> expect_ok "validate" (Frontend.validate_parsed_top top)) tops with
  | [ Kernel.Expr expr ] -> (
      match expect_ok "resolve" (Resolve.resolve (Store.names_view store) (Kernel.Expr expr)) with
      | Kernel.Expr resolved -> resolved
      | Kernel.Decl _ -> Alcotest.fail "expected an expression")
  | _ -> Alcotest.fail "expected one expression"

(* A root operation with no grant is [Unhandled]; any other failure is reported by its code. *)
let failure = function
  | Ok value -> Alcotest.failf "expected a runtime failure, got %s" (Value.show value)
  | Error (Runtime_err.Unhandled _) -> "unhandled"
  | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)

let run_state ctx state =
  match Eval.run_state_capturing ctx state with
  | Ok (Eval.CValue value) -> Ok value
  | Ok (Eval.COp { name; _ }) -> Alcotest.failf "unexpected root operation %s" name
  | Error error -> Error error

let grant_console ctx buffer =
  expect_ok "grant console"
    (Prelude.grant ctx "console" ~infer_cache:None ~out:(Buffer.add_string buffer) ~seed:0)

let test_grants_are_scoped () =
  let store, ctx = prepared "grants" "" in
  let greet = expression store "print(\"hello\")" in
  let first = Buffer.create 16 and second = Buffer.create 16 in
  (* each invocation grants its own sink; neither sees the other's output *)
  Eval.with_invocation ctx (fun _ ->
      grant_console ctx first;
      ignore (Eval.run_expr ctx greet));
  Eval.with_invocation ctx (fun _ ->
      grant_console ctx second;
      ignore (Eval.run_expr ctx greet));
  Alcotest.(check string) "first sink" "hello" (Buffer.contents first);
  Alcotest.(check string) "second sink" "hello" (Buffer.contents second);
  (* an invocation that grants nothing inherits nothing *)
  let code = Eval.with_invocation ctx (fun _ -> failure (Eval.run_expr ctx greet)) in
  Alcotest.(check string) "ungranted console is unhandled" "unhandled" code;
  Alcotest.(check string) "no stray output" "hello" (Buffer.contents first)

let test_stale_once_resumption () =
  let store, ctx = prepared "once" "once effect Probe where { probe.next : () -> Int }\n" in
  let asking = expression store "add(probe.next(), 1)" in
  let capture () =
    match
      expect_ok "capture"
        (Result.map_error
           (fun e -> [ Runtime_err.to_diag e ])
           (Eval.run_state_capturing ctx (Eval.expr_state asking)))
    with
    | Eval.COp { kont; _ } -> kont
    | Eval.CValue _ -> Alcotest.fail "the operation was not captured"
  in
  (* a capture resumes within the invocation that made it *)
  let resumed =
    Eval.with_invocation ctx (fun _ ->
        let kont = capture () in
        match Eval.resume_captured_state ctx kont (Value.VInt 41) with
        | Ok state -> run_state ctx state
        | Error error -> Error error)
  in
  (match resumed with
  | Ok (Value.VInt 42) -> ()
  | Ok value -> Alcotest.failf "resumed to %s" (Value.show value)
  | Error error -> Alcotest.failf "resume failed: %s" (Diag.to_string (Runtime_err.to_diag error)));
  (* Once ownership is evaluator-lifetime: a capture from an earlier invocation over the same
     program still resumes (memoized values may hold resumptions), and its affine budget holds *)
  let kept = Eval.with_invocation ctx (fun _ -> capture ()) in
  let later =
    Eval.with_invocation ctx (fun _ ->
        match Eval.resume_captured_state ctx kept (Value.VInt 1) with
        | Ok state -> run_state ctx state
        | Error error -> Error error)
  in
  (match later with
  | Ok (Value.VInt 2) -> ()
  | Ok value -> Alcotest.failf "later invocation resumed to %s" (Value.show value)
  | Error error ->
      Alcotest.failf "later resume failed: %s" (Diag.to_string (Runtime_err.to_diag error)));
  let twice =
    Eval.with_invocation ctx (fun _ ->
        match Eval.resume_captured_state ctx kept (Value.VInt 1) with
        | Ok state -> failure (run_state ctx state)
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error))
  in
  Alcotest.(check string) "the budget is spent once" "E0906" twice;
  (* a capture from another evaluator is refused before its budget is spent *)
  let _other_store, other =
    prepared "once-other" "once effect Probe where { probe.next : () -> Int }\n"
  in
  let foreign = Eval.with_invocation ctx (fun _ -> capture ()) in
  let code =
    Eval.with_invocation other (fun _ ->
        match Eval.resume_captured_state other foreign (Value.VInt 1) with
        | Ok state -> failure (run_state other state)
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error))
  in
  Alcotest.(check string) "foreign once resumption refused" "E0907" code;
  (* ... and it is still resumable where it was made: the refusal consumed nothing *)
  match
    Eval.with_invocation ctx (fun _ -> Eval.resume_captured_state ctx foreign (Value.VInt 5))
  with
  | Ok state -> (
      match run_state ctx state with
      | Ok (Value.VInt 6) -> ()
      | Ok value -> Alcotest.failf "owner resumed to %s" (Value.show value)
      | Error error ->
          Alcotest.failf "owner resume failed: %s" (Diag.to_string (Runtime_err.to_diag error)))
  | Error error ->
      Alcotest.failf "owner resume refused: %s" (Diag.to_string (Runtime_err.to_diag error))

exception Boom

let test_restoration_on_exception () =
  let store, ctx = prepared "restore" "" in
  let greet = expression store "print(\"hello\")" in
  let sink = Buffer.create 16 in
  (match
     Eval.with_invocation ~coverage:false ctx (fun _ ->
         grant_console ctx sink;
         Alcotest.(check bool) "active inside" true (Eval.invocation_active ctx);
         raise Boom)
   with
  | () -> Alcotest.fail "the body's exception was swallowed"
  | exception Boom -> ());
  Alcotest.(check bool) "inactive after" false (Eval.invocation_active ctx);
  (* the grant made before the exception is gone *)
  let code = Eval.with_invocation ctx (fun _ -> failure (Eval.run_expr ctx greet)) in
  Alcotest.(check string) "grant withdrawn" "unhandled" code;
  (* one outer observer stays in effect across an invocation that raises (even after a nested
     observer raised inside it) and still observes the next invocation in the same extent *)
  let seen = ref 0 in
  Eval.with_root_observer ctx
    ~on_operation:(fun _ -> incr seen)
    ~on_output:(fun _ _ -> ())
    (fun () ->
      (match
         Eval.with_invocation ctx (fun _ ->
             grant_console ctx sink;
             ignore (Eval.run_expr ctx greet);
             Eval.with_root_observer ctx
               ~on_operation:(fun _ -> ())
               ~on_output:(fun _ _ -> ())
               (fun () -> raise Boom))
       with
      | () -> Alcotest.fail "no exception"
      | exception Boom -> ());
      Alcotest.(check int) "the outer observer saw the raising invocation's operation" 1 !seen;
      Eval.with_invocation ctx (fun _ ->
          grant_console ctx sink;
          ignore (Eval.run_expr ctx greet)));
  Alcotest.(check int) "the same outer observer is back in effect afterwards" 2 !seen;
  (* coverage tracking is back on: a term reference is recorded again *)
  let _, covered =
    Eval.with_fresh_coverage ctx (fun () ->
        ignore (Eval.run_expr ctx (expression store "list.length([1, 2])")))
  in
  Alcotest.(check bool) "coverage restored" true (covered <> [])

let test_teardown_exactly_once () =
  let _store, ctx = prepared "teardown" "" in
  let log = ref [] in
  let note label () = log := label :: !log in
  let kept =
    Eval.with_invocation ctx (fun invocation ->
        Eval.on_teardown invocation (note "first");
        Eval.on_teardown invocation (note "second");
        invocation)
  in
  Alcotest.(check (list string)) "most recent first, once" [ "second"; "first" ] (List.rev !log);
  (match Eval.on_teardown kept (note "late") with
  | () -> Alcotest.fail "registered on an ended invocation"
  | exception Invalid_argument _ -> ());
  (* on an exception every callback still runs once and the body's exception wins *)
  log := [];
  (match
     Eval.with_invocation ctx (fun invocation ->
         Eval.on_teardown invocation (fun () ->
             note "failing" ();
             failwith "teardown");
         Eval.on_teardown invocation (note "after");
         raise Boom)
   with
  | () -> Alcotest.fail "no exception"
  | exception Boom -> ()
  | exception Failure _ -> Alcotest.fail "a teardown failure replaced the body's exception");
  Alcotest.(check (list string)) "all ran" [ "after"; "failing" ] (List.rev !log);
  (* after a normal body the first teardown failure is reported once every callback ran *)
  log := [];
  (match
     Eval.with_invocation ctx (fun invocation ->
         Eval.on_teardown invocation (note "last");
         Eval.on_teardown invocation (fun () -> failwith "teardown"))
   with
  | () -> Alcotest.fail "the teardown failure was lost"
  | exception Failure message -> Alcotest.(check string) "failure" "teardown" message);
  Alcotest.(check (list string)) "remaining callback ran" [ "last" ] (List.rev !log);
  (* invocations do not nest *)
  match Eval.with_invocation ctx (fun _ -> Eval.with_invocation ctx (fun _ -> ())) with
  | () -> Alcotest.fail "nested invocation accepted"
  | exception Invalid_argument _ ->
      Alcotest.(check bool) "outer ended cleanly" false (Eval.invocation_active ctx)

let test_program_is_reusable () =
  (* the memo and builtins persist across invocations; results are unchanged *)
  let store, ctx = prepared "reuse" "fact(n) = if eq(n, 0) then 1 else mul(n, fact(sub(n, 1)))\n" in
  let call = expression store "fact(10)" in
  let run () =
    Eval.with_invocation ~coverage:false ctx (fun _ ->
        match Eval.run_expr ctx call with
        | Ok value -> Value.show value
        | Error error -> Diag.to_string (Runtime_err.to_diag error))
  in
  let first = run () in
  Alcotest.(check string) "first" "3628800" first;
  Alcotest.(check string) "second" first (run ());
  Alcotest.(check string) "third" first (run ())

(* --- computation fuel (RT.1) --- *)

(* [fuel ctx ?budget source] evaluates [source] in one invocation and returns its rendered result
   (or failure code) and the fuel it used. *)
let fueled ?budget ctx store source =
  let call = expression store source in
  Eval.with_invocation ~coverage:false ?fuel:budget ctx (fun invocation ->
      let outcome =
        match Eval.run_expr ctx call with
        (* rendering the finished result is outside the budget, as it is for the CLI *)
        | Ok value -> Fuel_meter.unmetered (fun () -> Value.show value)
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
      in
      (outcome, Eval.fuel_used invocation))

let test_fuel_stops_a_pure_loop () =
  let store, ctx = prepared "fuel-loop" "spin(n) = spin(add(n, 1))\n" in
  let first = fueled ~budget:10_000 ctx store "spin(0)" in
  Alcotest.(check (pair string int)) "stops at the budget" ("E0919", 10_000) first;
  (* the boundary is reproducible, on this evaluator and on a fresh one *)
  Alcotest.(check (pair string int))
    "same boundary" first
    (fueled ~budget:10_000 ctx store "spin(0)");
  let store, ctx = prepared "fuel-loop-fresh" "spin(n) = spin(add(n, 1))\n" in
  Alcotest.(check (pair string int))
    "same boundary on a fresh evaluator" first
    (fueled ~budget:10_000 ctx store "spin(0)");
  (* a zero budget refuses the very first transition *)
  Alcotest.(check (pair string int)) "zero budget" ("E0919", 0) (fueled ~budget:0 ctx store "1")

let fact_program = "fact(n) = if eq(n, 0) then 1 else mul(n, fact(sub(n, 1)))\n"

let test_fuel_exact_boundary () =
  let store, ctx = prepared "fuel-exact" fact_program in
  let result, cost = fueled ctx store "fact(10)" in
  Alcotest.(check string) "unbounded result" "3628800" result;
  Alcotest.(check bool) "the run costs something" true (cost > 0);
  Alcotest.(check (pair string int))
    "completes at exactly its cost" (result, cost)
    (fueled ~budget:cost ctx store "fact(10)");
  Alcotest.(check (pair string int))
    "one unit short is exhausted"
    ("E0919", cost - 1)
    (fueled ~budget:(cost - 1) ctx store "fact(10)");
  (* an unbounded invocation still counts, and bounding it changes nothing else *)
  Alcotest.(check (pair string int))
    "generous budget" (result, cost)
    (fueled ~budget:(cost * 10) ctx store "fact(10)")

let test_fuel_is_shared_by_multi_shot_branches () =
  let store, ctx =
    prepared "fuel-multi"
      "effect Pick where { multi pick : () -> Int }\n\
       fact(n) = if eq(n, 0) then 1 else mul(n, fact(sub(n, 1)))\n\
       both(body) = handle body() {\n\
      \  | return value -> value\n\
      \  | pick() resume k -> add(k(0), k(1))\n\
       }\n"
  in
  let one = snd (fueled ctx store "fact(8)") in
  let _, both_cost = fueled ctx store "both(fn () -> fact(add(pick(), 8)))" in
  (* both branches pay: the resumed branches cannot share a copied allowance *)
  Alcotest.(check bool) "aggregate exceeds two branches" true (both_cost > 2 * one);
  Alcotest.(check (pair string int))
    "a budget for one branch is not enough for both"
    ("E0919", 2 * one)
    (fueled ~budget:(2 * one) ctx store "both(fn () -> fact(add(pick(), 8)))");
  (* exact enumeration drives every branch through one invocation too *)
  let model =
    expression store "{ let c = `op:sample`(Bernoulli(0.5)); fact(if c then 8 else 9) }"
  in
  let enumerate budget =
    Eval.with_invocation ?fuel:budget ctx (fun invocation ->
        let outcome =
          match Infer_dist.enumerate_v1 ctx (Eval.expr_state model) with
          | Ok _ -> "posterior"
          | Error diagnostics -> String.concat "," (List.map Diag.code_or_uncoded diagnostics)
        in
        (outcome, Eval.fuel_used invocation))
  in
  let outcome, cost = enumerate None in
  Alcotest.(check string) "enumerates" "posterior" outcome;
  Alcotest.(check bool) "both branches paid" true (cost > 2 * one);
  Alcotest.(check (pair string int)) "exact" ("posterior", cost) (enumerate (Some cost));
  Alcotest.(check (pair string int))
    "an exhausted enumeration is E0919, not a runtime failure"
    ("E0919", cost - 1)
    (enumerate (Some (cost - 1)))

let memo_program =
  fact_program
  ^ "base = fact(12)\n\
     derived = add(base, 1)\n\
     other = add(base, derived)\n\
     spliced = quote { pair(unquote(code.of-int(base)), 2) }\n"

(* --- logical allocation (RT.2) --- *)

let allocated ?budget ctx store source =
  let call = expression store source in
  Eval.with_invocation ~coverage:false ?alloc:budget ctx (fun invocation ->
      let outcome =
        match Eval.run_expr ctx call with
        | Ok value -> Fuel_meter.unmetered (fun () -> Value.show value)
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
      in
      (outcome, Eval.alloc_used invocation))

let list_program =
  "type Chain = End | Link Int Chain\n\
   build(n) = if eq(n, 0) then End else Link(n, build(sub(n, 1)))\n\
   size(xs) = match xs { | End -> 0 | Link(_, rest) -> add(1, size(rest)) }\n"

let test_alloc_exact_boundary () =
  let store, ctx = prepared "alloc-exact" list_program in
  let result, cost = allocated ctx store "size(build(50))" in
  Alcotest.(check string) "unbounded result" "50" result;
  Alcotest.(check bool) "the run allocates" true (cost > 50);
  Alcotest.(check (pair string int))
    "same count on a fresh evaluator" (result, cost)
    (let store, ctx = prepared "alloc-exact-fresh" list_program in
     allocated ctx store "size(build(50))");
  Alcotest.(check (pair string int))
    "completes at exactly its cost" (result, cost)
    (allocated ~budget:cost ctx store "size(build(50))");
  Alcotest.(check (pair string int))
    "one cell short is exhausted"
    ("E0921", cost - 1)
    (allocated ~budget:(cost - 1) ctx store "size(build(50))");
  Alcotest.(check (pair string int))
    "zero budget" ("E0921", 0)
    (allocated ~budget:0 ctx store "size(build(1))")

let test_alloc_is_shared_by_multi_shot_branches () =
  let store, ctx =
    prepared "alloc-multi"
      (list_program
     ^ "effect Pick where { multi pick : () -> Int }\n\
        both(body) = handle body() {\n\
       \  | return value -> value\n\
       \  | pick() resume k -> add(k(0), k(1))\n\
        }\n")
  in
  let one = snd (allocated ctx store "size(build(20))") in
  let _, both_cost = allocated ctx store "both(fn () -> size(build(add(pick(), 20))))" in
  (* both resumed branches build their own chain, and capture and resumption pay per frame *)
  Alcotest.(check bool) "aggregate exceeds two branches" true (both_cost > 2 * one);
  Alcotest.(check (pair string int))
    "a budget for one branch is not enough for both"
    ("E0921", 2 * one)
    (allocated ~budget:(2 * one) ctx store "both(fn () -> size(build(add(pick(), 20))))")

let test_alloc_ignores_memo_warmth () =
  (* a memoized term's allocation is charged once per invocation, warm or cold *)
  let cold source =
    let store, ctx = prepared "alloc-memo-cold" memo_program in
    snd (allocated ctx store source)
  in
  let store, ctx = prepared "alloc-memo-warm" memo_program in
  List.iter
    (fun source ->
      let expected = cold source in
      Alcotest.(check int) ("warm " ^ source) expected (snd (allocated ctx store source)))
    [ "other"; "derived"; "base"; "spliced"; "other" ]

let test_alloc_nullary_and_driver_resumptions () =
  let store, ctx = prepared "alloc-nullary" list_program in
  Alcotest.(check (pair string int))
    "a nullary constructor costs a cell" ("E0921", 0)
    (allocated ~budget:0 ctx store "End");
  Alcotest.(check (pair string int))
    "and fits in one" ("end", 1)
    (allocated ~budget:1 ctx store "End");
  (* exact enumeration resumes captured continuations from the driver: each reinstalled frame
     costs a cell, so the posterior needs its whole cost *)
  let model =
    expression store "{ let c = `op:sample`(Bernoulli(0.5)); size(build(if c then 3 else 4)) }"
  in
  let enumerate budget =
    Eval.with_invocation ?alloc:budget ctx (fun invocation ->
        let outcome =
          match Infer_dist.enumerate_v1 ctx (Eval.expr_state model) with
          | Ok _ -> "posterior"
          | Error _ -> "incomplete"
        in
        (outcome, Eval.alloc_used invocation))
  in
  let outcome, cost = enumerate None in
  Alcotest.(check string) "enumerates" "posterior" outcome;
  Alcotest.(check (pair string int)) "exact" ("posterior", cost) (enumerate (Some cost));
  Alcotest.(check string) "one cell short" "incomplete" (fst (enumerate (Some (cost - 1))))

(* a warm memo hit stops where a cold run does when one budget runs out: the same outcome, and the
   same count on that budget. A cold run charges a memoized term's fuel and cells as they happen, a
   warm hit replays each segment's fuel before its cells, so the other budget's count may differ by
   one segment's charges; when both run out inside the term, the codes may differ too, and both
   runs are incomplete (owner decision, 2026-10-29) *)
let test_alloc_and_fuel_memo_order () =
  let outcome ctx store ~fuel ~alloc source =
    let call = expression store source in
    Eval.with_invocation ~coverage:false ~fuel ~alloc ctx (fun invocation ->
        let code =
          match Eval.run_expr ctx call with
          | Ok _ -> "value"
          | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
        in
        (code, Eval.fuel_used invocation, Eval.alloc_used invocation))
  in
  List.iter
    (fun (fuel, alloc) ->
      let cold =
        let store, ctx = prepared "alloc-order-cold" memo_program in
        outcome ctx store ~fuel ~alloc "spliced"
      in
      let store, ctx = prepared "alloc-order-warm" memo_program in
      ignore (outcome ctx store ~fuel:1_000_000 ~alloc:1_000_000 "spliced");
      let warm = outcome ctx store ~fuel ~alloc "spliced" in
      (* keep the count of the budget that ran out, or both when the run completed *)
      let binding (code, fuel_used, cells) =
        match code with
        | "E0919" -> (code, fuel_used, -1)
        | "E0921" -> (code, -1, cells)
        | _ -> (code, fuel_used, cells)
      in
      Alcotest.(check (triple string int int))
        (Printf.sprintf "fuel %d alloc %d" fuel alloc)
        (binding cold) (binding warm))
    [
      (0, 1_000_000);
      (5, 1_000_000);
      (50, 1_000_000);
      (200, 1_000_000);
      (1_000_000, 0);
      (1_000_000, 5);
      (1_000_000, 50);
      (1_000_000, 1_000_000);
    ];
  (* both budgets binding inside the memoized term: both runs are incomplete *)
  List.iter
    (fun (fuel, alloc) ->
      let incomplete (code, _, _) = List.mem code [ "E0919"; "E0921" ] in
      let store, ctx = prepared "alloc-both-cold" memo_program in
      let cold = outcome ctx store ~fuel ~alloc "spliced" in
      let store, ctx = prepared "alloc-both-warm" memo_program in
      ignore (outcome ctx store ~fuel:1_000_000 ~alloc:1_000_000 "spliced");
      let warm = outcome ctx store ~fuel ~alloc "spliced" in
      Alcotest.(check (pair bool bool))
        (Printf.sprintf "both incomplete, fuel %d alloc %d" fuel alloc)
        (true, true)
        (incomplete cold, incomplete warm))
    [ (50, 3); (200, 10) ]

(* a memoized term that failed inside another one, caught by a native, still counts in the
   survivor's record *)
let test_alloc_failed_memo_dependency () =
  let doomed_store, doomed_ctx = prepared "alloc-doomed" "doomed = { let x = (); div(1, 0) }\n" in
  let doomed = expression doomed_store "doomed" in
  let store, ctx = prepared "alloc-bridge" "bridge(u) = 0\nouter = bridge(1)\n" in
  (match Store.lookup_kind store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin ctx hash
        (Value.VBuiltin
           ("bridge", fun _ -> match Eval.run_expr doomed_ctx doomed with _ -> Ok (Value.VInt 0)))
  | None -> Alcotest.fail "bridge not declared");
  let outer = expression store "outer" in
  let cells () =
    Eval.with_invocation ctx (fun invocation ->
        ignore (Eval.run_expr ctx outer);
        Eval.alloc_used invocation)
  in
  let cold = cells () in
  Alcotest.(check bool) "the failed term allocated" true (cold > 0);
  Alcotest.(check int) "warm counts the failed dependency's cells" cold (cells ())

let test_alloc_exhaustion_is_sticky () =
  let store, ctx = prepared "alloc-sticky" list_program in
  let first = expression store "size(build(30))" and second = expression store "1" in
  let outcomes =
    Eval.with_invocation ~alloc:10 ctx (fun _ ->
        let code = function
          | Ok _ -> "value"
          | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
        in
        let a = code (Eval.run_expr ctx first) in
        (* a later run that allocates nothing still cannot deliver a value *)
        (a, code (Eval.run_expr ctx second)))
  in
  Alcotest.(check (pair string string)) "sticky" ("E0921", "E0921") outcomes;
  (* the next invocation starts fresh *)
  Alcotest.(check (pair string int))
    "fresh invocation" ("1", 0)
    (allocated ~budget:10 ctx store "1")

let test_fuel_ignores_memo_warmth () =
  (* the fuel an expression costs is the same on a fresh evaluator and after any earlier
     invocation warmed the memo in any order *)
  let cold source =
    let store, ctx = prepared "fuel-memo-cold" memo_program in
    snd (fueled ctx store source)
  in
  let sources =
    [ "base"; "derived"; "other"; "add(derived, base)"; "add(other, 1)"; "code.render(spliced)" ]
  in
  let expected = List.map (fun source -> (source, cold source)) sources in
  let orders =
    [
      sources;
      List.rev sources;
      [ "other"; "code.render(spliced)"; "base"; "add(other, 1)"; "derived"; "add(derived, base)" ];
    ]
  in
  List.iter
    (fun order ->
      let store, ctx = prepared "fuel-memo-warm" memo_program in
      List.iter
        (fun source ->
          let _, cost = fueled ctx store source in
          Alcotest.(check int) ("warm " ^ source) (List.assoc source expected) cost;
          (* repeating within a warm evaluator also costs the same *)
          Alcotest.(check int) ("again " ^ source) cost (snd (fueled ctx store source)))
        order)
    orders;
  (* the recorded cost is a real cost: a warm memo still needs the budget a cold one would *)
  let store, ctx = prepared "fuel-memo-budget" memo_program in
  ignore (fueled ctx store "other");
  let cost = List.assoc "other" expected in
  Alcotest.(check (pair string int))
    "warm memo exhausts like a cold one"
    ("E0919", cost - 1)
    (fueled ~budget:(cost - 1) ctx store "other")

let test_fuel_charges_native_payloads () =
  let store, ctx = prepared "fuel-native" "" in
  let small = snd (fueled ctx store "text.length(\"\")") in
  let big = String.make 6400 'x' in
  let large = snd (fueled ctx store (Printf.sprintf "text.length(\"%s\")" big)) in
  (* 6400 argument bytes are 100 units; the Int result is free *)
  Alcotest.(check int) "argument bytes are charged" (small + 100) large;
  let concat source = snd (fueled ctx store source) in
  (* 12800 argument bytes (200) and a 12800-byte result (200) *)
  Alcotest.(check int)
    "argument and result bytes are charged"
    (concat "text.concat(\"\", \"\")" + 400)
    (concat (Printf.sprintf "text.concat(\"%s\", \"%s\")" big big))

let test_fuel_exhaustion_is_sticky () =
  let store, ctx = prepared "fuel-sticky" "spin(n) = spin(add(n, 1))\n" in
  let spin = expression store "spin(0)" and one = expression store "add(1, 2)" in
  let codes =
    Eval.with_invocation ~fuel:1_000 ctx (fun _ ->
        let first = failure (Eval.run_expr ctx spin) in
        (* nothing later in the invocation can produce a value *)
        let later = failure (Eval.run_expr ctx one) in
        [ first; later ])
  in
  Alcotest.(check (list string)) "exhausted, then refused" [ "E0919"; "E0919" ] codes;
  (* the next invocation has its own budget *)
  let cost = snd (fueled ctx store "add(1, 2)") in
  Alcotest.(check (pair string int))
    "fresh invocation" ("3", cost)
    (fueled ~budget:cost ctx store "add(1, 2)");
  match Eval.with_invocation ~fuel:(-1) ctx (fun _ -> ()) with
  | () -> Alcotest.fail "negative fuel accepted"
  | exception Invalid_argument _ ->
      Alcotest.(check bool) "no invocation left behind" false (Eval.invocation_active ctx)

let test_fuel_does_not_retry_side_effects () =
  let store, ctx = prepared "fuel-effects" "spin(n) = spin(add(n, 1))\n" in
  let sink = Buffer.create 16 in
  let code =
    Eval.with_invocation ~fuel:1_000 ctx (fun _ ->
        grant_console ctx sink;
        failure (Eval.run_expr ctx (expression store "{ print(\"once\"); spin(0) }")))
  in
  Alcotest.(check string) "exhausted" "E0919" code;
  Alcotest.(check string) "the effect before exhaustion happened once" "once" (Buffer.contents sink)

let test_fuel_bounds_deep_natives () =
  (* sharing makes a value's expanded size exponential in what building it cost; a native that
     renders or hashes the whole value pays for that size before it runs, and the measurement
     itself stops at the budget *)
  let store, ctx =
    prepared "fuel-deep"
      "type T = | L | N(left: T, right: T)\n\
       dbl(x, k) = if eq(k, 0) then x else dbl(N(x, x), sub(k, 1))\n\
       cdbl(c, k) = if eq(k, 0) then c else cdbl(code.form(\"p\", [c, c]), sub(k, 1))\n\
       qdbl(c, k) = if eq(k, 0) then c else qdbl(quote { pair(unquote(c), unquote(c)) }, sub(k, 1))\n"
  in
  Alcotest.(check (pair string int))
    "rendering a shared value" ("E0919", 1_000)
    (fueled ~budget:1_000 ctx store "text.length(debug.inspect(dbl(L, 40)))");
  Alcotest.(check (pair string int))
    "rendering shared code" ("E0919", 1_000)
    (fueled ~budget:1_000 ctx store "text.length(code.render(cdbl(code.of-int(1), 40)))");
  Alcotest.(check (pair string int))
    "comparing shared values in pmf" ("E0919", 1_000)
    (fueled ~budget:1_000 ctx store "pmf(Categorical([mk-pair(dbl(L, 40), 1.0)]), dbl(L, 40))");
  Alcotest.(check (pair string int))
    "keying a shared sampled value" ("E0919", 1_000)
    (fueled ~budget:1_000 ctx store "dist.sample-lw(fn () -> dbl(L, 40), 1, 0)");
  (* a deep native pays for the walk it does, not for the whole value: a comparison that stops at
     the first node stays cheap on an exponentially shared form, bounded or not *)
  let unequal = "code.eq?(code.of-int(0), cdbl(code.of-int(1), 22))" in
  let result, cost = fueled ctx store unequal in
  Alcotest.(check string) "short-circuits unbounded" "false" result;
  Alcotest.(check (pair string int))
    "and under its exact budget" ("false", cost)
    (fueled ~budget:cost ctx store unequal);
  (* the evaluator's guard scan of a native's code result visits each shared subform once, so
     building a 2^40-node payload costs only its construction; splicing and scope stamping
     rebuild every node and draw on the budget *)
  Alcotest.(check string)
    "discarded shared code" "0"
    (fst (fueled ~budget:3_000 ctx store "{ let _ = cdbl(code.of-int(1), 40); 0 }"));
  Alcotest.(check (pair string int))
    "spliced shared quotes" ("E0919", 3_000)
    (fueled ~budget:3_000 ctx store "{ let _ = qdbl(quote { 1 }, 40); 0 }");
  (* comparing code pays for the bytes it compares *)
  let big = String.make 6400 'x' in
  let compare text =
    snd
      (fueled ctx store
         (Printf.sprintf "code.eq?(code.of-text(\"%s\"), code.of-text(\"%s\"))" text text))
  in
  Alcotest.(check bool) "string bytes compared are charged" true (compare big - compare "" >= 300);
  (* walks outside any run draw on the budget too: the scheduler rendering a task result, and exact
     enumeration comparing an observed value *)
  let scheduled =
    expression store
      "async.scope(fn () -> { let a = async.spawn(fn () -> dbl(L, 40)); let _ = async.await(a); 0 \
       })"
  in
  let code =
    Eval.with_invocation ~fuel:100_000 ctx (fun _ -> failure (Round_robin.run_expr ctx scheduled))
  in
  Alcotest.(check string) "scheduler rendering" "E0919" code;
  let infer ?fuel run source =
    let model = expression store source in
    Eval.with_invocation ?fuel ctx (fun _ ->
        match run (Eval.expr_state model) with
        | Ok _ -> "posterior"
        | Error diagnostics -> String.concat "," (List.map Diag.code_or_uncoded diagnostics))
  in
  Alcotest.(check string)
    "exact observe comparison" "E0919"
    (infer ~fuel:100_000
       (fun state -> Infer_dist.enumerate_v1 ctx state)
       "{ let t = dbl(L, 40); `op:observe`(Categorical([mk-pair(t, 1.0)]), t); 1 }");
  (* unbounded, a value no one renders is never walked *)
  Alcotest.(check string)
    "unbounded drops unrendered values" "posterior"
    (infer
       (fun state -> Infer_dist.likelihood_weighting_v1 ctx ~seed:1 ~samples:20 (fun () -> state))
       "{ let c = `op:sample`(Bernoulli(0.5)); `op:observe`(Bernoulli(1.0), c); if c then L else \
        dbl(L, 40) }");
  (* a small shared value still renders, and pays for its expanded size *)
  let small, cost = fueled ctx store "text.length(debug.inspect(dbl(L, 8)))" in
  Alcotest.(check (pair string int))
    "exact" (small, cost)
    (fueled ~budget:cost ctx store "text.length(debug.inspect(dbl(L, 8)))")

let test_fuel_survives_nested_drivers () =
  (* a native driver that wraps the evaluator's error still reports E0919 *)
  let store, ctx = prepared "fuel-nested" "spin(n) = spin(add(n, 1))\n" in
  let model = expression store "dist.sample-lw(fn () -> spin(0), 3, 1)" in
  let code =
    Eval.with_invocation ~fuel:500 ctx (fun _ ->
        match Infer_dist.enumerate_v1 ctx (Eval.expr_state model) with
        | Ok _ -> "posterior"
        | Error diagnostics -> String.concat "," (List.map Diag.code_or_uncoded diagnostics))
  in
  Alcotest.(check string) "E0919, not E0902" "E0919" code

let test_alloc_survives_drivers () =
  (* RT.2: every driver reports allocation exhaustion as E0921, however a native driver, the
     scheduler or a sampler wrapped the evaluator's error *)
  let store, ctx = prepared "alloc-drivers" "grow(n) = { let _ = (n, n); grow(add(n, 1)) }\n" in
  let code_of = function
    | Ok _ -> "posterior"
    | Error diagnostics -> String.concat "," (List.map Diag.code_or_uncoded diagnostics)
  in
  let bounded source run =
    let model = expression store source in
    Eval.with_invocation ~alloc:500 ctx (fun _ -> code_of (run (Eval.expr_state model)))
  in
  Alcotest.(check string)
    "a native driver" "E0921"
    (bounded "dist.sample-lw(fn () -> grow(0), 3, 1)" (Infer_dist.enumerate_v1 ctx));
  Alcotest.(check string)
    "likelihood weighting" "E0921"
    (bounded "{ let _ = `op:sample`(Bernoulli(0.5)); grow(0) }" (fun state ->
         Infer_dist.likelihood_weighting_v1 ctx ~seed:1 ~samples:3 (fun () -> state)));
  let scheduled =
    expression store
      "async.scope(fn () -> { let _ = async.spawn(fn () -> grow(0)); let b = async.spawn(fn () -> \
       7); async.await(b) })"
  in
  Alcotest.(check string)
    "a scheduled task" "E0921"
    (Eval.with_invocation ~alloc:500 ctx (fun _ -> failure (Round_robin.run_expr ctx scheduled)));
  (* exhaustion is sticky: a driver entered after the invocation ran out reports it *)
  let spent = expression store "grow(0)" and model = expression store "1" in
  Alcotest.(check string)
    "a driver entered after exhaustion" "E0921"
    (Eval.with_invocation ~alloc:500 ctx (fun _ ->
         ignore (Eval.run_expr ctx spent);
         code_of (Infer_dist.enumerate_v1 ctx (Eval.expr_state model))))

let test_fuel_outside_runs () =
  let store, ctx = prepared "fuel-outside" "spin(n) = spin(add(n, 1))\n" in
  (* a driver applying a native outside any run never raises exhaustion; the next run reports it *)
  let big = Value.VBuiltin ("big", fun _ -> Ok (Value.VText (String.make 640 'x'))) in
  let code =
    Eval.with_invocation ~fuel:3 ctx (fun _ ->
        let state = Eval.apply_state ctx big [] in
        failure (run_state ctx state))
  in
  Alcotest.(check string) "deferred to the next run" "E0919" code;
  (* a native that catches exhaustion cannot replace it with its own error *)
  let spin = expression store "spin(0)" in
  let swallow =
    Value.VBuiltin
      ( "swallow",
        fun _ ->
          ignore (Eval.run_expr ctx spin);
          Error (Runtime_err.Arithmetic "fallback") )
  in
  let caller = expression store "fn (f) -> f()" in
  let code =
    Eval.with_invocation ~fuel:1_000 ctx (fun _ ->
        match Eval.run_expr ctx caller with
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
        | Ok closure -> failure (run_state ctx (Eval.apply_state ctx closure [ swallow ])))
  in
  Alcotest.(check string) "exhaustion wins over the native's error" "E0919" code;
  (* after exhaustion no native runs again, whoever applies it *)
  let calls = ref 0 in
  let counting =
    Value.VBuiltin
      ( "counting",
        fun _ ->
          incr calls;
          Ok Value.unit_v )
  in
  let codes =
    Eval.with_invocation ~fuel:1_000 ctx (fun _ ->
        let first = failure (Eval.run_expr ctx spin) in
        let second = failure (Eval.call ctx counting []) in
        let third = failure (run_state ctx (Eval.apply_state ctx counting [])) in
        [ first; second; third ])
  in
  Alcotest.(check (list string)) "all exhausted" [ "E0919"; "E0919"; "E0919" ] codes;
  Alcotest.(check int) "the native never ran" 0 !calls;
  (* a native that re-enters the evaluator while a driver applies it cannot raise out of
     [apply_state] *)
  let reenter =
    Value.VBuiltin ("reenter", fun _ -> Result.map (fun v -> v) (Eval.run_expr ctx spin))
  in
  let code =
    Eval.with_invocation ~fuel:0 ctx (fun _ ->
        failure (run_state ctx (Eval.apply_state ctx reenter [])))
  in
  Alcotest.(check string) "reported by the run" "E0919" code;
  (* an unbounded invocation on another evaluator nested inside a bounded one draws on the outer
     budget, and its teardown does not clear the outer exhaustion *)
  let other_store, other = prepared "fuel-outside-other" "spin(n) = spin(add(n, 1))\n" in
  let other_spin = expression other_store "spin(0)" in
  let nested =
    Value.VBuiltin
      ( "nested",
        fun _ ->
          ignore (Eval.with_invocation other (fun _ -> Eval.run_expr other other_spin));
          Error (Runtime_err.Arithmetic "fallback") )
  in
  let code =
    Eval.with_invocation ~fuel:1_000 ctx (fun _ ->
        match Eval.run_expr ctx caller with
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
        | Ok closure -> failure (run_state ctx (Eval.apply_state ctx closure [ nested ])))
  in
  Alcotest.(check string) "the outer invocation stays exhausted" "E0919" code;
  (* a nested invocation that finishes exactly at the outer ceiling is complete, not exhausted *)
  let literal = expression other_store "7" in
  let exact =
    Eval.with_invocation other (fun invocation ->
        ignore (Eval.run_expr other literal);
        Eval.fuel_used invocation)
  in
  let completed =
    Eval.with_invocation ~fuel:exact ctx (fun _ ->
        let value = Eval.with_invocation other (fun _ -> Eval.run_expr other literal) in
        (Result.is_ok value, Eval.fuel_exhausted ctx))
  in
  Alcotest.(check (pair bool bool)) "exact nested completion" (true, false) completed;
  (* a nested exhaustion returned outside any invocation leaves the process meter untouched *)
  let returns_nested =
    Value.VBuiltin
      ( "returns-nested",
        fun _ -> Eval.with_invocation ~fuel:0 other (fun _ -> Eval.run_expr other literal) )
  in
  ignore (Eval.call ctx returns_nested []);
  Alcotest.(check bool) "no exhaustion leaks outside invocations" false (Eval.fuel_exhausted ctx);
  (* a root observer cannot evaluate at all (RF.3), so it can neither spend fuel nor run an effect
     before the operation it observed; test_observer_cannot_evaluate pins the refusal *)
  (* identity hashing is not metered: a scheduled run of spliced code under no budget at all
     returns E0919 from its first transition rather than raising *)
  let spliced = expression store "quote { pair(unquote(code.of-int(1)), 2) }" in
  let code =
    Eval.with_invocation ~fuel:0 ctx (fun _ ->
        match Round_robin.run_expr_scheduled ctx ~mode:Round_robin.Record_schedule spliced with
        | Ok _ -> "ok"
        | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error))
  in
  Alcotest.(check string) "scheduled spliced code" "E0919" code;
  (* a native that re-enters another evaluator without its own invocation charges that
     evaluator's memoized terms against the active invocation, warm or cold *)
  let memo_store, memo_ctx = prepared "fuel-outside-memo" (fact_program ^ "table = fact(15)\n") in
  let table = expression memo_store "table" in
  let reenter_memo =
    Value.VBuiltin
      ("reenter-memo", fun _ -> Result.map_error (fun e -> e) (Eval.run_expr memo_ctx table))
  in
  let cost () =
    Eval.with_invocation ctx (fun invocation ->
        match Eval.run_expr ctx caller with
        | Error error -> Alcotest.failf "caller: %s" (Diag.to_string (Runtime_err.to_diag error))
        | Ok closure ->
            ignore (run_state ctx (Eval.apply_state ctx closure [ reenter_memo ]));
            Eval.fuel_used invocation)
  in
  let cold = cost () in
  Alcotest.(check int) "warm memo on another evaluator costs the same" cold (cost ());
  (* ... also when that evaluator's memoized term is reached inside a memo sub-run here, and
     referenced again directly afterwards *)
  let bridge_store, bridge_ctx =
    prepared "fuel-outside-bridge" "bridge(u) = 0\nouter = bridge(1)\n"
  in
  (match Store.lookup_kind bridge_store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin bridge_ctx hash
        (Value.VBuiltin ("bridge", fun _ -> Eval.run_expr memo_ctx table))
  | None -> Alcotest.fail "bridge not declared");
  let outer = expression bridge_store "outer" in
  let cost () =
    Eval.with_invocation bridge_ctx (fun invocation ->
        ignore (Eval.run_expr bridge_ctx outer);
        ignore (Eval.run_expr memo_ctx table);
        Eval.fuel_used invocation)
  in
  let cold = cost () in
  Alcotest.(check int) "memo dependency on another evaluator" cold (cost ());
  (* ... and when the native opens its own nested invocation there *)
  let nested_store, nested_ctx =
    prepared "fuel-outside-nested-bridge" "bridge(u) = 0\nouter = bridge(1)\n"
  in
  (match Store.lookup_kind nested_store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin nested_ctx hash
        (Value.VBuiltin
           ("bridge", fun _ -> Eval.with_invocation memo_ctx (fun _ -> Eval.run_expr memo_ctx table)))
  | None -> Alcotest.fail "bridge not declared");
  let nested_outer = expression nested_store "outer" in
  let cost () =
    Eval.with_invocation nested_ctx (fun invocation ->
        ignore (Eval.run_expr memo_ctx table);
        ignore (Eval.run_expr nested_ctx nested_outer);
        ignore (Eval.run_expr memo_ctx table);
        Eval.fuel_used invocation)
  in
  let cold = cost () in
  Alcotest.(check int) "memo dependency through a nested invocation" cold (cost ());
  (* a memo hit refused under a nested cap leaves the term unpaid *)
  let capped_then_direct memo_ctx table =
    Eval.with_invocation ctx (fun invocation ->
        ignore (Eval.with_invocation ~fuel:1 memo_ctx (fun _ -> Eval.run_expr memo_ctx table));
        ignore (Eval.run_expr memo_ctx table);
        Eval.fuel_used invocation)
  in
  let fresh_store, fresh_ctx =
    prepared "fuel-outside-capped" (fact_program ^ "table = fact(15)\n")
  in
  let fresh_table = expression fresh_store "table" in
  let cold = capped_then_direct fresh_ctx fresh_table in
  Alcotest.(check int)
    "refused memo debit is not credited" cold
    (capped_then_direct fresh_ctx fresh_table);
  (* every cap, including ones that end after a dependency completed: warm replays the cold
     charging sequence, so the same terms end up paid *)
  let program = "base = add(12340, 5)\ntable = add(base, 2)\n" in
  let sequence cap memo_ctx table =
    Eval.with_invocation ctx (fun invocation ->
        ignore (Eval.with_invocation ~fuel:cap memo_ctx (fun _ -> Eval.run_expr memo_ctx table));
        ignore (Eval.run_expr memo_ctx table);
        Eval.fuel_used invocation)
  in
  let warm_store, warm_ctx = prepared "fuel-outside-warm-caps" program in
  let warm_table = expression warm_store "table" in
  ignore (Eval.with_invocation warm_ctx (fun _ -> Eval.run_expr warm_ctx warm_table));
  for cap = 0 to 16 do
    let cold_store, cold_ctx = prepared "fuel-outside-cold-caps" program in
    let cold = sequence cap cold_ctx (expression cold_store "table") in
    Alcotest.(check int) (Printf.sprintf "cap %d" cap) cold (sequence cap warm_ctx warm_table)
  done;
  (* ... and when the capped attempt runs inside another term's memo sub-run that survives it: the
     surviving term still records the dependencies the attempt completed *)
  let surviving cap =
    let b_store, b_ctx = prepared "fuel-outside-surviving-b" program in
    let b_table = expression b_store "table" and b_base = expression b_store "base" in
    let a_store, a_ctx = prepared "fuel-outside-surviving-a" "bridge(u) = 0\nouter = bridge(1)\n" in
    (match Store.lookup_kind a_store "bridge" Resolve.KTerm with
    | Some { Resolve.hash; _ } ->
        Eval.register_builtin a_ctx hash
          (Value.VBuiltin
             ( "bridge",
               fun _ ->
                 ignore
                   (Eval.with_invocation ~fuel:cap b_ctx (fun _ -> Eval.run_expr b_ctx b_table));
                 Ok (Value.VInt 0) ))
    | None -> Alcotest.fail "bridge not declared");
    let a_outer = expression a_store "outer" in
    fun () ->
      Eval.with_invocation a_ctx (fun invocation ->
          ignore (Eval.run_expr a_ctx a_outer);
          ignore (Eval.run_expr b_ctx b_base);
          Eval.fuel_used invocation)
  in
  (* a memo computed outside any invocation, whose native opens an unbounded invocation on another
     evaluator, still records that evaluator's term as its dependency *)
  let b_store, b_ctx = prepared "fuel-outside-outside-b" program in
  let b_base = expression b_store "base" in
  let a_store, a_ctx = prepared "fuel-outside-outside-a" "bridge(u) = 0\nouter = bridge(1)\n" in
  (match Store.lookup_kind a_store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin a_ctx hash
        (Value.VBuiltin
           ( "bridge",
             fun _ ->
               ignore (Eval.with_invocation b_ctx (fun _ -> Eval.run_expr b_ctx b_base));
               Ok (Value.VInt 0) ))
  | None -> Alcotest.fail "bridge not declared");
  let a_outer = expression a_store "outer" in
  let both () =
    Eval.with_invocation a_ctx (fun invocation ->
        ignore (Eval.run_expr a_ctx a_outer);
        ignore (Eval.run_expr b_ctx b_base);
        Eval.fuel_used invocation)
  in
  let warmed_outside =
    ignore (Eval.run_expr a_ctx a_outer);
    both ()
  in
  let b_store', b_ctx' = prepared "fuel-outside-outside-b3" program in
  let b_base' = expression b_store' "base" in
  let a_store', a_ctx' = prepared "fuel-outside-outside-a3" "bridge(u) = 0\nouter = bridge(1)\n" in
  (match Store.lookup_kind a_store' "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin a_ctx' hash
        (Value.VBuiltin
           ( "bridge",
             fun _ ->
               ignore (Eval.with_invocation b_ctx' (fun _ -> Eval.run_expr b_ctx' b_base'));
               Ok (Value.VInt 0) ))
  | None -> Alcotest.fail "bridge not declared");
  let a_outer' = expression a_store' "outer" in
  let cold =
    Eval.with_invocation a_ctx' (fun invocation ->
        ignore (Eval.run_expr a_ctx' a_outer');
        ignore (Eval.run_expr b_ctx' b_base');
        Eval.fuel_used invocation)
  in
  Alcotest.(check int) "memo warmed outside an invocation" cold warmed_outside;
  for cap = 0 to 16 do
    let run = surviving cap in
    let cold = run () in
    Alcotest.(check int) (Printf.sprintf "surviving cap %d" cap) cold (run ())
  done;
  (* a Warp runner that runs out reports a runner error, never a failing verdict *)
  (match Store.lookup_kind store "test.run" Resolve.KTerm with
  | None -> Alcotest.fail "the prelude has no test.run"
  | Some { Resolve.hash; _ } ->
      let test_run =
        match Eval.with_invocation ctx (fun _ -> Warp.value_of ctx hash) with
        | Ok test_run -> test_run
        | Error error -> Alcotest.failf "test.run: %s" (Diag.to_string (Runtime_err.to_diag error))
      in
      let spinning = expression store "fn () -> spin(0)" in
      let outcome budget =
        Eval.with_invocation ~fuel:budget ctx (fun _ ->
            match Eval.run_expr ctx spinning with
            | Error _ -> "setup"
            | Ok thunk -> (
                match Warp.run_thunk ctx ~test_run thunk with
                | Ok _ -> "verdict"
                | Error _ -> "error"))
      in
      Alcotest.(check string) "warp under exhaustion" "error" (outcome 2_000);
      (* ... and a nested invocation's exhaustion, returned by a native, is not a verdict either *)
      let nested_zero =
        Value.VBuiltin
          ( "nested-zero",
            fun _ -> Eval.with_invocation ~fuel:0 other (fun _ -> Eval.run_expr other other_spin) )
      in
      let code =
        Eval.with_invocation ~fuel:100_000 ctx (fun _ ->
            match Warp.run_thunk ctx ~test_run nested_zero with
            | Ok _ -> "verdict"
            | Error _ -> "error")
      in
      Alcotest.(check string) "nested exhaustion in warp" "error" code);
  (* an operation a driver applies outside any run performs nothing until a run starts *)
  let print_op =
    Eval.with_invocation ctx (fun _ ->
        match Eval.run_expr ctx (expression store "print") with
        | Ok op -> op
        | Error error -> Alcotest.failf "print: %s" (Diag.to_string (Runtime_err.to_diag error)))
  in
  let sink = Buffer.create 16 in
  let code =
    Eval.with_invocation ~fuel:0 ctx (fun _ ->
        grant_console ctx sink;
        let state = Eval.apply_state ctx print_op [ Value.VText (String.make 640 'x') ] in
        failure (run_state ctx state))
  in
  Alcotest.(check string) "the operation is refused by the run" "E0919" code;
  Alcotest.(check string) "and printed nothing" "" (Buffer.contents sink);
  (* a multi-shot resumption made by a driver pays for the frames it reinstalls *)
  let model =
    expression store "{ let c = `op:sample`(Bernoulli(0.5)); add(if c then 1 else 2, 3) }"
  in
  let enumerate budget =
    Eval.with_invocation ?fuel:budget ctx (fun invocation ->
        match Infer_dist.enumerate_v1 ctx (Eval.expr_state model) with
        | Ok _ -> ("posterior", Eval.fuel_used invocation)
        | Error diagnostics ->
            ( String.concat "," (List.map Diag.code_or_uncoded diagnostics),
              Eval.fuel_used invocation ))
  in
  let _, cost = enumerate None in
  let kept = Eval.with_invocation ctx (fun invocation -> invocation) in
  Alcotest.(check int) "a finished invocation keeps its count" 0 (Eval.fuel_used kept);
  ignore (enumerate None);
  Alcotest.(check int) "... even after later invocations" 0 (Eval.fuel_used kept);
  Alcotest.(check (pair string int))
    "one unit short"
    ("E0919", cost - 1)
    (enumerate (Some (cost - 1)))

let test_fuel_scopes () =
  let store, ctx = prepared "fuel-scope" "spin(n) = spin(add(n, 1))\n" in
  let spin = expression store "spin(0)" and one = expression store "add(1, 2)" in
  (* a scope's cap is its own outcome: the invocation keeps its remaining allowance *)
  let outcome =
    Eval.with_invocation ~fuel:10_000 ctx (fun invocation ->
        let result, exhausted, used =
          Eval.with_fuel_scope ctx ~fuel:100 (fun () -> Eval.run_expr ctx spin)
        in
        let after = Eval.run_expr ctx one in
        ( failure result,
          exhausted,
          used,
          Result.is_ok after,
          Eval.fuel_exhausted ctx,
          Eval.fuel_used invocation > 100 ))
  in
  Alcotest.(check bool)
    "scope exhausted" true
    (match outcome with "E0919", true, 100, true, false, true -> true | _ -> false);
  (* a scope that reaches the invocation's own budget leaves the invocation exhausted *)
  let outer =
    Eval.with_invocation ~fuel:50 ctx (fun _ ->
        let _, exhausted, _ =
          Eval.with_fuel_scope ctx ~fuel:1_000 (fun () -> Eval.run_expr ctx spin)
        in
        (exhausted, Eval.fuel_exhausted ctx, failure (Eval.run_expr ctx one)))
  in
  Alcotest.(check (triple bool bool string)) "aggregate reached" (true, true, "E0919") outer;
  (* a term the invocation already paid for stays paid after a scope charged it again *)
  let memo_store, memo_ctx = prepared "fuel-scope-memo" (fact_program ^ "table = fact(15)\n") in
  let table = expression memo_store "table" in
  let twice_then_after scoped =
    Eval.with_invocation memo_ctx (fun invocation ->
        ignore (Eval.run_expr memo_ctx table);
        if scoped then
          ignore
            (Eval.with_fuel_scope memo_ctx ~fuel:1_000_000 (fun () -> Eval.run_expr memo_ctx table));
        let before = Eval.fuel_used invocation in
        ignore (Eval.run_expr memo_ctx table);
        Eval.fuel_used invocation - before)
  in
  Alcotest.(check int)
    "outer payment survives a scope" (twice_then_after false) (twice_then_after true);
  (* scopes need an invocation *)
  match Eval.with_fuel_scope ctx ~fuel:1 (fun () -> ()) with
  | _ -> Alcotest.fail "scope outside an invocation"
  | exception Invalid_argument _ -> ()

let test_alloc_scopes () =
  let store, ctx = prepared "alloc-scope" (list_program ^ "table = build(30)\n") in
  let grow = expression store "{ let rec g(n) = { let _ = (n, n); g(add(n, 1)) }; g(0) }"
  and one = expression store "size(build(3))" in
  let code = function
    | Some error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
    | None -> "-"
  in
  (* a scope's cap is its own outcome: the invocation keeps its remaining allowance *)
  let scoped, used, after, still =
    Eval.with_invocation ~alloc:100_000 ctx (fun _ ->
        let _, report = Eval.with_scope ctx ~alloc:100 (fun () -> Eval.run_expr ctx grow) in
        let after = Eval.run_expr ctx one in
        (code report.Eval.exhaustion, report.Eval.alloc_used, Result.is_ok after, Eval.exhausted ctx))
  in
  Alcotest.(check (pair string int)) "scope exhausted at its cap" ("E0921", 100) (scoped, used);
  Alcotest.(check (pair bool bool)) "the invocation continues" (true, false) (after, still);
  (* a scope that reaches the invocation's own budget leaves the invocation exhausted *)
  let reached =
    Eval.with_invocation ~alloc:50 ctx (fun _ ->
        let _, report = Eval.with_scope ctx ~alloc:1_000 (fun () -> Eval.run_expr ctx grow) in
        (code report.Eval.exhaustion, Eval.exhausted ctx, failure (Eval.run_expr ctx one)))
  in
  Alcotest.(check (triple string bool string)) "aggregate reached" ("E0921", true, "E0921") reached;
  (* and reports the limit that bound it, not the larger cap *)
  let bound =
    Eval.with_invocation ~alloc:50 ctx (fun _ ->
        match Eval.with_scope ctx ~alloc:1_000 (fun () -> Eval.run_expr ctx grow) with
        | _, { Eval.exhaustion = Some (Runtime_err.Alloc_exhausted { limit; _ }); _ } -> limit
        | _ -> -1)
  in
  Alcotest.(check int) "the enclosing limit binds" 50 bound;
  (* with both caps, the first to run out is reported *)
  let both =
    Eval.with_invocation ctx (fun _ ->
        let _, report =
          Eval.with_scope ctx ~fuel:1_000_000 ~alloc:100 (fun () -> Eval.run_expr ctx grow)
        in
        code report.Eval.exhaustion)
  in
  Alcotest.(check string) "allocation before ample fuel" "E0921" both;
  (* a smaller cap that ended, nested or scoped, never leaves exhaustion behind *)
  let other_store, other_ctx = prepared "alloc-scope-other" list_program in
  let other_grow =
    expression other_store "{ let rec g(n) = { let _ = (n, n); g(add(n, 1)) }; g(0) }"
  in
  let after_nested =
    Eval.with_invocation ~alloc:100_000 ctx (fun _ ->
        ignore
          (Eval.with_invocation ~alloc:10 other_ctx (fun _ -> Eval.run_expr other_ctx other_grow));
        code (Eval.exhaustion ctx))
  in
  Alcotest.(check string) "after a nested invocation's smaller cap" "-" after_nested;
  Alcotest.(check string)
    "in a later unbounded invocation" "-"
    (Eval.with_invocation ctx (fun _ -> code (Eval.exhaustion ctx)));
  (* each scope pays for the memoized terms it uses, whatever an earlier scope paid *)
  let table = expression store "table" in
  let costs =
    Eval.with_invocation ctx (fun _ ->
        List.init 2 (fun _ ->
            (snd (Eval.with_scope ctx ~alloc:1_000_000 (fun () -> Eval.run_expr ctx table)))
              .Eval.alloc_used))
  in
  Alcotest.(check bool)
    "a warm memo costs the same in a later scope" true
    (match costs with [ first; second ] -> first > 0 && first = second | _ -> false);
  match Eval.with_scope ctx ~alloc:1 (fun () -> ()) with
  | _ -> Alcotest.fail "scope outside an invocation"
  | exception Invalid_argument _ -> ()

let test_alloc_wrapped_native_exhaustion () =
  (* a native returning a nested invocation's E0921, even wrapped in a diagnostic, exhausts the
     enclosing invocation: the work depending on it is incomplete *)
  let nested_store, nested_ctx = prepared "alloc-wrapped-nested" list_program in
  let grow = expression nested_store "{ let rec g(n) = { let _ = (n, n); g(add(n, 1)) }; g(0) }" in
  let store, ctx = prepared "alloc-wrapped" "bridge(u) = 0\n" in
  (match Store.lookup_kind store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin ctx hash
        (Value.VBuiltin
           ( "bridge",
             fun _ ->
               match
                 Eval.with_invocation ~alloc:10 nested_ctx (fun _ -> Eval.run_expr nested_ctx grow)
               with
               | Error error -> Error (Runtime_err.Diagnostic (Runtime_err.to_diag error))
               | Ok _ -> Ok (Value.VInt 0) ))
  | None -> Alcotest.fail "bridge not declared");
  let call = expression store "bridge(1)" and one = expression store "add(1, 2)" in
  let outcome =
    Eval.with_invocation ~alloc:100_000 ctx (fun _ ->
        let first = failure (Eval.run_expr ctx call) in
        (first, Eval.exhausted ctx, failure (Eval.run_expr ctx one)))
  in
  Alcotest.(check (triple string bool string))
    "the enclosing invocation is exhausted" ("E0921", true, "E0921") outcome;
  (* an error that only carries the code, with no nested run behind it, exhausts nothing *)
  let forged_store, forged_ctx = prepared "alloc-forged" "forge(u) = 0\n" in
  (match Store.lookup_kind forged_store "forge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin forged_ctx hash
        (Value.VBuiltin
           ( "forge",
             fun _ ->
               Error
                 (Runtime_err.Diagnostic
                    (Runtime_err.to_diag
                       (Runtime_err.Alloc_exhausted { model = Eval.alloc_model; limit = 1 }))) ))
  | None -> Alcotest.fail "forge not declared");
  let forged = expression forged_store "forge(1)" and sum = expression forged_store "add(1, 2)" in
  let after =
    Eval.with_invocation ~alloc:100_000 forged_ctx (fun _ ->
        ignore (Eval.run_expr forged_ctx forged);
        (Eval.exhausted forged_ctx, Result.is_ok (Eval.run_expr forged_ctx sum)))
  in
  Alcotest.(check (pair bool bool)) "a forged E0921 exhausts nothing" (false, true) after

(* bytes the program allocates while [f] runs, in the OCaml heap *)
let test_registry_ceilings () =
  (* RT.2 §4: retained tasks and open channels are counted across the invocation, released when
     the run's scopes are torn down; the entry past a ceiling is E0921, sticky like allocation *)
  let store, ctx =
    prepared "registry-ceilings"
      "count(n) = if eq(n, 0) then 0 else { let t = async.spawn(fn () -> n); let v = match \
       async.await(t) { | Done(v) -> v | _ -> 100 }; add(v, count(sub(n, 1))) }\n\
       opens(n, size) = if eq(n, 0) then 0 else match channel.open(size) { | Err(_) -> 100 | Ok(_) \
       -> add(1, opens(sub(n, 1), size)) }\n\
       cancels(n) = if eq(n, 0) then 0 else { let t = async.spawn(fn () -> { let _ = \
       async.yield(); let _ = async.yield(); n }); let _ = async.cancel(t); let v = match \
       async.await(t) { | Done(v) -> v | _ -> 1 }; add(v, cancels(sub(n, 1))) }\n"
  in
  let spawns = expression store "async.scope(fn () -> count(3))"
  and cancelled = expression store "async.scope(fn () -> cancels(3))"
  and channels size = expression store (Printf.sprintf "async.scope(fn () -> opens(2, %d))" size)
  and pure = expression store "add(1, 2)" in
  let outcome = function
    | Ok value -> Value.show value
    | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
  in
  let counts () = (Retain_meter.tasks.count, Retain_meter.channels.count) in
  let run ?max_tasks ?max_channels expr =
    Eval.with_invocation ?max_tasks ?max_channels ctx (fun _ ->
        let result = outcome (Round_robin.run_expr ctx expr) in
        (result, counts ()))
  in
  (* the scope body and three spawned tasks are retained until the run ends *)
  Alcotest.(check (pair string (pair int int)))
    "four tasks fit"
    ("done(6)", (0, 0))
    (run ~max_tasks:4 spawns);
  Alcotest.(check (pair string (pair int int)))
    "the fifth is refused"
    ("E0921", (0, 0))
    (run ~max_tasks:3 spawns);
  Alcotest.(check string)
    "the ceiling is named"
    "registry ceiling reached: the --max-tasks ceiling of 3 retained task(s) was reached before \
     evaluation finished; the result is incomplete"
    (Eval.with_invocation ~max_tasks:3 ctx (fun _ ->
         match Round_robin.run_expr ctx spawns with
         | Error error -> Runtime_err.to_string error
         | Ok _ -> "completed"));
  Alcotest.(check (pair string (pair int int)))
    "two channels fit"
    ("done(2)", (0, 0))
    (run ~max_channels:2 (channels 4));
  Alcotest.(check (pair string (pair int int)))
    "the second channel is refused"
    ("E0921", (0, 0))
    (run ~max_channels:1 (channels 4));
  (* reaching a ceiling is sticky: no later run of the invocation delivers a value *)
  Alcotest.(check (pair string string))
    "sticky" ("E0921", "E0921")
    (Eval.with_invocation ~max_tasks:1 ctx (fun _ ->
         let first = outcome (Round_robin.run_expr ctx spawns) in
         (first, outcome (Eval.run_expr ctx pure))));
  (* a scope's ceiling is its own outcome, and a scope cannot raise the invocation's *)
  let scoped, later, held =
    Eval.with_invocation ~max_tasks:100 ctx (fun _ ->
        let _, report =
          Eval.with_scope ctx ~max_tasks:2 (fun () -> Round_robin.run_expr ctx spawns)
        in
        let later = outcome (Round_robin.run_expr ctx spawns) in
        ( Option.map (fun e -> Diag.code_or_uncoded (Runtime_err.to_diag e)) report.exhaustion,
          later,
          Eval.exhausted ctx ))
  in
  Alcotest.(check (option string)) "the scope reached its ceiling" (Some "E0921") scoped;
  Alcotest.(check (pair string bool)) "the invocation continues" ("done(6)", false) (later, held);
  Alcotest.(check string)
    "a scope cannot raise the ceiling" "E0921"
    (Eval.with_invocation ~max_tasks:3 ctx (fun _ ->
         let result, _ =
           Eval.with_scope ctx ~max_tasks:10 (fun () -> Round_robin.run_expr ctx spawns)
         in
         outcome result));
  (* every entry is released when the invocation ends, even one a raising body left counted *)
  (match
     Eval.with_invocation ~max_tasks:5 ctx (fun _ ->
         ignore (Retain_meter.acquire Retain_meter.Tasks);
         raise Exit)
   with
  | () -> Alcotest.fail "expected Exit"
  | exception Exit -> ());
  Alcotest.(check (pair int int)) "released after an exception" (0, 0) (counts ());
  (* a cancelled task stays retained until its scope is torn down, then is released (§4): each
     child yields twice, so the cancel reaches it live; the scope body and all three cancelled
     children are held at once, where releasing at cancellation would hold at most two *)
  Alcotest.(check (pair string (pair int int)))
    "cancelled tasks are held until teardown"
    ("cancelled", (0, 0))
    (run ~max_tasks:4 cancelled);
  Alcotest.(check (pair string (pair int int)))
    "cancellation does not release a task early"
    ("E0921", (0, 0))
    (run ~max_tasks:3 cancelled);
  (* a scope's run restores the count it began with, not zero *)
  let scope_code limit =
    let result, _ =
      Eval.with_scope ctx ~max_tasks:limit (fun () -> Round_robin.run_expr ctx cancelled)
    in
    outcome result
  in
  Alcotest.(check (pair (pair string string) (pair int int)))
    "a scope restores a non-zero count"
    (("cancelled", "E0921"), (1, 0))
    (Eval.with_invocation ~max_tasks:10 ctx (fun _ ->
         ignore (Retain_meter.acquire Retain_meter.Tasks);
         let fits = scope_code 4 in
         let refused = scope_code 3 in
         ((fits, refused), counts ())));
  Alcotest.(check (pair int int)) "and the outer one releases it" (0, 0) (counts ());
  Alcotest.(check bool) "nothing held after the invocation" false (Retain_meter.exhausted ());
  (* a native returning a nested invocation's ceiling E0921, even wrapped, leaves the enclosing
     invocation with that ceiling reached *)
  let outer_store, outer_ctx = prepared "registry-ceilings-outer" "bridge(u) = 0\n" in
  (match Store.lookup_kind outer_store "bridge" Resolve.KTerm with
  | Some { Resolve.hash; _ } ->
      Eval.register_builtin outer_ctx hash
        (Value.VBuiltin
           ( "bridge",
             fun _ ->
               match
                 Eval.with_invocation ~max_tasks:1 ctx (fun _ -> Round_robin.run_expr ctx spawns)
               with
               | Error error -> Error (Runtime_err.Diagnostic (Runtime_err.to_diag error))
               | Ok _ -> Ok (Value.VInt 0) ))
  | None -> Alcotest.fail "bridge not declared");
  let call = expression outer_store "bridge(1)" and sum = expression outer_store "add(1, 2)" in
  Alcotest.(check (triple string bool string))
    "a nested ceiling exhausts the enclosing invocation" ("E0921", true, "E0921")
    (Eval.with_invocation ~max_tasks:100 outer_ctx (fun _ ->
         let first = outcome (Eval.run_expr outer_ctx call) in
         (first, Eval.exhausted outer_ctx, outcome (Eval.run_expr outer_ctx sum))));
  Alcotest.(check bool) "and nothing is held after it" false (Retain_meter.exhausted ());
  (* a channel's buffer is paid for in advance, as cells *)
  let cells size =
    Eval.with_invocation ~alloc:1_000_000 ctx (fun invocation ->
        ignore (Round_robin.run_expr ctx (channels size));
        Eval.alloc_used invocation)
  in
  Alcotest.(check int) "declared capacity is charged" (2 * 999) (cells 1000 - cells 1);
  (* a capacity the program sizes cannot wrap the count past the budget *)
  let huge = expression store "async.scope(fn () -> opens(2, 4611686018427387903))" in
  Alcotest.(check (pair string bool))
    "a huge capacity is refused" ("E0921", true)
    (Eval.with_invocation ~alloc:1_000 ctx (fun invocation ->
         let result = outcome (Round_robin.run_expr ctx huge) in
         (result, Eval.alloc_used invocation >= 0)));
  (* unbounded, the huge charge is skipped, so a later bounded invocation still has its room *)
  let unbounded = Eval.with_invocation ctx (fun _ -> outcome (Round_robin.run_expr ctx huge)) in
  Alcotest.(check (pair string (pair string bool)))
    "an unbounded huge capacity leaves later bounds intact"
    ("done(2)", ("E0921", true))
    ( unbounded,
      Eval.with_invocation ~alloc:1_000 ctx (fun invocation ->
          let result = outcome (Round_robin.run_expr ctx huge) in
          (result, Eval.alloc_used invocation <= 1_000)) );
  (* a capacity that fits leaves the count near [max_int]: a later run still counts from zero, and
     a scope bounded inside the same run fails closed rather than becoming unbounded *)
  let near = expression store "async.scope(fn () -> opens(2, 4611686018427387000))" in
  ignore (Eval.with_invocation ctx (fun _ -> outcome (Round_robin.run_expr ctx near)));
  Alcotest.(check (pair string string))
    "a later run keeps its whole allowance" ("done(2)", "E0921")
    ( Eval.with_invocation ~alloc:100_000 ctx (fun _ ->
          outcome (Round_robin.run_expr ctx (channels 1000))),
      Eval.with_invocation ~alloc:1_000 ctx (fun _ -> outcome (Round_robin.run_expr ctx huge)) );
  Alcotest.(check (pair string bool))
    "a scope bounded near the top fails closed" ("E0921", true)
    (Eval.with_invocation ctx (fun _ ->
         ignore (Round_robin.run_expr ctx near);
         let result, report =
           Eval.with_scope ctx ~alloc:100_000 (fun () ->
               outcome (Round_robin.run_expr ctx (channels 1000)))
         in
         (result, report.Eval.alloc_used >= 0)))

let heap_bytes f =
  let before = Gc.allocated_bytes () in
  let result = f () in
  (result, Gc.allocated_bytes () -. before)

let test_alloc_root_handlers () =
  let store, ctx =
    prepared "alloc-roots"
      "cdbl(c, k) = if eq(k, 0) then c else cdbl(code.form(\"tuple\", [c, c]), sub(k, 1))\n"
  in
  let dir = fresh_root "alloc-roots-files" in
  Sys.mkdir dir 0o755;
  let file name contents =
    let path = Filename.concat dir name in
    Out_channel.with_open_bin path (fun oc -> output_string oc contents);
    path
  in
  let lines = ref [] in
  let console_read () =
    match !lines with
    | line :: rest ->
        lines := rest;
        Some line
    | [] -> None
  in
  let printed = Buffer.create 16 in
  let run ?budget source =
    Eval.with_invocation ~coverage:false ?alloc:budget ctx (fun invocation ->
        List.iter
          (fun effect_ ->
            expect_ok effect_
              (Prelude.grant ~console_read ctx effect_ ~infer_cache:None
                 ~out:(Buffer.add_string printed) ~seed:0))
          [ "clock"; "console"; "eval"; "fs" ];
        let outcome =
          match Eval.run_expr ctx (expression store source) with
          | Ok value -> Fuel_meter.unmetered (fun () -> Value.show value)
          | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
        in
        (outcome, Eval.alloc_used invocation))
  in
  let cost source = snd (run source) in
  (* a handler's result is charged on return: its new nodes, by the cells a native's would cost *)
  Alcotest.(check int) "a scalar result" 0 (cost "now()");
  Alcotest.(check int) "unit" 1 (cost "print(\"x\")");
  let hello = file "hello.txt" "hello, world" in
  Alcotest.(check (pair string int))
    "a file's text" ("\"hello, world\"", 3)
    (run (Printf.sprintf "read(%S)" hello));
  let listed = Filename.concat dir "listed" in
  Sys.mkdir listed 0o755;
  List.iter (fun name -> ignore (file (Filename.concat "listed" name) "")) [ "a"; "b"; "c" ];
  Alcotest.(check int)
    "a directory listing: per entry a cons and its text, then nil"
    ((3 * (3 + 2)) + 1)
    (cost (Printf.sprintf "list-dir(%S)" listed));
  lines := [ "abcdefghi" ];
  Alcotest.(check (pair string int)) "a console line" ("\"abcdefghi\"", 3) (run "read-line()");
  (* a file's length is checked before it is read: a large file under a small budget is refused
     without reading it *)
  let large = Filename.concat dir "large.bin" in
  let fd = Unix.openfile large [ Unix.O_WRONLY; Unix.O_CREAT ] 0o644 in
  Unix.ftruncate fd (256 * 1024 * 1024);
  Unix.close fd;
  let outcome, bytes = heap_bytes (fun () -> run ~budget:1_000 (Printf.sprintf "read(%S)" large)) in
  Alcotest.(check (pair string int)) "a large file is refused" ("E0921", 1_000) outcome;
  Alcotest.(check bool) "and not read" true (bytes < 16. *. 1024. *. 1024.);
  Alcotest.(check (pair string int))
    "a file fits at exactly its cost" ("\"hello, world\"", 3)
    (run ~budget:3 (Printf.sprintf "read(%S)" hello));
  Alcotest.(check string)
    "and is refused one cell short" "E0921"
    (fst (run ~budget:2 (Printf.sprintf "read(%S)" hello)));
  (* a console line past the allowance is refused, and stdin is read at most one byte past it *)
  lines := [ String.make 10_000 'x' ];
  Alcotest.(check (pair string int))
    "a long line is refused" ("E0921", 100) (run ~budget:100 "read-line()");
  let long = file "long.txt" (String.make 100_000 'y' ^ "\nnext\n") in
  In_channel.with_open_bin long (fun ic ->
      Alcotest.(check (option int))
        "a bounded read stops one byte past its limit" (Some 11)
        (Option.map String.length (Prelude.read_line_within ic ~limit:(Some 10))));
  In_channel.with_open_bin long (fun ic ->
      let source = Prelude.line_source_within ic in
      Alcotest.(check (option int))
        "a refused line is read one byte past the limit" (Some 11)
        (Option.map String.length (source ~limit:(Some 10)));
      Alcotest.(check (option string))
        "then input has ended, so no read sees its rest" None (source ~limit:(Some 1_000_000)));
  In_channel.with_open_bin long (fun ic ->
      let source = Prelude.line_source_within ic in
      ignore (source ~limit:None);
      Alcotest.(check (option string))
        "a line within its limit leaves the next one" (Some "next") (source ~limit:(Some 10)));
  In_channel.with_open_bin long (fun ic ->
      let first = Prelude.read_line_within ic ~limit:None in
      Alcotest.(check (option int)) "unbounded" (Some 100_000) (Option.map String.length first);
      Alcotest.(check (option string))
        "the next line" (Some "next")
        (Prelude.read_line_within ic ~limit:None);
      Alcotest.(check (option string)) "end of input" None (Prelude.read_line_within ic ~limit:None));
  (* eval charges one cell per kernel node before converting the payload; what the payload builds
     is charged by the evaluator, and its result is not charged again *)
  Alcotest.(check int)
    "eval of one node" 1
    (cost "eval-code(code.of-int(5))" - cost "code.of-int(5)");
  Alcotest.(check int)
    "eval of a tuple" (3 + 3)
    (cost "eval-code(code.form(\"tuple\", [code.of-int(1), code.of-int(2)]))"
    - cost "code.form(\"tuple\", [code.of-int(1), code.of-int(2)])");
  (* code sharing a subform 2^22 ways is 2^22 kernel nodes: refused before it is converted *)
  let outcome, bytes =
    heap_bytes (fun () -> run ~budget:1_000 "eval-code(cdbl(code.of-int(0), 22))")
  in
  Alcotest.(check (pair string int)) "shared code is refused" ("E0921", 1_000) outcome;
  Alcotest.(check bool) "before it is converted" true (bytes < 64. *. 1024. *. 1024.);
  (* by class: a handler returning its argument adds nothing; one that charges itself adds nothing
     on return *)
  let print_op =
    match Prelude_identity.lookup_kind store "print" Resolve.KOp with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "print"
  in
  let with_handler alloc handler source =
    Eval.with_invocation ~coverage:false ctx (fun invocation ->
        Eval.register_root_handler ?alloc ctx print_op handler;
        ignore (Eval.run_expr ctx (expression store source));
        Eval.alloc_used invocation)
  in
  let text = "\"abcdefghijklmnopq\"" in
  let base = cost (Printf.sprintf "text.length(%s)" text) in
  let echo = function [ value ] -> Ok value | _ -> Error (Runtime_err.Eval_error "arity") in
  let fresh = function _ -> Ok (Value.VText (String.make 100 'z')) in
  Alcotest.(check int)
    "an echo is shared" 0
    (with_handler None echo (Printf.sprintf "print(%s)" text) - base);
  Alcotest.(check int)
    "a fresh result is new" (1 + 13)
    (with_handler None fresh (Printf.sprintf "print(%s)" text) - base);
  Alcotest.(check int)
    "an evaluated result is not charged again" 0
    (with_handler (Some Native_alloc.Evaluated) fresh (Printf.sprintf "print(%s)" text) - base);
  (* a driver dispatching a captured operation charges the handler's result the same way *)
  let routed path =
    Eval.with_invocation ~coverage:false ~alloc:1_000 ctx (fun invocation ->
        expect_ok "fs" (Prelude.grant ctx "fs" ~infer_cache:None ~out:ignore ~seed:0);
        let state = Eval.expr_state (expression store (Printf.sprintf "read(%S)" path)) in
        match Eval.run_state_capturing_once_routed ctx state with
        | Ok (Eval.OCOp { call; op; name; args; resume }) ->
            let before = Eval.alloc_used invocation in
            let outcome =
              match Eval.dispatch_root_operation ~call ctx ~resume ~op ~name ~effect_:"" args with
              | Ok value -> Value.show value
              | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
            in
            (outcome, Eval.alloc_used invocation - before)
        | _ -> Alcotest.fail "expected a captured read")
  in
  Alcotest.(check (pair string int)) "a routed read" ("\"hello, world\"", 3) (routed hello);
  let (outcome, _), bytes = heap_bytes (fun () -> routed large) in
  Alcotest.(check string) "a routed read past the budget" "E0921" outcome;
  Alcotest.(check bool) "is refused without reading" true (bytes < 16. *. 1024. *. 1024.);
  (* a scope's own budget bounds a read inside it, and the enclosing invocation goes on *)
  Alcotest.(check (pair string string))
    "a scope bounds its reads" ("E0921", "\"hello, world\"")
    (Eval.with_invocation ~coverage:false ~alloc:1_000 ctx (fun _ ->
         expect_ok "fs" (Prelude.grant ctx "fs" ~infer_cache:None ~out:ignore ~seed:0);
         let read () =
           match Eval.run_expr ctx (expression store (Printf.sprintf "read(%S)" hello)) with
           | Ok value -> Value.show value
           | Error error -> Diag.code_or_uncoded (Runtime_err.to_diag error)
         in
         let scoped, _ = Eval.with_scope ctx ~alloc:2 read in
         (scoped, read ())))

let test_alloc_natives () =
  let store, ctx =
    prepared "alloc-natives"
      "type T = | L | N(left: T, right: T)\n\
       dbl(x, k) = if eq(k, 0) then x else dbl(N(x, x), sub(k, 1))\n"
  in
  (* every trusted native the prelude installs has an allocation class *)
  Alcotest.(check (list string))
    "every native is classified" []
    (List.filter
       (fun name -> Option.is_none (Native_alloc.classify name))
       (Eval.trusted_builtin_names ctx));
  Alcotest.(check bool)
    "the inventory is not empty" true
    (List.length (Eval.trusted_builtin_names ctx) > 40);
  (* a native's result costs its new cells: text one plus one per started 8 bytes, a boolean one *)
  let cost source = snd (allocated ctx store source) in
  Alcotest.(check int) "short text" 2 (cost "text.concat(\"ab\", \"cd\")");
  Alcotest.(check int) "longer text" 3 (cost "text.concat(\"abcdefgh\", \"i\")");
  Alcotest.(check int) "scalar" 0 (cost "add(1, 2)");
  Alcotest.(check int) "boolean" 1 (cost "eq(1, 2)");
  (* a list of pieces: per piece a cons (3) and its text (2), then nil *)
  Alcotest.(check int) "split" ((2 * (3 + 2)) + 1) (cost "text.split(\"a,b\", \",\")");
  (* splitting code shares its children: some, the pair, the head, a cons and wrapper each *)
  let form = "code.form(\"pair\", [code.of-int(1), code.of-int(2)])" in
  Alcotest.(check int)
    "un-form shares the children"
    (2 + 3 + 1 + (2 * 4) + 1)
    (cost (Printf.sprintf "code.un-form(%s)" form) - cost form);
  (* the result is charged before the program receives it: one cell short is incomplete *)
  let concat = "text.concat(\"abcdefgh\", \"i\")" in
  Alcotest.(check (pair string int))
    "exact boundary" ("\"abcdefghi\"", 3)
    (allocated ~budget:3 ctx store concat);
  Alcotest.(check string) "one cell short" "E0921" (fst (allocated ~budget:2 ctx store concat));
  (* rendering an exponentially shared value stops at the budget while the text is built *)
  Alcotest.(check (pair string int))
    "rendering is guarded" ("E0921", 1_000)
    (allocated ~budget:1_000 ctx store "text.length(debug.inspect(dbl(L, 40)))");
  (* a sampler retains one pair per finished run, so a model that allocates nothing per run still
     stops at the budget instead of retaining runs without bound *)
  Alcotest.(check (pair string int))
    "sampling is bounded" ("E0921", 1_000)
    (allocated ~budget:1_000 ctx store "dist.sample-lw(fn () -> 1, 100000000, 1)");
  (* joining pays for its separators before building: many pieces and a long separator stop at the
     budget instead of first building the text *)
  let separator = String.make 1_000 'x' in
  Alcotest.(check string)
    "joining is guarded" "E0921"
    (fst
       (allocated ~budget:100 ctx store
          (Printf.sprintf "text.join-list([\"\", \"\", \"\", \"\", \"\"], \"%s\")" separator)));
  (* nodes are counted once each: a value shared 2^40 ways costs its 40 distinct nodes *)
  let rec shared k value =
    if k = 0 then value else shared (k - 1) (Value.VTuple [ value; value ])
  in
  Alcotest.(check int)
    "distinct nodes" (40 * 3)
    (Native_alloc.fresh_cells (shared 40 (Value.VInt 0)));
  (* and what a result shares with the native's inputs is not charged again *)
  let input = shared 10 (Value.VText "abcdefghijklmnop") in
  Alcotest.(check int)
    "inputs are already paid for" (3 + 2)
    (Native_alloc.cells Native_alloc.Posterior ~args:[ input ]
       (Value.VTuple [ input; Value.VText "ab" ]));
  (* a Bernoulli's support makes its two booleans as well as the list of pairs *)
  Alcotest.(check int)
    "support"
    ((2 * 6) + 1 + 2)
    (cost "support(Bernoulli(0.5))" - cost "Bernoulli(0.5)");
  (* a code literal's text is already held: extracting it adds only the option and the wrapper *)
  let literal = Printf.sprintf "code.of-text(\"%s\")" (String.make 800 'x') in
  Alcotest.(check int)
    "to-text shares its bytes" 3
    (cost (Printf.sprintf "code.to-text(%s)" literal) - cost literal);
  (* comparing allocates nothing: equal forms need only the room for "identical" *)
  let wide k = Printf.sprintf "wide(code.of-int(1), %d)" k in
  let store, ctx =
    prepared "alloc-natives-code"
      "wide(c, k) = if eq(k, 0) then c else wide(code.form(\"p\", [c, c]), sub(k, 1))\n"
  in
  let diff = Printf.sprintf "code.diff(%s, %s)" (wide 12) (wide 12) in
  let result, used = allocated ctx store diff in
  Alcotest.(check string) "equal forms" "\"identical\"" result;
  Alcotest.(check (pair string int))
    "fit their exact budget" (result, used)
    (allocated ~budget:used ctx store diff);
  (* a hash charges the text it renders, and completes at exactly that cost *)
  let hash = Printf.sprintf "code.hash(%s)" (wide 3) in
  Alcotest.(check bool) "hash" true (snd (allocated ctx store hash) > 5);
  Alcotest.(check string)
    "and one cell short is incomplete" "E0921"
    (fst (allocated ~budget:(snd (allocated ctx store hash) - 1) ctx store hash));
  let store, ctx =
    prepared "alloc-natives-shared"
      "type T = | L | N(left: T, right: T)\n\
       dbl(x, k) = if eq(k, 0) then x else dbl(N(x, x), sub(k, 1))\n"
  in
  (* a sampler keys its runs by rendering them: that rendering stops at the budget too *)
  Alcotest.(check (pair string int))
    "sampling a shared value" ("E0921", 1_000)
    (allocated ~budget:1_000 ctx store "dist.sample-lw(fn () -> dbl(L, 40), 1, 0)");
  (* a refused rendering leaves nothing behind *)
  let big = expression store "debug.inspect(dbl(L, 40))"
  and small = expression store "debug.inspect(dbl(L, 2))" in
  Alcotest.(check bool)
    "the invocation continues after a refused rendering" true
    (Eval.with_invocation ~alloc:100_000 ctx (fun _ ->
         let _, report = Eval.with_scope ctx ~alloc:100 (fun () -> Eval.run_expr ctx big) in
         Option.is_some report.Eval.exhaustion && Result.is_ok (Eval.run_expr ctx small)));
  (* comparing by rendering stops at the budget as well *)
  Alcotest.(check (pair string int))
    "pmf over a shared value" ("E0921", 1_000)
    (allocated ~budget:1_000 ctx store "pmf(Categorical([mk-pair(dbl(L, 40), 1.0)]), dbl(L, 40))");
  (* a form holds a reference per child, so repeating one over a list pays for each spine *)
  let form_store, form_ctx = prepared "alloc-natives-form" "" in
  let bare = "code.of-int(1)" in
  let cost_form source = snd (allocated form_ctx form_store source) in
  let two = Printf.sprintf "[%s, %s]" bare bare in
  Alcotest.(check int)
    "a form costs one plus its children" 3
    (cost_form (Printf.sprintf "code.form(\"p\", %s)" two) - cost_form two);
  (* differing scalars are counted as they are found: a 2^40-way difference stops at the budget *)
  let diverging_store, diverging_ctx =
    prepared "alloc-natives-diff"
      "wide(c, k) = if eq(k, 0) then c else wide(code.form(\"p\", [c, c]), sub(k, 1))\n"
  in
  Alcotest.(check (pair string int))
    "differing scalars" ("E0921", 1_000)
    (allocated ~budget:1_000 diverging_ctx diverging_store
       "code.diff(wide(code.of-int(1), 40), wide(code.of-int(2), 40))");
  (* a form of many scalars is checked at each one, so it overshoots by at most one *)
  let many = Form.form "p" (List.init 100_000 (fun _ -> Form.Text (String.make 80 'x'))) in
  Alcotest.(check bool)
    "a wide form stops within one scalar" true
    (Eval.with_invocation ~alloc:50 ctx (fun _ ->
         Eval.with_rendered ctx
           ~exceeded:(fun _ -> true)
           (fun () ->
             ignore (Printer.print_compact many);
             false)));
  (* a changed operation mode is rendered with the operation's name: one divergence whose path is
     tiny still stops at the budget when the name is long *)
  let name = String.make 10_000 'n' in
  let leaf = Form.form "lit" [ Form.Int 0 ] in
  let op mode = Form.form "op" ((Form.Sym name :: mode) @ [ Form.F leaf; Form.F leaf ]) in
  Alcotest.(check bool)
    "operation-mode divergences are counted" true
    (Eval.with_invocation ~alloc:1_000 ctx (fun _ ->
         Eval.with_rendered ctx
           ~exceeded:(fun _ -> true)
           (fun () ->
             ignore (Diff.form_divergences ~path:"log" (op []) (op [ Form.Sym "once" ]));
             false)));
  (* a nested rendering counts what the enclosing one has pending *)
  Alcotest.(check bool)
    "nested renderings share the allowance" true
    (Eval.with_invocation ~alloc:50 ctx (fun _ ->
         Eval.with_rendered ctx
           ~exceeded:(fun _ -> true)
           (fun () ->
             ignore (Value.show (Value.VText (String.make 300 'x')));
             (* about 31 cells: it fits alone, but not over the 39 the outer one has pending *)
             Eval.with_rendered ctx
               ~exceeded:(fun _ -> true)
               (fun () ->
                 ignore (Value.show (Value.VTuple (List.init 20 (fun _ -> Value.VText "xxxxxxxx"))));
                 false))));
  let rendered = "debug.inspect(dbl(L, 2))" in
  let text, used = allocated ctx store rendered in
  Alcotest.(check (pair string int))
    "and completes at exactly its cost" (text, used)
    (allocated ~budget:used ctx store rendered)

(* --- typed observation (RF.3) --- *)

let describe = function
  | Observation.Operation { name; arguments; _ } ->
      Printf.sprintf "op %s(%s)" name
        (String.concat ", " (List.map Observation.render (Lazy.force arguments)))
  | Observation.Output { bytes; _ } -> Printf.sprintf "out %S" bytes
  | Observation.Result { result; _ } -> (
      match Lazy.force result with
      | Ok value -> "ok " ^ Observation.render value
      | Error error -> "error " ^ Diag.code_or_uncoded (Runtime_err.to_diag error))

let test_typed_events () =
  let store, ctx = prepared "observe-events" "" in
  let greet = expression store "{ print(\"a\"); print(\"bc\"); 1 }" in
  let sink = Buffer.create 16 in
  let seen = ref [] in
  let result =
    Eval.with_invocation ctx (fun _ ->
        grant_console ctx sink;
        Eval.with_observer ctx
          (fun event -> seen := describe event :: !seen)
          (fun () -> Eval.run_expr ctx greet))
  in
  (match result with Ok (Value.VInt 1) -> () | _ -> Alcotest.fail "evaluation changed");
  Alcotest.(check (list string))
    "ordered operation, output and result"
    [ "op print(\"a\")"; "out \"a\""; "ok ()"; "op print(\"bc\")"; "out \"bc\""; "ok ()" ]
    (List.rev !seen);
  Alcotest.(check string) "each operation dispatched once" "abc" (Buffer.contents sink);
  (* after its extent, the observer receives nothing *)
  let before = List.length !seen in
  Eval.with_invocation ctx (fun _ ->
      grant_console ctx sink;
      ignore (Eval.run_expr ctx greet));
  Alcotest.(check int) "no events after the observer ended" before (List.length !seen)

let test_observer_cannot_evaluate () =
  let store, ctx = prepared "observe-refuse" "" in
  let greet = expression store "print(\"x\")" and one = expression store "add(1, 2)" in
  let sink = Buffer.create 16 in
  let attempts = ref [] in
  let result =
    Eval.with_invocation ctx (fun _ ->
        grant_console ctx sink;
        Eval.with_observer ctx
          (fun _ ->
            attempts :=
              (match Eval.run_expr ctx one with
              | Ok _ -> "evaluated"
              | Error error -> Runtime_err.to_string error)
              :: !attempts)
          (fun () -> Eval.run_expr ctx greet))
  in
  Alcotest.(check bool) "the observed run still completes" true (Result.is_ok result);
  Alcotest.(check bool)
    "every callback evaluation was refused" true
    (!attempts <> [] && List.for_all (fun a -> a <> "evaluated") !attempts);
  Alcotest.(check string) "the effect happened once" "x" (Buffer.contents sink);
  (* a callback exception propagates; the observer and the refusal flag are restored *)
  (match
     Eval.with_invocation ctx (fun _ ->
         grant_console ctx sink;
         Eval.with_observer ctx (fun _ -> raise Boom) (fun () -> Eval.run_expr ctx greet))
   with
  | _ -> Alcotest.fail "the observer exception was swallowed"
  | exception Boom -> ());
  Alcotest.(check string)
    "the operation was not dispatched after the failing callback" "x" (Buffer.contents sink);
  (* a callback cannot grant the operation it observes *)
  let granted_inside =
    Eval.with_invocation ctx (fun _ ->
        Eval.with_observer ctx
          (fun event ->
            match
              Eval.register_root_handler ctx (Observation.operation event) (fun _ ->
                  Ok Value.unit_v)
            with
            | () -> Alcotest.fail "a callback registered a handler"
            | exception Invalid_argument _ -> ())
          (fun () -> failure (Eval.run_expr ctx greet)))
  in
  Alcotest.(check string) "the ungranted operation stays unhandled" "unhandled" granted_inside;
  (* observers see data, never live secrets or closures *)
  let secret = Value.VSecret (Secret.of_string "hunter2") in
  let rendered =
    List.map Observation.render
      (List.map Observation.of_value
         [ secret; Value.VTuple [ Value.VInt 1; Value.VText "a" ]; Value.VResume [] ])
  in
  Alcotest.(check (list string))
    "opaque secrets and continuations"
    [ "<secret>"; "(1, \"a\")"; "<resumption>" ]
    rendered;
  (* the v1 view never sees results *)
  let v1 = ref 0 in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         grant_console ctx sink;
         Eval.with_root_observer ctx
           ~on_operation:(fun _ -> incr v1)
           ~on_output:(fun _ _ -> incr v1)
           (fun () -> Eval.run_expr ctx greet)));
  Alcotest.(check int) "v1 observes operation and output only" 2 !v1;
  Alcotest.(check bool)
    "evaluation works again" true
    (Eval.with_invocation ctx (fun _ -> Result.is_ok (Eval.run_expr ctx one)))

(* RF.3 boundary: data views of real events, nested extents, and refused restoration *)
let test_observer_boundary () =
  let store, ctx =
    prepared "observe-boundary" "once effect Probe where { probe.next : (Int) -> Int }\n"
  in
  let asking = expression store "add(probe.next(1), 1)" in
  let seen = ref [] in
  let record event = seen := describe event :: !seen in
  (* an ungranted operation is observed, then left unhandled: no Result *)
  let operation = ref None in
  let code =
    Eval.with_invocation ctx (fun _ ->
        Eval.with_observer ctx
          (fun event ->
            operation := Some (Observation.operation event);
            record event)
          (fun () -> failure (Eval.run_expr ctx asking)))
  in
  Alcotest.(check string) "ungranted" "unhandled" code;
  Alcotest.(check (list string)) "operation only" [ "op probe.next(1)" ] (List.rev !seen);
  let operation = Option.get !operation in
  (* a granted handler returning a secret: the program receives it, the observer sees <secret> *)
  seen := [];
  let secret = Value.VSecret (Secret.of_string "hunter2") in
  let secret_result =
    Eval.with_invocation ctx (fun _ ->
        Eval.register_root_handler ctx operation (fun _ -> Ok secret);
        Eval.with_observer ctx record (fun () ->
            Eval.run_expr ctx (expression store "probe.next(2)")))
  in
  (match secret_result with
  | Ok (Value.VSecret _) -> ()
  | _ -> Alcotest.fail "the program did not receive the secret");
  Alcotest.(check (list string))
    "secret result is opaque"
    [ "op probe.next(2)"; "ok <secret>" ]
    (List.rev !seen);
  (* the innermost observer owns its extent; the outer one resumes afterwards *)
  let outer = ref 0 and inner = ref 0 in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         Eval.register_root_handler ctx operation (fun _ -> Ok (Value.VInt 3));
         Eval.with_observer ctx
           (fun _ -> incr outer)
           (fun () ->
             ignore
               (Eval.with_observer ctx
                  (fun _ -> incr inner)
                  (fun () -> Eval.run_expr ctx (expression store "probe.next(4)")));
             Eval.run_expr ctx (expression store "probe.next(5)"))));
  Alcotest.(check (pair int int)) "nested observers are isolated" (2, 2) (!outer, !inner);
  (* a callback can neither resume a captured Once continuation nor restore a validated state *)
  let captured =
    Eval.with_invocation ctx (fun _ ->
        match Eval.run_state_capturing ctx (Eval.expr_state asking) with
        | Ok (Eval.COp { kont; _ }) -> kont
        | _ -> Alcotest.fail "the operation was not captured")
  in
  let validated =
    match Eval.validate_state_once ctx (Eval.expr_state (expression store "add(1, 2)")) with
    | Ok state -> state
    | Error error -> Alcotest.failf "validation failed: %s" (Runtime_err.to_string error)
  in
  let refusals = ref [] in
  let sink = Buffer.create 16 in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         grant_console ctx sink;
         Eval.with_observer ctx
           (fun _ ->
             (match Eval.resume_captured_state ctx captured (Value.VInt 1) with
             | Ok _ -> refusals := "resumed" :: !refusals
             | Error _ -> refusals := "resume refused" :: !refusals);
             (match Eval.fresh_validated_state ctx validated with
             | _ -> refusals := "restored" :: !refusals
             | exception Invalid_argument _ -> refusals := "restore refused" :: !refusals);
             match Eval.fresh_audit_run_id ctx with
             | _ -> refusals := "minted" :: !refusals
             | exception Invalid_argument _ -> refusals := "mint refused" :: !refusals)
           (fun () -> Eval.run_expr ctx (expression store "print(\"x\")"))));
  Alcotest.(check (list string))
    "every callback attempt was refused"
    [ "mint refused"; "restore refused"; "resume refused" ]
    (List.sort_uniq compare !refusals);
  (* a Result callback that exhausts the budget and swallows the exception still ends the run *)
  let swallowed =
    Eval.with_invocation ~fuel:1_000_000 ctx (fun _ ->
        Eval.register_root_handler ctx operation (fun _ -> Ok (Value.VInt 3));
        Eval.with_observer ctx
          (function
            | Observation.Result _ -> (
                try
                  Fuel_meter.trip ();
                  raise Fuel_meter.Exceeded
                with Fuel_meter.Exceeded -> ())
            | _ -> ())
          (fun () -> failure (Eval.run_expr ctx (expression store "probe.next(6)"))))
  in
  Alcotest.(check string) "observer exhaustion is not hidden" "E0919" swallowed;
  (* the refused resumption consumed nothing: the owner still resumes it once *)
  match
    Eval.with_invocation ctx (fun _ ->
        match Eval.resume_captured_state ctx captured (Value.VInt 41) with
        | Ok state -> run_state ctx state
        | Error error -> Error error)
  with
  | Ok (Value.VInt 42) -> ()
  | Ok value -> Alcotest.failf "resumed to %s" (Value.show value)
  | Error error -> Alcotest.failf "resume failed: %s" (Runtime_err.to_string error)

let suite =
  [
    Alcotest.test_case "grants are scoped to one invocation" `Quick test_grants_are_scoped;
    Alcotest.test_case "observers see data views and cannot restore or resume" `Quick
      test_observer_boundary;
    Alcotest.test_case "once resumptions are evaluator-owned and refused elsewhere" `Quick
      test_stale_once_resumption;
    Alcotest.test_case "grants, observers, and coverage are restored on exceptions" `Quick
      test_restoration_on_exception;
    Alcotest.test_case "teardown runs exactly once, most recent first" `Quick
      test_teardown_exactly_once;
    Alcotest.test_case "the prepared program is reused across invocations" `Quick
      test_program_is_reusable;
    Alcotest.test_case "fuel stops a pure loop at a reproducible boundary" `Quick
      test_fuel_stops_a_pure_loop;
    Alcotest.test_case "fuel completes at exactly the program's cost" `Quick
      test_fuel_exact_boundary;
    Alcotest.test_case "multi-shot branches and enumeration share one budget" `Quick
      test_fuel_is_shared_by_multi_shot_branches;
    Alcotest.test_case "fuel does not depend on memo warmth" `Quick test_fuel_ignores_memo_warmth;
    Alcotest.test_case "allocation completes at exactly the program's cost" `Quick
      test_alloc_exact_boundary;
    Alcotest.test_case "allocation is shared by multi-shot branches" `Quick
      test_alloc_is_shared_by_multi_shot_branches;
    Alcotest.test_case "allocation exhaustion is sticky" `Quick test_alloc_exhaustion_is_sticky;
    Alcotest.test_case "allocation of a failed memo dependency is replayed" `Quick
      test_alloc_failed_memo_dependency;
    Alcotest.test_case "allocation charges nullary values and driver resumptions" `Quick
      test_alloc_nullary_and_driver_resumptions;
    Alcotest.test_case "allocation and fuel stop at the same point warm or cold" `Quick
      test_alloc_and_fuel_memo_order;
    Alcotest.test_case "allocation does not depend on memo warmth" `Quick
      test_alloc_ignores_memo_warmth;
    Alcotest.test_case "natives pay for text payloads" `Quick test_fuel_charges_native_payloads;
    Alcotest.test_case "exhaustion is sticky within an invocation" `Quick
      test_fuel_exhaustion_is_sticky;
    Alcotest.test_case "exhaustion never retries an effect" `Quick
      test_fuel_does_not_retry_side_effects;
    Alcotest.test_case "every value walk draws on the budget" `Quick test_fuel_bounds_deep_natives;
    Alcotest.test_case "wrapped exhaustion stays E0919" `Quick test_fuel_survives_nested_drivers;
    Alcotest.test_case "drivers report allocation exhaustion as E0921" `Quick
      test_alloc_survives_drivers;
    Alcotest.test_case "allocation scopes cap one branch of an invocation" `Quick test_alloc_scopes;
    Alcotest.test_case "every native is classified and charged" `Quick test_alloc_natives;
    Alcotest.test_case "root handlers charge their results and bound external reads" `Quick
      test_alloc_root_handlers;
    Alcotest.test_case "registry ceilings bound retained tasks and open channels" `Quick
      test_registry_ceilings;
    Alcotest.test_case "a native's wrapped E0921 exhausts its invocation" `Quick
      test_alloc_wrapped_native_exhaustion;
    Alcotest.test_case "work outside runs is charged and never raises" `Quick test_fuel_outside_runs;
    Alcotest.test_case "fuel scopes cap one branch of the aggregate" `Quick test_fuel_scopes;
    Alcotest.test_case "typed root events are ordered and single" `Quick test_typed_events;
    Alcotest.test_case "observers cannot evaluate and failures propagate" `Quick
      test_observer_cannot_evaluate;
  ]
