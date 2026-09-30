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
        | Ok value -> Value.show value
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
  fact_program ^ "base = fact(12)\nderived = add(base, 1)\nother = add(base, derived)\n"

let test_fuel_ignores_memo_warmth () =
  (* the fuel an expression costs is the same on a fresh evaluator and after any earlier
     invocation warmed the memo in any order *)
  let cold source =
    let store, ctx = prepared "fuel-memo-cold" memo_program in
    snd (fueled ctx store source)
  in
  let sources = [ "base"; "derived"; "other"; "add(derived, base)"; "add(other, 1)" ] in
  let expected = List.map (fun source -> (source, cold source)) sources in
  let orders =
    [
      sources;
      List.rev sources;
      [ "other"; "base"; "add(other, 1)"; "derived"; "add(derived, base)" ];
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
  let small = snd (fueled ctx store "text.length(\"ab\")") in
  let big = String.make 6400 'x' in
  let large = snd (fueled ctx store (Printf.sprintf "text.length(\"%s\")" big)) in
  (* 6400 argument bytes are 100 units; the Int result is free *)
  Alcotest.(check int) "argument bytes are charged" (small + 100) large;
  let concat source = snd (fueled ctx store source) in
  (* 12800 argument bytes (200) and a 12800-byte result (200) *)
  Alcotest.(check int)
    "argument and result bytes are charged"
    (concat "text.concat(\"ab\", \"cd\")" + 400)
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
       cdbl(c, k) = if eq(k, 0) then c else cdbl(code.form(\"p\", [c, c]), sub(k, 1))\n"
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

let suite =
  [
    Alcotest.test_case "grants are scoped to one invocation" `Quick test_grants_are_scoped;
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
    Alcotest.test_case "natives pay for text payloads" `Quick test_fuel_charges_native_payloads;
    Alcotest.test_case "exhaustion is sticky within an invocation" `Quick
      test_fuel_exhaustion_is_sticky;
    Alcotest.test_case "exhaustion never retries an effect" `Quick
      test_fuel_does_not_retry_side_effects;
    Alcotest.test_case "deep natives pay for expanded size first" `Quick
      test_fuel_bounds_deep_natives;
    Alcotest.test_case "wrapped exhaustion stays E0919" `Quick test_fuel_survives_nested_drivers;
    Alcotest.test_case "work outside runs is charged and never raises" `Quick test_fuel_outside_runs;
  ]
