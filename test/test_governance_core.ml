open Jacquard

(* GM.1: versioned membrane values, pure refusal paths, and hash-bound artifacts. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_value source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "governance core evaluation failed: %s\nsource: %s"
        (Runtime_err.to_string error) source

let show source = Value.show (eval_value source)
let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let hash_a = String.make 64 'a'
let hash_b = String.make 64 'b'
let hash_c = String.make 64 'c'
let hash_d = String.make 64 'd'

let hash value =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (var parsed)))"
    (qtext value)

let authority_effect ?(id = hash_a) () = Printf.sprintf "(app (var governance-effect) %s)" (hash id)

let resource ?(effect_id = hash_a) ?(scope = "bucket/a") ?(configuration = hash_b) () =
  Printf.sprintf "(app (var governance-resource) %s (lit %s) %s)" (hash effect_id) (qtext scope)
    (hash configuration)

let list values =
  List.fold_right
    (fun value tail -> Printf.sprintf "(app (var cons) %s %s)" value tail)
    values "(var nil)"

let authority = list [ authority_effect (); resource () ]

let make_call ?(operation_name = "fs.write") ?(arguments = "(quote (arguments (lit 7)))")
    ?(authority = authority) ?(summary = "write one object")
    ?(preconditions = "(quote (preconditions (lit \"fresh\")))") ?(parent = "(var none)") () =
  Printf.sprintf "(app (var governance.make-call) (lit %s) %s %s (lit %s) %s %s)"
    (qtext operation_name) arguments authority (qtext summary) preconditions parent

let unwrap_ok expression =
  Printf.sprintf
    "(match %s (clause (pcon ok (pvar value)) (var value)) (clause (pcon err (pvar message)) (var \
     message)))"
    expression

let resolved_operation name =
  unwrap_ok (Printf.sprintf "(app (var governance.resolve-operation-id) (lit %s))" (qtext name))

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.failf "missing GM.1 name %s" name

let test_schema_and_frozen_identities () =
  List.iter
    (fun name -> ignore (lookup name Resolve.KType))
    [
      "governance-version";
      "tool-error";
      "governance-authority";
      "governance-call";
      "governance-assessment";
      "governance-outcome-summary";
      "live-policy";
      "dry-policy";
      "stored-policy";
      "bound-policy";
    ];
  Alcotest.(check string)
    "ET.6 Approval identity unchanged"
    "362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196"
    (Hash.to_hex (lookup "approval" Resolve.KEffect));
  Alcotest.(check string)
    "ET.2 Decision identity unchanged"
    "4d07b0003ce00355c129e894d589c0626bc7ccb3230305537c908a37d5012e4c"
    (Hash.to_hex (lookup "decision" Resolve.KType));
  Alcotest.(check string)
    "ET.6 Proposal identity unchanged"
    "5eff01f74c47214e9c4ebec752a75959ddb0bb4fb34a5cc5d5bb58c0e47dc9b7"
    (Hash.to_hex (lookup "proposal" Resolve.KType));
  Alcotest.(check string)
    "existing code.hash identity unchanged"
    "83b76604ebb921438d4ff5ae92173fad8c1d527dc91ae1e39c419ad5310d0c44"
    (Hash.to_hex (lookup "code.hash" Resolve.KTerm));
  Alcotest.(check string)
    "GM.1 GovernanceCall identity unchanged"
    "20824137b34985dabf9e6bb0c20cf9987c1ca93b5cdd8d1da60cbc69550efc27"
    (Hash.to_hex (lookup "governance-call" Resolve.KType));
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string)
        (name ^ " identity unchanged") expected
        (Hash.to_hex (lookup name Resolve.KType)))
    [
      ("live-policy", "313c11b97a460ed1c4b2fc3c215dc76e3af85378f9ec2146604094acf0fe9269");
      ("dry-policy", "465569b1f1b94025f3e40d3efe4fc99cd780e887fe1366da8b74011a810ffae1");
      ("stored-policy", "f520783c93ebab3648d5996bc431c78e3a0e6e11135ec73424531e67fb7928f7");
      ("bound-policy", "71eba002ffd98c2be9d0bf74e9bce53275ba87c763367450f8bef74a439fbf82");
      ("governance-proposal", "c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8");
    ];
  ignore (lookup "governance.resolve-operation-id" Resolve.KTerm)

