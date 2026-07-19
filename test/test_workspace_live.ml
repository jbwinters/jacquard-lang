open Jacquard

(* GM.11: the live Workspace membrane keeps the agent on the facade while the
   trusted driver boundary introduces exact raw authority after governance. *)

let lookup store name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing GM.11 name %s" name

let checker store =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make GM.11 checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register GM.11 builtins" diagnostics);
  checker

let scheme store name =
  let checker = checker store in
  match Check.force_term checker (lookup store name Resolve.KTerm) with
  | Ok scheme -> Check.show_scheme checker scheme
  | Error diagnostics -> Eval_support.fail_diags ("force " ^ name) diagnostics

let check_source store source =
  let checker = checker store in
  match Reader.parse_string ~file:"workspace-live-check.jqd" source with
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
  | None -> Alcotest.fail "GM.11 check produced no signature"

let count_substring text needle =
  let rec loop offset count =
    if offset + String.length needle > String.length text then count
    else if String.sub text offset (String.length needle) = needle then
      loop (offset + String.length needle) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

type counters = {
  fs_read : int ref;
  fs_write : int ref;
  net_fetch : int ref;
  secret_read : int ref;
  secret_expose : int ref;
  events : string list ref;
  audit_count : int ref;
  fail_audit_at : int option ref;
  fail_read : bool ref;
}

let make_ctx () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let counters =
    {
      fs_read = ref 0;
      fs_write = ref 0;
      net_fetch = ref 0;
      secret_read = ref 0;
      secret_expose = ref 0;
      events = ref [];
      audit_count = ref 0;
      fail_audit_at = ref None;
      fail_read = ref false;
    }
  in
  let event name = counters.events := !(counters.events) @ [ name ] in
  let response =
    match
      Eval_support.eval_with ctx store "(app (var mk-response) (lit 207) (lit \"live-response\"))"
    with
    | Ok value -> value
    | Error error -> Alcotest.fail (Runtime_err.to_string error)
  in
  Eval.register_root_handler ctx (lookup store "read" Resolve.KOp) (function
    | [ Value.VText path ] ->
        incr counters.fs_read;
        event ("fs.read:" ^ path);
        if !(counters.fail_read) then Error (Runtime_err.Io "injected Fs.read failure")
        else Ok (Value.VText ("live:" ^ path))
    | args ->
        Error
          (Runtime_err.Type_error
             ("GM.11 read args: " ^ String.concat ", " (List.map Value.show args))));
  Eval.register_root_handler ctx (lookup store "write" Resolve.KOp) (function
    | [ Value.VText path; Value.VText text ] ->
        incr counters.fs_write;
        event (Printf.sprintf "fs.write:%s:%s" path text);
        Ok Value.unit_v
    | args ->
        Error
          (Runtime_err.Type_error
             ("GM.11 write args: " ^ String.concat ", " (List.map Value.show args))));
  Eval.register_root_handler ctx (lookup store "fetch" Resolve.KOp) (fun args ->
      incr counters.net_fetch;
      event ("net.fetch:" ^ String.concat "," (List.map Value.show args));
      Ok response);
  Eval.register_root_handler ctx (lookup store "secret.read" Resolve.KOp) (fun args ->
      incr counters.secret_read;
      event ("secret.read:" ^ String.concat "," (List.map Value.show args));
      Ok (Value.VSecret (Secret.of_string "gm11-secret-fixture")));
  Eval.register_root_handler ctx (lookup store "secret.expose" Resolve.KOp) (function
    | [ Value.VSecret secret ] ->
        incr counters.secret_expose;
        event "secret.expose:<redacted>";
        Ok (Value.VText (Secret.expose secret))
    | args ->
        Error
          (Runtime_err.Type_error
             ("GM.11 expose args: " ^ String.concat ", " (List.map Value.show args))));
  Eval.register_root_handler ctx (lookup store "record" Resolve.KOp) (fun args ->
      let position = !(counters.audit_count) in
      incr counters.audit_count;
      event ("audit:" ^ String.concat "," (List.map Value.show args));
      match !(counters.fail_audit_at) with
      | Some expected when expected = position -> Error (Runtime_err.Io "injected Audit failure")
      | _ -> Ok Value.unit_v);
  (store, ctx, counters)

let reset counters =
  counters.fs_read := 0;
  counters.fs_write := 0;
  counters.net_fetch := 0;
  counters.secret_read := 0;
  counters.secret_expose := 0;
  counters.events := [];
  counters.audit_count := 0;
  counters.fail_audit_at := None;
  counters.fail_read := false

let assessment risk =
  Printf.sprintf
    "(app (var governance-assessment-v0) (var governance-v0) (var %s) (lit 0.9) (var nil) (quote \
     (gm11-evidence)))"
    risk

type decision = Approve | Deny | Escalate | Stale

