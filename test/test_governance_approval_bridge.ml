open Jacquard

let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let fixture_hash = String.make 64 'a'
let allowed_approvers = [ "reviewer" ]

let frozen_hash label encoded =
  match Hash.of_canonical_hex encoded with
  | Some hash -> hash
  | None -> Alcotest.failf "invalid frozen %s hash" label

let approved_constructor_hash =
  frozen_hash "approved constructor"
    "5fd7cbc33194f5d2d1d1f7b6253f237b8144d52040a0612aff416b99a8e768fa"

let lookup store name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing GM.13B name %s" name

let fail_diags what diagnostics =
  Alcotest.failf "%s: %s" what (String.concat "; " (List.map Diag.to_string diagnostics))

let ok what = function Ok value -> value | Error diagnostics -> fail_diags what diagnostics

let contains_substring value substring =
  try
    ignore (Str.search_forward (Str.regexp_string substring) value 0);
    true
  with Not_found -> false

let expression store source =
  match Reader.parse_one ~file:"gm13b.jqd" source with
  | Error diagnostics -> fail_diags "parse GM.13B expression" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> fail_diags "validate GM.13B expression" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics -> fail_diags "resolve GM.13B expression" diagnostics))

let fresh_ctx store =
  let ctx = Eval.make_ctx store in
  (match Prelude.wire_builtins ctx with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "wire GM.13B builtins" diagnostics);
  ctx

let with_queue body =
  let file = Filename.temp_file "governance-approval-bridge-" ".queue" in
  Sys.remove file;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists file then Sys.remove file)
    (fun () -> body file)

let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash_code value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]