let test_confidence_and_policy_refusals () =
  List.iter
    (fun (label, confidence) ->
      List.iter
        (fun (constructor, expression) ->
          Alcotest.(check bool)
            (label ^ " rejected by " ^ constructor)
            true
            (String.starts_with ~prefix:"err(" (show expression)))
        [
          ( "Assessment",
            Printf.sprintf
              "(app (var governance.make-assessment) (var low) %s (var nil) (quote (evidence)))"
              confidence );
          ( "LivePolicy",
            Printf.sprintf "(app (var governance.make-live-policy) (var low) (var high) %s)"
              confidence );
          ("DryPolicy", Printf.sprintf "(app (var governance.make-dry-policy) %s)" confidence);
        ])
    [
      ("negative confidence", "(lit -0.01)");
      ("confidence above one", "(lit 1.01)");
      ("NaN confidence", "(app (var real.div) (lit 0.0) (lit 0.0))");
      ("infinite confidence", "(app (var real.div) (lit 1.0) (lit 0.0))");
    ];
  Alcotest.(check string)
    "inclusive confidence endpoints"
    "(ok(governance-assessment-v0(governance-v0, low, 0.0, nil, (quote (evidence)))), \
     ok(governance-assessment-v0(governance-v0, high, 1.0, nil, (quote (evidence)))))"
    (show
       "(tuple (app (var governance.make-assessment) (var low) (lit 0.0) (var nil) (quote \
        (evidence))) (app (var governance.make-assessment) (var high) (lit 1.0) (var nil) (quote \
        (evidence))))");
  List.iter
    (fun (label, expression) ->
      Alcotest.(check bool) label true (String.starts_with ~prefix:"ok(" (show expression)))
    [
      ( "live confidence endpoint zero",
        "(app (var governance.make-live-policy) (var low) (var high) (lit 0.0))" );
      ( "live confidence endpoint one",
        "(app (var governance.make-live-policy) (var low) (var high) (lit 1.0))" );
      ("dry confidence endpoint zero", "(app (var governance.make-dry-policy) (lit 0.0))");
      ("dry confidence endpoint one", "(app (var governance.make-dry-policy) (lit 1.0))");
    ];
  Alcotest.(check string)
    "reversed live thresholds refused" "err(\"invalid LivePolicy: auto-up-to exceeds ask-up-to\")"
    (show "(app (var governance.make-live-policy) (var high) (var low) (lit 0.5))");
  Alcotest.(check bool)
    "verifier catches directly constructed invalid assessment" true
    (String.starts_with ~prefix:"err("
       (show
          "(app (var governance.validate-assessment) (app (var governance-assessment-v0) (var \
           governance-v0) (var low) (app (var real.div) (lit 0.0) (lit 0.0)) (var nil) (quote \
           (evidence))))"));
  Alcotest.(check bool)
    "verifier catches directly constructed invalid live policy" true
    (String.starts_with ~prefix:"err("
       (show
          "(app (var governance.validate-live-policy) (app (var live-policy-v0) (var \
           governance-v0) (var high) (var low) (lit 0.5)))"));
  Alcotest.(check bool)
    "verifier catches directly constructed invalid dry policy" true
    (String.starts_with ~prefix:"err("
       (show
          "(app (var governance.validate-dry-policy) (app (var dry-policy-v0) (var governance-v0) \
           (app (var real.div) (lit 1.0) (lit 0.0))))"))

let test_operation_name_table () =
  let malformed =
    Corpus_support.read_file "../corpus/governance/malformed-operation-names.tsv"
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
        if String.equal line "" || String.starts_with ~prefix:"#" line then None
        else
          match String.split_on_char '\t' line with
          | [ label; "<empty>" ] -> Some (label, "")
          | [ label; name ] -> Some (label, name)
          | _ -> Alcotest.failf "malformed governance corpus row: %s" line)
  in
  let unresolved =
    Corpus_support.read_file "../corpus/governance/unresolved-operations.tsv"
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
        if String.equal line "" || String.starts_with ~prefix:"#" line then None
        else
          match String.split_on_char '\t' line with
          | [ label; name ] -> Some (label, name)
          | _ -> Alcotest.failf "malformed unresolved-operation corpus row: %s" line)
  in
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string)
        name expected
        (show (Printf.sprintf "(app (var governance.valid-operation-name?) (lit %s))" (qtext name))))
    [ ("fs.write", "true"); ("net.fetch?", "true"); ("clock.sleep-until!", "true") ];
  List.iter
    (fun (label, name) ->
      Alcotest.(check string)
        label "false"
        (show (Printf.sprintf "(app (var governance.valid-operation-name?) (lit %s))" (qtext name))))
    malformed;
  Alcotest.(check string)
    "constructor shares operation-name refusal"
    "err(\"invalid Call: operation name is empty or noncanonical\")"
    (show (make_call ~operation_name:"Fs.write" ()));
  let write_id = Hash.to_hex (lookup "write" Resolve.KOp) in
  Alcotest.(check string)
    "exact resolved Fs.write operation identity"
    (Printf.sprintf "ok(#%s)" write_id)
    (show "(app (var governance.resolve-operation-id) (lit \"fs.write\"))");
  let async_spawn_id = Hash.to_hex (lookup "async.spawn" Resolve.KOp) in
  Alcotest.(check string)
    "dotted Async operation resolves after the first qualifier separator"
    (Printf.sprintf "ok(#%s)" async_spawn_id)
    (show "(app (var governance.resolve-operation-id) (lit \"async.async.spawn\"))");
  Alcotest.(check bool)
    "shortened dotted Async operation is not silently reinterpreted" true
    (String.starts_with ~prefix:"err("
       (show "(app (var governance.resolve-operation-id) (lit \"async.spawn\"))"));
  List.iter
    (fun (label, operation_name) ->
      Alcotest.(check bool)
        label true
        (String.starts_with ~prefix:"err(" (show (make_call ~operation_name ()))))
    unresolved

