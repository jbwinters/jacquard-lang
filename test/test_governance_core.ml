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
  ignore (lookup "governance.resolve-operation-id" Resolve.KTerm)

let test_confidence_and_policy_refusals () =
  List.iter
    (fun (label, confidence) ->
      Alcotest.(check bool)
        label true
        (String.starts_with ~prefix:"err("
           (show
              (Printf.sprintf
                 "(app (var governance.make-assessment) (var low) %s (var nil) (quote (evidence)))"
                 confidence))))
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
  Alcotest.(check string)
    "reversed live thresholds refused" "err(\"invalid LivePolicy: auto-up-to exceeds ask-up-to\")"
    (show "(app (var governance.make-live-policy) (var high) (var low) (lit 0.5))");
  Alcotest.(check bool)
    "verifier catches directly constructed invalid assessment" true
    (String.starts_with ~prefix:"err("
       (show
          "(app (var governance.validate-assessment) (app (var governance-assessment-v0) (var \
           governance-v0) (var low) (app (var real.div) (lit 0.0) (lit 0.0)) (var nil) (quote \
           (evidence))))"))

let test_operation_name_table () =
  let malformed =
    Corpus_support.read_file "../corpus/governance/malformed-operation-names.tsv"
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
        if String.equal line "" || String.starts_with ~prefix:"#" line then None
        else
          match String.split_on_char '\t' line with
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
  List.iter
    (fun (label, operation_name) ->
      Alcotest.(check bool)
        label true
        (String.starts_with ~prefix:"err(" (show (make_call ~operation_name ()))))
    unresolved

let test_authority_refusal_table () =
  let malformed =
    [
      ("resource without effect", list [ resource () ]);
      ("empty resource scope", list [ authority_effect (); resource ~scope:"" () ]);
      ("duplicate effect", list [ authority_effect (); authority_effect () ]);
      ("noncanonical order", list [ authority_effect ~id:hash_b (); authority_effect ~id:hash_a () ]);
    ]
  in
  List.iter
    (fun (label, value) ->
      Alcotest.(check bool)
        label true
        (String.starts_with ~prefix:"err("
           (show (Printf.sprintf "(app (var governance.validate-authority) %s)" value))))
    malformed;
  Alcotest.(check bool)
    "canonical envelope accepted" true
    (String.starts_with ~prefix:"ok("
       (show (Printf.sprintf "(app (var governance.validate-authority) %s)" authority)))

let call_id call =
  show
    (Printf.sprintf "(app (var hash.to-text) (app (var governance.call-id) %s))" (unwrap_ok call))

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
  Alcotest.(check bool)
    "canonical call code is versioned" true
    (String.starts_with ~prefix:"\"(governance-call-v0 (governance-v0)" rendered)

let live_policy =
  "(match (app (var governance.make-live-policy) (var low) (var high) (lit 0.75)) (clause (pcon ok \
   (pvar policy)) (var policy)))"

let dry_policy =
  "(match (app (var governance.make-dry-policy) (lit 0.75)) (clause (pcon ok (pvar policy)) (var \
   policy)))"

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
  let bound = Printf.sprintf "(app (var governance.bind-live-policy) %s)" live_policy in
  Alcotest.(check bool)
    "canonical bound policy validates" true
    (String.starts_with ~prefix:"ok(#"
       (show
          (Printf.sprintf "(app (var governance.validate-bound-live-policy) %s)" (unwrap_ok bound))));
  let forged =
    Printf.sprintf "(app (var bound-policy-v0) (var governance-v0) %s %s)" (hash hash_d) live_policy
  in
  Alcotest.(check string)
    "forged bound policy refused"
    "err(\"invalid BoundPolicy: carried policy hash does not match canonical live-policy-v0 \
     bytes\")"
    (show (Printf.sprintf "(app (var governance.validate-bound-live-policy) %s)" forged))

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
  QCheck.Test.make ~count:60 ~name:"all finite confidence samples in [0,1] are accepted"
    QCheck.(make Gen.(map (fun n -> float_of_int n /. 1000.) (int_bound 1000)))
    (fun confidence ->
      String.starts_with ~prefix:"ok("
        (show
           (Printf.sprintf
              "(app (var governance.make-assessment) (var medium) (lit %.17f) (var nil) (quote \
               (evidence)))"
              confidence)))

let prop_call_hash_is_deterministic =
  QCheck.Test.make ~count:50 ~name:"Call HASH_V0 ignores safe display summaries"
    QCheck.(make Gen.(string_size ~gen:printable (int_bound 24)))
    (fun summary -> String.equal (call_id (make_call ())) (call_id (make_call ~summary ())))

let prop_dry_simulates_with_any_threshold =
  let risk_name = function 0 -> "low" | 1 -> "medium" | 2 -> "high" | _ -> "forbidden" in
  QCheck.Test.make ~count:80
    ~name:"dry policy Simulates every non-Forbidden risk when a simulator exists"
    QCheck.(pair (int_bound 3) (int_bound 1000))
    (fun (risk_rank, threshold_millis) ->
      let threshold = float_of_int threshold_millis /. 1000. in
      let expected = if risk_rank = 3 then "ok(block)" else "ok(simulate)" in
      String.equal expected
        (show
           (Printf.sprintf
              "(app (var governance.dry-verdict) (match (app (var governance.make-dry-policy) (lit \
               %.17f)) (clause (pcon ok (pvar policy)) (var policy))) (var %s) (var true))"
              threshold (risk_name risk_rank))))

let suite =
  [
    Alcotest.test_case "schemas and frozen identities" `Quick test_schema_and_frozen_identities;
    Alcotest.test_case "confidence and policy refusals" `Quick test_confidence_and_policy_refusals;
    Alcotest.test_case "operation-name table" `Quick test_operation_name_table;
    Alcotest.test_case "authority malformed table" `Quick test_authority_refusal_table;
    Alcotest.test_case "Call hash and verifier" `Quick test_call_hash_and_verifier;
    Alcotest.test_case "policy laws and BoundPolicy verifier" `Quick
      test_policy_laws_and_bound_verifier;
    Alcotest.test_case "safe summaries" `Quick test_safe_summaries;
    QCheck_alcotest.to_alcotest prop_valid_confidence_is_accepted;
    QCheck_alcotest.to_alcotest prop_call_hash_is_deterministic;
    QCheck_alcotest.to_alcotest prop_dry_simulates_with_any_threshold;
  ]