let decision kind proposal_id =
  match kind with
  | `Approved ->
      form "approved-v1" [ hash_code proposal_id; lit "reviewer"; form "review-evidence-v1" [] ]
  | `Denied -> form "denied-v1" [ hash_code proposal_id; lit "reviewer"; lit "denied" ]
  | `Escalate -> form "escalate-v1" [ hash_code proposal_id; lit "needs owner" ]

let run_with allowed_approvers ctx store file source =
  Governance_approval_bridge.run ctx ~file ~allowed_approvers
    (Eval.expr_state (expression store source))

let run ctx store file source = run_with allowed_approvers ctx store file source

let awaiting = function
  | Governance_approval_bridge.Awaiting_approval { proposal_id; _ } -> proposal_id
  | Governance_approval_bridge.Completed value ->
      Alcotest.failf "expected Awaiting, completed with %s" (Value.show value)
  | Governance_approval_bridge.Busy _ -> Alcotest.fail "expected Awaiting, got Busy"
  | Governance_approval_bridge.Stale_approval _ -> Alcotest.fail "expected Awaiting, got Stale"

let direct_source =
  Printf.sprintf
    "(let nonrec (pvar fixture-hash)\n\
     (match (app (var hash.parse) (lit %s))\n\
     (clause (pcon ok (pvar value)) (var value))\n\
     (clause (pcon err (pwild)) (app (var throw) (lit \"bad fixture hash\"))))\n\
     (let nonrec (pvar authority)\n\
     (app (var cons) (app (var governance-effect) (var fixture-hash)) (var nil))\n\
     (let nonrec (pvar call)\n\
     (match (app (var governance.make-call) (lit \"fs.write\")\n\
     (quote (arguments (lit 7))) (var authority) (lit \"queued write\")\n\
     (quote (preconditions)) (var none))\n\
     (clause (pcon ok (pvar value)) (var value))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message))))\n\
     (let nonrec (pvar policy)\n\
     (match (app (var governance.make-live-policy) (var low) (var medium) (lit 0.5))\n\
     (clause (pcon ok (pvar value))\n\
     (match (app (var governance.bind-live-policy) (var value))\n\
     (clause (pcon ok (pvar bound)) (var bound))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message))))\n\
     (let nonrec (pvar assessment)\n\
     (app (var governance-assessment-v0) (var governance-v0) (var medium)\n\
     (lit 0.9) (var nil) (quote (assessment-evidence)))\n\
     (match (app (var governance.make-proposal) (var call) (var policy)\n\
     (var assessment) (app (var governance.call-code) (var call))\n\
     (app (var governance.call-summary) (var call)) (var none))\n\
     (clause (pcon ok (pvar proposal))\n\
     (app (var governance-approval.ask) (var proposal)))\n\
     (clause (pcon err (pvar message)) (app (var throw) (var message)))))))))"
    (qtext fixture_hash)

let replace_once source pattern replacement =
  Str.replace_first (Str.regexp_string pattern) replacement source

let tampered_source =
  replace_once direct_source "(app (var governance-approval.ask) (var proposal))"
    "(match (var proposal)\n\
     (clause (pcon governance-proposal-v0 (pvar version) (pwild) (pvar call-id)\n\
     (pvar policy-id) (pvar assessment-id) (pvar rendering) (pvar summary)\n\
     (pvar authority) (pvar preview))\n\
     (app (var governance-approval.ask)\n\
     (app (var governance-proposal-v0) (var version) (var fixture-hash)\n\
     (var call-id) (var policy-id) (var assessment-id) (var rendering)\n\
     (var summary) (var authority) (var preview)))))"

let two_asks_source =
  replace_once direct_source "(app (var governance-approval.ask) (var proposal))"
    "(tuple (app (var governance-approval.ask) (var proposal))\n\
     (app (var governance-approval.ask) (var proposal)))"

let test_two_run_exact_codec_and_root_bypass () =
  with_queue (fun file ->
      let store, ctx = Eval_support.make_prelude_ctx () in
      let bypass_calls = ref 0 in
      Eval.register_root_handler ctx (lookup store "governance-approval.ask" Resolve.KOp) (fun _ ->
          incr bypass_calls;
          Error (Runtime_err.Type_error "approval root bypass ran"));
      let proposal_id = run ctx store file direct_source |> ok "first bridge run" |> awaiting in
      Alcotest.(check int)
        "preinstalled approval root handler did not bypass bridge" 0 !bypass_calls;
      let snapshot =
        match Governance_approval_queue.inspect_file ~file |> ok "inspect submitted proposal" with
        | Governance_approval_queue.Snapshot snapshot -> snapshot
        | Governance_approval_queue.Busy_inspection -> Alcotest.fail "submitted queue was Busy"
      in
      Alcotest.(check int) "one durable Submit record" 1 snapshot.records;
      let drift_ctx = fresh_ctx store in
      (match run_with [ "other-reviewer" ] drift_ctx store file direct_source with
      | Ok _ -> Alcotest.fail "approver configuration drift was accepted"
      | Error _ -> ());
      ignore
        (Governance_approval_queue.decide_file ~file ~proposal_id ~actor:"reviewer"
           ~decision:(decision `Approved proposal_id)
        |> ok "approve proposal");
      let ctx = fresh_ctx store in
      (match run ctx store file direct_source |> ok "approved rerun" with
      | Governance_approval_bridge.Completed
          (Value.VCon
             {
               con;
               name = "approved";
               args = [ Value.VHash embedded; Value.VText "reviewer"; Value.VCode evidence ];
             }) ->
          Alcotest.(check bool)
            "exact Approved constructor identity" true
            (Hash.equal con approved_constructor_hash);
          Alcotest.(check bool)
            "Decision remains bound to exact proposal" true (Hash.equal embedded proposal_id);
          Alcotest.(check string)
            "Decision evidence round trips" "review-evidence-v1" evidence.Form.head
      | Governance_approval_bridge.Completed value ->
          Alcotest.failf "approved rerun returned wrong value %s" (Value.show value)
      | _ -> Alcotest.fail "approved rerun did not complete");
      let ctx = fresh_ctx store in
      match run ctx store file direct_source |> ok "stale replay" with
      | Governance_approval_bridge.Stale_approval { proposal_id = stale } ->
          Alcotest.(check bool)
            "replay names exact stale proposal" true (Hash.equal stale proposal_id)
      | _ -> Alcotest.fail "consumed approval was not stale on replay")