let test_authority_refusal_table () =
  let net = Hash.to_hex (lookup "net" Resolve.KEffect) in
  let secret = Hash.to_hex (lookup "secret" Resolve.KEffect) in
  let order_key identity =
    show (Printf.sprintf "(app (var governance.effect-order-key) %s)" (hash identity))
  in
  let unknown_a_key = order_key hash_a in
  let unknown_b_key = order_key hash_b in
  List.iteri
    (fun position (entry : Effect_registry.metadata) ->
      match entry.interface with
      | Effect_registry.Released { hash = identity; _ } ->
          let hex = Hash.to_hex identity in
          let expected = qtext (Printf.sprintf "0:%08d:%s" position hex) in
          let actual = order_key hex in
          Alcotest.(check string)
            (Printf.sprintf "%s exact frozen order key" entry.display_name)
            expected actual;
          Alcotest.(check bool)
            (Printf.sprintf "%s sorts before unknown fallback" entry.display_name)
            true
            (String.compare actual unknown_a_key < 0)
      | Effect_registry.Reserved _ -> ())
    Effect_registry.catalog;
  Alcotest.(check string)
    "unknown fallback key is canonical and deterministic"
    (qtext ("1:" ^ hash_a))
    unknown_a_key;
  Alcotest.(check bool)
    "unknown fallback retains hash order" true
    (String.compare unknown_a_key unknown_b_key < 0);
  let validate value = show (Printf.sprintf "(app (var governance.validate-authority) %s)" value) in
  let strict_order_error =
    "err(\"invalid Authority: entries must be in strict canonical order without duplicates\")"
  in
  let malformed =
    [
      ( "resource without effect",
        "err(\"invalid Authority: Resource must refine a preceding Effect\")",
        list [ resource () ] );
      ( "resource for a different preceding effect",
        "err(\"invalid Authority: Resource must refine a preceding Effect\")",
        list [ authority_effect (); resource ~effect_id:hash_b () ] );
      ( "empty resource scope",
        "err(\"invalid Authority: Resource scope is empty\")",
        list [ authority_effect (); resource ~scope:"" () ] );
      ("duplicate effect", strict_order_error, list [ authority_effect (); authority_effect () ]);
      ( "duplicate resource",
        strict_order_error,
        list [ authority_effect (); resource (); resource () ] );
      ( "unknown effect reverse order",
        strict_order_error,
        list [ authority_effect ~id:hash_b (); authority_effect ~id:hash_a () ] );
      ( "reversed blessed taxonomy order",
        strict_order_error,
        list [ authority_effect ~id:secret (); authority_effect ~id:net () ] );
      ( "resource scope reverse order",
        strict_order_error,
        list [ authority_effect (); resource ~scope:"scope/b" (); resource ~scope:"scope/a" () ] );
      ( "resource delimiter-prefix reverse order",
        strict_order_error,
        list
          [
            authority_effect ();
            resource ~scope:"a::" ();
            resource ~scope:"a:" ();
            resource ~scope:"a" ();
          ] );
      ( "resource configuration reverse order",
        strict_order_error,
        list
          [
            authority_effect ();
            resource ~scope:"scope/a" ~configuration:hash_b ();
            resource ~scope:"scope/a" ~configuration:hash_a ();
          ] );
    ]
  in
  List.iter
    (fun (label, expected, value) -> Alcotest.(check string) label expected (validate value))
    malformed;
  Alcotest.(check bool)
    "canonical envelope accepted" true
    (String.starts_with ~prefix:"ok(" (validate authority));
  Alcotest.(check bool)
    "Net then Secret follows frozen taxonomy order" true
    (String.starts_with ~prefix:"ok("
       (validate (list [ authority_effect ~id:net (); authority_effect ~id:secret () ])));
  Alcotest.(check bool)
    "unknown fallback accepts ascending hashes" true
    (String.starts_with ~prefix:"ok("
       (validate (list [ authority_effect (); authority_effect ~id:hash_b () ])));
  Alcotest.(check bool)
    "Resource entries are adjacent and bytewise ordered across prefix/delimiter scopes then \
     configuration"
    true
    (String.starts_with ~prefix:"ok("
       (validate
          (list
             [
               authority_effect ();
               resource ~scope:"a" ~configuration:hash_a ();
               resource ~scope:"a" ~configuration:hash_b ();
               resource ~scope:"a:" ~configuration:hash_a ();
               resource ~scope:"a::" ~configuration:hash_a ();
               authority_effect ~id:hash_b ();
             ])))

let call_id call =
  show
    (Printf.sprintf "(app (var hash.to-text) (app (var governance.call-id) %s))" (unwrap_ok call))

let live_policy =
  "(match (app (var governance.make-live-policy) (var low) (var high) (lit 0.75)) (clause (pcon ok \
   (pvar policy)) (var policy)))"

let bound_live_policy =
  unwrap_ok (Printf.sprintf "(app (var governance.bind-live-policy) %s)" live_policy)

