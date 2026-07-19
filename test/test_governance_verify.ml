open Jacquard
module G = Governance_verify

let store, _ = Eval_support.make_prelude_ctx ()

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing verifier fixture identity `%s`" name

let pos line col offset = Span.{ line; col; offset }

let meta line =
  Meta.with_span
    (Span.make ~file:"governance-verifier-fixture.jac"
       ~start_pos:(pos line 3 (line * 10))
       ~end_pos:(pos line 17 ((line * 10) + 14)))
    Meta.empty

let claim line head =
  let canonical_subject = Form.form head [] in
  G.{ carried = code_hash canonical_subject; canonical_subject; meta = meta line }

let term line name = G.{ hash = lookup name Resolve.KTerm; label = name; meta = meta line }
let gate_live = lookup "governance.gate-live" Resolve.KTerm
let gate_dry = lookup "governance.gate-dry" Resolve.KTerm
let workspace = lookup "workspace" Resolve.KEffect
let fs = lookup "fs" Resolve.KEffect
let net = lookup "net" Resolve.KEffect
let secret = lookup "secret" Resolve.KEffect
let judge = lookup "judge" Resolve.KEffect
let eval = lookup "eval" Resolve.KEffect
let state = lookup "state" Resolve.KEffect

let effect_hiding_hash =
  let hashes =
    Eval_support.put_src store (Store.names_view store)
      "(defterm ((binding verifier-effect-hiding ((tarrow ((tarrow () (row (eref fs)) (tref text)) \
       (tref path)) (row) (tapp (tref result) (tref text) (tref governance-call)))) (lam ((pvar \
       hidden) (pvar path)) (app (var workspace.call-read) (var path))))))"
  in
  List.assoc "verifier-effect-hiding" hashes.Canon.named

type fixture_expectation = { code : string; line : int }

let fixture_expectations =
  Corpus_support.read_file "../corpus/governance/verifier-cases-v0.tsv"
  |> String.split_on_char '\n'
  |> List.filter_map (fun row ->
      if String.equal row "" || String.starts_with ~prefix:"#" row then None
      else
        match String.split_on_char '\t' row with
        | [ name; code; line ] -> (
            match int_of_string_opt line with
            | Some line -> Some (name, { code; line })
            | None -> Alcotest.failf "invalid governance verifier corpus line: %s" row)
        | _ -> Alcotest.failf "malformed governance verifier corpus row: %s" row)

let fixture name =
  match List.assoc_opt name fixture_expectations with
  | Some expectation -> expectation
  | None -> Alcotest.failf "missing governance verifier corpus fixture `%s`" name

let workspace_operations =
  [
    lookup "workspace.read-file" Resolve.KOp;
    lookup "workspace.write-file" Resolve.KOp;
    lookup "workspace.fetch" Resolve.KOp;
  ]

let live_flows line =
  Some
    [
      G.
        {
          kind = Live_execute;
          gate = gate_live;
          steps = [ Invoke_action; Record_completion; Consume_resume ];
          meta = meta line;
        };
      G.{ kind = Live_refuse; gate = gate_live; steps = [ Consume_resume ]; meta = meta (line + 1) };
    ]

let dry_flows line =
  Some
    [
      G.{ kind = Dry_simulated; gate = gate_dry; steps = [ Consume_resume ]; meta = meta line };
      G.{ kind = Dry_refuse; gate = gate_dry; steps = [ Consume_resume ]; meta = meta (line + 1) };
    ]

