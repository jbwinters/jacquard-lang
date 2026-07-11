open Jacquard

(* W6.1-W6.3, W6.8: report semantics, both directions of the failure assertions,
   cache entry round-trips, and the coverage memo trap. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)
let run body = Printf.sprintf "(app (var test.run) (lam () %s))" body

(* --- W6.1 report goldens --- *)

let test_report_all_pass () =
  Alcotest.(check string)
    "two entries in check order"
    "mk-report(cons((\"first\", true), cons((\"second\", true), nil)), none)"
    (show
       (run
          "(let nonrec (pwild) (app (var check.true) (var true) (lit \"first\")) (app (var \
           check.true) (var true) (lit \"second\")))"))

let test_report_soft_fail_order () =
  Alcotest.(check string)
    "soft failures collect, later checks still run"
    "mk-report(cons((\"a\", false), cons((\"b\", true), cons((\"c\", false), nil))), none)"
    (show
       (run
          "(let nonrec (pwild) (app (var check.true) (var false) (lit \"a\")) (let nonrec (pwild) \
           (app (var check.true) (var true) (lit \"b\")) (app (var check.true) (var false) (lit \
           \"c\"))))"))

let test_report_hard_fail_short_circuits () =
  Alcotest.(check string)
    "checks before the fail survive; after never runs"
    "mk-report(cons((\"before\", true), nil), some(\"boom\"))"
    (show
       (run
          "(let nonrec (pwild) (app (var check.true) (var true) (lit \"before\")) (let nonrec \
           (pwild) (app (var fail) (lit \"boom\")) (app (var check.true) (var true) (lit \
           \"after\"))))"))

let test_report_zero_checks () =
  Alcotest.(check string)
    "empty-vs-asserted is distinguishable" "mk-report(nil, none)"
    (show (run "(tuple)"))

(* --- W6.1 assertions, both directions --- *)

let test_check_fails_both_directions () =
  Alcotest.(check string)
    "aborting body passes" "mk-report(cons((\"expected abort\", true), nil), none)"
    (show
       (run
          "(app (var check.fails) (lam () (app (var option.get!) (var none))) (lit \"expected \
           abort\"))"));
  Alcotest.(check string)
    "completing body is a recorded failure"
    "mk-report(cons((\"expected abort: completed without aborting\", false), nil), none)"
    (show (run "(app (var check.fails) (lam () (lit 7)) (lit \"expected abort\"))"))

let test_check_throws_both_directions () =
  let pred = "(lam ((pvar e)) (app (var eq) (var e) (lit 7)))" in
  Alcotest.(check string)
    "throwing body passes the predicate"
    "mk-report(cons((\"expected throw: threw 7\", true), nil), none)"
    (show
       (run
          (Printf.sprintf
             "(app (var check.throws) (lam () (app (var throw) (lit 7))) %s (var int.show) (lit \
              \"expected throw\"))"
             pred)));
  Alcotest.(check string)
    "completing body is a recorded failure"
    "mk-report(cons((\"expected throw: completed without throwing\", false), nil), none)"
    (show
       (run
          (Printf.sprintf
             "(app (var check.throws) (lam () (lit 1)) %s (var int.show) (lit \"expected throw\"))"
             pred)))

let test_check_eq_renders_both_sides () =
  Alcotest.(check string)
    "failure message shows expected and got"
    "mk-report(cons((\"sum: expected 5, got 4\", false), nil), none)"
    (show
       (run
          "(app (var check.eq) (app (var add) (lit 2) (lit 2)) (lit 5) (var int.eq) (var int.show) \
           (lit \"sum\"))"))

(* the whole suite above ran with ZERO grants: pure Jacquard over rings 0-1, asserted *)
let test_manifest_pure () =
  match Reader.parse_one ~file:"m.jqd" (run "(app (var check.true) (var true) (lit \"t\"))") with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok f -> (
      match Result.bind (Kernel.expr_of_form f) (Resolve.resolve_expr (Store.names_view store)) with
      | Error ds -> Eval_support.fail_diags "resolve" ds
      | Ok e -> (
          match Check.make_ctx store with
          | Error ds -> Eval_support.fail_diags "ctx" ds
          | Ok cctx -> (
              (match Prelude.builtin_signatures store with
              | Ok sigs -> Check.register_builtin_signatures cctx sigs
              | Error ds -> Eval_support.fail_diags "sigs" ds);
              match Check.check_top cctx (Kernel.Expr e) with
              | Error ds -> Eval_support.fail_diags "check" ds
              | Ok { Check.row = Some r; _ } ->
                  Alcotest.(check (list string))
                    "no fixed effects" []
                    (List.map (fun h -> Hash.to_hex h) (Types.repr_row r).Types.effects)
              | Ok _ -> Alcotest.fail "expected a row")))