let decision_source = function
  | Approve ->
      "(app (var approved) (app (var governance.proposal-id) (var proposal-value)) (lit \
       \"reviewer\") (quote (gm11-approved)))"
  | Deny ->
      "(app (var denied) (app (var governance.proposal-id) (var proposal-value)) (lit \
       \"reviewer\") (lit \"denied\"))"
  | Escalate ->
      "(app (var escalate) (app (var governance.proposal-id) (var proposal-value)) (lit \"owner \
       review\"))"
  | Stale ->
      "(app (var approved) (var workspace.fs-authority-hash-v0) (lit \"reviewer\") (quote (stale)))"

let simulators = "(app (var workspace.simulators) (var none) (var none) (var none))"

let with_policy body =
  Printf.sprintf
    "(match (app (var governance.make-live-policy) (var low) (var medium) (lit 0.5))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar policy-value))\n\
     (match (app (var governance.bind-live-policy) (var policy-value))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))\n\
     (clause (pcon ok (pvar policy)) %s))))"
    body

let run_source ~risk ~decision body =
  let run =
    Printf.sprintf
      "(app (var judge.fixed)\n\
       (lam ()\n\
       (handle (app (var workspace.live) (var policy) %s %s)\n\
       (ret (pvar value) (var value))\n\
       (opclause governance-approval.ask ((pvar proposal-value)) k\n\
       (app (var k) %s))))\n\
       %s)"
      simulators body (decision_source decision) (assessment risk)
  in
  with_policy run

let read_body =
  "(lam () (app (var workspace.read-file) (app (var path-value) (lit \"README.md\"))))"

let all_body =
  "(lam ()\n\
   (let nonrec (pvar first)\n\
   (app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))\n\
   (let nonrec (pvar second)\n\
   (app (var workspace.write-file) (app (var path-value) (lit \"generated.txt\"))\n\
   (lit \"generated\"))\n\
   (let nonrec (pvar third)\n\
   (app (var workspace.fetch)\n\
   (app (var mk-request) (lit \"https://example.test/data\") (lit \"body\")))\n\
   (tuple (var first) (var second) (var third))))))"

let eval_show ctx store source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> Value.show value
  | Error error ->
      Alcotest.failf "GM.11 evaluation failed: %s\nsource: %s" (Runtime_err.to_string error) source

let test_exact_rows_and_static_routing () =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  Alcotest.(check string)
    "live layer exposes exact control and raw rows"
    "forall a | e. (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators, () ->{Workspace | \
     e} a) ->{Audit, GovernanceApprovalV1, State, Secret, Fs, Judge, Net | e} a"
    (scheme store "workspace.live-layer");
  Alcotest.(check string)
    "live owner discharges State"
    "forall a | e. (BoundPolicy LivePolicy, WorkspaceSimulators, () ->{Workspace | e} a) ->{Audit, \
     GovernanceApprovalV1, Secret, Fs, Judge, Net | e} a"
    (scheme store "workspace.live");
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string) (name ^ " exact raw row") expected (scheme store name))
    [
      ("workspace.driver-read", "(Path) ->{Fs} Result ToolError Text");
      ("workspace.driver-write", "(Path, Text) ->{Fs} Result ToolError ()");
      ("workspace.driver-fetch", "(Request) ->{Secret, Net} Result ToolError Response");
    ];
  let source =
    "(defterm ((binding gm11-agent ()\n\
     (lam () (app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))))))"
  in
  let local_checker = checker store in
  (match check_source store source with
  | Error diagnostics -> Eval_support.fail_diags "GM.11 agent row" diagnostics
  | Ok signature ->
      Alcotest.(check string)
        "agent names only Workspace" "() ->{Workspace} Result ToolError Text"
        (only_scheme local_checker signature));
  let layer = lookup store "workspace.live-layer" Resolve.KTerm in
  let deps =
    match Store.deps store layer with
    | Ok deps -> deps
    | Error diagnostics -> Eval_support.fail_diags "GM.11 live-layer deps" diagnostics
  in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("live layer references " ^ name) true
        (List.mem (lookup store name Resolve.KTerm) deps))
    [
      "workspace.call-read";
      "workspace.call-write";
      "workspace.call-fetch";
      "workspace.driver-read";
      "workspace.driver-write";
      "workspace.driver-fetch";
      "governance.gate-live";
      "governance.complete";
    ]

