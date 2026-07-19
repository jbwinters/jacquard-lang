open Jacquard

(* GM.10: an unchanged Workspace body runs behind the ordinary, world-free
   dry membrane. Tests pin inferred rows, exact routing, audit behavior,
   simulator containment, and root-authority counters. *)

let qtext value = "\"" ^ Printer.escape_text value ^ "\""

let lookup store name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing GM.10 name %s" name

let checker store =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make GM.10 checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register GM.10 builtins" diagnostics);
  checker

let scheme store name =
  let checker = checker store in
  match Check.force_term checker (lookup store name Resolve.KTerm) with
  | Ok scheme -> Check.show_scheme checker scheme
  | Error diagnostics -> Eval_support.fail_diags ("force " ^ name) diagnostics

let check_source store source =
  let checker = checker store in
  match Reader.parse_string ~file:"workspace-dry-run-check.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok forms ->
      let rec loop last = function
        | [] -> Ok last
        | form :: rest -> (
            match Kernel.of_form form with
            | Error diagnostics -> Error diagnostics
            | Ok top -> (
                match Resolve.resolve (Store.names_view store) top with
                | Error diagnostics -> Error diagnostics
                | Ok resolved -> (
                    match Check.check_top checker resolved with
                    | Error diagnostics -> Error diagnostics
                    | Ok signature -> (
                        match resolved with
                        | Kernel.Expr _ -> loop (Some signature) rest
                        | Kernel.Decl declaration -> (
                            match Store.put_decl store declaration with
                            | Ok _ -> loop (Some signature) rest
                            | Error diagnostics -> Error diagnostics)))))
      in
      loop None forms

let only_scheme checker = function
  | Some { Check.names = [ (_, scheme) ]; _ } -> Check.show_scheme checker scheme
  | Some { Check.names; _ } ->
      String.concat "; "
        (List.map (fun (name, scheme) -> name ^ " : " ^ Check.show_scheme checker scheme) names)
  | None -> Alcotest.fail "GM.10 check produced no signature"

type authority_counters = {
  fs_read : int ref;
  fs_write : int ref;
  net_fetch : int ref;
  secret_read : int ref;
  secret_expose : int ref;
  approval : int ref;
  governance_approval : int ref;
}

let make_ctx_with_authority_counters () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let counters =
    {
      fs_read = ref 0;
      fs_write = ref 0;
      net_fetch = ref 0;
      secret_read = ref 0;
      secret_expose = ref 0;
      approval = ref 0;
      governance_approval = ref 0;
    }
  in
  let install name counter =
    Eval.register_root_handler ctx (lookup store name Resolve.KOp) (fun _ ->
        incr counter;
        Error (Runtime_err.Type_error ("GM.10 unexpectedly reached " ^ name)))
  in
  install "read" counters.fs_read;
  install "write" counters.fs_write;
  install "fetch" counters.net_fetch;
  install "secret.read" counters.secret_read;
  install "secret.expose" counters.secret_expose;
  install "ask" counters.approval;
  install "governance-approval.ask" counters.governance_approval;
  (store, ctx, counters)

let reset_counters counters =
  List.iter
    (fun counter -> counter := 0)
    [
      counters.fs_read;
      counters.fs_write;
      counters.net_fetch;
      counters.secret_read;
      counters.secret_expose;
      counters.approval;
      counters.governance_approval;
    ]

let assert_zero_counters label counters =
  List.iter
    (fun (name, counter) -> Alcotest.(check int) (label ^ " no " ^ name) 0 !counter)
    [
      ("Fs.read", counters.fs_read);
      ("Fs.write", counters.fs_write);
      ("Net.fetch", counters.net_fetch);
      ("Secret.read", counters.secret_read);
      ("Secret.expose", counters.secret_expose);
      ("Approval.ask", counters.approval);
      ("GovernanceApprovalV1.ask", counters.governance_approval);
    ]

let eval_show ctx store source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> Value.show value
  | Error error ->
      Alcotest.failf "GM.10 evaluation failed: %s\nsource: %s" (Runtime_err.to_string error) source

let count_substring text needle =
  let rec loop offset count =
    if offset + String.length needle > String.length text then count
    else if String.sub text offset (String.length needle) = needle then
      loop (offset + String.length needle) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

let contains text needle = count_substring text needle > 0

let bound_policy threshold body =
  Printf.sprintf
    "(match (app (var governance.make-dry-policy) (lit %s))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar policy-value))\n\
     (match (app (var governance.bind-dry-policy) (var policy-value))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar policy)) %s))))"
    threshold body