let make_operation ~index ~operation_id ~authority ~normalizer ~summarizer ~action =
  let base = 20 + (index * 20) in
  let call = claim base (Printf.sprintf "workspace-call-%d-v0" index) in
  let bound_policy = claim (base + 1) (Printf.sprintf "bound-policy-%d-v0" index) in
  let assessment = claim (base + 2) (Printf.sprintf "assessment-%d-v0" index) in
  let proposal_identity = claim (base + 3) (Printf.sprintf "proposal-%d-v0" index) in
  let proposal =
    G.
      {
        identity = proposal_identity;
        call_id = Some call.carried;
        policy_id = Some bound_policy.carried;
        assessment_id = Some assessment.carried;
        authority = Some authority;
        serialized = [ Form.form "review-v0" [ Form.F (Form.form "secret-ref-v0" []) ] ];
        meta = meta (base + 3);
      }
  in
  G.
    {
      operation_id;
      frozen_authority = authority;
      call_authority = authority;
      proposal_authority = authority;
      call;
      bound_policy;
      assessment;
      proposal;
      serialized_call_data = [ Form.form (Printf.sprintf "workspace-arguments-%d-v0" index) [] ];
      normalizer = term (base + 4) normalizer;
      summarizer = term (base + 5) summarizer;
      action;
      live_flows = live_flows (base + 6);
      dry_flows = dry_flows (base + 8);
      lineage = Original;
      meta = meta base;
    }

let base_contract () =
  let read =
    make_operation ~index:0 ~operation_id:(List.nth workspace_operations 0)
      ~authority:[ G.Effect fs ] ~normalizer:"workspace.call-read"
      ~summarizer:"workspace.summarize-read"
      ~action:[ G.Raw { effect_id = fs; resources = [] } ]
  in
  let write =
    make_operation ~index:1 ~operation_id:(List.nth workspace_operations 1)
      ~authority:[ G.Effect fs ] ~normalizer:"workspace.call-write"
      ~summarizer:"workspace.summarize-write"
      ~action:[ G.Raw { effect_id = fs; resources = [] } ]
  in
  let fetch =
    make_operation ~index:2 ~operation_id:(List.nth workspace_operations 2)
      ~authority:[ G.Effect net; G.Effect secret ] ~normalizer:"workspace.call-fetch"
      ~summarizer:"workspace.summarize-fetch"
      ~action:
        [ G.Raw { effect_id = net; resources = [] }; G.Raw { effect_id = secret; resources = [] } ]
  in
  G.
    {
      version;
      facade_effect = workspace;
      operations = [ read; write; fetch ];
      governed_reachable_effects = [ workspace ];
      sequence =
        {
          owner_count = 1;
          nested_owner_count = 0;
          owner_token = 7;
          layer_tokens = [ 7; 7 ];
          meta = meta 8;
        };
      meta = meta 1;
    }

let verify contract = G.verify store contract
let verify_with verifier_store contract = G.verify verifier_store contract
let fail_diags diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label contract =
  match verify contract with
  | Ok report -> report
  | Error diagnostics -> Alcotest.failf "%s unexpectedly failed:\n%s" label (fail_diags diagnostics)

let expect_fixture_with verifier_store name contract =
  let { code; line = expected_line } = fixture name in
  match verify_with verifier_store contract with
  | Ok _ -> Alcotest.failf "expected %s" code
  | Error diagnostics -> (
      match
        List.find_opt (fun diagnostic -> String.equal diagnostic.Diag.code code) diagnostics
      with
      | None -> Alcotest.failf "missing %s in:\n%s" code (fail_diags diagnostics)
      | Some diagnostic ->
          let line = Option.map (fun span -> span.Span.start_pos.line) diagnostic.Diag.span in
          Alcotest.(check (option int)) (code ^ " source line") (Some expected_line) line)

let expect_fixture name contract = expect_fixture_with store name contract

let expect_fixture_count name expected_count contract =
  let { code; line = expected_line } = fixture name in
  match verify contract with
  | Ok _ -> Alcotest.failf "expected %s" code
  | Error diagnostics ->
      let matching =
        List.filter (fun diagnostic -> String.equal diagnostic.Diag.code code) diagnostics
      in
      Alcotest.(check int) (code ^ " diagnostic count") expected_count (List.length matching);
      let first_line =
        match matching with
        | first :: _ -> Option.map (fun span -> span.Span.start_pos.line) first.Diag.span
        | [] -> None
      in
      Alcotest.(check (option int)) (code ^ " first source line") (Some expected_line) first_line

