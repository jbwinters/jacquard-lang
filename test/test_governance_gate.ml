open Jacquard

(* GM.6: the dry gate returns a disposition and owns no Resume or live authority. *)

let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let fixture_hash = String.make 64 'a'

let lookup store name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing GM.6 name %s" name

let make_ctx_with_authority_counters () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let live_calls = ref 0 and approval_calls = ref 0 in
  Eval.register_root_handler ctx (lookup store "write" Resolve.KOp) (fun _ ->
      incr live_calls;
      Error (Runtime_err.Type_error "GM.6 unexpectedly reached Fs.write"));
  Eval.register_root_handler ctx (lookup store "ask" Resolve.KOp) (fun _ ->
      incr approval_calls;
      Error (Runtime_err.Type_error "GM.6 unexpectedly reached Approval.ask"));
  (store, ctx, live_calls, approval_calls)

let eval_show ctx store source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> Value.show value
  | Error error ->
      Alcotest.failf "gate-dry evaluation failed: %s\nsource: %s" (Runtime_err.to_string error)
        source

let expect_stale ctx store label source =
  match Eval_support.eval_with ctx store source with
  | Error (Runtime_err.Type_error message) ->
      Alcotest.(check bool) label true (String.starts_with ~prefix:"stale AuditSequence:" message)
  | Error error ->
      Alcotest.failf "%s failed with the wrong runtime error: %s" label
        (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "%s unexpectedly returned %s" label (Value.show value)

let checker store =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make GM.6 checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register GM.6 builtins" diagnostics);
  checker

let scheme store name =
  let checker = checker store in
  match Check.force_term checker (lookup store name Resolve.KTerm) with
  | Ok scheme -> Check.show_scheme checker scheme
  | Error diagnostics -> Eval_support.fail_diags ("force " ^ name) diagnostics

let check_program source =
  let store, _ctx = Eval_support.make_prelude_ctx () in
  let checker = checker store in
  match Reader.parse_string ~file:"governance-gate-affine.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok forms ->
      let rec loop = function
        | [] -> Ok ()
        | form :: rest -> (
            match Kernel.of_form form with
            | Error diagnostics -> Error diagnostics
            | Ok top -> (
                match Resolve.resolve (Store.names_view store) top with
                | Error diagnostics -> Error diagnostics
                | Ok resolved -> (
                    match Check.check_top checker resolved with
                    | Error diagnostics -> Error diagnostics
                    | Ok _ -> (
                        match resolved with
                        | Kernel.Expr _ -> loop rest
                        | Kernel.Decl declaration -> (
                            match Store.put_decl store declaration with
                            | Ok _ -> loop rest
                            | Error diagnostics -> Error diagnostics)))))
      in
      loop forms

let wrap_fixture body =
  Printf.sprintf
    "(app (var throw.to-result) (lam ()\n\
     (let nonrec (pvar fixture-hash)\n\
     (match (app (var hash.parse) (lit %s))\n\
     (clause (pcon ok (pvar value)) (var value))\n\
     (clause (pcon err (pwild)) (app (var throw) (lit \"bad fixture hash\"))))\n\
     (let nonrec (pvar authority)\n\
     (app (var cons) (app (var governance-effect) (var fixture-hash))\n\
     (app (var cons)\n\
     (app (var governance-resource) (var fixture-hash) (lit \"bucket/a\")\n\
     (var fixture-hash)) (var nil)))\n\
     (let nonrec (pvar call)\n\
     (match (app (var governance.make-call) (lit \"fs.write\")\n\
     (quote (arguments (lit 7))) (var authority) (lit \"dry write\")\n\
     (quote (preconditions)) (var none))\n\
     (clause (pcon ok (pvar value)) (var value))\n\
     (clause (pcon err (pwild)) (app (var throw) (lit \"bad call\"))))\n\
     (let nonrec (pvar policy)\n\
     (match (app (var governance.make-dry-policy) (lit 0.5))\n\
     (clause (pcon err (pwild)) (app (var throw) (lit \"bad policy\")))\n\
     (clause (pcon ok (pvar value))\n\
     (match (app (var governance.bind-dry-policy) (var value))\n\
     (clause (pcon ok (pvar bound)) (var bound))\n\
     (clause (pcon err (pwild)) (app (var throw) (lit \"bad bound\"))))))\n\
     %s))))))"
    (qtext fixture_hash) body

let assessment risk confidence =
  Printf.sprintf
    "(app (var governance-assessment-v0) (var governance-v0) (var %s) (lit %s) (var nil) (quote \
     (evidence)))"
    risk confidence

let simulator = function
  | `None -> "(var none)"
  | `Ok -> "(app (var some) (lam () (app (var ok) (lit \"simulated\"))))"
  | `Error ->
      "(app (var some) (lam () (app (var err) (app (var driver-failed) (lit \"sim-failed\")))))"

let gate_call simulator =
  Printf.sprintf
    "(app (var governance.gate-dry) (var sequence) (var policy) (var call) %s\n\
     (lam ((pwild))\n\
     (app (var governance-outcome-summary-v0) (var governance-v0)\n\
     (lit \"done\") (app (var governance.call-id) (var call)) (lit \"dry\"))))"
    simulator

let matrix_source risk confidence simulator_kind =
  let body =
    Printf.sprintf
      "(app (var judge.fixed)\n\
       (lam () (app (var audit.in-memory)\n\
       (lam () (app (var governance.with-sequence) (lam ((pvar sequence)) %s))))) %s)"
      (gate_call (simulator simulator_kind))
      (assessment risk confidence)
  in
  wrap_fixture body

let count_substring text needle =
  let rec loop offset count =
    if offset + String.length needle > String.length text then count
    else if String.sub text offset (String.length needle) = needle then
      loop (offset + String.length needle) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

let test_exact_world_free_signature_and_local_resume () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let actual = scheme store "governance.gate-dry" in
  Alcotest.(check string)
    "exact frozen gate-dry row"
    "forall a. (AuditSequence, BoundPolicy DryPolicy, GovernanceCall, Option (() ->{} Result \
     ToolError a), (Result ToolError a) ->{} GovernanceOutcomeSummary) ->{Audit, State, Judge} \
     DryDisposition a"
    actual;
  List.iter
    (fun forbidden ->
      Alcotest.(check int)
        (forbidden ^ " absent from gate signature")
        0
        (count_substring actual forbidden))
    [ "Approval"; "Secret"; "Eval"; "Fs"; "Net"; "World" ];
  Alcotest.(check string)
    "run owner discharges State" "forall a | e. ((AuditSequence) ->{State | e} a) ->{| e} a"
    (scheme store "governance.with-sequence");
  Alcotest.(check bool)
    "AuditSequence constructor is private" true
    (Store.lookup_kind store "audit-sequence-v0" Resolve.KCon = None);
  let hidden_markers =
    List.map
      (fun name ->
        Alcotest.(check bool)
          (name ^ " has no public name") true
          (Store.lookup_kind store name Resolve.KTerm = None);
        let hash =
          match Store.lookup_internal_kind store name Resolve.KTerm with
          | Some { Resolve.hash; _ } -> hash
          | None -> Alcotest.failf "trusted hidden marker %s is missing" name
        in
        (match Store.locate store hash with
        | Error [ { Diag.code = "E0601"; _ } ] -> ()
        | Error diagnostics -> Eval_support.fail_diags (name ^ " public hash lookup") diagnostics
        | Ok _ -> Alcotest.failf "%s remained publicly hash-addressable" name);
        (match Store.bind_name store ("forged-" ^ name) hash with
        | Error [ { Diag.code = "E0601"; _ } ] -> ()
        | Error diagnostics -> Eval_support.fail_diags (name ^ " public rebinding") diagnostics
        | Ok () -> Alcotest.failf "%s could be rebound publicly" name);
        (match check_program (Printf.sprintf "(app (var %s))" name) with
        | Error diagnostics ->
            Alcotest.(check bool)
              (name ^ " is unresolved") true
              (List.exists
                 (fun diagnostic -> String.equal diagnostic.Diag.code "E0301")
                 diagnostics)
        | Ok () -> Alcotest.failf "%s unexpectedly type-checked" name);
        let hex = Hash.to_hex hash in
        (match check_program (Printf.sprintf "(ref #%s term)" hex) with
        | Error diagnostics ->
            Alcotest.(check bool)
              (name ^ " direct hash is unknown")
              true
              (List.exists
                 (fun diagnostic -> String.equal diagnostic.Diag.code "E0805")
                 diagnostics)
        | Ok () -> Alcotest.failf "%s direct hash unexpectedly type-checked" name);
        (match Eval_support.eval_with ctx store (Printf.sprintf "(ref #%s term)" hex) with
        | Error (Runtime_err.Unresolved message) ->
            Alcotest.(check bool)
              (name ^ " unchecked direct hash is unknown")
              true
              (String.starts_with ~prefix:"error[E0601]: unknown hash" message)
        | Error error ->
            Alcotest.failf "%s direct hash failed with wrong runtime error: %s" name
              (Runtime_err.to_string error)
        | Ok value -> Alcotest.failf "%s direct hash returned %s" name (Value.show value));
        (name, hash))
      [ "governance.fresh-audit-run-id"; "governance.require-audit-run-id" ]
  in
  let sequence_hex = "3e9b091027d525ea128d13df8033dc02a7494d82b2a529e9157e81ffeebf1900" in
  let sequence_hash = Option.get (Hash.of_hex sequence_hex) in
  (match Store.locate store sequence_hash with
  | Error [ { Diag.code = "E0601"; _ } ] -> ()
  | Error diagnostics -> Eval_support.fail_diags "private sequence hash lookup" diagnostics
  | Ok _ -> Alcotest.fail "private AuditSequence constructor remained hash-addressable");
  (match Store.bind_name store "forged-audit-sequence" sequence_hash with
  | Error [ { Diag.code = "E0601"; _ } ] -> ()
  | Error diagnostics -> Eval_support.fail_diags "private sequence hash rebinding" diagnostics
  | Ok () -> Alcotest.fail "private AuditSequence constructor could be rebound");
  (match check_program "(app (var audit-sequence-v0) (app (var code.hash) (quote (forged))))" with
  | Error diagnostics ->
      Alcotest.(check bool)
        "direct token fabrication is unresolved" true
        (List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0301") diagnostics)
  | Ok () -> Alcotest.fail "private AuditSequence constructor unexpectedly type-checked");
  (match check_program (Printf.sprintf "(ref #%s con)" sequence_hex) with
  | Error diagnostics ->
      Alcotest.(check bool)
        "derived-hash token fabrication is unknown" true
        (List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0805") diagnostics)
  | Ok () -> Alcotest.fail "private AuditSequence constructor hash unexpectedly type-checked");
  (match Eval_support.eval_with ctx store (Printf.sprintf "(ref #%s con)" sequence_hex) with
  | Error (Runtime_err.Unresolved message) ->
      Alcotest.(check bool)
        "unchecked derived-hash token fabrication is unknown" true
        (String.starts_with ~prefix:"error[E0601]: unknown hash" message)
  | Error error ->
      Alcotest.failf "private hash failed with the wrong runtime error: %s"
        (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "private hash constructed %s" (Value.show value));
  let reopened =
    match Store.open_store store.Store.root with
    | Ok reopened -> reopened
    | Error diagnostics -> Eval_support.fail_diags "reopen GM.6 prelude store" diagnostics
  in
  Alcotest.(check bool)
    "reopen preserves private constructor name" true
    (Store.lookup_kind reopened "audit-sequence-v0" Resolve.KCon = None);
  List.iter
    (fun (name, hash) ->
      Alcotest.(check bool)
        ("reopen preserves hidden " ^ name)
        true
        (Store.lookup_kind reopened name Resolve.KTerm = None);
      match Store.locate reopened hash with
      | Error [ { Diag.code = "E0601"; _ } ] -> ()
      | Error diagnostics -> Eval_support.fail_diags ("reopened " ^ name) diagnostics
      | Ok _ -> Alcotest.failf "reopen exposed hidden marker %s" name)
    hidden_markers;
  (match Store.locate reopened sequence_hash with
  | Error [ { Diag.code = "E0601"; _ } ] -> ()
  | Error diagnostics -> Eval_support.fail_diags "reopened private sequence hash" diagnostics
  | Ok _ -> Alcotest.fail "reopen restored the private sequence hash");
  let reopened_ctx = Eval.make_ctx reopened in
  (match Prelude.wire_builtins reopened_ctx with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "wire reopened GM.6 prelude" diagnostics);
  Alcotest.(check string)
    "reopened owner retains private construction authority" "\"ok\""
    (eval_show reopened_ctx reopened
       "(app (var governance.with-sequence) (lam ((pwild)) (lit \"ok\")))");
  (match
     Eval_support.eval_with reopened_ctx reopened (Printf.sprintf "(ref #%s con)" sequence_hex)
   with
  | Error (Runtime_err.Unresolved message) ->
      Alcotest.(check bool)
        "reopened direct hash remains unknown" true
        (String.starts_with ~prefix:"error[E0601]: unknown hash" message)
  | Error error ->
      Alcotest.failf "reopened private hash failed with the wrong runtime error: %s"
        (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "reopened private hash constructed %s" (Value.show value));
  let local_gate = gate_call (simulator `Ok) in
  let facade branch =
    "(defeffect gm6-affine ()\n\
     (op gm6-invoke once ()\n\
     (tapp (tref result) (tref tool-error) (tref text))))\n"
    ^ wrap_fixture
        (Printf.sprintf
           "(app (var judge.fixed) (lam () (app (var audit.in-memory) (lam ()\n\
            (app (var governance.with-sequence) (lam ((pvar sequence))\n\
            (handle (app (var gm6-invoke))\n\
            (ret (pvar result) (var result))\n\
            (opclause gm6-invoke () k %s))))))) %s)"
           branch (assessment "low" "0.9"))
  in
  let consume_once =
    Printf.sprintf
      "(match %s\n\
       (clause (pcon simulated (pvar result)) (app (var k) (var result)))\n\
       (clause (pcon refuse-dry (pvar error))\n\
       (app (var k) (app (var err) (var error)))))"
      local_gate
  in
  (match check_program (facade consume_once) with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "facade-local affine Resume accepted" diagnostics);
  let duplicate =
    Printf.sprintf
      "(let nonrec (pvar disposition) %s\n\
       (let nonrec (pwild)\n\
       (match (var disposition)\n\
       (clause (pcon simulated (pvar result)) (app (var k) (var result)))\n\
       (clause (pcon refuse-dry (pvar error))\n\
       (app (var k) (app (var err) (var error)))))\n\
       (app (var k) (app (var err) (var no-simulation)))))"
      local_gate
  in
  match check_program (facade duplicate) with
  | Error diagnostics ->
      Alcotest.(check bool)
        "facade cannot consume Resume twice" true
        (List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0816") diagnostics)
  | Ok () -> Alcotest.fail "facade duplicate Resume unexpectedly type-checked"

let test_risk_confidence_matrix_and_counters () =
  let store, ctx, live_calls, approval_calls = make_ctx_with_authority_counters () in
  let risks = [ "low"; "medium"; "high"; "forbidden" ] in
  let confidences = [ "0.0"; "0.25"; "0.5"; "0.75"; "1.0" ] in
  let simulators = [ `None; `Ok; `Error ] in
  List.iter
    (fun risk ->
      List.iter
        (fun confidence ->
          List.iter
            (fun simulator_kind ->
              live_calls := 0;
              approval_calls := 0;
              let shown = eval_show ctx store (matrix_source risk confidence simulator_kind) in
              let label = Printf.sprintf "%s/%s" risk confidence in
              Alcotest.(check int) (label ^ " no live calls") 0 !live_calls;
              Alcotest.(check int) (label ^ " no approval calls") 0 !approval_calls;
              Alcotest.(check int)
                (label ^ " accepted Evaluated position zero")
                1
                (count_substring shown "evaluated(governance-v0, 0,");
              Alcotest.(check int)
                (label ^ " accepted Completed position one")
                1
                (count_substring shown "completed(governance-v0, 1,");
              Alcotest.(check int) (label ^ " one Evaluated") 1 (count_substring shown "evaluated(");
              Alcotest.(check int) (label ^ " one Completed") 1 (count_substring shown "completed(");
              Alcotest.(check int) (label ^ " no Consented") 0 (count_substring shown "consented(");
              if String.equal risk "forbidden" then
                Alcotest.(check int)
                  (label ^ " explicit block disposition")
                  1
                  (count_substring shown "refuse-dry(tool-blocked(\"dry policy blocked call\"))")
              else
                match simulator_kind with
                | `None ->
                    Alcotest.(check int)
                      (label ^ " explicit missing-simulation refusal")
                      1
                      (count_substring shown "refuse-dry(no-simulation)")
                | `Ok ->
                    Alcotest.(check int)
                      (label ^ " simulated result disposition")
                      1
                      (count_substring shown "simulated(ok(\"simulated\"))")
                | `Error ->
                    Alcotest.(check int)
                      (label ^ " preserved simulator failure")
                      1
                      (count_substring shown "simulated(err(driver-failed(\"sim-failed\")))"))
            simulators)
        confidences)
    risks