let test_invalid_carried_id_and_second_rendezvous () =
  with_queue (fun file ->
      let store, ctx = Eval_support.make_prelude_ctx () in
      (match run ctx store file tampered_source with
      | Ok _ -> Alcotest.fail "tampered carried proposal ID was accepted"
      | Error diagnostics ->
          Alcotest.(check bool)
            "tampered ID returns E1523" true
            (List.exists (fun diagnostic -> Diag.code diagnostic = Some "E1523") diagnostics));
      Alcotest.(check bool) "invalid proposal never creates queue" false (Sys.file_exists file));
  with_queue (fun file ->
      let store, ctx = Eval_support.make_prelude_ctx () in
      let proposal_id = run ctx store file two_asks_source |> ok "two-ask submit" |> awaiting in
      ignore
        (Governance_approval_queue.decide_file ~file ~proposal_id ~actor:"reviewer"
           ~decision:(decision `Approved proposal_id)
        |> ok "approve two-ask first proposal");
      let ctx = fresh_ctx store in
      (match run ctx store file two_asks_source with
      | Ok _ -> Alcotest.fail "second sequential approval rendezvous was accepted"
      | Error diagnostics ->
          Alcotest.(check bool)
            "second rendezvous explains single-run boundary" true
            (List.exists
               (fun diagnostic -> contains_substring (Diag.cause diagnostic) "a second sequential")
               diagnostics));
      let snapshot =
        match Governance_approval_queue.inspect_file ~file |> ok "inspect two-ask refusal" with
        | Governance_approval_queue.Snapshot snapshot -> snapshot
        | Governance_approval_queue.Busy_inspection -> Alcotest.fail "two-ask queue was Busy"
      in
      Alcotest.(check int) "second rendezvous adds no queue transition" 3 snapshot.records)

let rebind store name target kind =
  let target_hash = lookup store target kind in
  Store.bind_name store name target_hash |> ok ("rebind " ^ name)

let test_frozen_schema_rejects_name_rebinding () =
  List.iter
    (fun (name, target, kind) ->
      with_queue (fun file ->
          let store, ctx = Eval_support.make_prelude_ctx () in
          rebind store name target kind;
          match run ctx store file direct_source with
          | Ok _ -> Alcotest.failf "rebound released name %s was accepted" name
          | Error diagnostics ->
              Alcotest.(check bool)
                (name ^ " reports E1527") true
                (List.exists (fun diagnostic -> Diag.code diagnostic = Some "E1527") diagnostics)))
    [
      ("governance-approval-v1", "audit", Resolve.KEffect);
      ("governance-approval.ask", "record", Resolve.KOp);
      ("governance-proposal-v0", "governance-assessment-v0", Resolve.KCon);
      ("decision", "governance-proposal", Resolve.KType);
    ]

let register_builtin store ctx name native =
  let hash = lookup store name Resolve.KTerm in
  Eval.register_builtin ctx hash (Value.VBuiltin (name, native))

let declare_probes store =
  match
    Eval_support.put_src store (Store.names_view store)
      "(defterm\n\
       ((binding gm13b.driver () (quote (gm13b-driver)))\n\
       (binding gm13b.summarize () (quote (gm13b-summarize)))))"
  with
  | _ -> ()

type probes = { events : string list ref; driver_calls : int ref; fail_event : string option }

let install_probes store ctx fail_event =
  let probes = { events = ref []; driver_calls = ref 0; fail_event } in
  Eval.register_root_handler ctx (lookup store "record" Resolve.KOp) (fun args ->
      match args with
      | [ Value.VCon { name; _ } ] ->
          probes.events := !(probes.events) @ [ name ];
          if Option.equal String.equal fail_event (Some name) then
            Error (Runtime_err.Io ("refused " ^ name))
          else Ok Value.unit_v
      | _ -> Error (Runtime_err.Type_error "Audit.record received an invalid entry"));
  register_builtin store ctx "gm13b.driver" (fun args ->
      match args with
      | [] ->
          incr probes.driver_calls;
          Eval_support.eval_with ctx store "(app (var ok) (lit \"live-result\"))"
      | _ -> Error (Runtime_err.Arity "gm13b.driver takes no arguments"));
  register_builtin store ctx "gm13b.summarize" (fun args ->
      match args with
      | [ _ ] ->
          Eval_support.eval_with ctx store
            (Printf.sprintf
               "(match (app (var hash.parse) (lit %s))\n\
                (clause (pcon ok (pvar digest))\n\
                (app (var governance-outcome-summary-v0) (var governance-v0)\n\
                (lit \"success\") (var digest) (lit \"gm13b\"))))"
               (qtext fixture_hash))
      | _ -> Error (Runtime_err.Arity "gm13b.summarize takes one argument"));
  probes

let gate_source =
  Printf.sprintf
    "(let nonrec (pvar fixture-hash)\n\
     (match (app (var hash.parse) (lit %s))\n\
     (clause (pcon ok (pvar value)) (var value)))\n\
     (let nonrec (pvar authority)\n\
     (app (var cons) (app (var governance-effect) (var fixture-hash)) (var nil))\n\
     (let nonrec (pvar call)\n\
     (match (app (var governance.make-call) (lit \"fs.write\")\n\
     (quote (arguments (lit 7))) (var authority) (lit \"queued write\")\n\
     (quote (preconditions)) (var none))\n\
     (clause (pcon ok (pvar value)) (var value)))\n\
     (let nonrec (pvar policy)\n\
     (match (app (var governance.make-live-policy) (var low) (var medium) (lit 0.5))\n\
     (clause (pcon ok (pvar value))\n\
     (match (app (var governance.bind-live-policy) (var value))\n\
     (clause (pcon ok (pvar bound)) (var bound)))))\n\
     (app (var judge.fixed)\n\
     (lam () (app (var governance.with-sequence) (lam ((pvar sequence))\n\
     (match (app (var governance.gate-live) (var sequence) (var policy) (var call)\n\
     (var none) (var gm13b.summarize))\n\
     (clause (pcon execute-live)\n\
     (let nonrec (pvar result) (app (var gm13b.driver))\n\
     (let nonrec (pvar outcome) (app (var gm13b.summarize) (var result))\n\
     (let nonrec (pwild) (app (var governance.complete) (var sequence) (var call)\n\
     (lit \"executed\") (var outcome)) (var result)))))\n\
     (clause (pcon refuse-live (pvar error)) (app (var err) (var error)))))))\n\
     (app (var governance-assessment-v0) (var governance-v0) (var medium)\n\
     (lit 0.9) (var nil) (quote (assessment-evidence))))))))"
    (qtext fixture_hash)

let start_gate store file fail_event =
  let ctx = fresh_ctx store in
  let probes = install_probes store ctx fail_event in
  (probes, run ctx store file gate_source)

let decide_from_queue file kind =
  let snapshot =
    match Governance_approval_queue.inspect_file ~file |> ok "inspect pending gate proposal" with
    | Governance_approval_queue.Snapshot snapshot -> snapshot
    | Governance_approval_queue.Busy_inspection -> Alcotest.fail "pending gate queue was Busy"
  in
  let item = List.hd snapshot.items in
  ignore
    (Governance_approval_queue.decide_file ~file ~proposal_id:item.proposal_id ~actor:"reviewer"
       ~decision:(decision kind item.proposal_id)
    |> ok "decide gate proposal");
  item.proposal_id

let test_gate_audit_restart_and_stranded_consent () =
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      let first, first_result = start_gate store file None in
      let proposal_id = first_result |> ok "first gate run" |> awaiting in
      Alcotest.(check (list string))
        "first run audits only Evaluated" [ "evaluated" ] !(first.events);
      Alcotest.(check int) "pending run has no action" 0 !(first.driver_calls);
      ignore (decide_from_queue file `Approved);
      let approved, approved_result = start_gate store file None in
      (match approved_result |> ok "approved gate rerun" with
      | Governance_approval_bridge.Completed _ -> ()
      | _ -> Alcotest.fail "approved gate rerun did not complete");
      Alcotest.(check (list string))
        "approved ordering"
        [ "evaluated"; "consented"; "completed" ]
        !(approved.events);
      Alcotest.(check int) "approved driver exactly once" 1 !(approved.driver_calls);
      let replay, replay_result = start_gate store file None in
      (match replay_result |> ok "gate replay" with
      | Governance_approval_bridge.Stale_approval { proposal_id = stale } ->
          Alcotest.(check bool) "gate replay exact stale ID" true (Hash.equal stale proposal_id)
      | _ -> Alcotest.fail "gate replay did not return Stale");
      Alcotest.(check (list string))
        "stale replay stops after Evaluated" [ "evaluated" ] !(replay.events);
      Alcotest.(check int) "stale replay has no action" 0 !(replay.driver_calls));
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      ignore (start_gate store file None |> snd |> ok "stranding submit" |> awaiting);
      ignore (decide_from_queue file `Approved);
      let refused, result = start_gate store file (Some "consented") in
      (match result with
      | Ok _ -> Alcotest.fail "refused Consented audit unexpectedly completed"
      | Error _ -> ());
      Alcotest.(check (list string))
        "Consume precedes refused Consented" [ "evaluated"; "consented" ] !(refused.events);
      Alcotest.(check int) "Consented failure prevents action" 0 !(refused.driver_calls);
      let stale, replay = start_gate store file None in
      (match replay |> ok "stranded replay" with
      | Governance_approval_bridge.Stale_approval _ -> ()
      | _ -> Alcotest.fail "consumed decision was not stranded stale");
      Alcotest.(check int) "stranded replay never acts" 0 !(stale.driver_calls))

let test_denied_escalated_and_evaluated_failure () =
  List.iter
    (fun kind ->
      with_queue (fun file ->
          let store, _ = Eval_support.make_prelude_ctx () in
          declare_probes store;
          ignore (start_gate store file None |> snd |> ok "refusal submit" |> awaiting);
          ignore (decide_from_queue file kind);
          let probes, result = start_gate store file None in
          (match result |> ok "refusal rerun" with
          | Governance_approval_bridge.Completed _ -> ()
          | _ -> Alcotest.fail "refusal decision did not complete the gate");
          Alcotest.(check (list string))
            "refusal records exact consent" [ "evaluated"; "consented" ] !(probes.events);
          Alcotest.(check int) "refusal never calls driver" 0 !(probes.driver_calls)))
    [ `Denied; `Escalate ];
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      let probes, result = start_gate store file (Some "evaluated") in
      (match result with
      | Ok _ -> Alcotest.fail "refused Evaluated audit unexpectedly completed"
      | Error _ -> ());
      Alcotest.(check (list string)) "Evaluated was attempted once" [ "evaluated" ] !(probes.events);
      Alcotest.(check int) "Evaluated failure prevents action" 0 !(probes.driver_calls);
      Alcotest.(check bool) "Evaluated failure leaves queue absent" false (Sys.file_exists file))

let test_busy_corruption_and_io_fail_closed () =
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      ignore (start_gate store file None |> snd |> ok "Busy bridge submit" |> awaiting);
      let observed_busy = ref false in
      for _round = 1 to 3 do
        let start = Atomic.make false in
        let contenders =
          List.init 8 (fun _ ->
              Domain.spawn (fun () ->
                  while not (Atomic.get start) do
                    Domain.cpu_relax ()
                  done;
                  start_gate store file None))
        in
        Atomic.set start true;
        List.iter
          (fun contender ->
            let probes, result = Domain.join contender in
            Alcotest.(check int) "contended bridge never calls driver" 0 !(probes.driver_calls);
            match result with
            | Ok (Governance_approval_bridge.Busy _) -> observed_busy := true
            | Ok (Governance_approval_bridge.Awaiting_approval _) -> ()
            | _ -> Alcotest.fail "contended pending bridge returned an unexpected outcome")
          contenders
      done;
      Alcotest.(check bool) "Domain contention exposes typed Busy" true !observed_busy);
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      ignore (start_gate store file None |> snd |> ok "corrupt bridge submit" |> awaiting);
      let channel = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0 file in
      output_string channel "(not-a-queue-record)\n";
      close_out channel;
      let probes, result = start_gate store file None in
      (match result with
      | Ok _ -> Alcotest.fail "corrupt queue reached the bridge continuation"
      | Error diagnostics ->
          Alcotest.(check bool)
            "corruption retains a queue diagnostic" true
            (List.exists
               (fun diagnostic ->
                 List.mem (Diag.code_or_uncoded diagnostic) [ "E1520"; "E1521"; "E1522" ])
               diagnostics));
      Alcotest.(check int) "corrupt queue never calls driver" 0 !(probes.driver_calls));
  with_queue (fun file ->
      Unix.mkfifo file 0o600;
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      let probes, result = start_gate store file None in
      (match result with
      | Ok _ -> Alcotest.fail "unsafe FIFO queue reached the bridge continuation"
      | Error diagnostics ->
          Alcotest.(check bool)
            "unsafe queue path reports E1526" true
            (List.exists (fun diagnostic -> Diag.code diagnostic = Some "E1526") diagnostics));
      Alcotest.(check int) "unsafe queue path never calls driver" 0 !(probes.driver_calls))

let decide_after_submit start file =
  while not (Atomic.get start) do
    Domain.cpu_relax ()
  done;
  let rec retry attempts =
    if attempts = 0 then None
    else
      match Governance_approval_queue.inspect_file ~file with
      | Ok (Governance_approval_queue.Snapshot { items = [ item ]; _ }) -> (
          match
            Governance_approval_queue.decide_file ~file ~proposal_id:item.proposal_id
              ~actor:"reviewer"
              ~decision:(decision `Approved item.proposal_id)
          with
          | Ok (Governance_approval_queue.Applied _ | Governance_approval_queue.Unchanged _) ->
              Some item.proposal_id
          | Ok (Governance_approval_queue.Busy | Governance_approval_queue.Stale) | Error _ ->
              Unix.sleepf 0.0001;
              retry (attempts - 1))
      | Ok (Governance_approval_queue.Snapshot { items = []; _ })
      | Ok Governance_approval_queue.Busy_inspection
      | Error _ ->
          Unix.sleepf 0.0001;
          retry (attempts - 1)
      | Ok (Governance_approval_queue.Snapshot _) -> None
  in
  retry 100_000

