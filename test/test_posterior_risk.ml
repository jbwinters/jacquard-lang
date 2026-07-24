open Jacquard

(* GM.21: exact posterior evidence may only tighten an independently produced v0 assessment.
   Seeded inference remains a distinct non-authorizing evidence type. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "posterior-risk evaluation failed: %s\nsource: %s"
        (Runtime_err.to_string error) source

let qtext value = "\"" ^ Printer.escape_text value ^ "\""

let hash_value hash =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (var parsed)))"
    (qtext (Hash.to_hex hash))

let list values =
  List.fold_right
    (fun value tail -> Printf.sprintf "(app (var cons) %s %s)" value tail)
    values "(var nil)"

let unwrap_ok expression =
  Printf.sprintf
    "(match %s (clause (pcon ok (pvar value)) (var value)) (clause (pcon err (pvar message)) (var \
     message)))"
    expression

let call =
  unwrap_ok
    (Printf.sprintf
       "(app (var governance.make-call) (lit %s) (quote (arguments (lit \"report.txt\"))) (var \
        nil) (lit \"read the release report\") (quote (preconditions (lit \"reviewed\"))) (var \
        none))"
       (qtext "workspace.read-file"))

let baseline ?(risk = "medium") () =
  Printf.sprintf
    "(app (var governance-assessment-v0) (var governance-v0) (var %s) (lit 0.91) %s (quote \
     (baseline-evidence-v1 (lit \"deterministic rules\"))))"
    risk
    (list [ "(lit \"baseline reason\")" ])

let categorical entries =
  let pairs =
    List.map
      (fun (risk, weight) -> Printf.sprintf "(app (var mk-pair) (var %s) (lit %s))" risk weight)
      entries
  in
  Printf.sprintf "(app (var categorical) %s)" (list pairs)

let define_model name ~row body =
  let hashes =
    Eval_support.put_src store (Store.names_view store)
      (Printf.sprintf
         "(defterm ((binding %s ((tarrow ((tref governance-call)) %s (tref risk))) (lam ((pwild)) \
          %s))))"
         name row body)
  in
  List.assoc name hashes.Canon.named

let low_model =
  define_model "posterior-test.low-model" ~row:"(row (eref dist))"
    "(app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var low) (lit \
     1.0)) (var nil))))"

let medium_model =
  define_model "posterior-test.medium-model" ~row:"(row (eref dist))"
    "(app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var medium) (lit \
     1.0)) (var nil))))"

let high_model =
  define_model "posterior-test.high-model" ~row:"(row (eref dist))"
    "(app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var high) (lit \
     1.0)) (var nil))))"

let forbidden_point_model =
  define_model "posterior-test.forbidden-point-model" ~row:"(row (eref dist))"
    "(app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var forbidden) \
     (lit 1.0)) (var nil))))"

let mixed_model =
  define_model "posterior-test.mixed-model" ~row:"(row (eref dist))"
    (Printf.sprintf "(app (var sample) %s)" (categorical [ ("low", "0.6"); ("high", "0.4") ]))

let equivalent_mixed_model =
  define_model "posterior-test.equivalent-mixed-model" ~row:"(row (eref dist))"
    (Printf.sprintf "(app (var sample) %s)"
       (categorical [ ("low", "0.2"); ("low", "0.4"); ("high", "0.4") ]))

let forbidden_model =
  define_model "posterior-test.forbidden-model" ~row:"(row (eref dist))"
    (Printf.sprintf "(app (var sample) %s)"
       (categorical [ ("low", "1.0"); ("forbidden", "2.220446049250313e-16") ]))

let wrong_signature_model = define_model "posterior-test.wrong-signature" ~row:"(row)" "(var low)"

let model_ref model_id =
  Printf.sprintf "(app (var posterior-risk-model-ref-v1) %s)" (hash_value model_id)

let exact_config branches = Printf.sprintf "(app (var posterior-exact-config-v1) (lit %d))" branches

