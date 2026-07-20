open Jacquard

(* GM.15 keeps host Runtime_err failures separate from the closed in-language
   matrix. These cases run the released Workspace membrane unchanged and inject
   failures only through interpreter root handlers. *)

let count text needle = Test_workspace_live.count_substring text needle

let has_prefix prefix text =
  String.length text >= String.length prefix && String.sub text 0 (String.length prefix) = prefix

let normalized_events ~judge_succeeded counters =
  let normalize event =
    if String.equal event "judge:attempt" then [ "J" ]
    else if String.equal event "approval:attempt" then [ "A" ]
    else if has_prefix "fs.read:" event then [ "D" ]
    else if has_prefix "audit:" event && count event "evaluated(" = 1 then [ "E" ]
    else if has_prefix "audit:" event && count event "consented(" = 1 then [ "A"; "K" ]
    else if has_prefix "audit:" event && count event "completed(" = 1 then [ "C" ]
    else [ "unexpected:" ^ event ]
  in
  (if judge_succeeded then [ "J" ] else [])
  @ List.concat_map normalize !(counters.Test_workspace_live.events)

let check_prefix label expected ~judge_succeeded counters =
  Alcotest.(check (list string)) label expected (normalized_events ~judge_succeeded counters)

let expect_runtime_error label expected run =
  match run () with
  | Error error when String.equal (Runtime_err.to_string error) expected -> error
  | Error error ->
      Alcotest.failf "%s: expected %S, got %S" label expected (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "%s: unexpectedly returned %s" label (Value.show value)

let bare_live_source risk =
  let run =
    Printf.sprintf "(app (var workspace.live) (var policy) %s %s)" Test_workspace_live.simulators
      Test_workspace_live.read_body
  in
  let governed =
    Printf.sprintf "(app (var judge.fixed) (lam () %s) %s)" run
      (Test_workspace_live.assessment risk)
  in
  Test_workspace_live.with_policy governed

let test_real_runtime_fail_stop_boundaries () =
  let store, ctx, counters = Test_workspace_live.make_ctx () in
  let lookup name = Test_workspace_live.lookup store name Resolve.KOp in
  let run source = Eval_support.eval_with ctx store source in
  (* Judge is deliberately not wrapped by judge.fixed in this case. *)
  Eval.register_root_handler ctx (lookup "assess") (fun _ ->
      counters.events := !(counters.events) @ [ "judge:attempt" ];
      Error (Runtime_err.Io "injected Judge failure"));
  let judge_source =
    Test_workspace_live.with_policy
      (Printf.sprintf "(app (var workspace.live) (var policy) %s %s)" Test_workspace_live.simulators
         Test_workspace_live.read_body)
  in
  ignore
    (expect_runtime_error "Judge" "io error: injected Judge failure" (fun () -> run judge_source));
  check_prefix "Judge exact attempted prefix" [ "J" ] ~judge_succeeded:false counters;
  Alcotest.(check int) "Judge failure performs no action" 0 !(counters.fs_read);

  Test_workspace_live.reset counters;
  Eval.register_root_handler ctx (lookup "governance-approval.ask") (fun _ ->
      counters.events := !(counters.events) @ [ "approval:attempt" ];
      Error (Runtime_err.Io "injected Approval failure"));
  ignore
    (expect_runtime_error "Approval" "io error: injected Approval failure" (fun () ->
         run (bare_live_source "medium")));
  check_prefix "Approval exact attempted prefix" [ "J"; "E"; "A" ] ~judge_succeeded:true counters;
  let approval_events = String.concat "\n" !(counters.events) in
  Alcotest.(check int)
    "Approval has one successful Evaluated" 1
    (count approval_events "evaluated(");
  Alcotest.(check int) "Approval has no Consented" 0 (count approval_events "consented(");
  Alcotest.(check int) "Approval has no Completed" 0 (count approval_events "completed(");
  Alcotest.(check int) "Approval failure performs no action" 0 !(counters.fs_read);

  let audit_case label risk decision position expected_audits expected_prefix expected_action =
    Test_workspace_live.reset counters;
    counters.fail_audit_at := Some position;
    ignore
      (expect_runtime_error label "io error: injected Audit failure" (fun () ->
           run (Test_workspace_live.run_source ~risk ~decision Test_workspace_live.read_body)));
    check_prefix (label ^ " exact attempted prefix") expected_prefix ~judge_succeeded:true counters;
    Alcotest.(check int) (label ^ " exact Audit attempts") expected_audits !(counters.audit_count);
    Alcotest.(check int) (label ^ " raw action count") expected_action !(counters.fs_read)
  in
  audit_case "Evaluated" "low" Test_workspace_live.Approve 0 1 [ "J"; "E" ] 0;
  audit_case "Consented" "medium" Test_workspace_live.Approve 1 2 [ "J"; "E"; "A"; "K" ] 0;

  Test_workspace_live.reset counters;
  counters.fail_read := true;
  ignore
    (expect_runtime_error "raw driver" "io error: injected Fs.read failure" (fun () ->
         run
           (Test_workspace_live.run_source ~risk:"low" ~decision:Test_workspace_live.Approve
              Test_workspace_live.read_body)));
  check_prefix "raw driver exact attempted prefix" [ "J"; "E"; "D" ] ~judge_succeeded:true counters;
  Alcotest.(check int) "raw action attempted once" 1 !(counters.fs_read);

  audit_case "Completed after Allow" "low" Test_workspace_live.Approve 1 2 [ "J"; "E"; "D"; "C" ] 1;
  audit_case "Completed after Approved" "medium" Test_workspace_live.Approve 2 3
    [ "J"; "E"; "A"; "K"; "D"; "C" ] 1

type replay_event = { site : string; operation : string; subject : string; result : string }

let event_of_token token =
  match String.split_on_char '/' token with
  | [ site; operation; subject; result ] -> { site; operation; subject; result }
  | _ -> Alcotest.failf "malformed GM.15 replay token: %S" token

let load_traces () =
  let path = "../corpus/governance/gm15-healthy-traces-v0.tsv" in
  In_channel.with_open_text path (fun channel ->
      In_channel.input_lines channel
      |> List.filter (fun line -> line <> "" && line.[0] <> '#')
      |> List.map (fun line ->
          match String.split_on_char '\t' line with
          | [ label; events ] -> (label, String.split_on_char ',' events |> List.map event_of_token)
          | _ -> Alcotest.failf "malformed GM.15 replay fixture line: %S" line))

let show_event event =
  String.concat "/" [ event.site; event.operation; event.subject; event.result ]

let replay expected actual =
  let rec loop raw = function
    | [], [] -> Ok raw
    | [], event :: _ -> Error (raw, "extra event " ^ show_event event)
    | event :: _, [] -> Error (raw, "missing event " ^ show_event event)
    | wanted :: more_wanted, got :: more_got ->
        if wanted = got then
          loop (raw + if String.equal got.site "D" then 1 else 0) (more_wanted, more_got)
        else Error (raw, "expected " ^ show_event wanted ^ ", got " ^ show_event got)
  in
  loop 0 (expected, actual)

let replace_nth n value xs = List.mapi (fun index item -> if index = n then value else item) xs
let rec drop n = function xs when n = 0 -> xs | [] -> [] | _ :: rest -> drop (n - 1) rest

let test_strict_replay_shapes_and_drift () =
  let traces = load_traces () in
  Alcotest.(check int) "all eight healthy shapes are pinned" 8 (List.length traces);
  List.iter
    (fun (label, events) ->
      match replay events events with
      | Ok raw ->
          let expected_raw = if List.exists (fun event -> event.site = "D") events then 1 else 0 in
          Alcotest.(check int) (label ^ " healthy raw count") expected_raw raw;
          ()
      | Error (_, message) -> Alcotest.failf "%s healthy trace refused: %s" label message)
    traces;
  let approved = List.assoc "live-approved" traces in
  let at n = List.nth approved n in
  let drift_cases =
    [
      ("missing", List.filteri (fun index _ -> index <> 1) approved);
      ("extra", event_of_token "X/extra/call/ok" :: approved);
      ("reordered", at 0 :: at 2 :: at 1 :: drop 3 approved);
      ("wrong operation", replace_nth 1 { (at 1) with operation = "wrong-record" } approved);
      ("wrong request", replace_nth 0 { (at 0) with subject = "wrong-request" } approved);
      ("wrong proposal", replace_nth 3 { (at 3) with subject = "wrong-proposal" } approved);
      ("wrong result", replace_nth 1 { (at 1) with result = "block" } approved);
    ]
  in
  List.iter
    (fun (label, actual) ->
      match replay approved actual with
      | Error (raw, _) -> Alcotest.(check int) (label ^ " refuses before raw work") 0 raw
      | Ok _ -> Alcotest.failf "%s drift was accepted" label)
    drift_cases

let suite =
  [
    Alcotest.test_case "real Runtime_err boundaries fail stop" `Quick
      test_real_runtime_fail_stop_boundaries;
    Alcotest.test_case "eight strict traces and adversarial drift" `Quick
      test_strict_replay_shapes_and_drift;
  ]
