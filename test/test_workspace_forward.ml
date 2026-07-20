open Jacquard

(* GM.12B is the reusable non-leaf membrane: it attenuates Workspace
   authority, forwards unchanged arguments, and never owns raw authority. *)

let bound_policy name auto_up_to ask_up_to body =
  Printf.sprintf
    "(match (app (var governance.make-live-policy) (var %s) (var %s) (lit 0.5))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar raw-%s))\n\
     (match (app (var governance.bind-live-policy) (var raw-%s))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar %s)) %s))))"
    auto_up_to ask_up_to name name name body

let nested_source ?(forward_layers = 1) ~inner_auto ~inner_ask ~outer_auto ~outer_ask ~risk
    ~decision body =
  let rec forward n tail =
    if n = 0 then tail
    else
      forward (n - 1)
        (Printf.sprintf
           "(app (var workspace.forward-layer) (var sequence) (var inner-policy) %s (lam () %s))"
           Test_workspace_live.simulators tail)
  in
  let governed =
    Printf.sprintf
      "(app (var workspace.live-layer) (var sequence) (var outer-policy) %s (lam () %s))"
      Test_workspace_live.simulators (forward forward_layers body)
  in
  let run =
    Printf.sprintf
      "(app (var judge.fixed)\n\
       (lam ()\n\
       (app (var governance.with-sequence)\n\
       (lam ((pvar sequence))\n\
       (handle %s\n\
       (ret (pvar value) (var value))\n\
       (opclause governance-approval.ask ((pvar proposal-value)) k\n\
       (app (var k) %s))))))\n\
       %s)"
      governed
      (Test_workspace_live.decision_source decision)
      (Test_workspace_live.assessment risk)
  in
  bound_policy "inner-policy" inner_auto inner_ask
    (bound_policy "outer-policy" outer_auto outer_ask run)

let read = "(app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))"

let check_dep store deps kind name expected =
  Alcotest.(check bool)
    ((if expected then "references " else "does not reference ") ^ name)
    expected
    (List.mem (Test_workspace_live.lookup store name kind) deps)

let check_hash_dep deps name hex expected =
  let hash = Option.get (Hash.of_hex hex) in
  Alcotest.(check bool)
    ((if expected then "references " else "does not reference ") ^ name)
    expected (List.mem hash deps)

let test_exact_public_row_and_dependency_boundary () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  Alcotest.(check string)
    "forward layer retains only governance control plus Workspace"
    "forall a | e. (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators, () ->{Workspace | \
     e} a) ->{Audit, GovernanceApprovalV1, State, Judge, Workspace | e} a"
    (Test_workspace_live.scheme store "workspace.forward-layer");
  let term = Test_workspace_live.lookup store "workspace.forward-layer" Resolve.KTerm in
  let deps =
    match Store.deps store term with
    | Ok deps -> deps
    | Error diagnostics -> Eval_support.fail_diags "GM.12B dependency boundary" diagnostics
  in
  List.iter
    (fun (name, hash) -> check_hash_dep deps name hash true)
    [
      ("workspace.read-file", "632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1");
      ("workspace.write-file", "73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c");
      ("workspace.fetch", "f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01");
    ];
  List.iter
    (fun name -> check_dep store deps Resolve.KTerm name true)
    [
      "workspace.call-read";
      "workspace.call-write";
      "workspace.call-fetch";
      "workspace.read-simulation";
      "workspace.write-simulation";
      "workspace.fetch-simulation";
      "workspace.summarize-read";
      "workspace.summarize-write";
      "workspace.summarize-fetch";
      "governance.gate-live";
      "governance.complete";
    ];
  List.iter
    (fun name -> check_dep store deps Resolve.KTerm name false)
    [
      "workspace.driver-read";
      "workspace.driver-write";
      "workspace.driver-fetch";
      "workspace.live-layer";
      "governance.with-sequence";
    ];
  List.iter
    (fun name -> check_dep store deps Resolve.KOp name false)
    [ "read"; "write"; "fetch"; "secret.read"; "secret.expose" ]

