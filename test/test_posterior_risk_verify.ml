open Jacquard

let store, ctx = Eval_support.make_prelude_ctx ()

let builtin_signatures =
  match Prelude.builtin_signatures store with
  | Ok signatures -> signatures
  | Error diagnostics -> Eval_support.fail_diags "posterior verifier builtins" diagnostics

let eval source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "posterior verifier evaluation failed: %s\nsource: %s"
        (Runtime_err.to_string error) source

let qtext value = "\"" ^ Printer.escape_text value ^ "\""

let hash_value hash =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (var parsed)))"
    (qtext (Hash.to_hex hash))

let unwrap_ok expression =
  Printf.sprintf
    "(match %s (clause (pcon ok (pvar value)) (var value)) (clause (pcon err (pvar message)) (var \
     message)))"
    expression

let call_source =
  unwrap_ok
    (Printf.sprintf
       "(app (var governance.make-call) (lit %s) (quote (arguments (lit \"report.txt\"))) (var \
        nil) (lit \"read the release report\") (quote (preconditions (lit \"reviewed\"))) (var \
        none))"
       (qtext "workspace.read-file"))

let baseline_source =
  "(app (var governance-assessment-v0) (var governance-v0) (var low) (lit 0.91) (app (var cons) \
   (lit \"baseline reason\") (var nil)) (quote (baseline-evidence-v1 (lit \"deterministic \
   rules\"))))"

let model_id =
  let body =
    "(app (var sample) (app (var categorical) (app (var cons) (app (var mk-pair) (var low) (lit \
     0.6)) (app (var cons) (app (var mk-pair) (var high) (lit 0.4)) (var nil)))))"
  in
  let hashes =
    Eval_support.put_src store (Store.names_view store)
      (Printf.sprintf
         "(defterm ((binding posterior-verify-test.model ((tarrow ((tref governance-call)) (row \
          (eref dist)) (tref risk))) (lam ((pwild)) %s))))"
         body)
  in
  List.assoc "posterior-verify-test.model" hashes.Canon.named

let call = eval call_source
let baseline = eval baseline_source

let model_ref =
  eval (Printf.sprintf "(app (var posterior-risk-model-ref-v1) %s)" (hash_value model_id))

let config = eval "(app (var posterior-exact-config-v1) (lit 8))"
let source_evidence = eval "(quote (source-evidence-v1 (lit \"fixture\")))"
let rule = eval "(var posterior-worst-case-v1)"

let replay ?(evidence = source_evidence) ?(exact_config = config) () =
  Posterior_risk_verify.
    { model_ref; config = exact_config; source_evidence = evidence; call; baseline; rule }

let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]
let int value = Form.form "lit" [ Form.Int value ]
let real value = Form.form "lit" [ Form.Real value ]
let version = form "governance-v0" []
let code_hash value = Hash.of_string (Printer.print_compact value)

type call_artifact = { call_id : Hash.t; form : Form.t }

let call_artifact =
  match call with
  | Value.VCon
      {
        name = "governance-call-v0";
        args =
          [
            _version;
            Value.VHash call_id;
            Value.VHash operation_id;
            Value.VText operation_name;
            Value.VCode arguments;
            Value.VCon { name = "nil"; args = []; _ };
            Value.VText summary;
            Value.VCode preconditions;
            Value.VCon { name = "none"; args = []; _ };
          ];
        _;
      } ->
      {
        call_id;
        form =
          form "governance-call-artifact-v1"
            [
              version;
              hash_form call_id;
              hash_form operation_id;
              lit operation_name;
              arguments;
              form "governance-authority-list-v0" [];
              lit summary;
              preconditions;
              form "none-v0" [];
            ];
      }
  | value -> Alcotest.failf "unexpected Governance Call fixture: %s" (Value.show value)

type policy_artifact = { policy_id : Hash.t; form : Form.t }

let policy_artifact value =
  let policy_id = code_hash value in
  { policy_id; form = form "bound-policy-artifact-v1" [ version; hash_form policy_id; value ] }

let live_policy =
  policy_artifact (form "live-policy-v0" [ version; form "high" []; form "high" []; real 0.8 ])

let dry_policy = policy_artifact (form "dry-policy-v0" [ version; real 0.8 ])

let replayed_assessment () =
  match
    Posterior_risk.replay_exact ctx ~builtin_signatures ~model_ref ~config ~source_evidence ~call
      ~baseline ~rule
  with
  | Ok replayed -> replayed.Posterior_risk.assessment_code
  | Error message -> Alcotest.failf "cannot prepare posterior verifier fixture: %s" message

let evaluated sequence policy assessment verdict =
  form "audit-entry-v2"
    [
      form "evaluated-v2"
        [
          version;
          int sequence;
          hash_form call_artifact.call_id;
          hash_form policy.policy_id;
          assessment;
          form verdict [];
        ];
    ]

let record_form record =
  match Reader.parse_one ~file:"posterior-verifier-audit-record" (Audit_chain.render record) with
  | Ok value -> value
  | Error diagnostics -> Eval_support.fail_diags "parse posterior verifier Audit record" diagnostics