let test_applied_submit_never_resumes_under_reviewer_race () =
  let store, _ = Eval_support.make_prelude_ctx () in
  for _round = 1 to 6 do
    with_queue (fun file ->
        let start = Atomic.make false in
        let reviewers =
          List.init 4 (fun _ -> Domain.spawn (fun () -> decide_after_submit start file))
        in
        Atomic.set start true;
        let rec run_first attempts =
          if attempts = 0 then Alcotest.fail "reviewer contention kept the bridge Busy"
          else
            match run (fresh_ctx store) store file direct_source with
            | Ok (Governance_approval_bridge.Busy _) ->
                Unix.sleepf 0.0001;
                run_first (attempts - 1)
            | Ok outcome -> outcome
            | Error diagnostics -> fail_diags "reviewer-race first run" diagnostics
        in
        let outcome = run_first 100_000 in
        let reviewer_results = List.map Domain.join reviewers in
        let proposal_id =
          match outcome with
          | Governance_approval_bridge.Awaiting_approval { proposal_id; _ } -> proposal_id
          | Governance_approval_bridge.Completed _ ->
              Alcotest.fail "Applied Submit consumed a racing Decision on the first run"
          | _ -> Alcotest.fail "reviewer-race first run did not return Awaiting"
        in
        Alcotest.(check bool)
          "a racing reviewer records this proposal's Decision" true
          (List.exists
             (Option.fold ~none:false ~some:(fun decided -> Hash.equal proposal_id decided))
             reviewer_results);
        let snapshot =
          match Governance_approval_queue.inspect_file ~file |> ok "inspect reviewer race" with
          | Governance_approval_queue.Snapshot snapshot -> snapshot
          | Governance_approval_queue.Busy_inspection ->
              Alcotest.fail "reviewer-race queue remained Busy"
        in
        Alcotest.(check int) "first run never appends Consume" 2 snapshot.records)
  done