let test_sequence_owner_freshness_and_escape_rejection () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  Alcotest.(check string)
    "same owner reads and advances its counter" "(0, 1)"
    (eval_show ctx store
       "(app (var governance.with-sequence) (lam ((pvar owner))\n\
       \        (let nonrec (pvar before) (app (var governance.next-sequence) (var owner))\n\
       \        (let nonrec (pwild) (app (var governance.accept-sequence) (var owner))\n\
       \        (tuple (var before) (app (var governance.next-sequence) (var owner)))))))");
  let returned =
    eval_show ctx store "(app (var governance.with-sequence) (lam ((pvar owner)) (var owner)))"
  in
  Alcotest.(check bool)
    "owner token can be returned only as an opaque value" true
    (String.starts_with ~prefix:"audit-sequence-v0(#" returned);
  expect_stale ctx store "returned token rejected by a later owner"
    "(let nonrec (pvar escaped)\n\
    \       (app (var governance.with-sequence) (lam ((pvar owner)) (var owner)))\n\
    \       (app (var governance.with-sequence) (lam ((pwild))\n\
    \         (app (var governance.next-sequence) (var escaped)))))";
  expect_stale ctx store "outer token rejected while nested owner is active"
    "(app (var governance.with-sequence) (lam ((pvar outer))\n\
    \       (app (var governance.with-sequence) (lam ((pwild))\n\
    \         (app (var governance.next-sequence) (var outer))))))";
  Alcotest.(check string)
    "nested owners keep independent counters" "(0, 1, 0)"
    (eval_show ctx store
       "(app (var governance.with-sequence) (lam ((pvar outer))\n\
       \        (let nonrec (pvar outer-before)\n\
       \          (app (var governance.next-sequence) (var outer))\n\
       \        (let nonrec (pvar inner-after)\n\
       \          (app (var governance.with-sequence) (lam ((pvar inner))\n\
       \            (let nonrec (pwild) (app (var governance.accept-sequence) (var inner))\n\
       \              (app (var governance.next-sequence) (var inner)))))\n\
       \          (tuple (var outer-before) (var inner-after)\n\
       \            (app (var governance.next-sequence) (var outer)))))))");
  expect_stale ctx store "escaped token rejected under arbitrary state.run"
    (Printf.sprintf
       "(let nonrec (pvar fixture-hash)\n\
       \          (match (app (var hash.parse) (lit %s))\n\
       \            (clause (pcon ok (pvar value)) (var value)))\n\
       \          (let nonrec (pvar escaped)\n\
       \            (app (var governance.with-sequence) (lam ((pvar owner)) (var owner)))\n\
       \            (app (var state.run)\n\
       \              (lam () (app (var governance.next-sequence) (var escaped)))\n\
       \              (tuple (var fixture-hash) (lit 0)))))"
       (qtext fixture_hash))

