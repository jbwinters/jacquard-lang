open Jacquard

let store, _ctx = Eval_support.make_prelude_ctx ()
let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash seed = Hash.of_string ("gm14-test:" ^ seed)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]
let int value = Form.form "lit" [ Form.Int value ]
let real value = Form.form "lit" [ Form.Real value ]
let version = form "governance-v0" []
let none = form "none-v0" []
let some_hash value = form "some-v0" [ hash_form value ]
let code_hash value = Hash.of_string (Printer.print_compact value)

let authority seed =
  form "governance-authority-list-v0"
    [ form "governance-effect-v0" [ hash_form (hash (seed ^ ":effect")) ] ]

let workspace_write_id () =
  match Store.lookup_kind store "workspace.write-file" Resolve.KOp with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.fail "prelude has no resolved workspace.write-file operation"

type call = { id : Hash.t; artifact : Form.t; authority : Form.t }
type policy = { id : Hash.t; artifact : Form.t }
type assessment = { id : Hash.t; artifact : Form.t }
type proposal = { id : Hash.t; artifact : Form.t }

let make_call ?parent ?(authority = authority "workspace") seed : call =
  let operation_id = workspace_write_id () in
  let arguments = form "arguments-v1" [ lit seed ] in
  let preconditions = form "preconditions-v1" [ lit (seed ^ ":expected") ] in
  let parent = match parent with None -> none | Some id -> some_hash id in
  let subject =
    form "governance-call-v0"
      [ version; hash_form operation_id; arguments; authority; preconditions; parent ]
  in
  let id = code_hash subject in
  let artifact =
    form "governance-call-artifact-v1"
      [
        version;
        hash_form id;
        hash_form operation_id;
        lit "workspace.write-file";
        arguments;
        authority;
        lit ("write " ^ seed);
        preconditions;
        parent;
      ]
  in
  { id; artifact; authority }

let make_policy () : policy =
  let value = form "live-policy-v0" [ version; form "low" []; form "high" []; real 0.8 ] in
  let id = code_hash value in
  { id; artifact = form "bound-policy-artifact-v1" [ version; hash_form id; value ] }

let make_dry_policy () : policy =
  let value = form "dry-policy-v0" [ version; real 0.8 ] in
  let id = code_hash value in
  { id; artifact = form "bound-policy-artifact-v1" [ version; hash_form id; value ] }

let make_assessment () : assessment =
  let artifact =
    form "governance-assessment-v0"
      [
        version;
        form "medium" [];
        real 0.95;
        form "text-list-v1" [ lit "policy match" ];
        form "assessment-evidence-v1" [ lit "rules-v1" ];
      ]
  in
  { id = code_hash artifact; artifact }

let make_proposal (call : call) (policy : policy) (assessment : assessment) seed : proposal =
  let rendering = form "review-v1" [ lit seed ] in
  let summary = "approve " ^ seed in
  let subject =
    form "governance-proposal-v0"
      [
        version;
        hash_form call.id;
        hash_form policy.id;
        hash_form assessment.id;
        call.authority;
        none;
        rendering;
        lit summary;
      ]
  in
  let id = code_hash subject in
  {
    id;
    artifact =
      form "governance-proposal-artifact-v1"
        [
          version;
          hash_form id;
          hash_form call.id;
          hash_form policy.id;
          hash_form assessment.id;
          rendering;
          lit summary;
          call.authority;
          none;
        ];
  }

let evaluated sequence (call : call) (policy : policy) (assessment : assessment) verdict =
  form "audit-entry-v2"
    [
      form "evaluated-v2"
        [
          version;
          int sequence;
          hash_form call.id;
          hash_form policy.id;
          assessment.artifact;
          form verdict [];
        ];
    ]

let consented sequence (call : call) (proposal : proposal) =
  form "audit-entry-v2"
    [
      form "consented-v2"
        [
          version;
          int sequence;
          hash_form call.id;
          hash_form proposal.id;
          form "approved-v1"
            [ hash_form proposal.id; lit "principal:reviewer-1"; form "approval-proof-v1" [] ];
        ];
    ]

