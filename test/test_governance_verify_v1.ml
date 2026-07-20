open Jacquard
module G = Governance_verify
module V = G.V1

let store, _ = Eval_support.make_prelude_ctx ()

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing verifier-v1 fixture identity `%s`" name

let pos line col offset = Span.{ line; col; offset }

let meta line =
  Meta.with_span
    (Span.make ~file:"governance-verifier-v1-fixture.jac"
       ~start_pos:(pos line 3 (line * 10))
       ~end_pos:(pos line 17 ((line * 10) + 14)))
    Meta.empty

let claim line head =
  let canonical_subject = Form.form head [] in
  G.{ carried = code_hash canonical_subject; canonical_subject; meta = meta line }

let term line name = G.{ hash = lookup name Resolve.KTerm; label = name; meta = meta line }
let gate_live = lookup "governance.gate-live" Resolve.KTerm
let workspace = lookup "workspace" Resolve.KEffect
let fs = lookup "fs" Resolve.KEffect
let net = lookup "net" Resolve.KEffect
let secret = lookup "secret" Resolve.KEffect
let judge = lookup "judge" Resolve.KEffect
let eval = lookup "eval" Resolve.KEffect

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

let raw_action index =
  match index with
  | 0 | 1 -> [ V.Raw { effect_id = fs; resources = [] } ]
  | 2 -> [ V.Raw { effect_id = net; resources = [] }; V.Raw { effect_id = secret; resources = [] } ]
  | _ -> Alcotest.fail "invalid Workspace operation fixture index"

let authority index =
  match index with
  | 0 | 1 -> [ G.Effect fs ]
  | 2 -> [ G.Effect net; G.Effect secret ]
  | _ -> Alcotest.fail "invalid Workspace authority fixture index"

let normalizer index =
  match index with
  | 0 -> "workspace.call-read"
  | 1 -> "workspace.call-write"
  | 2 -> "workspace.call-fetch"
  | _ -> Alcotest.fail "invalid Workspace normalizer fixture index"

let summarizer index =
  match index with
  | 0 -> "workspace.summarize-read"
  | 1 -> "workspace.summarize-write"
  | 2 -> "workspace.summarize-fetch"
  | _ -> Alcotest.fail "invalid Workspace summarizer fixture index"

let make_operation ~layer_id ~outer_layer_id ~index =
  let base = 100 + (layer_id * 20) + (index * 5) in
  let authority = authority index in
  let call = claim base (Printf.sprintf "workspace-call-%d-v1" index) in
  let bound_policy = claim (base + 1) (Printf.sprintf "bound-policy-%d-%d-v1" layer_id index) in
  let assessment = claim (base + 2) (Printf.sprintf "assessment-%d-%d-v1" layer_id index) in
  let proposal_identity = claim (base + 3) (Printf.sprintf "proposal-%d-%d-v1" layer_id index) in
  let proposal =
    G.
      {
        identity = proposal_identity;
        call_id = Some call.carried;
        policy_id = Some bound_policy.carried;
        assessment_id = Some assessment.carried;
        authority = Some authority;
        serialized = [ Form.form "review-v1" [ Form.F (Form.form "secret-ref-v0" []) ] ];
        meta = meta (base + 3);
      }
  in
  let action, lineage =
    match outer_layer_id with
    | None ->
        ( raw_action index,
          G.Unchanged_forward { previous_call_id = call.carried; current_call_id = call.carried } )
    | Some outer ->
        ( [ V.Forward { layer_id = outer; operation_id = List.nth workspace_operations index } ],
          if layer_id = 10 then G.Original
          else
            G.Unchanged_forward { previous_call_id = call.carried; current_call_id = call.carried }
        )
  in
  V.
    {
      operation_id = List.nth workspace_operations index;
      frozen_authority = authority;
      call_authority = authority;
      proposal_authority = authority;
      call;
      bound_policy;
      assessment;
      proposal;
      serialized_call_data = [ Form.form (Printf.sprintf "workspace-arguments-%d-v1" index) [] ];
      normalizer = term (base + 4) (normalizer index);
      summarizer = term (base + 5) (summarizer index);
      action;
      live_flows = live_flows (base + 6);
      lineage;
      meta = meta base;
    }