let assessment ?(risk = "medium") ?(confidence = "0.8") ?(evidence = "(quote (evidence))") () =
  unwrap_ok
    (Printf.sprintf
       "(app (var governance.make-assessment) (var %s) (lit %s) (app (var cons) (lit \"reviewed\") \
        (var nil)) %s)"
       risk confidence evidence)

let outcome ?(status = "simulated") ?(digest = hash_c) ?(detail = "safe preview") () =
  unwrap_ok
    (Printf.sprintf "(app (var governance.make-outcome-summary) (lit %s) %s (lit %s))"
       (qtext status) (hash digest) (qtext detail))

let preview = Printf.sprintf "(app (var some) %s)" (outcome ())

let make_proposal ?(call = make_call ()) ?(bound_policy = bound_live_policy)
    ?(assessment = assessment ()) ?(rendering = "(quote (review (lit \"ship\")))")
    ?(summary = "ship?") ?(preview = preview) () =
  Printf.sprintf "(app (var governance.make-proposal) %s %s %s %s (lit %s) %s)" (unwrap_ok call)
    bound_policy assessment rendering (qtext summary) preview

let proposal_id proposal =
  show
    (Printf.sprintf "(app (var hash.to-text) (app (var governance.proposal-id) %s))"
       (unwrap_ok proposal))

let canonical_proposal ?(call_id = hash_a) ?(policy_id = hash_b) ?(assessment_id = hash_c)
    ?(authority = authority) ?(rendering = "(quote (review (lit \"ship\")))") ?(summary = "ship?")
    ?(preview = preview) () =
  Printf.sprintf "(app (var governance.make-proposal-canonical) %s %s %s %s %s (lit %s) %s)"
    (hash call_id) (hash policy_id) (hash assessment_id) authority rendering (qtext summary) preview

let canonical_proposal_id value =
  show (Printf.sprintf "(app (var hash.to-text) (app (var governance.proposal-id) %s))" value)

let test_call_hash_and_verifier () =
  let base = make_call () in
  let base_id = call_id base in
  Alcotest.(check bool)
    "different resolved operation changes subject identity" false
    (String.equal base_id (call_id (make_call ~operation_name:"fs.read" ())));
  Alcotest.(check string)
    "display summary excluded from subject identity" base_id
    (call_id (make_call ~summary:"safe alternate wording" ()));
  Alcotest.(check bool)
    "arguments remain subject identity" false
    (String.equal base_id (call_id (make_call ~arguments:"(quote (arguments (lit 8)))" ())));
  Alcotest.(check bool)
    "safe constructor validates" true
    (String.starts_with ~prefix:"ok(#"
       (show (Printf.sprintf "(app (var governance.validate-call) %s)" (unwrap_ok base))));
  let forged =
    Printf.sprintf
      "(app (var governance-call-v0) (var governance-v0) %s %s (lit \"fs.write\") (quote \
       (arguments (lit 7))) %s (lit \"write one object\") (quote (preconditions (lit \"fresh\"))) \
       (var none))"
      (hash hash_d) (resolved_operation "fs.write") authority
  in
  Alcotest.(check string)
    "forged call hash refused"
    "err(\"invalid Call: carried call hash does not match canonical governance-call-v0 bytes\")"
    (show (Printf.sprintf "(app (var governance.validate-call) %s)" forged));
  let forged_operation =
    Printf.sprintf
      "(app (var governance-call-v0) (var governance-v0) %s %s (lit \"fs.write\") (quote \
       (arguments (lit 7))) %s (lit \"write one object\") (quote (preconditions (lit \"fresh\"))) \
       (var none))"
      (hash hash_d) (hash hash_c) authority
  in
  Alcotest.(check string)
    "forged operation hash refused before Call hash"
    "err(\"invalid Call: operation hash does not match the resolved exact operation\")"
    (show (Printf.sprintf "(app (var governance.validate-call) %s)" forged_operation));
  let rendered =
    show
      (Printf.sprintf "(app (var code.render) (app (var governance.call-code) %s))" (unwrap_ok base))
  in
  let operation_id = Hash.to_hex (lookup "write" Resolve.KOp) in
  let expected_wire =
    Printf.sprintf
      "(governance-call-v0 (governance-v0) (hash #%s) (arguments (lit 7)) \
       (governance-authority-list-v0 (governance-effect-v0 (hash #%s)) (governance-resource-v0 \
       (hash #%s) (lit \"bucket/a\") (hash #%s))) (preconditions (lit \"fresh\")) (none-v0))"
      operation_id hash_a hash_a hash_b
  in
  Alcotest.(check string) "canonical Call semantic wire" (qtext expected_wire) rendered;
  Alcotest.(check string)
    "Call HASH_V0 golden" "\"9426cb4c99c5120487c8c421f948c1de6b4425d2a859a6de2536bd85c6136a85\""
    base_id