let approximate_config ~samples ~seed =
  Printf.sprintf "(app (var posterior-approximate-config-v1) (lit %d) (lit %d))" samples seed

let exact_run ?(evidence = "(quote (source-evidence-v1 (lit \"fixture\")))") ?(branches = 8)
    model_id =
  Printf.sprintf "(app (var posterior.run-exact-v1) %s %s %s %s)" (model_ref model_id)
    (exact_config branches) evidence call

let project ?(baseline = baseline ()) ?(rule = "(var posterior-worst-case-v1)") model_id =
  Printf.sprintf
    "(match %s (clause (pcon err (pvar message)) (app (var err) (var message))) (clause (pcon ok \
     (pvar exact)) (app (var posterior.project-exact-v1) %s %s (var exact) %s)))"
    (exact_run model_id) call baseline rule

let projected_assessment = function
  | Value.VCon
      {
        name = "ok";
        args =
          [
            Value.VCon
              { name = "posterior-projected-assessment-v1"; args = [ assessment; projection ]; _ };
          ];
        _;
      } ->
      (assessment, projection)
  | value -> Alcotest.failf "expected projected assessment, got %s" (Value.show value)

let assessment_fields = function
  | Value.VCon
      {
        name = "governance-assessment-v0";
        args = [ _version; Value.VCon { name = risk; args = []; _ }; confidence; reasons; evidence ];
        _;
      } ->
      (risk, confidence, reasons, evidence)
  | value -> Alcotest.failf "expected GovernanceAssessmentV0, got %s" (Value.show value)

let test_conservative_join_and_preservation () =
  let assessment, _ = projected_assessment (eval (project low_model)) in
  let risk, confidence, reasons, evidence = assessment_fields assessment in
  Alcotest.(check string) "posterior Low cannot lower baseline Medium" "medium" risk;
  Alcotest.(check string) "confidence preserved byte-for-byte" "0.91" (Value.show confidence);
  Alcotest.(check string)
    "reasons preserved byte-for-byte" "cons(\"baseline reason\", nil)" (Value.show reasons);
  match evidence with
  | Value.VCode { Form.head = "posterior-risk-evidence-v1"; args; _ } ->
      Alcotest.(check int)
        "self-contained evidence has baseline, exact result, projection" 3 (List.length args)
  | value -> Alcotest.failf "expected posterior evidence Code, got %s" (Value.show value)

let test_exhaustive_monotone_join_and_unchanged_live_verdict () =
  let risks = [| "low"; "medium"; "high"; "forbidden" |] in
  let models = [| low_model; medium_model; high_model; forbidden_point_model |] in
  let expected_verdict = [| "allow"; "allow"; "ask"; "block" |] in
  let policy =
    "(match (app (var governance.make-live-policy) (var medium) (var high) (lit 0.75)) (clause \
     (pcon ok (pvar policy)) (var policy)))"
  in
  Array.iteri
    (fun baseline_rank baseline_risk ->
      Array.iteri
        (fun posterior_rank model ->
          let expected_rank = max baseline_rank posterior_rank in
          let assessment, _ =
            projected_assessment (eval (project ~baseline:(baseline ~risk:baseline_risk ()) model))
          in
          let actual_risk, confidence, reasons, _ = assessment_fields assessment in
          let label = Printf.sprintf "%s + %s" baseline_risk risks.(posterior_rank) in
          Alcotest.(check string) (label ^ " is the lattice join") risks.(expected_rank) actual_risk;
          Alcotest.(check string) (label ^ " preserves confidence") "0.91" (Value.show confidence);
          Alcotest.(check string)
            (label ^ " preserves reasons") "cons(\"baseline reason\", nil)" (Value.show reasons);
          let verdict =
            eval
              (Printf.sprintf "(app (var governance.live-verdict) %s (var %s) (lit 0.91))" policy
                 actual_risk)
          in
          Alcotest.(check string)
            (label ^ " uses the unchanged live-policy verdict")
            expected_verdict.(expected_rank) (Value.show verdict))
        models)
    risks