let test_concurrent_bridge_consumers_act_at_most_once () =
  with_queue (fun file ->
      let store, _ = Eval_support.make_prelude_ctx () in
      declare_probes store;
      ignore (start_gate store file None |> snd |> ok "concurrent submit" |> awaiting);
      ignore (decide_from_queue file `Approved);
      let run_one () = start_gate store file None in
      let left = Domain.spawn run_one in
      let right = Domain.spawn run_one in
      let left_probes, left_result = Domain.join left in
      let right_probes, right_result = Domain.join right in
      let classify = function
        | Ok (Governance_approval_bridge.Completed _) -> `Completed
        | Ok (Governance_approval_bridge.Stale_approval _) -> `Stale
        | Ok (Governance_approval_bridge.Busy _) -> `Busy
        | Ok (Governance_approval_bridge.Awaiting_approval _) -> `Awaiting
        | Error _ -> `Error
      in
      let outcomes = [ classify left_result; classify right_result ] in
      Alcotest.(check int)
        "one concurrent bridge completes" 1
        (List.length (List.filter (fun outcome -> outcome = `Completed) outcomes));
      Alcotest.(check bool)
        "loser is stale or transiently busy" true
        (List.exists (fun outcome -> outcome = `Stale || outcome = `Busy) outcomes);
      Alcotest.(check int)
        "concurrent bridge action count is one" 1
        (!(left_probes.driver_calls) + !(right_probes.driver_calls)))

let suite =
  [
    Alcotest.test_case "two-run codec, replay, and root bypass" `Quick
      test_two_run_exact_codec_and_root_bypass;
    Alcotest.test_case "invalid ID and second rendezvous refusal" `Quick
      test_invalid_carried_id_and_second_rendezvous;
    Alcotest.test_case "frozen schema rejects rebound names" `Quick
      test_frozen_schema_rejects_name_rebinding;
    Alcotest.test_case "gate audit, restart, and stranded consent" `Quick
      test_gate_audit_restart_and_stranded_consent;
    Alcotest.test_case "denied, escalated, and Evaluated failure" `Quick
      test_denied_escalated_and_evaluated_failure;
    Alcotest.test_case "Busy, corruption, and I/O fail closed" `Quick
      test_busy_corruption_and_io_fail_closed;
    Alcotest.test_case "Applied Submit ignores a racing reviewer" `Quick
      test_applied_submit_never_resumes_under_reviewer_race;
    Alcotest.test_case "concurrent consumers act at most once" `Quick
      test_concurrent_bridge_consumers_act_at_most_once;
  ]