let make_layer layer_id outer_layer_id =
  V.
    {
      layer_id;
      outer_layer_id;
      operations = List.init 3 (fun index -> make_operation ~layer_id ~outer_layer_id ~index);
      meta = meta (layer_id * 20);
    }

let base_contract () =
  V.
    {
      version;
      facade_effect = workspace;
      layers = [ make_layer 10 (Some 20); make_layer 20 (Some 30); make_layer 30 None ];
      governed_reachable_effects = [ workspace ];
      sequence =
        G.
          {
            owner_count = 1;
            nested_owner_count = 0;
            owner_token = 7;
            layer_tokens = [ 7; 7; 7 ];
            meta = meta 8;
          };
      meta = meta 1;
    }

let fail_diags diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label contract =
  match V.verify store contract with
  | Ok report -> report
  | Error diagnostics -> Alcotest.failf "%s unexpectedly failed:\n%s" label (fail_diags diagnostics)

let expect_code code contract =
  match V.verify store contract with
  | Ok _ -> Alcotest.failf "expected %s" code
  | Error diagnostics ->
      if
        not
          (List.exists
             (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) code)
             diagnostics)
      then Alcotest.failf "missing %s in:\n%s" code (fail_diags diagnostics)

let layer (contract : V.contract) layer_id =
  match List.find_opt (fun (layer : V.layer) -> layer.layer_id = layer_id) contract.layers with
  | Some layer -> layer
  | None -> Alcotest.failf "missing layer %d" layer_id

let operation (layer : V.layer) index : V.operation = List.nth layer.operations index

let replace_layer (replacement : V.layer) (contract : V.contract) =
  V.
    {
      contract with
      layers =
        List.map
          (fun (candidate : layer) ->
            if candidate.layer_id = replacement.layer_id then replacement else candidate)
          contract.layers;
    }

let replace_operation index replacement (layer : V.layer) =
  V.
    {
      layer with
      operations =
        List.mapi
          (fun current operation -> if current = index then replacement else operation)
          layer.operations;
    }

let test_valid_same_operation_chain () =
  let contract = base_contract () in
  let report = expect_ok "three-layer same-operation forwarding" contract in
  Alcotest.(check string) "layer-aware version" "governance-verifier-v1" report.version;
  Alcotest.(check string) "released verifier remains v0" "governance-verifier-v0" G.version;
  Alcotest.(check int) "three reports per layer" 9 (List.length report.operations);
  List.iter
    (fun index ->
      let call_ids =
        List.map
          (fun layer_id -> (operation (layer contract layer_id) index).call.carried)
          [ 10; 20; 30 ]
      in
      match call_ids with
      | first :: rest ->
          Alcotest.(check bool)
            "unchanged forwarding retains the exact Call ID" true
            (List.for_all (Hash.equal first) rest)
      | [] -> Alcotest.fail "missing Call IDs")
    [ 0; 1; 2 ]

let test_complete_facade_per_layer () =
  let contract = base_contract () in
  let middle = layer contract 20 in
  expect_code "E1402"
    (replace_layer V.{ middle with operations = List.tl middle.operations } contract);
  let read = operation middle 0 in
  expect_code "E1402"
    (replace_layer V.{ middle with operations = [ read; read; operation middle 2 ] } contract)

let test_linear_topology () =
  let contract = base_contract () in
  let middle = layer contract 20 in
  let leaf = layer contract 30 in
  expect_code "E1407" V.{ contract with layers = middle :: contract.layers };
  expect_code "E1407" (replace_layer V.{ middle with outer_layer_id = Some 99 } contract);
  expect_code "E1407" (replace_layer V.{ leaf with outer_layer_id = Some 10 } contract);
  let branch = make_layer 40 (Some 30) in
  expect_code "E1407" V.{ contract with layers = branch :: contract.layers };
  let disconnected = make_layer 40 None in
  expect_code "E1407" V.{ contract with layers = disconnected :: contract.layers }