let test_low_confidence_and_higher_risk_never_auto_allow () =
  let low_confidence_baseline =
    "(app (var governance-assessment-v0) (var governance-v0) (var low) (lit 0.5) (app (var cons) \
     (lit \"baseline reason\") (var nil)) (quote (baseline-evidence-v1)))"
  in
  let assessment, _ =
    projected_assessment (eval (project ~baseline:low_confidence_baseline mixed_model))
  in
  let risk, confidence, _, _ = assessment_fields assessment in
  Alcotest.(check string) "higher-risk mass raises effective risk" "high" risk;
  Alcotest.(check string) "low baseline confidence remains visible" "0.5" (Value.show confidence);
  let policy =
    "(match (app (var governance.make-live-policy) (var low) (var high) (lit 0.75)) (clause (pcon \
     ok (pvar policy)) (var policy)))"
  in
  Alcotest.(check string)
    "unchanged live policy asks instead of auto-allowing" "ask"
    (Value.show
       (eval (Printf.sprintf "(app (var governance.live-verdict) %s (var high) (lit 0.5))" policy)))

let test_tiny_forbidden_mass_is_non_discardable () =
  let assessment, _ = projected_assessment (eval (project forbidden_model)) in
  let risk, _, _, _ = assessment_fields assessment in
  Alcotest.(check string) "any positive Forbidden mass wins WorstCase" "forbidden" risk

let test_upper_tail_exact_boundary () =
  let at_boundary =
    project ~baseline:(baseline ~risk:"low" ())
      ~rule:"(app (var posterior-upper-tail-v1) (lit 0.4))" mixed_model
  in
  let below_boundary =
    project ~baseline:(baseline ~risk:"low" ())
      ~rule:"(app (var posterior-upper-tail-v1) (lit 0.39999999999999997))" mixed_model
  in
  let at_risk, _, _, _ = assessment_fields (fst (projected_assessment (eval at_boundary))) in
  let below_risk, _, _, _ = assessment_fields (fst (projected_assessment (eval below_boundary))) in
  Alcotest.(check string) "UpperTail accepts exact equality" "low" at_risk;
  Alcotest.(check string) "adjacent lower tolerance raises risk" "high" below_risk

let test_handler_forwards_to_independent_baseline () =
  let expression =
    Printf.sprintf
      "(app (var judge.fixed) (lam () (app (var judge.posterior-exact-v1) (lam () (app (var \
       assess) %s)) %s %s (quote (source-evidence-v1 (lit \"handler\"))) (var \
       posterior-worst-case-v1))) %s)"
      call (model_ref mixed_model) (exact_config 8) (baseline ~risk:"low" ())
  in
  let risk, _, _, _ = assessment_fields (eval expression) in
  Alcotest.(check string) "outer Judge baseline is tightened by exact posterior" "high" risk

let exact_result = function
  | Value.VCon { name = "ok"; args = [ exact ]; _ } -> exact
  | value -> Alcotest.failf "expected exact posterior result, got %s" (Value.show value)

let exact_id = function
  | Value.VCon { name = "posterior-exact-result-v1"; args = Value.VHash id :: _; _ } -> id
  | value -> Alcotest.failf "expected exact result carrier, got %s" (Value.show value)

let test_exact_identity_is_deterministic_and_input_bound () =
  let first = exact_result (eval (exact_run mixed_model)) in
  let second = exact_result (eval (exact_run mixed_model)) in
  Alcotest.(check string)
    "same exact inputs are byte-identical" (Value.show first) (Value.show second);
  let changed =
    exact_result
      (eval (exact_run ~evidence:"(quote (source-evidence-v1 (lit \"changed\")))" mixed_model))
  in
  Alcotest.(check bool)
    "source evidence changes posterior identity" false
    (Hash.equal (exact_id first) (exact_id changed))