let register_probe store ctx name calls value =
  let hashes =
    Eval_support.put_src store (Store.names_view store)
      (Printf.sprintf "(defterm ((binding %s () (quote (probe %s)))))" name name)
  in
  let hash = List.assoc name hashes.Canon.named in
  Eval.register_builtin ctx hash
    (Value.VBuiltin
       ( name,
         fun _args ->
           incr calls;
           Ok value ))

let probe_ctx () =
  let store, ctx, live_calls, approval_calls = make_ctx_with_authority_counters () in
  let simulator_calls = ref 0 and summarizer_calls = ref 0 in
  let simulator_value =
    match Eval_support.eval_with ctx store "(app (var ok) (lit \"probe-simulated\"))" with
    | Ok value -> value
    | Error error -> Alcotest.fail (Runtime_err.to_string error)
  in
  let outcome_value =
    match
      Eval_support.eval_with ctx store
        (Printf.sprintf
           "(match (app (var hash.parse) (lit %s))\n\
            (clause (pcon ok (pvar digest))\n\
            (app (var governance-outcome-summary-v0) (var governance-v0) (lit \"probe\")\n\
            (var digest) (lit \"probe\")))\n\
            (clause (pcon err (pwild))\n\
            (app (var governance-outcome-summary-v0) (var governance-v0) (lit \"bad\")\n\
            (app (var code.hash) (quote (bad))) (lit \"bad\"))))"
           (qtext fixture_hash))
    with
    | Ok value -> value
    | Error error -> Alcotest.fail (Runtime_err.to_string error)
  in
  register_probe store ctx "gm6.simulator-probe" simulator_calls simulator_value;
  register_probe store ctx "gm6.summarizer-probe" summarizer_calls outcome_value;
  (store, ctx, live_calls, approval_calls, simulator_calls, summarizer_calls)