let test_exact_forwarding_and_raw_leaf () =
  let contract = base_contract () in
  let inner = layer contract 10 in
  let read = operation inner 0 in
  let wrong_operation = List.nth workspace_operations 1 in
  let wrong_target =
    V.{ read with action = [ Forward { layer_id = 20; operation_id = wrong_operation } ] }
  in
  expect_code "E1407" (replace_layer (replace_operation 0 wrong_target inner) contract);
  let wrong_layer =
    V.{ read with action = [ Forward { layer_id = 30; operation_id = read.operation_id } ] }
  in
  expect_code "E1407" (replace_layer (replace_operation 0 wrong_layer inner) contract);
  let leaf = layer contract 30 in
  let leaf_read = operation leaf 0 in
  expect_code "E1407"
    (replace_layer (replace_operation 0 V.{ leaf_read with action = [] } leaf) contract);
  expect_code "E1407"
    (replace_layer
       (replace_operation 0
          V.
            {
              leaf_read with
              action = [ Forward { layer_id = 30; operation_id = leaf_read.operation_id } ];
            }
          leaf)
       contract);
  let facade_authority = [ G.Effect workspace ] in
  let with_facade_authority (operation : V.operation) action =
    V.
      {
        operation with
        frozen_authority = facade_authority;
        call_authority = facade_authority;
        proposal_authority = facade_authority;
        proposal = { operation.proposal with authority = Some facade_authority };
        action;
      }
  in
  let inner =
    replace_operation 0 (with_facade_authority (operation inner 0) (operation inner 0).action) inner
  in
  let middle = layer contract 20 in
  let middle =
    replace_operation 0
      (with_facade_authority (operation middle 0) (operation middle 0).action)
      middle
  in
  let leaf =
    replace_operation 0
      (with_facade_authority (operation leaf 0) [ V.Raw { effect_id = workspace; resources = [] } ])
      leaf
  in
  expect_code "E1407" (contract |> replace_layer inner |> replace_layer middle |> replace_layer leaf)

let test_direct_lineage () =
  let contract = base_contract () in
  let inner = layer contract 10 in
  let inner_read = operation inner 0 in
  expect_code "E1411"
    (replace_layer
       (replace_operation 0
          V.
            {
              inner_read with
              lineage =
                Unchanged_forward
                  {
                    previous_call_id = inner_read.call.carried;
                    current_call_id = inner_read.call.carried;
                  };
            }
          inner)
       contract);
  let middle = layer contract 20 in
  let middle_read = operation middle 0 in
  expect_code "E1411"
    (replace_layer (replace_operation 0 V.{ middle_read with lineage = Original } middle) contract);
  let unrelated = Hash.of_string "unrelated-adjacent-call" in
  expect_code "E1411"
    (replace_layer
       (replace_operation 0
          V.
            {
              middle_read with
              lineage =
                Unchanged_forward
                  { previous_call_id = unrelated; current_call_id = middle_read.call.carried };
            }
          middle)
       contract)