let exact_semantics_id = function
  | Value.VCon { name = "posterior-exact-result-v1"; args = _ :: _ :: _ :: Value.VHash id :: _; _ }
    ->
      id
  | value -> Alcotest.failf "expected exact result carrier, got %s" (Value.show value)

let error_text = function
  | Value.VCon { name = "err"; args = [ Value.VText message ]; _ } -> message
  | value -> Alcotest.failf "expected language error, got %s" (Value.show value)

let test_fail_closed_boundaries () =
  let budget_error = error_text (eval (exact_run ~branches:1 mixed_model)) in
  Alcotest.(check bool)
    "branch budget returns no partial posterior" true
    (String.starts_with ~prefix:"E1544:" budget_error);
  let signature_error = error_text (eval (exact_run wrong_signature_model)) in
  Alcotest.(check string)
    "wrong model signature rejected exactly"
    "E1543: model must have the closed signature (GovernanceCall) ->{Dist} Risk" signature_error

let test_handler_failure_does_not_resume_continuation () =
  let expression =
    Printf.sprintf
      "(app (var state.run) (lam () (app (var throw.catch) (lam () (app (var judge.fixed) (lam () \
       (app (var judge.posterior-exact-v1) (lam () (let nonrec (pwild) (app (var assess) %s) (let \
       nonrec (pwild) (app (var put) (lit 1)) (lit \"resumed\")))) %s %s (quote \
       (source-evidence-v1 (lit \"budget failure\"))) (var posterior-worst-case-v1))) %s)) (lam \
       ((pvar message)) (var message)))) (lit 0))"
      call (model_ref mixed_model) (exact_config 1) (baseline ~risk:"low" ())
  in
  match eval expression with
  | Value.VTuple [ Value.VText message; Value.VInt state ] ->
      Alcotest.(check bool)
        "exact failure is reported before continuation resume" true
        (String.starts_with ~prefix:"E1544:" message);
      Alcotest.(check int) "continuation-owned state action did not run" 0 state
  | value ->
      Alcotest.failf "expected caught exact failure and unchanged state, got %s" (Value.show value)

let sample_run model_id =
  Printf.sprintf
    "(app (var posterior.sample-evidence-v1) %s %s (quote (source-evidence-v1 (lit \"sampled\"))) \
     %s)"
    (model_ref model_id)
    (approximate_config ~samples:64 ~seed:42)
    call

let checker () =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make posterior checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register posterior builtins" diagnostics);
  checker

let check_expression source =
  match Reader.parse_one ~file:"posterior-risk-type-boundary.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top (checker ()) (Kernel.Expr expression)))

let test_approximate_evidence_is_reproducible_but_non_authorizing () =
  let first = eval (sample_run mixed_model) in
  let second = eval (sample_run mixed_model) in
  Alcotest.(check string) "same seed is byte-identical" (Value.show first) (Value.show second);
  let approximate_semantics_id =
    match first with
    | Value.VCon
        {
          name = "ok";
          args =
            [
              Value.VCon
                {
                  name = "non-authorizing-approximate-risk-evidence-v1";
                  args = _ :: _ :: _ :: Value.VHash id :: _;
                  _;
                };
            ];
          _;
        } ->
        id
    | value -> Alcotest.failf "expected approximate evidence, got %s" (Value.show value)
  in
  let exact = exact_result (eval (exact_run mixed_model)) in
  Alcotest.(check bool)
    "same model visibly names different exact and approximate semantics" false
    (Hash.equal (exact_semantics_id exact) approximate_semantics_id);
  let attempted_projection =
    Printf.sprintf
      "(match %s (clause (pcon err (pvar message)) (app (var err) (var message))) (clause (pcon ok \
       (pvar approximate)) (app (var posterior.project-exact-v1) %s %s (var approximate) (var \
       posterior-worst-case-v1))))"
      (sample_run mixed_model) call (baseline ())
  in
  match check_expression attempted_projection with
  | Error diagnostics ->
      Alcotest.(check bool)
        "approximate carrier cannot inhabit exact projector input" true
        (List.exists (fun diagnostic -> Diag.code_or_uncoded diagnostic = "E0801") diagnostics)
  | Ok _ -> Alcotest.fail "approximate evidence unexpectedly typechecked as exact evidence"