(* --- W6.3 cache entries round-trip --- *)

let test_cache_entry_roundtrip () =
  let cases =
    [
      Warp.Pass 3;
      Warp.NoChecks;
      Warp.Fail { soft = [ "a: expected 1, got 2"; "b" ]; hard = None };
      Warp.Fail { soft = []; hard = Some "boom" };
    ]
  in
  (* one multi-outcome entry (the group shape) round-trips verdicts, displays, coverage *)
  let key = "warp-v1|case|deadbeef" in
  let coverage = [ Hash.of_string "x"; Hash.of_string "y" ] in
  let outcomes =
    List.mapi
      (fun i v ->
        (Printf.sprintf "g/case-%d" i, v, (if i = 0 then Some "prop: 5 cases" else None), coverage))
      cases
  in
  let printed = Printer.print (Warp.entry_form ~key ~outcomes) in
  match Reader.parse_one ~file:"entry.jqd" printed with
  | Error ds -> Eval_support.fail_diags "reparse" ds
  | Ok f -> (
      match Warp.entry_of_form f with
      | Some (k, back) ->
          Alcotest.(check string) "key" key k;
          Alcotest.(check int) "outcome count" (List.length outcomes) (List.length back);
          List.iter2
            (fun (d, v, n, c) (d', v', n', c') ->
              Alcotest.(check string) "display" d d';
              Alcotest.(check bool) "verdict" true (v = v');
              Alcotest.(check bool) "note" true (n = n');
              Alcotest.(check int) "coverage size" (List.length c) (List.length c'))
            outcomes back
      | None -> Alcotest.failf "entry did not round-trip:\n%s" printed)

(* --- W6.8: the memo trap — two tests sharing a dependency BOTH count it --- *)

let test_coverage_memo_trap () =
  let dep_hash =
    match Store.lookup_kind store "list.length" Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "list.length missing"
  in
  let test_run_v =
    match
      Eval.run_expr ctx
        {
          Kernel.it =
            Kernel.Ref
              ( (match Store.lookup_kind store "test.run" Resolve.KTerm with
                | Some e -> e.Resolve.hash
                | None -> Alcotest.fail "test.run"),
                Kernel.Term );
          meta = Meta.empty;
        }
    with
    | Ok v -> v
    | Error e -> Alcotest.failf "test.run value: %s" (Runtime_err.to_string e)
  in
  let thunk_src =
    "(lam () (app (var check.eq) (app (var list.length) (var nil)) (lit 0) (var int.eq) (var \
     int.show) (lit \"len\")))"
  in
  let thunk () = eval_ok thunk_src in
  let covered_by t =
    match Warp.run_thunk ctx ~test_run:test_run_v t with
    | Ok (_, cov) -> cov
    | Error e -> Alcotest.fail e
  in
  let first = covered_by (thunk ()) in
  Alcotest.(check bool) "first run counts the dep" true (List.exists (Hash.equal dep_hash) first);
  (* second run: list.length is now MEMOIZED in ctx — the coverage hook must fire anyway *)
  let second = covered_by (thunk ()) in
  Alcotest.(check bool)
    "memoized run still counts the dep" true
    (List.exists (Hash.equal dep_hash) second)

let suite =
  [
    Alcotest.test_case "report: all pass, in order" `Quick test_report_all_pass;
    Alcotest.test_case "report: soft failures collect" `Quick test_report_soft_fail_order;
    Alcotest.test_case "report: hard fail short-circuits" `Quick
      test_report_hard_fail_short_circuits;
    Alcotest.test_case "report: zero checks distinguishable" `Quick test_report_zero_checks;
    Alcotest.test_case "check.fails both directions" `Quick test_check_fails_both_directions;
    Alcotest.test_case "check.throws both directions" `Quick test_check_throws_both_directions;
    Alcotest.test_case "check.eq renders both sides" `Quick test_check_eq_renders_both_sides;
    Alcotest.test_case "suite is pure (zero grants)" `Quick test_manifest_pure;
    Alcotest.test_case "cache entry round-trip" `Quick test_cache_entry_roundtrip;
    Alcotest.test_case "coverage counts memo hits" `Quick test_coverage_memo_trap;
  ]