let assessment risk confidence =
  Printf.sprintf
    "(app (var governance-assessment-v0) (var governance-v0) (var %s) (lit %s) (var nil) (quote \
     (gm10-evidence)))"
    risk confidence

let unchanged_body =
  "(lam ()\n\
   (let nonrec (pvar read-result)\n\
   (app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))\n\
   (let nonrec (pvar write-result)\n\
   (app (var workspace.write-file) (app (var path-value) (lit \"generated.txt\"))\n\
   (lit \"generated\"))\n\
   (let nonrec (pvar fetch-result)\n\
   (app (var workspace.fetch)\n\
   (app (var mk-request) (lit \"https://example.test/data\") (lit \"body\")))\n\
   (tuple (var read-result) (var write-result) (var fetch-result))))))"

let successful_simulators =
  "(app (var workspace.simulators)\n\
   (app (var some)\n\
   (lam ((pvar path))\n\
   (match (var path)\n\
   (clause (pcon path-value (pvar raw))\n\
   (app (var ok) (app (var text.concat) (lit \"simulated:\") (var raw)))))))\n\
   (app (var some) (lam ((pwild) (pwild)) (app (var ok) (tuple))))\n\
   (app (var some)\n\
   (lam ((pwild)) (app (var ok) (app (var mk-response) (lit 204) (lit \"preview\"))))))"

let missing_read_simulator =
  "(app (var workspace.simulators) (var none)\n\
   (app (var some) (lam ((pwild) (pwild)) (app (var ok) (tuple))))\n\
   (app (var some)\n\
   (lam ((pwild)) (app (var ok) (app (var mk-response) (lit 204) (lit \"preview\"))))))"

let hostile_result_simulators =
  "(app (var workspace.simulators)\n\
   (app (var some)\n\
   (lam ((pwild))\n\
   (app (var err) (app (var driver-failed) (lit \"hostile simulator payload\")))))\n\
   (app (var some) (lam ((pwild) (pwild)) (app (var ok) (tuple))))\n\
   (app (var some)\n\
   (lam ((pwild)) (app (var ok) (app (var mk-response) (lit 204) (lit \"preview\"))))))"

let discharged_helper_simulators =
  "(app (var workspace.simulators)\n\
   (app (var some)\n\
   (lam ((pwild))\n\
   (app (var workspace.discharge-state)\n\
   (lam ()\n\
   (let nonrec (pvar before) (app (var get))\n\
   (let nonrec (pwild) (app (var put) (lit \"updated\"))\n\
   (app (var ok) (var before)))))\n\
   (lit \"state-backed\"))))\n\
   (app (var some)\n\
   (lam ((pwild) (pwild))\n\
   (app (var workspace.discharge-fault)\n\
   (lam ()\n\
   (match (app (var flaky) (lit \"workspace.write-file\"))\n\
   (clause (pcon true)\n\
   (app (var err) (app (var driver-failed) (lit \"fault\"))))\n\
   (clause (pcon false) (app (var ok) (tuple))))))))\n\
   (app (var some)\n\
   (lam ((pwild))\n\
   (app (var workspace.discharge-dist)\n\
   (lam () (app (var sample) (app (var uniform-int) (lit 0) (lit 1))))\n\
   (lam ((pvar branches))\n\
   (match (var branches)\n\
   (clause (pcon cons (pwild) (pcon cons (pwild) (pcon nil)))\n\
   (app (var ok) (app (var mk-response) (lit 209) (lit \"dist:2\"))))\n\
   (clause (pwild)\n\
   (app (var err) (app (var driver-failed) (lit \"bad distribution\"))))))))))"

let fault_all_simulators =
  "(app (var workspace.simulators)\n\
   (app (var some)\n\
   (lam ((pwild))\n\
   (app (var throw.catch)\n\
   (lam ()\n\
   (match\n\
   (app (var test.run)\n\
   (lam ()\n\
   (match\n\
   (app (var fault.all)\n\
   (lam ()\n\
   (match (app (var flaky) (lit \"workspace.read-file\"))\n\
   (clause (pcon false) (app (var ok) (lit \"no-fault\")))\n\
   (clause (pcon true)\n\
   (app (var err) (app (var driver-failed) (lit \"injected\"))))))\n\
   (lit 4))\n\
   (clause\n\
   (pcon cons (pcon ok (plit \"no-fault\"))\n\
   (pcon cons (pcon err (pcon driver-failed (plit \"injected\"))) (pcon nil)))\n\
   (app (var check.true) (var true) (lit \"fault-all:both\")))\n\
   (clause (pwild)\n\
   (app (var check.true) (var false) (lit \"fault-all:both\"))))))\n\
   (clause\n\
   (pcon mk-report\n\
   (pcon cons (ptuple (plit \"fault-all:both\") (pcon true)) (pcon nil))\n\
   (pcon none))\n\
   (app (var ok) (lit \"fault-all:both\")))\n\
   (clause (pwild)\n\
   (app (var err) (app (var driver-failed) (lit \"bad fault report\"))))))\n\
   (lam ((pvar message))\n\
   (app (var err) (app (var driver-failed) (var message)))))))\n\
   (app (var some) (lam ((pwild) (pwild)) (app (var ok) (tuple))))\n\
   (app (var some)\n\
   (lam ((pwild)) (app (var ok) (app (var mk-response) (lit 204) (lit \"preview\"))))))"