let test_semantics_descriptor_and_replay () =
  let language_descriptor = eval "(var posterior.exact-semantics-v1)" in
  (match language_descriptor with
  | Value.VCode descriptor ->
      Alcotest.(check bool)
        "language and trusted runtime freeze the same exact semantics descriptor" true
        (Form.equal_ignoring_meta Posterior_risk.exact_semantics_code descriptor)
  | value -> Alcotest.failf "expected exact semantics Code, got %s" (Value.show value));
  let language_semantics_id =
    match eval "(app (var code.hash) (var posterior.exact-semantics-v1))" with
    | Value.VHash hash -> hash
    | value -> Alcotest.failf "expected exact semantics hash, got %s" (Value.show value)
  in
  let exact = exact_result (eval (exact_run mixed_model)) in
  Alcotest.(check bool)
    "language HASH_V0 and exact result carry the same handler identity" true
    (Hash.equal language_semantics_id (exact_semantics_id exact));
  let successful_replay =
    Printf.sprintf
      "(match %s (clause (pcon err (pvar message)) (app (var err) (var message))) (clause (pcon ok \
       (pcon posterior-projected-assessment-v1 (pvar expected) (pwild))) (app (var \
       posterior.replay-exact-v1) %s %s (quote (source-evidence-v1 (lit \"fixture\"))) %s %s (var \
       posterior-worst-case-v1) (var expected))))"
      (project mixed_model) (model_ref mixed_model) (exact_config 8) call (baseline ())
  in
  (match eval successful_replay with
  | Value.VCon { name = "ok"; args = [ _ ]; _ } -> ()
  | value -> Alcotest.failf "exact replay failed: %s" (Value.show value));
  let mismatched_replay =
    Printf.sprintf
      "(app (var posterior.replay-exact-v1) %s %s (quote (source-evidence-v1 (lit \"fixture\"))) \
       %s %s (var posterior-worst-case-v1) %s)"
      (model_ref mixed_model) (exact_config 8) call (baseline ()) (baseline ~risk:"low" ())
  in
  Alcotest.(check string)
    "replay rejects a different expected assessment" "posterior replay assessment identity mismatch"
    (error_text (eval mismatched_replay))

let test_posterior_and_same_dist_laws () =
  let risk_eq =
    "(lam ((pvar left) (pvar right)) (match (tuple (var left) (var right)) (clause (ptuple (pcon \
     low) (pcon low)) (var true)) (clause (ptuple (pcon medium) (pcon medium)) (var true)) (clause \
     (ptuple (pcon high) (pcon high)) (var true)) (clause (ptuple (pcon forbidden) (pcon \
     forbidden)) (var true)) (clause (pwild) (var false))))"
  in
  let expected =
    list [ "(app (var mk-pair) (var low) (lit 0.6))"; "(app (var mk-pair) (var high) (lit 0.4))" ]
  in
  let posterior =
    Printf.sprintf
      "(app (var test.run) (lam () (app (var check.posterior) (lam () (app (var \
       posterior-test.mixed-model) %s)) %s (app (var mk-eq) %s) (app (var mk-show) (var \
       governance.risk-show)) (lit 0.000000000001))))"
      call expected risk_eq
  in
  let same_dist =
    Printf.sprintf
      "(app (var test.run) (lam () (app (var check.same-dist) (lam () (app (var \
       posterior-test.mixed-model) %s)) (lam () (app (var posterior-test.equivalent-mixed-model) \
       %s)) (app (var mk-eq) %s) (app (var mk-show) (var governance.risk-show)) (lit \
       0.000000000001))))"
      call call risk_eq
  in
  let has text fragment =
    let rec loop offset =
      offset + String.length fragment <= String.length text
      && (String.sub text offset (String.length fragment) = fragment || loop (offset + 1))
    in
    loop 0
  in
  let all_passed value =
    let shown = Value.show value in
    has shown "mk-report(" && not (has shown "false")
  in
  Alcotest.(check bool) "hand-derived posterior law passes" true (all_passed (eval posterior));
  Alcotest.(check bool)
    "equivalent risk models satisfy same-dist" true
    (all_passed (eval same_dist))

