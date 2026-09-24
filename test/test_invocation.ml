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

let suite =
  [
    Alcotest.test_case "grants are scoped to one invocation" `Quick test_grants_are_scoped;
    Alcotest.test_case "once resumptions are evaluator-owned and refused elsewhere" `Quick
      test_stale_once_resumption;
    Alcotest.test_case "grants and coverage are restored on exceptions" `Quick
      test_restoration_on_exception;
    Alcotest.test_case "teardown runs exactly once, most recent first" `Quick
      test_teardown_exactly_once;
    Alcotest.test_case "the prepared program is reused across invocations" `Quick
      test_program_is_reusable;
  ]