let bind_name verifier_store name hash =
  match Store.bind_name verifier_store name hash with
  | Ok () -> ()
  | Error diagnostics ->
      Alcotest.failf "cannot rebind verifier fixture name `%s`:\n%s" name (fail_diags diagnostics)

let replace_operation index (replacement : G.operation) (contract : G.contract) =
  G.
    {
      contract with
      operations =
        List.mapi
          (fun current operation -> if current = index then replacement else operation)
          contract.operations;
    }

let operation (contract : G.contract) index : G.operation = List.nth contract.operations index

let test_workspace_contract_passes () =
  let contract = base_contract () in
  let report = expect_ok "Workspace v0" contract in
  Alcotest.(check string) "verifier version" G.version report.version;
  Alcotest.(check int) "all Workspace operations" 3 (List.length report.operations);
  Alcotest.(check string)
    "exact facade identity" (Hash.to_hex workspace)
    (Hash.to_hex report.facade_effect)

let test_transitive_forward_and_resource_evidence () =
  let contract = base_contract () in
  let read = operation contract 0 in
  let write_id = (operation contract 1).operation_id in
  ignore
    (expect_ok "unchanged forward expansion"
       (replace_operation 0 G.{ read with action = [ Forward write_id ] } contract));
  let configuration = Hash.of_string "workspace-root-v0" in
  let resource = G.Resource { effect_id = fs; scope = "workspace"; configuration } in
  let authority = [ G.Effect fs; resource ] in
  let read =
    G.
      {
        read with
        frozen_authority = authority;
        call_authority = authority;
        proposal_authority = authority;
        proposal = { read.proposal with authority = Some authority };
        action = [ Raw { effect_id = fs; resources = [ resource ] } ];
      }
  in
  ignore (expect_ok "configured Resource evidence" (replace_operation 0 read contract))

let test_version_and_facade_shape_fail_closed () =
  let contract = base_contract () in
  expect_fixture "unsupported-version" G.{ contract with version = "governance-verifier-v9" };
  expect_fixture "non-effect-facade"
    G.{ contract with facade_effect = lookup "workspace.call-read" Resolve.KTerm };
  expect_fixture "non-once-facade" G.{ contract with facade_effect = state };
  let effect_store, _ = Eval_support.make_prelude_ctx () in
  let effect_fs =
    match Store.lookup_kind effect_store "fs" Resolve.KEffect with
    | Some entry -> entry.Resolve.hash
    | None -> Alcotest.fail "fresh prelude is missing Fs"
  in
  bind_name effect_store "eval" effect_fs;
  expect_fixture_with effect_store "canonical-effect-rebind" contract;
  let type_store, _ = Eval_support.make_prelude_ctx () in
  let outcome_type =
    match Store.lookup_kind type_store "governance-outcome-summary" Resolve.KType with
    | Some entry -> entry.Resolve.hash
    | None -> Alcotest.fail "fresh prelude is missing GovernanceOutcomeSummary"
  in
  bind_name type_store "governance-call" outcome_type;
  expect_fixture_with type_store "canonical-identity-rebind" contract

let test_operation_and_clause_coverage () =
  let contract = base_contract () in
  expect_fixture "missing-operation" G.{ contract with operations = List.tl contract.operations };
  let read = operation contract 0 in
  expect_fixture "duplicate-operation"
    G.{ contract with operations = [ read; read; operation contract 2 ] };
  expect_fixture "missing-live-clause"
    (replace_operation 0 G.{ read with live_flows = None } contract);
  expect_fixture "missing-dry-clause"
    (replace_operation 0 G.{ read with dry_flows = None } contract)

