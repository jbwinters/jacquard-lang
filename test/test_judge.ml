open Jacquard

(* GM.5: blessed Judge identity, validated assessment handlers, and honest rows. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_value source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "Judge evaluation failed: %s\nsource: %s" (Runtime_err.to_string error) source

let show source = Value.show (eval_value source)
let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let hash_a = String.make 64 'a'

let hash value =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (var parsed)))"
    (qtext value)

let call =
  Printf.sprintf
    "(app (var governance-call-v0) (var governance-v0) %s %s (lit \"fs.write\") (quote (arguments \
     (lit 7))) (var nil) (lit \"write one object\") (quote (preconditions)) (var none))"
    (hash hash_a) (hash hash_a)

let list values =
  List.fold_right
    (fun value tail -> Printf.sprintf "(app (var cons) %s %s)" value tail)
    values "(var nil)"

let assessment ?(risk = "low") ?(confidence = "(lit 0.75)") ?(reasons = [ "rule matched" ])
    ?(evidence = "(quote (evidence (lit \"deterministic\")))") () =
  Printf.sprintf "(app (var governance-assessment-v0) (var governance-v0) (var %s) %s %s %s)" risk
    confidence
    (list (List.map (fun reason -> "(lit " ^ qtext reason ^ ")") reasons))
    evidence

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing released Judge name %s" name

let checker () =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make Judge checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register Judge builtins" diagnostics);
  checker

let scheme name =
  let checker = checker () in
  match Check.force_term checker (lookup name Resolve.KTerm) with
  | Ok scheme -> Check.show_scheme checker scheme
  | Error diagnostics -> Eval_support.fail_diags ("force " ^ name) diagnostics

let check_expr source =
  let checker = checker () in
  match Reader.parse_one ~file:"judge-row.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top checker (Kernel.Expr expression)))

let caught body =
  show
    (Printf.sprintf "(app (var throw.catch) (lam () %s) (lam ((pvar message)) (var message)))" body)

let test_released_identity_and_once_mode () =
  let judge = lookup "judge" Resolve.KEffect in
  ignore (lookup "assess" Resolve.KOp);
  Alcotest.(check string)
    "released Judge interface hash"
    "9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354" (Hash.to_hex judge);
  match Store.locate store judge with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops = [ operation ]; _ }; _ }; _ } ->
      Alcotest.(check bool) "Judge.assess is once" true (operation.op_mode = Kernel.Once)
  | Ok _ -> Alcotest.fail "Judge identity did not locate to its one-operation declaration"
  | Error diagnostics -> Eval_support.fail_diags "locate Judge" diagnostics

let test_exact_handler_rows () =
  let expected =
    [
      ( "judge.rules",
        "forall a | e. (() ->{Judge, Throw | e} a, (GovernanceCall) ->{} GovernanceAssessment) \
         ->{Throw | e} a" );
      ( "judge.fixed",
        "forall a | e. (() ->{Judge, Throw | e} a, GovernanceAssessment) ->{Throw | e} a" );
      ( "judge.scripted",
        "forall a | e. (() ->{Judge, Throw | e} a, List GovernanceAssessment) ->{Throw | e} a" );
      ( "judge.model",
        "forall a | e. (() ->{Infer, Judge, Throw | e} a, (GovernanceCall) ->{Infer} \
         GovernanceAssessment) ->{Infer, Throw | e} a" );
    ]
  in
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string) (name ^ " exact outward row") expected (scheme name))
    expected

let test_fixed_replay_is_exact () =
  let value = assessment () in
  let expression =
    Printf.sprintf
      "(app (var judge.fixed) (lam () (tuple (app (var assess) %s) (app (var assess) %s))) %s)" call
      call value
  in
  let first = show expression in
  let expected = show value in
  Alcotest.(check string)
    "fixed handler preserves risk, confidence, reasons, and evidence"
    (Printf.sprintf "(%s, %s)" expected expected)
    first;
  Alcotest.(check string) "fixed handler replays one value" first (show expression)

let test_rules_and_scripted_order () =
  let ruled = assessment ~risk:"medium" ~reasons:[ "pure rule" ] () in
  Alcotest.(check string)
    "pure rule receives the call" (show ruled)
    (show
       (Printf.sprintf
          "(app (var judge.rules) (lam () (app (var assess) %s)) (lam ((pvar proposed)) %s))" call
          ruled));
  let low = assessment ~risk:"low" ~reasons:[ "first" ] () in
  let high = assessment ~risk:"high" ~confidence:"(lit 0.9)" ~reasons:[ "second" ] () in
  let expression =
    Printf.sprintf
      "(app (var judge.scripted) (lam () (tuple (app (var assess) %s) (app (var assess) %s))) %s)"
      call call
      (list [ low; high ])
  in
  let first = show expression in
  Alcotest.(check string) "script replay is deterministic" first (show expression);
  Alcotest.(check bool)
    "script preserves operation order" true
    (String.starts_with ~prefix:"(governance-assessment-v0(governance-v0, low" first
    && String.contains first 'h')

let test_script_exhaustion_fails_closed () =
  let one = assessment () in
  let body =
    Printf.sprintf
      "(app (var judge.scripted) (lam () (let nonrec (pwild) (app (var assess) %s) (app (var \
       assess) %s))) %s)"
      call call (list [ one ])
  in
  Alcotest.(check string)
    "exhaustion does not resume" "\"judge.scripted: out of assessments\"" (caught body)