let test_transformed_lineage_is_explicit () =
  let contract = base_contract () in
  let middle = layer contract 20 in
  let middle_read = operation middle 0 in
  let previous = (operation (layer contract 10) 0).call.carried in
  let transformed_call = claim 901 "workspace-transformed-read-v1" in
  let transformed =
    V.
      {
        middle_read with
        call = transformed_call;
        proposal =
          {
            middle_read.proposal with
            call_id = Some transformed_call.carried;
            identity = claim 902 "workspace-transformed-proposal-v1";
          };
        lineage =
          Transformed_forward
            {
              previous_call_id = previous;
              current_call_id = transformed_call.carried;
              parent_call_id = Some previous;
            };
      }
  in
  let contract = replace_layer (replace_operation 0 transformed middle) contract in
  let leaf = layer contract 30 in
  let leaf_read = operation leaf 0 in
  let leaf_read =
    V.
      {
        leaf_read with
        call = transformed_call;
        proposal =
          {
            leaf_read.proposal with
            call_id = Some transformed_call.carried;
            identity = claim 903 "workspace-transformed-leaf-proposal-v1";
          };
        lineage =
          Unchanged_forward
            {
              previous_call_id = transformed_call.carried;
              current_call_id = transformed_call.carried;
            };
      }
  in
  let contract = replace_layer (replace_operation 0 leaf_read leaf) contract in
  ignore (expect_ok "explicit transformed parent lineage" contract);
  let bad_parent = Hash.of_string "not-the-immediate-parent" in
  let bad_middle =
    V.
      {
        transformed with
        lineage =
          Transformed_forward
            {
              previous_call_id = previous;
              current_call_id = transformed_call.carried;
              parent_call_id = Some bad_parent;
            };
      }
  in
  expect_code "E1411" (replace_layer (replace_operation 0 bad_middle middle) contract)

let test_qualified_authority_and_controls () =
  let contract = base_contract () in
  let inner = layer contract 10 in
  let read = operation inner 0 in
  expect_code "E1407"
    (replace_layer (replace_operation 0 V.{ read with call_authority = [] } inner) contract);
  let leaf = layer contract 30 in
  let leaf_read = operation leaf 0 in
  expect_code "E1408"
    (replace_layer
       (replace_operation 0
          V.{ leaf_read with action = [ Raw { effect_id = judge; resources = [] } ] }
          leaf)
       contract);
  expect_code "E1412"
    (replace_layer
       (replace_operation 0
          V.{ leaf_read with action = [ Raw { effect_id = eval; resources = [] } ] }
          leaf)
       contract)

let test_sequence_and_live_evidence () =
  let contract = base_contract () in
  expect_code "E1404"
    V.
      {
        contract with
        sequence = G.{ contract.sequence with layer_tokens = [ 7; 7 ]; meta = meta 950 };
      };
  let middle = layer contract 20 in
  let read = operation middle 0 in
  expect_code "E1402"
    (replace_layer (replace_operation 0 V.{ read with live_flows = None } middle) contract);
  expect_code "E1405"
    (replace_layer
       (replace_operation 0 V.{ read with normalizer = term 951 "governance.gate-live" } middle)
       contract);
  expect_code "E1406"
    (replace_layer
       (replace_operation 0
          V.
            {
              read with
              call = { read.call with carried = Hash.of_string "stale-v1-call"; meta = meta 952 };
            }
          middle)
       contract);
  expect_code "E1409"
    (replace_layer
       (replace_operation 0
          V.{ read with serialized_call_data = [ Form.form "secret-opaque" [] ] }
          middle)
       contract);
  expect_code "E1410"
    (replace_layer
       (replace_operation 0
          V.{ read with proposal = { read.proposal with assessment_id = None; meta = meta 953 } }
          middle)
       contract);
  expect_code "E1400" V.{ contract with version = "governance-verifier-v0" }

let suite =
  [
    Alcotest.test_case "valid layer-qualified same-operation chain" `Quick
      test_valid_same_operation_chain;
    Alcotest.test_case "complete facade coverage per layer" `Quick test_complete_facade_per_layer;
    Alcotest.test_case "one linear inner-to-outer topology" `Quick test_linear_topology;
    Alcotest.test_case "exact forwarding and raw leaf shape" `Quick
      test_exact_forwarding_and_raw_leaf;
    Alcotest.test_case "direct unchanged lineage" `Quick test_direct_lineage;
    Alcotest.test_case "explicit transformed parent lineage" `Quick
      test_transformed_lineage_is_explicit;
    Alcotest.test_case "transitive authority and control exclusion" `Quick
      test_qualified_authority_and_controls;
    Alcotest.test_case "one token per live layer" `Quick test_sequence_and_live_evidence;
  ]