let test_proposal_hash_and_verifier () =
  ignore (lookup "governance-proposal" Resolve.KType);
  let call = make_call () in
  let proposal = make_proposal ~call () in
  let value = unwrap_ok proposal in
  let rendered =
    show (Printf.sprintf "(app (var code.render) (app (var governance.proposal-code) %s))" value)
  in
  let expected_wire =
    Printf.sprintf
      "(governance-proposal-v0 (governance-v0) (hash #%s) (hash #%s) (hash #%s) \
       (governance-authority-list-v0 (governance-effect-v0 (hash #%s)) (governance-resource-v0 \
       (hash #%s) (lit \"bucket/a\") (hash #%s))) (some-v0 (governance-outcome-summary-v0 \
       (governance-v0) (lit \"simulated\") (hash #%s) (lit \"safe preview\"))) (review (lit \
       \"ship\")) (lit \"ship?\"))"
      "9426cb4c99c5120487c8c421f948c1de6b4425d2a859a6de2536bd85c6136a85"
      "90b89e26cc677201a904cc1757be0b78814aea45d13cbcd3fd66c9be56927e52"
      "a2d62fccd52d599b99bd2a595b386b351c1cb7bf033537aa31fd396cd9c9761b" hash_a hash_a hash_b hash_c
  in
  Alcotest.(check string) "Proposal canonical wire golden" (qtext expected_wire) rendered;
  let expected = "88e2c60b4e97c732917fc99a3e7a05eb85e79295fcfed053cae3a5b5421fd26e" in
  Alcotest.(check string) "Proposal HASH_V0 golden" (qtext expected) (proposal_id proposal);
  Alcotest.(check string)
    "safe Proposal validates exact artifacts"
    (Printf.sprintf "ok(#%s)" expected)
    (show
       (Printf.sprintf "(app (var governance.validate-proposal-artifacts) %s %s %s %s)"
          (unwrap_ok call) bound_live_policy (assessment ()) value));
  let forged =
    Printf.sprintf
      "(app (var governance-proposal-v0) (var governance-v0) %s %s %s %s (quote (review (lit \
       \"ship\"))) (lit \"ship?\") %s %s)"
      (hash hash_d) (hash hash_a) (hash hash_b) (hash hash_c) authority preview
  in
  Alcotest.(check string)
    "forged Proposal hash refused"
    "err(\"invalid Proposal: carried proposal hash does not match canonical governance-proposal-v0 \
     bytes\")"
    (show (Printf.sprintf "(app (var governance.validate-proposal) %s)" forged));
  let divergent_authority = list [ authority_effect ~id:hash_c () ] in
  let mismatched =
    Printf.sprintf
      "(app (var governance.make-proposal-canonical) (app (var governance.call-id) %s) (app (var \
       governance.bound-policy-id) %s) (app (var governance.assessment-id) %s) %s (quote (review \
       (lit \"ship\"))) (lit \"ship?\") %s)"
      (unwrap_ok call) bound_live_policy (assessment ()) divergent_authority preview
  in
  Alcotest.(check string)
    "cross-artifact authority mismatch refused"
    "err(\"invalid Proposal: authority does not match the validated Call\")"
    (show
       (Printf.sprintf "(app (var governance.validate-proposal-artifacts) %s %s %s %s)"
          (unwrap_ok call) bound_live_policy (assessment ()) mismatched))

let dry_policy =
  "(match (app (var governance.make-dry-policy) (lit 0.75)) (clause (pcon ok (pvar policy)) (var \
   policy)))"

let bound_dry_policy =
  unwrap_ok (Printf.sprintf "(app (var governance.bind-dry-policy) %s)" dry_policy)

let risk_names = [| "low"; "medium"; "high"; "forbidden" |]

let expected_live_verdict ~auto ~ask ~risk ~confidence =
  if risk = 3 then "ok(block)"
  else if confidence < 0.75 then if risk <= ask then "ok(ask)" else "ok(block)"
  else if risk <= auto then "ok(allow)"
  else if risk <= ask then "ok(ask)"
  else "ok(block)"