let test_gate_and_flow_ordering () =
  let contract = base_contract () in
  let read = operation contract 0 in
  let wrong_gate =
    G.
      {
        kind = Live_execute;
        gate = gate_dry;
        steps = [ Invoke_action; Record_completion; Consume_resume ];
        meta = meta 91;
      }
  in
  let wrong_gate_operation =
    G.
      {
        read with
        live_flows =
          Some
            [
              wrong_gate;
              { kind = Live_refuse; gate = gate_live; steps = [ Consume_resume ]; meta = meta 92 };
            ];
      }
  in
  expect_fixture "wrong-live-gate" (replace_operation 0 wrong_gate_operation contract);
  let wrong_order =
    G.
      {
        kind = Live_execute;
        gate = gate_live;
        steps = [ Invoke_action; Consume_resume; Record_completion ];
        meta = meta 93;
      }
  in
  let wrong_order_operation =
    G.
      {
        read with
        live_flows =
          Some
            [
              wrong_order;
              { kind = Live_refuse; gate = gate_live; steps = [ Consume_resume ]; meta = meta 94 };
            ];
      }
  in
  expect_fixture "live-completion-order" (replace_operation 0 wrong_order_operation contract)

let test_sequence_owner_provenance () =
  let contract = base_contract () in
  expect_fixture "multiple-sequence-owners"
    G.{ contract with sequence = { contract.sequence with owner_count = 2; meta = meta 96 } };
  expect_fixture "nested-sequence-owner"
    G.{ contract with sequence = { contract.sequence with nested_owner_count = 1; meta = meta 97 } };
  expect_fixture "wrong-layer-token"
    G.
      {
        contract with
        sequence = { contract.sequence with layer_tokens = [ 7; 8 ]; meta = meta 98 };
      };
  expect_fixture "empty-layer-tokens"
    G.{ contract with sequence = { contract.sequence with layer_tokens = []; meta = meta 106 } }

let test_purity_and_canonical_constructor () =
  let contract = base_contract () in
  let read = operation contract 0 in
  expect_fixture "impure-normalizer"
    (replace_operation 0 G.{ read with normalizer = term 99 "governance.gate-live" } contract);
  expect_fixture "impure-summarizer"
    (replace_operation 0 G.{ read with summarizer = term 100 "governance.gate-live" } contract);
  expect_fixture "noncanonical-call-constructor"
    (replace_operation 0 G.{ read with normalizer = term 101 "workspace.operation-name" } contract);
  expect_fixture "effect-hiding-nested-arrow"
    (replace_operation 0
       G.
         {
           read with
           normalizer =
             { hash = effect_hiding_hash; label = "verifier-effect-hiding"; meta = meta 107 };
         }
       contract)

let test_every_identity_recomputes () =
  let contract = base_contract () in
  let read = operation contract 0 in
  let stale = Hash.of_string "stale-governance-identity" in
  List.iter
    (fun (name, mutate) -> expect_fixture name (replace_operation 0 (mutate read) contract))
    [
      ( "stale-call-id",
        fun operation ->
          G.{ operation with call = { operation.call with carried = stale; meta = meta 102 } } );
      ( "stale-policy-id",
        fun operation ->
          G.
            {
              operation with
              bound_policy = { operation.bound_policy with carried = stale; meta = meta 103 };
            } );
      ( "stale-assessment-id",
        fun operation ->
          G.
            {
              operation with
              assessment = { operation.assessment with carried = stale; meta = meta 104 };
            } );
      ( "stale-proposal-id",
        fun operation ->
          G.
            {
              operation with
              proposal =
                {
                  operation.proposal with
                  identity = { operation.proposal.identity with carried = stale; meta = meta 105 };
                };
            } );
    ]