let completed ?(branch = "live") sequence (call : call) =
  let outcome =
    form "governance-outcome-summary-v0"
      [ version; lit "ok"; hash_form (hash "receipt"); lit "receipt stored by test driver" ]
  in
  form "audit-entry-v2"
    [ form "completed-v2" [ version; int sequence; hash_form call.id; lit branch; outcome ] ]

let record_form record =
  match Reader.parse_one ~file:"rendered-audit-record" (Audit_chain.render record) with
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "cannot parse rendered Audit record: %s"
        (String.concat "; " (List.map Diag.to_string diagnostics))

let chain entries =
  let rec loop previous reversed = function
    | [] -> (List.rev reversed, previous)
    | entry :: rest -> (
        match Audit_chain.append ~previous entry with
        | Ok record -> loop (Audit_chain.head record) (record_form record :: reversed) rest
        | Error diagnostics ->
            Alcotest.failf "cannot build Audit chain: %s"
              (String.concat "; " (List.map Diag.to_string diagnostics)))
  in
  loop Audit_chain.genesis [] entries

let run_bundle ~head ~records ~calls ~policies ~assessments ~proposals =
  form "governance-run-bundle-v1"
    [
      Form.form "published-head-v1" [ Form.Hash head ];
      form "audit-records-v1" records;
      form "governance-call-artifacts-v1" calls;
      form "bound-policy-artifacts-v1" policies;
      form "governance-assessment-artifacts-v1" assessments;
      form "governance-proposal-artifacts-v1" proposals;
    ]

type fixture = {
  root : call;
  child : call;
  policy : policy;
  assessment : assessment;
  proposal : proposal;
  records : Form.t list;
  head : Hash.t;
  bundle : Form.t;
}

let fixture () =
  let root = make_call "root" in
  let child = make_call ~parent:root.id "child" in
  let policy = make_policy () in
  let assessment = make_assessment () in
  let proposal = make_proposal child policy assessment "child" in
  let entries =
    [
      evaluated 0 root policy assessment "block";
      evaluated 1 child policy assessment "ask";
      consented 2 child proposal;
      completed 3 child;
    ]
  in
  let records, head = chain entries in
  let bundle =
    run_bundle ~head ~records ~calls:[ root.artifact; child.artifact ] ~policies:[ policy.artifact ]
      ~assessments:[ assessment.artifact ] ~proposals:[ proposal.artifact ]
  in
  { root; child; policy; assessment; proposal; records; head; bundle }

let record_digest = function
  | { Form.head = "audit-chain-v2"; args = [ Form.Hash _; Form.Hash digest; Form.F _ ]; _ } ->
      digest
  | _ -> Alcotest.fail "malformed test Audit record"

let outcome_of_entry = function
  | {
      Form.head = "audit-entry-v2";
      args =
        [
          Form.F
            {
              Form.head = "completed-v2";
              args = [ Form.F _; Form.F _; Form.F _; Form.F _; Form.F outcome ];
              _;
            };
        ];
      _;
    } ->
      outcome
  | _ -> Alcotest.fail "malformed test Completed entry"

let attempt sequence ~call ~authorization ~branch ~driver ~key =
  let attempt_id =
    Governance_reconcile.attempt_id ~call_id:call ~authorization ~branch ~driver_id:driver
      ~idempotency_key_digest:key
  in
  ( form "action-attempted-v1"
      [
        int sequence;
        hash_form attempt_id;
        hash_form call;
        hash_form authorization;
        lit branch;
        hash_form driver;
        hash_form key;
      ],
    attempt_id )

let receipt sequence ~attempt_id ~outcome ~external_digest =
  let receipt_id =
    Governance_reconcile.receipt_id ~attempt_id ~outcome ~external_receipt_digest:external_digest
  in
  form "action-receipt-v1"
    [ int sequence; hash_form receipt_id; hash_form attempt_id; outcome; hash_form external_digest ]