let test_policy_laws_and_bound_verifier () =
  List.iter
    (fun (label, expression, expected) -> Alcotest.(check string) label expected (show expression))
    [
      ( "live auto",
        Printf.sprintf "(app (var governance.live-verdict) %s (var low) (lit 0.9))" live_policy,
        "allow" );
      ( "live ask",
        Printf.sprintf "(app (var governance.live-verdict) %s (var medium) (lit 0.9))" live_policy,
        "ask" );
      ( "under confidence never allow",
        Printf.sprintf "(app (var governance.live-verdict) %s (var low) (lit 0.5))" live_policy,
        "ask" );
      ( "forbidden blocks",
        Printf.sprintf "(app (var governance.live-verdict) %s (var forbidden) (lit 1.0))"
          live_policy,
        "block" );
      ( "dry simulates",
        Printf.sprintf "(app (var governance.dry-verdict) %s (var low) (var true))" dry_policy,
        "ok(simulate)" );
      ( "dry lacks simulator",
        Printf.sprintf "(app (var governance.dry-verdict) %s (var low) (var false))" dry_policy,
        "err(no-simulation)" );
      ( "dry forbidden",
        Printf.sprintf "(app (var governance.dry-verdict) %s (var forbidden) (var true))" dry_policy,
        "ok(block)" );
    ];
  List.iter
    (fun (label, encoder, value, expected_hash) ->
      Alcotest.(check string)
        (label ^ " HASH_V0") (qtext expected_hash)
        (show
           (Printf.sprintf "(app (var hash.to-text) (app (var code.hash) (app (var %s) %s)))"
              encoder value)))
    [
      ( "live policy",
        "governance.live-policy-code",
        live_policy,
        "90b89e26cc677201a904cc1757be0b78814aea45d13cbcd3fd66c9be56927e52" );
      ( "dry policy",
        "governance.dry-policy-code",
        dry_policy,
        "60c734f066602ee2c7846ed4b4ead349bd3820077508a6de771b2a6cfe9396a1" );
    ];
  let bound = Printf.sprintf "(app (var governance.bind-live-policy) %s)" live_policy in
  Alcotest.(check string)
    "canonical bound policy validates exact hash"
    "ok(#90b89e26cc677201a904cc1757be0b78814aea45d13cbcd3fd66c9be56927e52)"
    (show (Printf.sprintf "(app (var governance.validate-bound-live-policy) %s)" (unwrap_ok bound)));
  Alcotest.(check string)
    "canonical dry bound policy validates exact hash"
    "ok(#60c734f066602ee2c7846ed4b4ead349bd3820077508a6de771b2a6cfe9396a1)"
    (show (Printf.sprintf "(app (var governance.validate-bound-dry-policy) %s)" bound_dry_policy));
  let forged =
    Printf.sprintf "(app (var bound-policy-v0) (var governance-v0) %s %s)" (hash hash_d) live_policy
  in
  Alcotest.(check string)
    "forged bound policy refused"
    "err(\"invalid BoundPolicy: carried policy hash does not match canonical live-policy-v0 \
     bytes\")"
    (show (Printf.sprintf "(app (var governance.validate-bound-live-policy) %s)" forged));
  Alcotest.(check string)
    "bound execution rejects forged live policy" "err(invalid-decision)"
    (show
       (Printf.sprintf "(app (var governance.live-policy-verdict) %s (var low) (lit 1.0))" forged));
  Alcotest.(check string)
    "bound execution rejects non-finite confidence" "err(invalid-decision)"
    (show
       (Printf.sprintf
          "(app (var governance.live-policy-verdict) %s (var low) (app (var real.div) (lit 0.0) \
           (lit 0.0)))"
          bound_live_policy));
  let forged_dry =
    Printf.sprintf "(app (var bound-policy-v0) (var governance-v0) %s %s)" (hash hash_d) dry_policy
  in
  Alcotest.(check string)
    "bound execution rejects forged dry policy" "err(invalid-decision)"
    (show
       (Printf.sprintf "(app (var governance.dry-policy-verdict) %s (var low) (var true))"
          forged_dry));
  let stored_live =
    unwrap_ok (Printf.sprintf "(app (var governance.make-stored-live-policy) %s)" live_policy)
  in
  let stored_dry =
    unwrap_ok (Printf.sprintf "(app (var governance.make-stored-dry-policy) %s)" dry_policy)
  in
  List.iter
    (fun (label, value, wire, expected_hash) ->
      Alcotest.(check string)
        (label ^ " canonical wire") (qtext wire)
        (show
           (Printf.sprintf "(app (var code.render) (app (var governance.stored-policy-code) %s))"
              value));
      Alcotest.(check string)
        (label ^ " HASH_V0") (qtext expected_hash)
        (show
           (Printf.sprintf "(app (var hash.to-text) (app (var governance.stored-policy-id) %s))"
              value));
      Alcotest.(check bool)
        (label ^ " validates") true
        (String.starts_with ~prefix:"ok("
           (show (Printf.sprintf "(app (var governance.validate-stored-policy) %s)" value))))
    [
      ( "stored live policy",
        stored_live,
        "(stored-live-policy-v0 (live-policy-v0 (governance-v0) (low) (high) (lit 0.75)))",
        "a36470e6ca6572907676552bf34ff9f6b014477b72c9b5db7404614aaaeb3de0" );
      ( "stored dry policy",
        stored_dry,
        "(stored-dry-policy-v0 (dry-policy-v0 (governance-v0) (lit 0.75)))",
        "036336921aef6c48b284574788a8e509fe67d7ce31356f73ea815597ffc77be0" );
    ];
  let bound_stored =
    unwrap_ok (Printf.sprintf "(app (var governance.bind-stored-policy) %s)" stored_live)
  in
  Alcotest.(check string)
    "canonical stored BoundPolicy validates exact hash"
    "ok(#a36470e6ca6572907676552bf34ff9f6b014477b72c9b5db7404614aaaeb3de0)"
    (show (Printf.sprintf "(app (var governance.validate-bound-stored-policy) %s)" bound_stored));
  let forged_stored =
    Printf.sprintf "(app (var bound-policy-v0) (var governance-v0) %s %s)" (hash hash_d) stored_live
  in
  Alcotest.(check string)
    "forged stored BoundPolicy refused"
    "err(\"invalid BoundPolicy: carried policy hash does not match canonical stored-policy-v0 \
     bytes\")"
    (show (Printf.sprintf "(app (var governance.validate-bound-stored-policy) %s)" forged_stored));
  Array.iteri
    (fun auto auto_name ->
      Array.iteri
        (fun ask ask_name ->
          let policy =
            Printf.sprintf "(app (var governance.make-live-policy) (var %s) (var %s) (lit 0.75))"
              auto_name ask_name
          in
          if auto > ask then
            Alcotest.(check bool)
              (Printf.sprintf "invalid threshold grid %s/%s" auto_name ask_name)
              true
              (String.starts_with ~prefix:"err(" (show policy))
          else
            let bound =
              unwrap_ok
                (Printf.sprintf "(app (var governance.bind-live-policy) %s)" (unwrap_ok policy))
            in
            Array.iteri
              (fun risk risk_name ->
                List.iter
                  (fun confidence ->
                    let label =
                      Printf.sprintf "live grid auto=%s ask=%s risk=%s confidence=%.2f" auto_name
                        ask_name risk_name confidence
                    in
                    let actual =
                      show
                        (Printf.sprintf
                           "(app (var governance.live-policy-verdict) %s (var %s) (lit %.17f))"
                           bound risk_name confidence)
                    in
                    Alcotest.(check string)
                      label
                      (expected_live_verdict ~auto ~ask ~risk ~confidence)
                      actual)
                  [ 0.; 0.5; 0.75; 1. ])
              risk_names)
        risk_names)
    risk_names;
  List.iter
    (fun threshold ->
      let policy =
        unwrap_ok (Printf.sprintf "(app (var governance.make-dry-policy) (lit %.17f))" threshold)
      in
      let bound = unwrap_ok (Printf.sprintf "(app (var governance.bind-dry-policy) %s)" policy) in
      Array.iteri
        (fun risk risk_name ->
          List.iter
            (fun (has_simulator, expected) ->
              let expected = if risk = 3 then "ok(block)" else expected in
              let actual =
                show
                  (Printf.sprintf "(app (var governance.dry-policy-verdict) %s (var %s) (var %b))"
                     bound risk_name has_simulator)
              in
              Alcotest.(check string)
                (Printf.sprintf "dry grid threshold=%.2f risk=%s simulator=%b" threshold risk_name
                   has_simulator)
                expected actual)
            [ (true, "ok(simulate)"); (false, "err(no-simulation)") ])
        risk_names)
    [ 0.; 0.5; 1. ]