let test_authority_projection_and_controls () =
  let contract = base_contract () in
  let read = operation contract 0 in
  expect_fixture "call-authority-mismatch"
    (replace_operation 0 G.{ read with call_authority = [] } contract);
  expect_fixture "proposal-authority-mismatch"
    (replace_operation 0 G.{ read with proposal_authority = [] } contract);
  let expected_configuration = Hash.of_string "expected-workspace-root-v0" in
  let actual_configuration = Hash.of_string "actual-workspace-root-v0" in
  let expected_resource =
    G.Resource { effect_id = fs; scope = "workspace"; configuration = expected_configuration }
  in
  let actual_resource =
    G.Resource { effect_id = fs; scope = "workspace"; configuration = actual_configuration }
  in
  let configured_authority = [ G.Effect fs; expected_resource ] in
  expect_fixture "resource-configuration-mismatch"
    (replace_operation 0
       G.
         {
           read with
           frozen_authority = configured_authority;
           call_authority = configured_authority;
           proposal_authority = configured_authority;
           proposal = { read.proposal with authority = Some configured_authority };
           action = [ Raw { effect_id = fs; resources = [ actual_resource ] } ];
         }
       contract);
  expect_fixture "resource-effect-entry"
    (replace_operation 0
       G.{ read with action = [ Raw { effect_id = fs; resources = [ Effect net ] } ] }
       contract);
  let wrong_effect_resource =
    G.Resource
      { effect_id = net; scope = "workspace"; configuration = Hash.of_string "workspace-root-v0" }
  in
  expect_fixture "resource-wrong-effect"
    (replace_operation 0
       G.{ read with action = [ Raw { effect_id = fs; resources = [ wrong_effect_resource ] } ] }
       contract);
  expect_fixture "unknown-forward"
    (replace_operation 0
       G.{ read with action = [ Forward (Hash.of_string "unknown-operation") ] }
       contract);
  let write = operation contract 1 in
  let read_to_write = G.{ read with action = [ Forward write.operation_id ] } in
  let write_to_read = G.{ write with action = [ Forward read.operation_id ] } in
  expect_fixture "forward-cycle"
    (contract |> replace_operation 0 read_to_write |> replace_operation 1 write_to_read);
  expect_fixture "gate-control-in-action"
    (replace_operation 0
       G.{ read with action = [ Raw { effect_id = judge; resources = [] } ] }
       contract);
  expect_fixture "sequence-state-in-action"
    (replace_operation 0
       G.{ read with action = [ Raw { effect_id = state; resources = [] } ] }
       contract)

let test_secret_serialization_and_generic_inspection () =
  let contract = base_contract () in
  let read = operation contract 0 in
  expect_fixture "serialized-secret"
    (replace_operation 0
       G.{ read with serialized_call_data = [ Form.form "secret-opaque" [] ] }
       contract);
  let secret_claim line =
    let canonical_subject = Form.form "secret-opaque" [] in
    G.{ carried = code_hash canonical_subject; canonical_subject; meta = meta line }
  in
  expect_fixture "secret-bound-policy"
    (replace_operation 0 G.{ read with bound_policy = secret_claim 110 } contract);
  expect_fixture "secret-assessment"
    (replace_operation 0 G.{ read with assessment = secret_claim 111 } contract);
  match Store.lookup_kind store "debug.inspect" Resolve.KTerm with
  | None -> Alcotest.fail "prelude must expose debug.inspect for secret-safe verifier coverage"
  | Some _ ->
      expect_fixture "generic-inspection"
        (replace_operation 0 G.{ read with summarizer = term 108 "debug.inspect" } contract);
      expect_fixture_count "dual-generic-inspection" 2
        (replace_operation 0
           G.
             {
               read with
               normalizer = term 112 "debug.inspect";
               summarizer = term 113 "debug.inspect";
             }
           contract)