let test_all_workspace_operations_forward_unchanged_exactly_once () =
  let store, ctx, counters = Test_workspace_live.make_ctx () in
  let source =
    nested_source ~inner_auto:"low" ~inner_ask:"medium" ~outer_auto:"low" ~outer_ask:"medium"
      ~risk:"low" ~decision:Test_workspace_live.Approve
      (Printf.sprintf "(app %s)" Test_workspace_live.all_body)
  in
  let shown = Test_workspace_live.eval_show ctx store source in
  Alcotest.(check int) "one unchanged read reaches raw leaf" 1 !(counters.fs_read);
  Alcotest.(check int) "one unchanged write reaches raw leaf" 1 !(counters.fs_write);
  Alcotest.(check int) "one unchanged fetch reaches raw leaf" 1 !(counters.net_fetch);
  Alcotest.(check int) "late secret lookup exactly once" 1 !(counters.secret_read);
  Alcotest.(check int) "late secret exposure exactly once" 1 !(counters.secret_expose);
  let events = !(counters.events) in
  List.iter
    (fun exact -> Alcotest.(check bool) exact true (List.mem exact events))
    [
      "fs.read:README.md";
      "fs.write:generated.txt:generated";
      "net.fetch:mk-request(\"https://example.test/data\", \"body\")";
    ];
  let evidence = shown ^ "\n" ^ String.concat "\n" events in
  Alcotest.(check int)
    "two evaluations per operation" 6
    (Test_workspace_live.count_substring evidence "evaluated(");
  Alcotest.(check int)
    "live and forwarded completion per operation" 6
    (Test_workspace_live.count_substring evidence "completed(");
  Alcotest.(check int)
    "three forwarded completion labels" 3
    (Test_workspace_live.count_substring evidence "\"forwarded\"");
  Alcotest.(check int)
    "secret bytes absent from results and evidence" 0
    (Test_workspace_live.count_substring evidence "gm11-secret-fixture");
  let categories =
    List.map
      (fun event ->
        if String.starts_with ~prefix:"audit:evaluated(" event then "evaluated"
        else if String.starts_with ~prefix:"audit:completed(" event then
          if Test_workspace_live.count_substring event "\"forwarded\"" = 1 then
            "completed-forwarded"
          else "completed-live"
        else if String.starts_with ~prefix:"fs.read:" event then "raw-read"
        else if String.starts_with ~prefix:"fs.write:" event then "raw-write"
        else if String.starts_with ~prefix:"secret.read:" event then "secret-read"
        else if String.starts_with ~prefix:"secret.expose:" event then "secret-expose"
        else if String.starts_with ~prefix:"net.fetch:" event then "raw-fetch"
        else "unexpected")
      events
  in
  Alcotest.(check (list string))
    "inner/leaf evaluation precedes raw action; live/forward completion unwinds outward"
    [
      "evaluated";
      "evaluated";
      "raw-read";
      "completed-live";
      "completed-forwarded";
      "evaluated";
      "evaluated";
      "raw-write";
      "completed-live";
      "completed-forwarded";
      "evaluated";
      "evaluated";
      "secret-read";
      "secret-expose";
      "raw-fetch";
      "completed-live";
      "completed-forwarded";
    ]
    categories

let run_read ctx store counters ~inner_auto ~inner_ask ~outer_auto ~outer_ask ~risk ~decision =
  Test_workspace_live.reset counters;
  let shown =
    Test_workspace_live.eval_show ctx store
      (nested_source ~inner_auto ~inner_ask ~outer_auto ~outer_ask ~risk ~decision read)
  in
  (shown, !(counters.fs_read), String.concat "\n" !(counters.events))

let test_nested_policies_only_attenuate () =
  let store, ctx, counters = Test_workspace_live.make_ctx () in
  let check_case label expected_reads expected_completed args =
    let shown, reads, events = args () in
    Alcotest.(check int) (label ^ " raw count") expected_reads reads;
    Alcotest.(check int)
      (label ^ " honest completion count")
      expected_completed
      (Test_workspace_live.count_substring events "completed(");
    shown
  in
  ignore
    (check_case "inner block" 0 0 (fun () ->
         run_read ctx store counters ~inner_auto:"low" ~inner_ask:"low" ~outer_auto:"medium"
           ~outer_ask:"medium" ~risk:"medium" ~decision:Test_workspace_live.Approve));
  ignore
    (check_case "outer block after inner execution" 0 1 (fun () ->
         run_read ctx store counters ~inner_auto:"medium" ~inner_ask:"medium" ~outer_auto:"low"
           ~outer_ask:"low" ~risk:"medium" ~decision:Test_workspace_live.Approve));
  let allowed =
    check_case "both allow" 1 2 (fun () ->
        run_read ctx store counters ~inner_auto:"medium" ~inner_ask:"medium" ~outer_auto:"medium"
          ~outer_ask:"medium" ~risk:"medium" ~decision:Test_workspace_live.Approve)
  in
  Alcotest.(check bool)
    "both allow returns the raw value" true
    (String.starts_with ~prefix:"ok(\"live:README.md\")" allowed);
  ignore
    (check_case "outer exact-proposal approval" 1 2 (fun () ->
         run_read ctx store counters ~inner_auto:"medium" ~inner_ask:"medium" ~outer_auto:"low"
           ~outer_ask:"medium" ~risk:"medium" ~decision:Test_workspace_live.Approve));
  Alcotest.(check int)
    "exact approval records one consent" 1
    (Test_workspace_live.count_substring (String.concat "\n" !(counters.events)) "consented(");
  ignore
    (check_case "inner exact-proposal denial" 0 0 (fun () ->
         run_read ctx store counters ~inner_auto:"low" ~inner_ask:"medium" ~outer_auto:"medium"
           ~outer_ask:"medium" ~risk:"medium" ~decision:Test_workspace_live.Deny));
  ignore
    (check_case "outer exact-proposal denial" 0 1 (fun () ->
         run_read ctx store counters ~inner_auto:"medium" ~inner_ask:"medium" ~outer_auto:"low"
           ~outer_ask:"medium" ~risk:"medium" ~decision:Test_workspace_live.Deny))