let contains text fragment =
  let rec loop offset =
    offset + String.length fragment <= String.length text
    && (String.sub text offset (String.length fragment) = fragment || loop (offset + 1))
  in
  loop 0

let test_existing_gate_records_effective_posterior_assessment () =
  let gate =
    Printf.sprintf
      "(match (app (var governance.make-dry-policy) (lit 0.5)) (clause (pcon err (pvar message)) \
       (var message)) (clause (pcon ok (pvar raw-policy)) (match (app (var \
       governance.bind-dry-policy) (var raw-policy)) (clause (pcon err (pvar message)) (var \
       message)) (clause (pcon ok (pvar policy)) (app (var judge.fixed) (lam () (app (var \
       judge.posterior-exact-v1) (lam () (app (var audit.in-memory) (lam () (app (var \
       governance.with-sequence) (lam ((pvar sequence)) (app (var governance.gate-dry) (var \
       sequence) (var policy) %s (app (var some) (lam () (app (var ok) (lit \"simulated\")))) (lam \
       ((pwild)) (app (var governance-outcome-summary-v0) (var governance-v0) (lit \"simulated\") \
       (app (var governance.call-id) %s) (lit \"posterior gate evidence\"))))))))) %s %s (quote \
       (source-evidence-v1 (lit \"gate\"))) (var posterior-worst-case-v1))) %s)))))"
      call call (model_ref mixed_model) (exact_config 8) (baseline ~risk:"low" ())
  in
  let rendered = Value.show (eval gate) in
  Alcotest.(check bool)
    "unchanged gate Audit carries posterior evidence" true
    (contains rendered "posterior-risk-evidence-v1");
  Alcotest.(check bool)
    "unchanged gate records an Evaluated entry" true (contains rendered "evaluated(")

let test_exact_result_constructor_is_not_public () =
  let internal =
    match Store.lookup_internal_kind store "posterior-exact-result-v1" Resolve.KCon with
    | Some entry -> entry.Resolve.hash
    | None -> Alcotest.fail "trusted exact result constructor is unavailable"
  in
  Alcotest.(check bool)
    "exact result constructor is hidden from language resolution" true
    (Store.lookup_kind store "posterior-exact-result-v1" Resolve.KCon = None);
  Alcotest.(check bool)
    "trusted runtime can still construct the exact carrier" true
    (Option.is_some (Store.lookup_internal_kind store "posterior-exact-result-v1" Resolve.KCon));
  (match Store.locate store internal with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "exact result constructor remained addressable by its derived hash");
  match check_expression (Printf.sprintf "(ref #%s con)" (Hash.to_hex internal)) with
  | Error diagnostics ->
      Alcotest.(check bool)
        "direct exact constructor hash is rejected" true
        (List.exists (fun diagnostic -> Diag.code_or_uncoded diagnostic = "E0805") diagnostics)
  | Ok _ -> Alcotest.fail "exact result constructor direct hash unexpectedly typechecked"

