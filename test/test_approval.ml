open Jacquard

(* ET.6: exact review-artifact identity and decision binding. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_value source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error -> Alcotest.failf "Approval evaluation failed: %s" (Runtime_err.to_string error)

let show source = Value.show (eval_value source)
let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let call_hash = String.make 64 'a'
let policy_hash = String.make 64 'b'
let assessment_hash = String.make 64 'c'
let alternate_hash = String.make 64 'd'
let preview_hash = String.make 64 'e'

let hash value =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (var parsed)))"
    (qtext value)

let authority =
  "(app (var cons) (app (var effect) (lit \"Net\")) (app (var cons) (app (var resource) (lit \
   \"Net\") (lit \"api.example\")) (var nil)))"

let preview =
  Printf.sprintf "(app (var some) (app (var outcome-summary) (lit \"simulated\") %s (lit \"ok\")))"
    (hash preview_hash)

let proposal ?(call = call_hash) ?(policy = policy_hash) ?(assessment = assessment_hash)
    ?(authority = authority) ?(rendering = "(quote (review (lit \"ship\")))") ?(summary = "ship?")
    ?(preview = preview) () =
  Printf.sprintf "(app (var approval.make-proposal) %s %s %s %s %s (lit %s) %s)" (hash call)
    (hash policy) (hash assessment) authority rendering (qtext summary) preview

let proposal_id source =
  show (Printf.sprintf "(app (var hash.to-text) (app (var approval.proposal-id) %s))" source)

let check_expr source =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make Approval checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register Approval builtins" diagnostics);
  match Reader.parse_one ~file:"approval-malformed.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top checker (Kernel.Expr expression)))

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing released Approval name %s" name

let test_released_identity_and_once_mode () =
  let approval = lookup "approval" Resolve.KEffect in
  ignore (lookup "ask" Resolve.KOp);
  ignore (lookup "proposal" Resolve.KType);
  ignore (lookup "proposal" Resolve.KCon);
  Alcotest.(check string)
    "released Approval interface hash"
    "362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196" (Hash.to_hex approval);
  Alcotest.(check string)
    "ET.2 Decision identity remains stable"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c"
    (Hash.to_hex (lookup "decision" Resolve.KType));
  Alcotest.(check string)
    "ET.2 Audit identity remains stable"
    "2c148fbc2e26bdc6f01279a8bf176f54d5798536e1f96805aa4f7c7a57e67632"
    (Hash.to_hex (lookup "audit" Resolve.KEffect));
  match Store.locate store approval with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops = [ operation ]; _ }; _ }; _ } ->
      Alcotest.(check bool) "Approval.ask is once" true (operation.op_mode = Kernel.Once)
  | Ok _ -> Alcotest.fail "Approval identity did not locate to its one-operation declaration"
  | Error diagnostics -> Eval_support.fail_diags "locate Approval" diagnostics

let expected_wire =
  Printf.sprintf
    "(proposal-v1 (hash #%s) (hash #%s) (hash #%s) (authority-list-v1 (effect-v1 (lit \"Net\")) \
     (resource-v1 (lit \"Net\") (lit \"api.example\"))) (review (lit \"ship\")) (lit \"ship?\") \
     (some-v1 (outcome-summary-v1 (lit \"simulated\") (hash #%s) (lit \"ok\"))))"
    call_hash policy_hash assessment_hash preview_hash

let test_canonical_encoding_and_hash_golden () =
  let value = proposal () in
  let rendered =
    show (Printf.sprintf "(app (var code.render) (app (var approval.proposal-code) %s))" value)
  in
  Alcotest.(check string) "single typed proposal-v1 encoding" (qtext expected_wire) rendered;
  let expected = "6077e8595a8a9c8ae142789cf66c55672c30a7687388c8d41f763fc0ec74dada" in
  Alcotest.(check string) "proposal HASH_V0 golden" (qtext expected) (proposal_id value);
  Alcotest.(check string)
    "safe constructor validates its carried identity"
    (Printf.sprintf "ok(#%s)" expected)
    (show (Printf.sprintf "(app (var approval.validate-proposal) %s)" value))

let test_every_review_field_changes_identity () =
  let base = proposal_id (proposal ()) in
  let variants =
    [
      ("call subject", proposal ~call:alternate_hash ());
      ("policy", proposal ~policy:alternate_hash ());
      ("assessment", proposal ~assessment:alternate_hash ());
      ( "authority",
        proposal ~authority:"(app (var cons) (app (var effect) (lit \"Fs\")) (var nil))" () );
      ("rendering", proposal ~rendering:"(quote (review (lit \"hold\")))" ());
      ("summary", proposal ~summary:"hold?" ());
      ("preview", proposal ~preview:"(var none)" ());
    ]
  in
  List.iter
    (fun (label, value) ->
      Alcotest.(check bool)
        (label ^ " invalidates approval") false
        (String.equal base (proposal_id value)))
    variants