let test_ask_binding_and_lineage () =
  let contract = base_contract () in
  let read = operation contract 0 in
  expect_fixture "incomplete-ask"
    (replace_operation 0
       G.{ read with proposal = { read.proposal with assessment_id = None; meta = meta 109 } }
       contract);
  expect_fixture "changed-unchanged-forward"
    (replace_operation 0
       G.
         {
           read with
           lineage =
             Unchanged_forward
               {
                 previous_call_id = read.call.carried;
                 current_call_id = Hash.of_string "changed-unchanged-call";
               };
         }
       contract);
  let unrelated = Hash.of_string "self-consistent-but-unrelated-call" in
  expect_fixture "unanchored-lineage"
    (replace_operation 0
       G.
         {
           read with
           lineage = Unchanged_forward { previous_call_id = unrelated; current_call_id = unrelated };
         }
       contract);
  expect_fixture "transformed-without-parent"
    (replace_operation 0
       G.
         {
           read with
           lineage =
             Transformed_forward
               {
                 previous_call_id = read.call.carried;
                 current_call_id = Hash.of_string "transformed-call";
                 parent_call_id = None;
               };
         }
       contract);
  expect_fixture "transformed-with-old-id"
    (replace_operation 0
       G.
         {
           read with
           lineage =
             Transformed_forward
               {
                 previous_call_id = read.call.carried;
                 current_call_id = read.call.carried;
                 parent_call_id = Some read.call.carried;
               };
         }
       contract)

let test_eval_is_absolutely_prohibited () =
  let contract = base_contract () in
  expect_fixture "reachable-eval"
    G.{ contract with governed_reachable_effects = [ workspace; eval ] };
  let read = operation contract 0 in
  expect_fixture "action-eval"
    (replace_operation 0
       G.{ read with action = [ Raw { effect_id = eval; resources = [] } ] }
       contract)

let test_diagnostic_catalog_is_complete () =
  Alcotest.(check (list string))
    "stable E1400--E1412 catalog"
    (List.init 13 (fun offset -> Printf.sprintf "E%04d" (1400 + offset)))
    (List.map fst G.diagnostic_codes)

let test_adversarial_corpus_is_complete () =
  let names = List.map fst fixture_expectations in
  Alcotest.(check int) "one named mutation per corpus row" 44 (List.length names);
  Alcotest.(check int)
    "unique fixture names" (List.length names)
    (List.length (List.sort_uniq String.compare names));
  List.iter
    (fun (name, expectation) ->
      Alcotest.(check bool)
        (name ^ " uses public diagnostic")
        true
        (List.mem_assoc expectation.code G.diagnostic_codes))
    fixture_expectations

let suite =
  [
    Alcotest.test_case "valid Workspace v0 contract" `Quick test_workspace_contract_passes;
    Alcotest.test_case "transitive forwarding and configured resources" `Quick
      test_transitive_forward_and_resource_evidence;
    Alcotest.test_case "version and facade shape fail closed" `Quick
      test_version_and_facade_shape_fail_closed;
    Alcotest.test_case "operation and live/dry coverage" `Quick test_operation_and_clause_coverage;
    Alcotest.test_case "canonical gates and branch ordering" `Quick test_gate_and_flow_ordering;
    Alcotest.test_case "single sequence owner and exact token" `Quick test_sequence_owner_provenance;
    Alcotest.test_case "pure terms and canonical Call construction" `Quick
      test_purity_and_canonical_constructor;
    Alcotest.test_case "all governance identities recompute" `Quick test_every_identity_recomputes;
    Alcotest.test_case "authority projection and control exclusion" `Quick
      test_authority_projection_and_controls;
    Alcotest.test_case "secret-safe serialization and rendering" `Quick
      test_secret_serialization_and_generic_inspection;
    Alcotest.test_case "Ask binding and forwarding lineage" `Quick test_ask_binding_and_lineage;
    Alcotest.test_case "absolute governed Eval prohibition" `Quick
      test_eval_is_absolutely_prohibited;
    Alcotest.test_case "stable diagnostic catalog" `Quick test_diagnostic_catalog_is_complete;
    Alcotest.test_case "adversarial corpus catalog" `Quick test_adversarial_corpus_is_complete;
  ]