let test_multiple_forward_layers_share_one_sequence () =
  let store, ctx, counters = Test_workspace_live.make_ctx () in
  let rec forward n tail =
    if n = 0 then tail
    else
      forward (n - 1)
        (Printf.sprintf
           "(app (var workspace.forward-layer) (var sequence) (var inner-policy) %s (lam () %s))"
           Test_workspace_live.simulators tail)
  in
  let leaf =
    Printf.sprintf
      "(handle %s (ret (pvar value) (var value))\n\
       (opclause workspace.read-file ((pcon path-value (pvar raw))) k\n\
       (let nonrec (pwild) (app (var emit) (lit \"leaf\"))\n\
       (app (var k) (app (var ok) (var raw))))))"
      (forward 2 read)
  in
  let run risk =
    Printf.sprintf
      "(app (var judge.fixed) (lam ()\n\
       (app (var emit.collect) (lam ()\n\
       (app (var governance.with-sequence) (lam ((pvar sequence)) %s))))) %s)"
      leaf
      (Test_workspace_live.assessment risk)
  in
  let source = bound_policy "inner-policy" "low" "medium" (run "low") in
  let shown = Test_workspace_live.eval_show ctx store source in
  Alcotest.(check string)
    "leaf receives the unchanged path exactly once" "(ok(\"README.md\"), cons(\"leaf\", nil))" shown;
  Alcotest.(check int) "hermetic leaf reaches no raw driver" 0 !(counters.fs_read);
  let audit_events = !(counters.events) in
  let events = String.concat "\n" audit_events in
  Alcotest.(check int)
    "two forward evaluations" 2
    (Test_workspace_live.count_substring events "evaluated(");
  Alcotest.(check int)
    "two forward completions" 2
    (Test_workspace_live.count_substring events "completed(");
  List.iteri
    (fun sequence kind ->
      Alcotest.(check int)
        (Printf.sprintf "sequence %d is contiguous" sequence)
        1
        (Test_workspace_live.count_substring events
           (Printf.sprintf "%s(governance-v0, %d," kind sequence)))
    [ "evaluated"; "evaluated"; "completed"; "completed" ];
  let call_ids =
    List.map
      (fun event ->
        match String.index_opt event '#' with
        | Some offset when String.length event >= offset + 65 -> String.sub event offset 65
        | _ -> Alcotest.failf "GM.12B audit entry has no Call ID: %s" event)
      audit_events
  in
  (match call_ids with
  | first :: rest ->
      List.iter
        (fun call_id -> Alcotest.(check string) "same Call ID at every layer" first call_id)
        rest
  | [] -> Alcotest.fail "GM.12B forwarding chain recorded no audit entries");
  Test_workspace_live.reset counters;
  let blocked =
    Test_workspace_live.eval_show ctx store
      (bound_policy "inner-policy" "low" "medium" (run "high"))
  in
  Alcotest.(check bool)
    "a refusing inner layer never reaches the leaf" true
    (String.ends_with ~suffix:", nil)" blocked);
  let blocked_events = String.concat "\n" !(counters.events) in
  Alcotest.(check int)
    "only the nearest refusing layer evaluates" 1
    (Test_workspace_live.count_substring blocked_events "evaluated(");
  Alcotest.(check int)
    "refusing chain invents no completion" 0
    (Test_workspace_live.count_substring blocked_events "completed(")

let suite =
  [
    Alcotest.test_case "exact public row and dependency boundary" `Quick
      test_exact_public_row_and_dependency_boundary;
    Alcotest.test_case "all Workspace operations forward unchanged exactly once" `Quick
      test_all_workspace_operations_forward_unchanged_exactly_once;
    Alcotest.test_case "nested policies only attenuate" `Quick test_nested_policies_only_attenuate;
    Alcotest.test_case "multiple forward layers share one sequence" `Quick
      test_multiple_forward_layers_share_one_sequence;
  ]