let test_allow_executes_exact_drivers_and_keeps_secret_out_of_evidence () =
  let store, ctx, counters = make_ctx () in
  let shown = eval_show ctx store (run_source ~risk:"low" ~decision:Approve all_body) in
  Alcotest.(check int) "one Fs.read" 1 !(counters.fs_read);
  Alcotest.(check int) "one Fs.write" 1 !(counters.fs_write);
  Alcotest.(check int) "one Net.fetch" 1 !(counters.net_fetch);
  Alcotest.(check int) "one Secret.read" 1 !(counters.secret_read);
  Alcotest.(check int) "one Secret.expose" 1 !(counters.secret_expose);
  let evidence = shown ^ String.concat "\n" !(counters.events) in
  Alcotest.(check int) "three Evaluated" 3 (count_substring evidence "evaluated(");
  Alcotest.(check int) "three Completed" 3 (count_substring evidence "completed(");
  Alcotest.(check int)
    "secret bytes absent from results, calls, summaries, and Audit" 0
    (count_substring evidence "gm11-secret-fixture");
  let events = !(counters.events) in
  let secret_tail =
    List.filter
      (fun event ->
        String.starts_with ~prefix:"secret." event || String.starts_with ~prefix:"net.fetch" event)
      events
  in
  Alcotest.(check (list string))
    "secret resolution is immediately before fetch"
    [
      "secret.read:secret-ref(\"workspace\", none)";
      "secret.expose:<redacted>";
      "net.fetch:mk-request(\"https://example.test/data\", \"body\")";
    ]
    secret_tail

let test_live_verdict_matrix_and_no_facade_bypass () =
  let store, ctx, counters = make_ctx () in
  let cases =
    [
      ("allow", "low", Approve, 1, "ok(\"live:README.md\")");
      ("approved", "medium", Approve, 1, "ok(\"live:README.md\")");
      ("denied", "medium", Deny, 0, "err(tool-denied(\"denied\"))");
      ("escalated", "medium", Escalate, 0, "err(tool-escalated(\"owner review\"))");
      ("stale approval", "medium", Stale, 0, "err(stale-approval)");
      ("blocked", "high", Approve, 0, "err(tool-blocked(\"live policy blocked call\"))");
    ]
  in
  List.iter
    (fun (label, risk, decision, expected_reads, expected) ->
      reset counters;
      let shown = eval_show ctx store (run_source ~risk ~decision read_body) in
      Alcotest.(check int) (label ^ " raw read count") expected_reads !(counters.fs_read);
      Alcotest.(check bool) (label ^ " result") true (String.starts_with ~prefix:expected shown))
    cases;
  reset counters;
  (match
     Eval_support.eval_with ctx store
       "(app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))"
   with
  | Error (Runtime_err.Unhandled { effect_ = "workspace"; _ }) -> ()
  | Error error ->
      Alcotest.failf "direct facade failed incorrectly: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "direct facade bypass returned %s" (Value.show value));
  Alcotest.(check int) "direct facade reaches no raw read" 0 !(counters.fs_read)

let test_audit_and_raw_handler_failures_are_honest () =
  let store, ctx, counters = make_ctx () in
  counters.fail_audit_at := Some 0;
  (match Eval_support.eval_with ctx store (run_source ~risk:"low" ~decision:Approve read_body) with
  | Error (Runtime_err.Io "injected Audit failure") -> ()
  | Error error -> Alcotest.failf "pre-action Audit wrong failure: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "pre-action Audit unexpectedly returned %s" (Value.show value));
  Alcotest.(check int) "pre-action Audit prevents raw read" 0 !(counters.fs_read);
  reset counters;
  counters.fail_read := true;
  (match Eval_support.eval_with ctx store (run_source ~risk:"low" ~decision:Approve read_body) with
  | Error (Runtime_err.Io "injected Fs.read failure") -> ()
  | Error error -> Alcotest.failf "raw handler wrong failure: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "raw handler unexpectedly returned %s" (Value.show value));
  Alcotest.(check int) "raw handler attempted once" 1 !(counters.fs_read);
  Alcotest.(check int)
    "raw handler failure has no fictional Completed" 0
    (List.fold_left (fun n event -> n + count_substring event "completed(") 0 !(counters.events));
  reset counters;
  counters.fail_audit_at := Some 1;
  (match Eval_support.eval_with ctx store (run_source ~risk:"low" ~decision:Approve read_body) with
  | Error (Runtime_err.Io "injected Audit failure") -> ()
  | Error error -> Alcotest.failf "completion Audit wrong failure: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "completion Audit unexpectedly returned %s" (Value.show value));
  Alcotest.(check int) "completion failure cannot roll back raw read" 1 !(counters.fs_read)

let suite =
  [
    Alcotest.test_case "exact rows and static routing" `Quick test_exact_rows_and_static_routing;
    Alcotest.test_case "Allow drivers and late secret" `Quick
      test_allow_executes_exact_drivers_and_keeps_secret_out_of_evidence;
    Alcotest.test_case "verdict matrix and no bypass" `Quick
      test_live_verdict_matrix_and_no_facade_bypass;
    Alcotest.test_case "Audit and raw handler failures" `Quick
      test_audit_and_raw_handler_failures_are_honest;
  ]