let run_fixture ~risk ~confidence ~threshold ~simulators =
  let run =
    Printf.sprintf
      "(app (var judge.fixed)\n\
       (lam ()\n\
       (app (var audit.in-memory)\n\
       (lam ()\n\
       (app (var workspace.dry-run) (var policy) %s %s))))\n\
       %s)"
      simulators unchanged_body (assessment risk confidence)
  in
  Printf.sprintf "(app (var throw.to-result) (lam () %s))" (bound_policy threshold run)

let test_exact_rows_and_static_routing () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  Alcotest.(check string)
    "dry layer exposes only control row plus continuation"
    "forall a | e. (AuditSequence, BoundPolicy DryPolicy, WorkspaceSimulators, () ->{Workspace | \
     e} a) ->{Audit, State, Judge | e} a"
    (scheme store "workspace.dry-layer");
  Alcotest.(check string)
    "run owner discharges State"
    "forall a | e. (BoundPolicy DryPolicy, WorkspaceSimulators, () ->{Workspace | e} a) ->{Audit, \
     Judge | e} a"
    (scheme store "workspace.dry-run");
  List.iter
    (fun name ->
      let actual = scheme store name in
      Alcotest.(check bool) (name ^ " has pure outer row") true (contains actual " ->{} "))
    [
      "workspace.simulators";
      "workspace.discharge-state";
      "workspace.discharge-fault";
      "workspace.discharge-dist";
      "workspace.read-simulation";
      "workspace.write-simulation";
      "workspace.fetch-simulation";
    ];
  let dry_layer = lookup store "workspace.dry-layer" Resolve.KTerm in
  let dependencies =
    match Store.deps store dry_layer with
    | Ok dependencies -> dependencies
    | Error diagnostics -> Eval_support.fail_diags "read dry-layer dependencies" diagnostics
  in
  let required =
    [
      "workspace.call-read";
      "workspace.call-write";
      "workspace.call-fetch";
      "workspace.summarize-read";
      "workspace.summarize-write";
      "workspace.summarize-fetch";
      "governance.gate-dry";
    ]
  in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("dry layer directly references " ^ name)
        true
        (List.mem (lookup store name Resolve.KTerm) dependencies))
    required;
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("dry layer handles exact " ^ name ^ " operation")
        true
        (List.mem (lookup store name Resolve.KOp) dependencies))
    [ "workspace.read-file"; "workspace.write-file"; "workspace.fetch" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("dry layer has no direct " ^ name ^ " operation")
        false
        (List.mem (lookup store name Resolve.KOp) dependencies))
    [ "read"; "write"; "fetch"; "secret.read"; "secret.expose"; "ask"; "governance-approval.ask" ]

let test_closed_simulator_boundary_and_fully_handled_row () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  let invalid_callbacks =
    [
      ( "State",
        "(app (var workspace.simulators)\n\
         (app (var some) (lam ((pwild)) (let nonrec (pwild) (app (var get)) (app (var ok) (lit \
         \"bad\"))))) (var none) (var none))" );
      ( "Fault",
        "(app (var workspace.simulators)\n\
         (app (var some) (lam ((pwild)) (let nonrec (pwild) (app (var flaky) (lit \"bad\")) (app \
         (var ok) (lit \"bad\"))))) (var none) (var none))" );
      ( "Dist",
        "(app (var workspace.simulators)\n\
         (app (var some) (lam ((pwild)) (let nonrec (pwild) (app (var sample) (app (var \
         uniform-int) (lit 0) (lit 1))) (app (var ok) (lit \"bad\"))))) (var none) (var none))" );
      ( "Fs",
        "(app (var workspace.simulators)\n\
         (app (var some) (lam ((pwild)) (app (var ok) (app (var read) (lit \"bad\"))))) (var none) \
         (var none))" );
    ]
  in
  List.iter
    (fun (label, source) ->
      match check_source store source with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "%s callback crossed the closed simulator boundary" label)
    invalid_callbacks;
  let source =
    Printf.sprintf "(defterm ((binding gm10-closed () (lam () %s))))"
      (run_fixture ~risk:"low" ~confidence:"0.9" ~threshold:"0.5" ~simulators:successful_simulators)
  in
  let local_store, _ctx = Eval_support.make_prelude_ctx () in
  let local_checker = checker local_store in
  match check_source local_store source with
  | Error diagnostics -> Eval_support.fail_diags "fully handled GM.10 fixture" diagnostics
  | Ok signature -> (
      let actual = only_scheme local_checker signature in
      Alcotest.(check bool) "pure handlers close the outer row" true (contains actual "() ->{}");
      let fault_source =
        Printf.sprintf "(defterm ((binding gm10-fault-closed () %s)))" fault_all_simulators
      in
      match check_source local_store fault_source with
      | Error diagnostics -> Eval_support.fail_diags "closed fault.all simulator" diagnostics
      | Ok _ -> ())