let chain entries =
  let rec loop previous reversed = function
    | [] -> (List.rev reversed, previous)
    | entry :: rest -> (
        match Audit_chain.append ~previous entry with
        | Ok record -> loop (Audit_chain.head record) (record_form record :: reversed) rest
        | Error diagnostics -> Eval_support.fail_diags "build posterior verifier Audit" diagnostics)
  in
  loop Audit_chain.genesis [] entries

let bundle ?(policy = live_policy) ?(verdict = "allow") ?assessment ?(evaluations = 1) () =
  let assessment = Option.value ~default:(replayed_assessment ()) assessment in
  let entries =
    List.init evaluations (fun sequence -> evaluated sequence policy assessment verdict)
  in
  let records, head = chain entries in
  form "governance-run-bundle-v1"
    [
      Form.form "published-head-v1" [ Form.Hash head ];
      form "audit-records-v1" records;
      form "governance-call-artifacts-v1" [ call_artifact.form ];
      form "bound-policy-artifacts-v1" [ policy.form ];
      form "governance-assessment-artifacts-v1" [ assessment ];
      form "governance-proposal-artifacts-v1" [];
    ]

let verify ?(replay = replay ()) value =
  Posterior_risk_verify.verify_form ~ctx ~builtin_signatures ~file:"posterior.bundle" ~replay value

let expect_error label code = function
  | Error (diagnostic :: _) -> Alcotest.(check string) label code (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned no diagnostics" label
  | Ok _ -> Alcotest.failf "%s unexpectedly verified" label

let test_valid_exact_replay () =
  match verify (bundle ()) with
  | Error diagnostics -> Eval_support.fail_diags "valid posterior-aware bundle" diagnostics
  | Ok report ->
      Alcotest.(check int) "v0 bundle still verified first" 1 report.governance.entries;
      Alcotest.(check int) "unique Evaluated entry" 0 report.entry_index;
      Alcotest.(check bool)
        "Call identity linked" true
        (Hash.equal call_artifact.call_id report.call_id);
      Alcotest.(check bool)
        "policy identity linked" true
        (Hash.equal live_policy.policy_id report.policy_id);
      Alcotest.(check bool)
        "recomputed live verdict" true
        (report.verdict = Posterior_risk_verify.Allow)

let test_committed_assessment_drift () =
  let assessment = replayed_assessment () in
  let drifted =
    match assessment with
    | {
     Form.head = "governance-assessment-v0";
     args = [ version; risk; _confidence; reasons; evidence ];
     _;
    } ->
        Form.form "governance-assessment-v0" [ version; risk; Form.F (real 0.9); reasons; evidence ]
    | _ -> Alcotest.fail "unexpected replayed assessment fixture"
  in
  let candidate = bundle ~assessment:drifted () in
  (match Governance_run_bundle.verify_form ~store ~file:"drifted-v0.bundle" candidate with
  | Ok _ -> ()
  | Error diagnostics ->
      Eval_support.fail_diags "v0 accepts internally linked drift fixture" diagnostics);
  expect_error "assessment drift" "E1549" (verify candidate)

let test_verdict_drift () =
  let candidate = bundle ~verdict:"ask" () in
  (match Governance_run_bundle.verify_form ~store ~file:"verdict-v0.bundle" candidate with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "v0 accepts linked verdict fixture" diagnostics);
  expect_error "verdict drift" "E1549" (verify candidate)

let test_evidence_and_config_drift () =
  let changed_evidence = eval "(quote (source-evidence-v1 (lit \"changed\")))" in
  expect_error "source-evidence drift" "E1549"
    (verify ~replay:(replay ~evidence:changed_evidence ()) (bundle ()));
  let exhausted_config = eval "(app (var posterior-exact-config-v1) (lit 1))" in
  expect_error "exact budget drift" "E1549"
    (verify ~replay:(replay ~exact_config:exhausted_config ()) (bundle ()))

let test_ambiguous_and_dry_policy_fail_closed () =
  expect_error "ambiguous evaluations" "E1548" (verify (bundle ~evaluations:2 ()));
  let dry_candidate = bundle ~policy:dry_policy ~verdict:"simulate" () in
  (match Governance_run_bundle.verify_form ~store ~file:"dry-v0.bundle" dry_candidate with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "v0 dry fixture" diagnostics);
  expect_error "dry policy unsupported" "E1548" (verify dry_candidate)

let suite =
  [
    Alcotest.test_case "valid exact replay" `Quick test_valid_exact_replay;
    Alcotest.test_case "committed assessment drift" `Quick test_committed_assessment_drift;
    Alcotest.test_case "committed verdict drift" `Quick test_verdict_drift;
    Alcotest.test_case "evidence and configuration drift" `Quick test_evidence_and_config_drift;
    Alcotest.test_case "ambiguous and dry policy" `Quick test_ambiguous_and_dry_policy_fail_closed;
  ]