let test_safe_summaries () =
  Alcotest.(check string)
    "safe call summary has no arguments or evidence" "\"Call(fs.write): write one object\""
    (show (Printf.sprintf "(app (var governance.call-summary) %s)" (unwrap_ok (make_call ()))));
  Alcotest.(check string)
    "ToolError summary omits driver detail" "\"Blocked\""
    (show
       "(app (var governance.tool-error-show) (app (var tool-blocked) (lit \
        \"credential=redacted\")))");
  Alcotest.(check string)
    "Assessment summary omits reasons and evidence" "\"Assessment(High, confidence=0.8)\""
    (show
       "(app (var governance.assessment-summary) (match (app (var governance.make-assessment) (var \
        high) (lit 0.8) (app (var cons) (lit \"private reason\") (var nil)) (quote \
        (private-evidence))) (clause (pcon ok (pvar value)) (var value))))");
  Alcotest.(check string)
    "Outcome summary omits digest and detail" "\"Outcome(succeeded)\""
    (show
       (Printf.sprintf
          "(app (var governance.outcome-summary) (match (app (var governance.make-outcome-summary) \
           (lit \"succeeded\") %s (lit \"private detail\")) (clause (pcon ok (pvar value)) (var \
           value))))"
          (hash hash_a)));
  let source = Corpus_support.read_file "../prelude/21-governance-core.jqd" in
  Alcotest.(check bool)
    "no generic Secret renderer" false
    (String.contains source 'S' && String.contains source 'e'
    &&
      try
        ignore (Str.search_forward (Str.regexp_string "(var secret") source 0);
        true
      with Not_found -> false);
  Alcotest.(check bool)
    "no debug inspection" false
    (try
       ignore (Str.search_forward (Str.regexp_string "debug.inspect") source 0);
       true
     with Not_found -> false)

let prop_valid_confidence_is_accepted =
  QCheck.Test.make ~count:60
    ~name:"all finite confidence samples in [0,1] are accepted by policy and assessment boundaries"
    QCheck.(make Gen.(map (fun n -> float_of_int n /. 1000.) (int_bound 1000)))
    (fun confidence ->
      List.for_all
        (fun expression -> String.starts_with ~prefix:"ok(" (show expression))
        [
          Printf.sprintf
            "(app (var governance.make-assessment) (var medium) (lit %.17f) (var nil) (quote \
             (evidence)))"
            confidence;
          Printf.sprintf "(app (var governance.make-live-policy) (var low) (var high) (lit %.17f))"
            confidence;
          Printf.sprintf "(app (var governance.make-dry-policy) (lit %.17f))" confidence;
        ])