let journal entries =
  let rec loop previous reversed = function
    | [] -> (List.rev reversed, previous)
    | entry :: rest -> (
        match Governance_reconcile.append_journal ~previous ~entry with
        | Ok (record, head) -> loop head (record :: reversed) rest
        | Error diagnostics ->
            Alcotest.failf "cannot build action journal: %s"
              (String.concat "; " (List.map Diag.to_string diagnostics)))
  in
  loop Governance_reconcile.journal_genesis [] entries

let package run_bundle journal_head records =
  form "governance-reconciliation-bundle-v1"
    [
      run_bundle;
      Form.form "published-action-journal-head-v1" [ Form.Hash journal_head ];
      form "governance-action-journal-v1" records;
    ]

let verify value = Governance_reconcile.verify_form ~store ~file:"test.reconcile" value

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_error label code result =
  match result with
  | Error (diagnostic :: _) -> Alcotest.(check string) label code (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned no diagnostics" label
  | Ok _ -> Alcotest.failf "%s unexpectedly verified" label

let fixture_attempt fixture =
  let authorization = record_digest (List.nth fixture.records 2) in
  attempt 0 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(hash "driver")
    ~key:(hash "idempotency-key")

let test_complete_and_gap_categories () =
  let fixture = fixture () in
  let attempted, attempt_id = fixture_attempt fixture in
  let outcome = outcome_of_entry (completed 3 fixture.child) in
  let received = receipt 1 ~attempt_id ~outcome ~external_digest:(hash "external-receipt") in
  let records, journal_head = journal [ attempted; received ] in
  (match verify (package fixture.bundle journal_head records) with
  | Error diagnostics -> fail_diags "complete reconciliation" diagnostics
  | Ok report ->
      Alcotest.(check int) "one refused decision" 1 report.no_action_legal;
      Alcotest.(check int) "one complete action" 1 report.reconciled_completed;
      Alcotest.(check int) "no receipt gap" 0 report.receipt_pending_completion;
      Alcotest.(check string)
        "audit head" (Hash.to_hex fixture.head) (Hash.to_hex report.audit_head));
  let empty = package fixture.bundle Governance_reconcile.journal_genesis [] in
  (match verify empty with
  | Ok report -> Alcotest.(check int) "authorized but not observed" 1 report.authorized_not_observed
  | Error diagnostics -> fail_diags "empty journal" diagnostics);
  let records, head = journal [ attempted ] in
  match verify (package fixture.bundle head records) with
  | Ok report ->
      Alcotest.(check int) "completion without receipt" 1 report.completion_without_receipt
  | Error diagnostics -> fail_diags "completion without receipt" diagnostics

let test_unknown_and_receipt_recovery () =
  let fixture = fixture () in
  let entries =
    [
      evaluated 0 fixture.root fixture.policy fixture.assessment "block";
      evaluated 1 fixture.child fixture.policy fixture.assessment "ask";
      consented 2 fixture.child fixture.proposal;
    ]
  in
  let audit_records, audit_head = chain entries in
  let run_bundle =
    run_bundle ~head:audit_head ~records:audit_records
      ~calls:[ fixture.root.artifact; fixture.child.artifact ]
      ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
      ~proposals:[ fixture.proposal.artifact ]
  in
  let authorization = record_digest (List.nth audit_records 2) in
  let attempted, attempt_id =
    attempt 0 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(hash "driver")
      ~key:(hash "idempotency-key")
  in
  let records, head = journal [ attempted ] in
  (match verify (package run_bundle head records) with
  | Ok report -> Alcotest.(check int) "unknown attempt" 1 report.attempt_outcome_unknown
  | Error diagnostics -> fail_diags "unknown attempt" diagnostics);
  let outcome = outcome_of_entry (completed 3 fixture.child) in
  let received = receipt 1 ~attempt_id ~outcome ~external_digest:(hash "external-receipt") in
  let records, head = journal [ attempted; received ] in
  match verify (package run_bundle head records) with
  | Ok report ->
      Alcotest.(check int) "receipt awaiting Audit completion" 1 report.receipt_pending_completion;
      Alcotest.(check int) "rollback not inferred" 0 report.reconciled_completed
  | Error diagnostics -> fail_diags "receipt recovery" diagnostics

let test_structural_contradictions_fail_closed () =
  let fixture = fixture () in
  let blocked_authorization = record_digest (List.hd fixture.records) in
  let unauthorized, _ =
    attempt 0 ~call:fixture.root.id ~authorization:blocked_authorization ~branch:"live"
      ~driver:(hash "driver") ~key:(hash "key")
  in
  let records, head = journal [ unauthorized ] in
  expect_error "unauthorized attempt" "E1515" (verify (package fixture.bundle head records));
  let attempted, attempt_id = fixture_attempt fixture in
  let different_outcome =
    form "governance-outcome-summary-v0"
      [ version; lit "failed"; hash_form (hash "different"); lit "provider rejected" ]
  in
  let received =
    receipt 1 ~attempt_id ~outcome:different_outcome ~external_digest:(hash "external")
  in
  let records, head = journal [ attempted; received ] in
  expect_error "outcome mismatch" "E1515" (verify (package fixture.bundle head records));
  let dry_policy = make_dry_policy () in
  let dry_allow_entries =
    [ evaluated 0 fixture.root dry_policy fixture.assessment "allow"; completed 1 fixture.root ]
  in
  let dry_allow_records, dry_allow_head = chain dry_allow_entries in
  let dry_allow_bundle =
    run_bundle ~head:dry_allow_head ~records:dry_allow_records ~calls:[ fixture.root.artifact ]
      ~policies:[ dry_policy.artifact ] ~assessments:[ fixture.assessment.artifact ] ~proposals:[]
  in
  let dry_attempt, dry_attempt_id =
    attempt 0 ~call:fixture.root.id
      ~authorization:(record_digest (List.hd dry_allow_records))
      ~branch:"live" ~driver:(hash "dry-driver") ~key:(hash "dry-key")
  in
  let dry_outcome = outcome_of_entry (completed 1 fixture.root) in
  let dry_receipt =
    receipt 1 ~attempt_id:dry_attempt_id ~outcome:dry_outcome ~external_digest:(hash "dry-external")
  in
  let records, head = journal [ dry_attempt; dry_receipt ] in
  expect_error "dry Allow cannot authorize" "E1515" (verify (package dry_allow_bundle head records));
  let incompatible policy verdict =
    let entries = [ evaluated 0 fixture.root policy fixture.assessment verdict ] in
    let records, head = chain entries in
    run_bundle ~head ~records ~calls:[ fixture.root.artifact ] ~policies:[ policy.artifact ]
      ~assessments:[ fixture.assessment.artifact ] ~proposals:[]
  in
  expect_error "dry Ask is incompatible" "E1515"
    (verify (package (incompatible dry_policy "ask") Governance_reconcile.journal_genesis []));
  expect_error "live Simulate is incompatible" "E1515"
    (verify
       (package (incompatible fixture.policy "simulate") Governance_reconcile.journal_genesis []));
  let verify_dry_completion verdict branch =
    let dry_entries =
      [
        evaluated 0 fixture.root dry_policy fixture.assessment verdict;
        completed ~branch 1 fixture.root;
      ]
    in
    let dry_records, dry_head = chain dry_entries in
    let dry_bundle =
      run_bundle ~head:dry_head ~records:dry_records ~calls:[ fixture.root.artifact ]
        ~policies:[ dry_policy.artifact ] ~assessments:[ fixture.assessment.artifact ] ~proposals:[]
    in
    match verify (package dry_bundle Governance_reconcile.journal_genesis []) with
    | Ok report ->
        Alcotest.(check int) ("dry " ^ branch ^ " is no-action evidence") 1 report.no_action_legal
    | Error diagnostics -> fail_diags ("legitimate dry " ^ branch ^ " completion") diagnostics
  in
  verify_dry_completion "block" "blocked";
  verify_dry_completion "simulate" "no-simulation";
  verify_dry_completion "simulate" "simulated";
  verify_dry_completion "simulate" "simulation-failed";
  let incompatible_dry_completion verdict branch =
    let entries =
      [
        evaluated 0 fixture.root dry_policy fixture.assessment verdict;
        completed ~branch 1 fixture.root;
      ]
    in
    let records, head = chain entries in
    run_bundle ~head ~records ~calls:[ fixture.root.artifact ] ~policies:[ dry_policy.artifact ]
      ~assessments:[ fixture.assessment.artifact ] ~proposals:[]
  in
  expect_error "Dry Block cannot claim simulation" "E1515"
    (verify
       (package
          (incompatible_dry_completion "block" "simulated")
          Governance_reconcile.journal_genesis []));
  expect_error "Dry Simulate cannot claim blocked" "E1515"
    (verify
       (package
          (incompatible_dry_completion "simulate" "blocked")
          Governance_reconcile.journal_genesis []));
  let blocked_completion_entries =
    [ evaluated 0 fixture.root fixture.policy fixture.assessment "block"; completed 1 fixture.root ]
  in
  let blocked_records, blocked_head = chain blocked_completion_entries in
  let blocked_bundle =
    run_bundle ~head:blocked_head ~records:blocked_records ~calls:[ fixture.root.artifact ]
      ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
      ~proposals:[]
  in
  expect_error "live Block cannot complete" "E1515"
    (verify (package blocked_bundle Governance_reconcile.journal_genesis []));
  let duplicate_completion_entries =
    [
      evaluated 0 fixture.root fixture.policy fixture.assessment "allow";
      completed 1 fixture.root;
      completed 2 fixture.root;
    ]
  in
  let duplicate_records, duplicate_head = chain duplicate_completion_entries in
  let duplicate_bundle =
    run_bundle ~head:duplicate_head ~records:duplicate_records ~calls:[ fixture.root.artifact ]
      ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
      ~proposals:[]
  in
  expect_error "ambiguous repeated completion" "E1515"
    (verify (package duplicate_bundle Governance_reconcile.journal_genesis []));
  let repeated_authorization_entries =
    [
      evaluated 0 fixture.root fixture.policy fixture.assessment "allow";
      evaluated 1 fixture.root fixture.policy fixture.assessment "allow";
    ]
  in
  let repeated_records, repeated_head = chain repeated_authorization_entries in
  let repeated_bundle =
    run_bundle ~head:repeated_head ~records:repeated_records ~calls:[ fixture.root.artifact ]
      ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
      ~proposals:[]
  in
  expect_error "ambiguous repeated evaluation" "E1515"
    (verify (package repeated_bundle Governance_reconcile.journal_genesis []));
  let second, _ =
    let authorization = record_digest (List.nth fixture.records 2) in
    attempt 1 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(hash "other-driver")
      ~key:(hash "idempotency-key")
  in
  let records, head = journal [ attempted; second ] in
  expect_error "unsafe second attempt" "E1515" (verify (package fixture.bundle head records));
  let duplicate_attempt, _ =
    let authorization = record_digest (List.nth fixture.records 2) in
    attempt 1 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(hash "driver")
      ~key:(hash "idempotency-key")
  in
  let records, head = journal [ attempted; duplicate_attempt ] in
  expect_error "duplicate attempt identity" "E1513" (verify (package fixture.bundle head records));
  let wrong_branch, _ =
    let authorization = record_digest (List.nth fixture.records 2) in
    attempt 0 ~call:fixture.child.id ~authorization ~branch:"simulated" ~driver:(hash "driver")
      ~key:(hash "idempotency-key")
  in
  let records, head = journal [ wrong_branch ] in
  expect_error "non-live action branch" "E1515" (verify (package fixture.bundle head records));
  let empty_branch, _ =
    let authorization = record_digest (List.nth fixture.records 2) in
    attempt 0 ~call:fixture.child.id ~authorization ~branch:"" ~driver:(hash "driver")
      ~key:(hash "idempotency-key")
  in
  expect_error "empty action branch" "E1510"
    (Governance_reconcile.append_journal ~previous:Governance_reconcile.journal_genesis
       ~entry:empty_branch);
  let outcome = outcome_of_entry (completed 3 fixture.child) in
  let first_receipt =
    receipt 1 ~attempt_id ~outcome ~external_digest:(hash "first-external-receipt")
  in
  let second_receipt =
    receipt 2 ~attempt_id ~outcome ~external_digest:(hash "second-external-receipt")
  in
  let records, head = journal [ attempted; first_receipt; second_receipt ] in
  expect_error "second receipt for attempt" "E1513" (verify (package fixture.bundle head records));
  let forged_receipt =
    match first_receipt with
    | { Form.head; args = sequence :: _ :: rest; meta } ->
        { Form.head; args = sequence :: Form.F (hash_form (hash "forged-receipt")) :: rest; meta }
    | _ -> Alcotest.fail "malformed test receipt"
  in
  let first_head =
    match
      Governance_reconcile.append_journal ~previous:Governance_reconcile.journal_genesis
        ~entry:attempted
    with
    | Ok (_record, head) -> head
    | Error diagnostics -> fail_diags "attempt journal record" diagnostics
  in
  expect_error "forged receipt identity" "E1512"
    (Governance_reconcile.append_journal ~previous:first_head ~entry:forged_receipt);
  let early_receipt =
    receipt 0 ~attempt_id ~outcome ~external_digest:(hash "early-external-receipt")
  in
  let records, head = journal [ early_receipt ] in
  expect_error "receipt before attempt" "E1514" (verify (package fixture.bundle head records));
  let records, _head = journal [ attempted ] in
  expect_error "wrong published journal head" "E1511"
    (verify (package fixture.bundle (hash "wrong-journal-head") records));
  let authorization = record_digest (List.nth fixture.records 2) in
  let skipped, _ =
    attempt 1 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(hash "driver")
      ~key:(hash "idempotency-key")
  in
  let records, head = journal [ skipped ] in
  expect_error "skipped journal sequence" "E1511" (verify (package fixture.bundle head records));
  let forged =
    match attempted with
    | { Form.head; args = sequence :: _ :: rest; meta } ->
        { Form.head; args = sequence :: Form.F (hash_form (hash "forged")) :: rest; meta }
    | _ -> Alcotest.fail "malformed test attempt"
  in
  expect_error "forged attempt identity" "E1512"
    (Governance_reconcile.append_journal ~previous:Governance_reconcile.journal_genesis
       ~entry:forged)

let with_temp_path prefix suffix body =
  let path = Filename.temp_file prefix suffix in
  Fun.protect
    ~finally:(fun () -> try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
    (fun () -> body path)

let test_canonical_file_and_nonblocking_boundary () =
  let fixture = fixture () in
  let value = package fixture.bundle Governance_reconcile.journal_genesis [] in
  let bytes = Printer.print_compact value ^ "\n" in
  (match Governance_reconcile.verify_string ~store ~file:"canonical.reconcile" bytes with
  | Ok _ -> ()
  | Error diagnostics -> fail_diags "canonical reconciliation bytes" diagnostics);
  expect_error "missing final LF" "E1510"
    (Governance_reconcile.verify_string ~store ~file:"no-lf.reconcile" (Printer.print_compact value));
  with_temp_path "governance-reconcile-" ".fifo" (fun fifo ->
      Unix.unlink fifo;
      Unix.mkfifo fifo 0o600;
      expect_error "FIFO" "E1510" (Governance_reconcile.verify_file ~store ~file:fifo));
  expect_error "character device" "E1510"
    (Governance_reconcile.verify_file ~store ~file:"/dev/null");
  with_temp_path "governance-reconcile-" ".oversized" (fun oversized ->
      Unix.truncate oversized ((16 * 1024 * 1024) + 1);
      expect_error "oversized file" "E1510"
        (Governance_reconcile.verify_file ~store ~file:oversized))

let test_long_linear_journal_remains_bounded () =
  let policy = make_policy () in
  let assessment = make_assessment () in
  let calls = List.init 1_000 (fun index -> make_call (Printf.sprintf "action-%04d" index)) in
  let entries =
    List.concat
      (List.mapi
         (fun index call ->
           [
             evaluated (index * 2) call policy assessment "allow"; completed ((index * 2) + 1) call;
           ])
         calls)
  in
  let audit_records, audit_head = chain entries in
  let audit_records_by_index = Array.of_list audit_records in
  let run_bundle =
    run_bundle ~head:audit_head ~records:audit_records
      ~calls:(List.map (fun (call : call) -> call.artifact) calls)
      ~policies:[ policy.artifact ] ~assessments:[ assessment.artifact ] ~proposals:[]
  in
  let journal_entries =
    List.concat
      (List.mapi
         (fun index (call : call) ->
           let authorization = record_digest audit_records_by_index.(index * 2) in
           let attempted, attempt_id =
             attempt (index * 2) ~call:call.id ~authorization ~branch:"live" ~driver:(hash "driver")
               ~key:(hash (Printf.sprintf "key-%04d" index))
           in
           let outcome = outcome_of_entry (completed ((index * 2) + 1) call) in
           let received =
             receipt
               ((index * 2) + 1)
               ~attempt_id ~outcome
               ~external_digest:(hash (Printf.sprintf "receipt-%04d" index))
           in
           [ attempted; received ])
         calls)
  in
  let records, head = journal journal_entries in
  match verify (package run_bundle head records) with
  | Ok report ->
      Alcotest.(check int) "one thousand reconciled completions" 1_000 report.reconciled_completed
  | Error diagnostics -> fail_diags "long linear action journal" diagnostics

let suite =
  [
    Alcotest.test_case "complete and gap categories" `Quick test_complete_and_gap_categories;
    Alcotest.test_case "unknown and receipt recovery" `Quick test_unknown_and_receipt_recovery;
    Alcotest.test_case "structural contradictions fail closed" `Quick
      test_structural_contradictions_fail_closed;
    Alcotest.test_case "canonical file and nonblocking boundary" `Quick
      test_canonical_file_and_nonblocking_boundary;
    Alcotest.test_case "long linear journal remains bounded" `Quick
      test_long_linear_journal_remains_bounded;
  ]

let write_requested_fixture () =
  match Sys.getenv_opt "GM14B_FIXTURE_OUT" with
  | None -> ()
  | Some path ->
      let fixture = fixture () in
      let attempted, attempt_id = fixture_attempt fixture in
      let outcome = outcome_of_entry (completed 3 fixture.child) in
      let received = receipt 1 ~attempt_id ~outcome ~external_digest:(hash "external-receipt") in
      let records, head = journal [ attempted; received ] in
      let channel = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () ->
          output_string channel (Printer.print_compact (package fixture.bundle head records) ^ "\n"))

let write_requested_gap_fixture () =
  match Sys.getenv_opt "GM14B_GAP_FIXTURE_OUT" with
  | None -> ()
  | Some path ->
      let fixture = fixture () in
      let value = package fixture.bundle Governance_reconcile.journal_genesis [] in
      let channel = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () -> output_string channel (Printer.print_compact value ^ "\n"))

let () = write_requested_fixture ()
let () = write_requested_gap_fixture ()