let test_projector_rejects_forged_nested_constructor_identity () =
  let exact = exact_result (eval (exact_run mixed_model)) in
  let forged =
    match exact with
    | Value.VCon
        ({
           args =
             [
               posterior_id;
               call_id;
               model_id;
               semantics_id;
               config;
               config_hash;
               evidence;
               evidence_hash;
               Value.VCon ({ args = weights; _ } as weight_carrier);
               belief;
               support;
               branches;
             ];
           _;
         } as carrier) ->
        let forged_con =
          match Store.lookup_kind store "none" Resolve.KCon with
          | Some entry -> entry.Resolve.hash
          | None -> Alcotest.fail "released none constructor is unavailable"
        in
        Value.VCon
          {
            carrier with
            args =
              [
                posterior_id;
                call_id;
                model_id;
                semantics_id;
                config;
                config_hash;
                evidence;
                evidence_hash;
                Value.VCon { weight_carrier with con = forged_con; args = weights };
                belief;
                support;
                branches;
              ];
          }
    | value -> Alcotest.failf "expected exact result carrier, got %s" (Value.show value)
  in
  let result =
    match
      Posterior_risk.project_exact_builtin ctx
        [ eval call; eval (baseline ()); forged; eval "(var posterior-worst-case-v1)" ]
    with
    | Ok value -> value
    | Error error -> Alcotest.failf "projector runtime failure: %s" (Runtime_err.to_string error)
  in
  Alcotest.(check string)
    "display-name forgery cannot substitute a released constructor identity"
    "E1545: forged PosteriorRiskWeightsV1 constructor identity" (error_text result)

let test_projector_rejects_nested_posterior_wrapper () =
  let first_assessment, _ = projected_assessment (eval (project mixed_model)) in
  let exact = exact_result (eval (exact_run low_model)) in
  let result =
    match
      Posterior_risk.project_exact_builtin ctx
        [ eval call; first_assessment; exact; eval "(var posterior-worst-case-v1)" ]
    with
    | Ok value -> value
    | Error error -> Alcotest.failf "projector runtime failure: %s" (Runtime_err.to_string error)
  in
  Alcotest.(check string)
    "v1 refuses unreviewed multi-posterior composition"
    "E1546: v1 does not define composition of two posterior wrappers" (error_text result)

let suite =
  [
    Alcotest.test_case "conservative join and preservation" `Quick
      test_conservative_join_and_preservation;
    Alcotest.test_case "exhaustive monotone join and live verdict" `Quick
      test_exhaustive_monotone_join_and_unchanged_live_verdict;
    Alcotest.test_case "low confidence and higher risk" `Quick
      test_low_confidence_and_higher_risk_never_auto_allow;
    Alcotest.test_case "tiny Forbidden mass" `Quick test_tiny_forbidden_mass_is_non_discardable;
    Alcotest.test_case "UpperTail exact boundary" `Quick test_upper_tail_exact_boundary;
    Alcotest.test_case "Judge forwarding" `Quick test_handler_forwards_to_independent_baseline;
    Alcotest.test_case "exact identity binding" `Quick
      test_exact_identity_is_deterministic_and_input_bound;
    Alcotest.test_case "fail-closed boundaries" `Quick test_fail_closed_boundaries;
    Alcotest.test_case "handler failure before resume" `Quick
      test_handler_failure_does_not_resume_continuation;
    Alcotest.test_case "approximate evidence boundary" `Quick
      test_approximate_evidence_is_reproducible_but_non_authorizing;
    Alcotest.test_case "semantics descriptor and replay" `Quick test_semantics_descriptor_and_replay;
    Alcotest.test_case "posterior and same-dist laws" `Quick test_posterior_and_same_dist_laws;
    Alcotest.test_case "unchanged gate and Audit linkage" `Quick
      test_existing_gate_records_effective_posterior_assessment;
    Alcotest.test_case "exact carrier opacity" `Quick test_exact_result_constructor_is_not_public;
    Alcotest.test_case "nested constructor identity" `Quick
      test_projector_rejects_forged_nested_constructor_identity;
    Alcotest.test_case "nested posterior wrapper" `Quick
      test_projector_rejects_nested_posterior_wrapper;
  ]