let prop_call_hash_is_deterministic =
  QCheck.Test.make ~count:60
    ~name:"Call HASH_V0 ignores formatting metadata and safe display summaries"
    QCheck.(pair (int_bound 8) (make Gen.(string_size ~gen:printable (int_bound 24))))
    (fun (padding, summary) ->
      let spaces = String.make (padding + 1) ' ' in
      let formatted = "(quote" ^ spaces ^ "(arguments" ^ spaces ^ "(lit 7)))" in
      String.equal (call_id (make_call ())) (call_id (make_call ~arguments:formatted ~summary ())))

let prop_call_hash_sensitivity =
  QCheck.Test.make ~count:100
    ~name:"Call HASH_V0 changes with operation, arguments, authority, or preconditions"
    QCheck.(pair (int_bound 3) (int_bound 100000))
    (fun (field, sample) ->
      let changed =
        match field with
        | 0 -> make_call ~operation_name:"fs.read" ()
        | 1 ->
            make_call ~arguments:(Printf.sprintf "(quote (arguments (lit %d)))" (sample + 100)) ()
        | 2 -> make_call ~authority:(list [ authority_effect ~id:hash_c () ]) ()
        | _ ->
            make_call
              ~preconditions:(Printf.sprintf "(quote (preconditions (lit %d)))" (sample + 100))
              ()
      in
      not (String.equal (call_id (make_call ())) (call_id changed)))

let prop_proposal_hash_is_stable =
  QCheck.Test.make ~count:60
    ~name:"Proposal HASH_V0 ignores formatting metadata in the exact rendering Code"
    QCheck.(int_bound 8)
    (fun padding ->
      let spaces = String.make (padding + 1) ' ' in
      let changed_rendering = "(quote" ^ spaces ^ "(review" ^ spaces ^ "(lit \"ship\")))" in
      String.equal
        (canonical_proposal_id (canonical_proposal ()))
        (canonical_proposal_id (canonical_proposal ~rendering:changed_rendering ())))

let prop_proposal_hash_sensitivity =
  QCheck.Test.make ~count:100
    ~name:"Proposal HASH_V0 changes with every exact review-artifact field"
    QCheck.(pair (int_bound 6) (int_bound 100000))
    (fun (field, sample) ->
      let changed =
        match field with
        | 0 -> canonical_proposal ~call_id:hash_d ()
        | 1 -> canonical_proposal ~policy_id:hash_d ()
        | 2 -> canonical_proposal ~assessment_id:hash_d ()
        | 3 -> canonical_proposal ~authority:(list [ authority_effect ~id:hash_c () ]) ()
        | 4 -> canonical_proposal ~preview:"(var none)" ()
        | 5 ->
            canonical_proposal
              ~rendering:(Printf.sprintf "(quote (review (lit %d)))" (sample + 100))
              ()
        | _ -> canonical_proposal ~summary:(Printf.sprintf "ship-%d?" (sample + 100)) ()
      in
      not
        (String.equal
           (canonical_proposal_id (canonical_proposal ()))
           (canonical_proposal_id changed)))

let prop_policy_numeric_boundaries =
  QCheck.Test.make ~count:80
    ~name:"live policy confidence comparison is inclusive and rejects values outside [0,1]"
    QCheck.(int_bound 1000)
    (fun threshold_millis ->
      let threshold = float_of_int threshold_millis /. 1000. in
      let policy =
        unwrap_ok
          (Printf.sprintf "(app (var governance.make-live-policy) (var low) (var high) (lit %.17f))"
             threshold)
      in
      let bound = unwrap_ok (Printf.sprintf "(app (var governance.bind-live-policy) %s)" policy) in
      let verdict confidence =
        show
          (Printf.sprintf "(app (var governance.live-policy-verdict) %s (var low) (lit %.17f))"
             bound confidence)
      in
      String.equal "ok(allow)" (verdict threshold)
      && (threshold = 0. || String.equal "ok(ask)" (verdict (threshold -. 0.001)))
      && String.equal "err(invalid-decision)" (verdict (-0.001))
      && String.equal "err(invalid-decision)" (verdict 1.001))

let suite =
  [
    Alcotest.test_case "schemas and frozen identities" `Quick test_schema_and_frozen_identities;
    Alcotest.test_case "confidence and policy refusals" `Quick test_confidence_and_policy_refusals;
    Alcotest.test_case "operation-name table" `Quick test_operation_name_table;
    Alcotest.test_case "authority malformed table" `Quick test_authority_refusal_table;
    Alcotest.test_case "Call hash and verifier" `Quick test_call_hash_and_verifier;
    Alcotest.test_case "Proposal hash and verifier" `Quick test_proposal_hash_and_verifier;
    Alcotest.test_case "policy laws and BoundPolicy verifier" `Quick
      test_policy_laws_and_bound_verifier;
    Alcotest.test_case "safe summaries" `Quick test_safe_summaries;
    QCheck_alcotest.to_alcotest prop_valid_confidence_is_accepted;
    QCheck_alcotest.to_alcotest prop_call_hash_is_deterministic;
    QCheck_alcotest.to_alcotest prop_call_hash_sensitivity;
    QCheck_alcotest.to_alcotest prop_proposal_hash_is_stable;
    QCheck_alcotest.to_alcotest prop_proposal_hash_sensitivity;
    QCheck_alcotest.to_alcotest prop_policy_numeric_boundaries;
  ]