let test_call_metadata_is_not_review_identity () =
  let expression =
    Printf.sprintf
      "(let nonrec (pvar first-call) (app (var code.hash) (quote (call (lit \"same\")))) (let \
       nonrec (pvar second-call) (app (var code.hash) (quote (call (lit \"same\")))) (tuple (app \
       (var hash.to-text) (var first-call)) (app (var hash.to-text) (var second-call)) (app (var \
       hash.to-text) (app (var approval.proposal-id) (app (var approval.make-proposal) (var \
       first-call) %s %s %s (quote (render (lit \"same\"))) (lit \"same\") (var none)))) (app (var \
       hash.to-text) (app (var approval.proposal-id) (app (var approval.make-proposal) (var \
       second-call) %s %s %s (quote (render (lit \"same\"))) (lit \"same\") (var none)))))))"
      (hash policy_hash) (hash assessment_hash) authority (hash policy_hash) (hash assessment_hash)
      authority
  in
  match eval_value expression with
  | Value.VTuple
      [ Value.VText first_call; Value.VText second_call; Value.VText first; Value.VText second ] ->
      Alcotest.(check string)
        "span-distinct quotes retain semantic call identity" first_call second_call;
      Alcotest.(check string) "metadata-only call changes retain proposal identity" first second
  | value -> Alcotest.failf "metadata identity witness returned %s" (Value.show value)

let test_malformed_and_hashless_rejected () =
  let valid = proposal () in
  let forged =
    Printf.sprintf
      "(app (var proposal) %s %s %s %s %s (quote (review (lit \"ship\"))) (lit \"ship?\") %s)"
      (hash alternate_hash) (hash call_hash) (hash policy_hash) (hash assessment_hash) authority
      preview
  in
  Alcotest.(check string)
    "forged carried hash fails closed"
    "err(\"invalid Proposal: carried proposal hash does not match canonical proposal-v1 bytes\")"
    (show (Printf.sprintf "(app (var approval.validate-proposal) %s)" forged));
  let hashless =
    Printf.sprintf
      "(app (var proposal) (lit \"missing\") %s %s %s %s (quote (render)) (lit \"summary\") (var \
       none))"
      (hash call_hash) (hash policy_hash) (hash assessment_hash) authority
  in
  (match check_expr hashless with
  | Error diagnostics ->
      Alcotest.(check bool)
        "hashless proposal gets a checker diagnostic" true
        (List.exists (fun diagnostic -> String.equal diagnostic.Diag.code "E0801") diagnostics)
  | Ok _ -> Alcotest.fail "hashless Proposal typechecked");
  ignore valid

let test_decision_binding_precedes_action () =
  let value = proposal () in
  let exact = Printf.sprintf "(app (var approval.proposal-id) %s)" value in
  List.iter
    (fun decision ->
      Alcotest.(check bool)
        "exact Decision binding validates" true
        (String.starts_with ~prefix:"ok("
           (show (Printf.sprintf "(app (var approval.validate-decision) %s %s)" value decision))))
    [
      Printf.sprintf "(app (var approved) %s (lit \"reviewer\") (quote (ticket)))" exact;
      Printf.sprintf "(app (var denied) %s (lit \"reviewer\") (lit \"no\"))" exact;
      Printf.sprintf "(app (var escalate) %s (lit \"later\"))" exact;
    ];
  let stale =
    Printf.sprintf "(app (var approved) %s (lit \"reviewer\") (quote (ticket)))"
      (hash alternate_hash)
  in
  Alcotest.(check string)
    "mismatched Decision is rejected"
    "err(\"stale Decision: embedded proposal hash does not match the exact review artifact\")"
    (show (Printf.sprintf "(app (var approval.validate-decision) %s %s)" value stale));
  let run decision =
    Printf.sprintf
      "(app (var state.run) (lam () (app (var approval.before-action) %s %s (lam () (let nonrec \
       (pwild) (app (var put) (lit 1)) (lit 42))))) (lit 0))"
      value decision
  in
  Alcotest.(check string)
    "stale binding cannot run action"
    "(err(\"stale Decision: embedded proposal hash does not match the exact review artifact\"), 0)"
    (show (run stale));
  let approved =
    Printf.sprintf "(app (var approved) %s (lit \"reviewer\") (quote (ticket)))" exact
  in
  Alcotest.(check string) "valid binding runs action once" "(ok(42), 1)" (show (run approved))

let prop_code_hash_ignores_metadata =
  QCheck.Test.make ~count:100 ~name:"code HASH_V0 ignores all Form metadata"
    QCheck.(make Gen.(string_size ~gen:printable (int_bound 32)))
    (fun origin ->
      let plain = Form.form "proposal-input" [ Form.Text "same" ] in
      let changed =
        Form.form
          ~meta:(Meta.add Meta.key_origin (Meta.Text origin) Meta.empty)
          "proposal-input" [ Form.Text "same" ]
      in
      Hash.equal
        (Hash.of_string (Printer.print_compact plain))
        (Hash.of_string (Printer.print_compact changed)))

let suite =
  [
    Alcotest.test_case "released identity and once mode" `Quick test_released_identity_and_once_mode;
    Alcotest.test_case "canonical proposal hash golden" `Quick
      test_canonical_encoding_and_hash_golden;
    Alcotest.test_case "all review fields invalidate" `Quick
      test_every_review_field_changes_identity;
    Alcotest.test_case "call metadata stability" `Quick test_call_metadata_is_not_review_identity;
    Alcotest.test_case "malformed and hashless refusal" `Quick test_malformed_and_hashless_rejected;
    Alcotest.test_case "decision validation before action" `Quick
      test_decision_binding_precedes_action;
    QCheck_alcotest.to_alcotest prop_code_hash_ignores_metadata;
  ]