let probe_gate handler =
  wrap_fixture
    (Printf.sprintf
       "(app (var judge.fixed) (lam ()\n\
        (app (var governance.with-sequence) (lam ((pvar sequence))\n\
        %s))) %s)"
       (handler
          "(app (var governance.gate-dry) (var sequence) (var policy) (var call)\n\
           (app (var some) (var gm6.simulator-probe)) (var gm6.summarizer-probe))")
       (assessment "low" "0.9"))

let assert_probe_counts live approval simulator summarizer expected =
  let l, a, s, z = expected in
  Alcotest.(check int) "live calls" l !live;
  Alcotest.(check int) "approval calls" a !approval;
  Alcotest.(check int) "simulator calls" s !simulator;
  Alcotest.(check int) "summarizer calls" z !summarizer

let test_pre_audit_failure_prevents_action () =
  let store, ctx, live, approval, simulator, summarizer = probe_ctx () in
  let source =
    probe_gate (fun gate ->
        Printf.sprintf
          "(handle %s (ret (pvar value) (var value))\n\
           (opclause record ((pwild)) k\n\
           (match (app (var get))\n\
           (clause (ptuple (pwild) (pvar count))\n\
           (tuple (lit \"audit-refused\") (var count))))))"
          gate)
  in
  Alcotest.(check string)
    "pre-audit refusal leaves position zero available" "ok((\"audit-refused\", 0))"
    (eval_show ctx store source);
  assert_probe_counts live approval simulator summarizer (0, 0, 0, 0)