let test_malformed_assessment_refusals () =
  let malformed =
    assessment ~confidence:"(app (var real.div) (lit 0.0) (lit 0.0))" ~reasons:[ "bad" ] ()
  in
  let cases =
    [
      ("fixed", Printf.sprintf "(app (var judge.fixed) (lam () (lit 1)) %s)" malformed);
      ( "rules",
        Printf.sprintf "(app (var judge.rules) (lam () (app (var assess) %s)) (lam ((pwild)) %s))"
          call malformed );
      ( "scripted",
        Printf.sprintf "(app (var judge.scripted) (lam () (app (var assess) %s)) %s)" call
          (list [ malformed ]) );
    ]
  in
  List.iter
    (fun (label, body) ->
      Alcotest.(check string)
        (label ^ " rejects malformed confidence")
        "\"invalid Assessment: confidence must be finite in [0,1]\"" (caught body))
    cases

let test_assessment_field_types_are_checked () =
  let variants =
    [
      ( "risk",
        "(app (var governance-assessment-v0) (var governance-v0) (lit \"low\") (lit 0.5) (var nil) \
         (quote (evidence)))" );
      ( "reasons",
        "(app (var governance-assessment-v0) (var governance-v0) (var low) (lit 0.5) (lit \
         \"not-a-list\") (quote (evidence)))" );
      ( "evidence",
        "(app (var governance-assessment-v0) (var governance-v0) (var low) (lit 0.5) (var nil) \
         (lit \"not-code\"))" );
    ]
  in
  List.iter
    (fun (label, expression) ->
      match check_expr expression with
      | Error diagnostics ->
          Alcotest.(check bool)
            (label ^ " is rejected before handling")
            true
            (List.exists
               (fun diagnostic ->
                 String.equal diagnostic.Diag.code "E0801"
                 || String.equal diagnostic.Diag.code "E0802")
               diagnostics)
      | Ok _ -> Alcotest.failf "malformed Assessment %s field typechecked" label)
    variants

let test_model_exposes_infer_and_replays () =
  let model_assessment confidence =
    Printf.sprintf
      "(app (var governance-assessment-v0) (var governance-v0) (var high) %s (app (var cons) (var \
       reason) (var nil)) (quote (model-evidence)))"
      confidence
  in
  let model =
    Printf.sprintf
      "(lam ((pwild)) (let nonrec (pvar reason) (app (var complete) (app (var mk-prompt) (lit \
       \"assess\") (var none))) (match (app (var text.eq?) (var reason) (lit \"invalid\")) (clause \
       (pcon true) %s) (clause (pcon false) %s))))"
      (model_assessment "(app (var real.div) (lit 0.0) (lit 0.0))")
      (model_assessment "(lit 0.8)")
  in
  let body =
    Printf.sprintf "(app (var judge.model) (lam () (app (var assess) %s)) %s)" call model
  in
  let run completion =
    show
      (Printf.sprintf "(app (var infer.scripted) (lam () %s) %s)" body
         (list [ "(lit " ^ qtext completion ^ ")" ]))
  in
  let first = run "model-a" in
  let second = run "model-b" in
  let expected completion =
    show
      (assessment ~risk:"high" ~confidence:"(lit 0.8)" ~reasons:[ completion ]
         ~evidence:"(quote (model-evidence))" ())
  in
  Alcotest.(check string)
    "first scripted completion becomes the assessment reason" (expected "model-a") first;
  Alcotest.(check string)
    "second scripted completion becomes the assessment reason" (expected "model-b") second;
  Alcotest.(check bool)
    "distinct completions produce distinct assessments" false (String.equal first second);
  Alcotest.(check string)
    "model adapter is deterministic under scripted Infer" first (run "model-a");
  let invalid =
    Printf.sprintf
      "(app (var infer.scripted) (lam () (app (var throw.catch) (lam () %s) (lam ((pvar message)) \
       (var message)))) %s)"
      body (list [ "(lit \"invalid\")" ])
  in
  Alcotest.(check string)
    "malformed model assessment is refused through the same adapter"
    "\"invalid Assessment: confidence must be finite in [0,1]\"" (show invalid)

let test_raw_world_rule_is_rejected () =
  let raw_rule =
    Printf.sprintf
      "(app (var judge.rules) (lam () (app (var assess) %s)) (lam ((pwild)) (let nonrec (pwild) \
       (app (var fetch) (app (var mk-request) (lit \"https://example.invalid\") (lit \"\"))) %s)))"
      call (assessment ())
  in
  match check_expr raw_rule with
  | Error diagnostics ->
      Alcotest.(check bool)
        "pure rules cannot hide Net" true
        (List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0802") diagnostics
        || List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0801") diagnostics)
  | Ok _ -> Alcotest.fail "judge.rules accepted a raw-world rule behind its pure signature"

let suite =
  [
    Alcotest.test_case "released identity and once mode" `Quick test_released_identity_and_once_mode;
    Alcotest.test_case "exact outward rows" `Quick test_exact_handler_rows;
    Alcotest.test_case "fixed replay" `Quick test_fixed_replay_is_exact;
    Alcotest.test_case "rules and scripted replay" `Quick test_rules_and_scripted_order;
    Alcotest.test_case "script exhaustion" `Quick test_script_exhaustion_fails_closed;
    Alcotest.test_case "malformed assessment refusal" `Quick test_malformed_assessment_refusals;
    Alcotest.test_case "assessment field types" `Quick test_assessment_field_types_are_checked;
    Alcotest.test_case "model Infer exposure" `Quick test_model_exposes_infer_and_replays;
    Alcotest.test_case "raw world rule refusal" `Quick test_raw_world_rule_is_rejected;
  ]