let assert_audit_sequence shown =
  List.iter
    (fun (kind, sequence) ->
      Alcotest.(check int)
        (Printf.sprintf "%s sequence %d exactly once" kind sequence)
        1
        (count_substring shown (Printf.sprintf "%s(governance-v0, %d," kind sequence)))
    [
      ("evaluated", 0);
      ("completed", 1);
      ("evaluated", 2);
      ("completed", 3);
      ("evaluated", 4);
      ("completed", 5);
    ]

let test_policy_matrix_and_zero_world_authority () =
  let store, ctx, counters = make_ctx_with_authority_counters () in
  List.iter
    (fun risk ->
      List.iter
        (fun threshold ->
          reset_counters counters;
          let label = risk ^ "/" ^ threshold in
          let shown =
            eval_show ctx store
              (run_fixture ~risk ~confidence:"0.75" ~threshold ~simulators:successful_simulators)
          in
          assert_zero_counters label counters;
          assert_audit_sequence shown;
          Alcotest.(check int)
            (label ^ " one audit pair per operation")
            3
            (count_substring shown "evaluated(");
          Alcotest.(check int) (label ^ " no consent") 0 (count_substring shown "consented(");
          if String.equal risk "forbidden" then
            Alcotest.(check int)
              (label ^ " all operations blocked")
              3
              (count_substring shown ", \"blocked\",")
          else
            Alcotest.(check int)
              (label ^ " all operations simulated")
              3
              (count_substring shown ", \"simulated\","))
        [ "0.0"; "0.25"; "0.5"; "0.75"; "1.0" ])
    [ "low"; "medium"; "high"; "forbidden" ]

let test_missing_hostile_and_discharged_helpers () =
  let store, ctx, counters = make_ctx_with_authority_counters () in
  let run simulators =
    reset_counters counters;
    let shown =
      eval_show ctx store (run_fixture ~risk:"low" ~confidence:"0.9" ~threshold:"0.5" ~simulators)
    in
    assert_zero_counters "simulator case" counters;
    assert_audit_sequence shown;
    shown
  in
  let missing = run missing_read_simulator in
  Alcotest.(check bool)
    "missing read returns NoSimulation" true
    (contains missing "err(no-simulation)");
  Alcotest.(check int)
    "exactly one missing-simulation audit" 1
    (count_substring missing ", \"no-simulation\",");
  let hostile = run hostile_result_simulators in
  Alcotest.(check bool)
    "hostile failure remains typed" true
    (contains hostile "err(driver-failed(\"hostile simulator payload\"))");
  Alcotest.(check bool)
    "hostile detail is absent from audit summary" true
    (count_substring hostile "hostile simulator payload" = 1);
  Alcotest.(check int)
    "exactly one simulation-failed audit" 1
    (count_substring hostile ", \"simulation-failed\",");
  let discharged = run discharged_helper_simulators in
  List.iter
    (fun expected ->
      Alcotest.(check bool) (expected ^ " helper result") true (contains discharged expected))
    [ "state-backed"; "ok(())"; "mk-response(209, \"dist:2\")" ];
  let exhaustive = run fault_all_simulators in
  Alcotest.(check bool)
    "fault.all explored both one-site paths before gate" true
    (contains exhaustive "ok(\"fault-all:both\")")

let suite =
  [
    Alcotest.test_case "exact rows and static gate routing" `Quick
      test_exact_rows_and_static_routing;
    Alcotest.test_case "closed simulators and fully handled row" `Quick
      test_closed_simulator_boundary_and_fully_handled_row;
    Alcotest.test_case "policy matrix keeps world counters zero" `Quick
      test_policy_matrix_and_zero_world_authority;
    Alcotest.test_case "missing, hostile, State/Fault/Dist, and fault.all" `Quick
      test_missing_hostile_and_discharged_helpers;
  ]