let test_completion_failure_precedes_disposition () =
  let store, ctx, live, approval, simulator, summarizer = probe_ctx () in
  let source =
    probe_gate (fun gate ->
        Printf.sprintf
          "(handle %s (ret (pvar value) (var value))\n\
           (opclause record ((pwild)) k\n\
           (match (app (var get))\n\
           (clause (ptuple (pwild) (pvar count))\n\
           (match (app (var eq) (var count) (lit 0))\n\
           (clause (pcon true) (app (var k) (tuple)))\n\
           (clause (pcon false)\n\
           (tuple (lit \"completion-refused\") (var count))))))))"
          gate)
  in
  let shown = eval_show ctx store source in
  Alcotest.(check string)
    "completion refusal leaves position one unconsumed" "ok((\"completion-refused\", 1))" shown;
  assert_probe_counts live approval simulator summarizer (0, 0, 1, 1)

let test_verifier_preconditions_refuse_before_audit () =
  let store, ctx, live, approval, simulator, summarizer = probe_ctx () in
  let run setup subject =
    wrap_fixture
      (Printf.sprintf
         "(let nonrec (pvar invalid-subject) %s\n\
          (app (var governance.with-sequence) (lam ((pvar sequence))\n\
          (app (var governance.gate-dry) (var sequence) %s\n\
          (app (var some) (var gm6.simulator-probe)) (var gm6.summarizer-probe)))))"
         setup subject)
    |> eval_show ctx store
  in
  let invalid_call =
    "(app (var governance-call-v0) (var governance-v0) (var fixture-hash)\n\
     (var fixture-hash) (lit \"fs.write\") (quote (arguments (lit 7)))\n\
     (var authority) (lit \"dry write\") (quote (preconditions)) (var none))"
  in
  Alcotest.(check string)
    "malformed Call is a defensive unaudited refusal" "ok(refuse-dry(invalid-decision))"
    (run invalid_call "(var policy) (var invalid-subject)");
  let invalid_policy =
    "(app (var bound-policy-v0) (var governance-v0) (var fixture-hash)\n\
     (app (var dry-policy-v0) (var governance-v0) (lit 0.5)))"
  in
  Alcotest.(check string)
    "malformed BoundPolicy is a defensive unaudited refusal" "ok(refuse-dry(invalid-decision))"
    (run invalid_policy "(var invalid-subject) (var call)");
  assert_probe_counts live approval simulator summarizer (0, 0, 0, 0)

let suite =
  [
    Alcotest.test_case "exact frozen row and local Resume" `Quick
      test_exact_world_free_signature_and_local_resume;
    Alcotest.test_case "risk/confidence matrix and counters" `Quick
      test_risk_confidence_matrix_and_counters;
    Alcotest.test_case "fresh sequence owner and escape rejection" `Quick
      test_sequence_owner_freshness_and_escape_rejection;
    Alcotest.test_case "pre-audit refusal prevents action" `Quick
      test_pre_audit_failure_prevents_action;
    Alcotest.test_case "completion refusal precedes disposition" `Quick
      test_completion_failure_precedes_disposition;
    Alcotest.test_case "verifier preconditions refuse before audit" `Quick
      test_verifier_preconditions_refuse_before_audit;
  ]
