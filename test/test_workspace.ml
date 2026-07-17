open Jacquard

(* GM.9: the typed Workspace facade, inspectable specs, pure normalizers, and
   operation-specific safe outcome summaries. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_value source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error ->
      Alcotest.failf "Workspace evaluation failed: %s\nsource: %s" (Runtime_err.to_string error)
        source

let show source = Value.show (eval_value source)
let qtext value = "\"" ^ Printer.escape_text value ^ "\""

let unwrap_ok expression =
  Printf.sprintf
    "(match %s (clause (pcon ok (pvar value)) (var value)) (clause (pcon err (pvar message)) (var \
     message)))"
    expression

let path value = Printf.sprintf "(app (var path-value) (lit %s))" (qtext value)
let call_read value = Printf.sprintf "(app (var workspace.call-read) %s)" (path value)

let call_write value text =
  Printf.sprintf "(app (var workspace.call-write) %s (lit %s))" (path value) (qtext text)

let request url body =
  Printf.sprintf "(app (var mk-request) (lit %s) (lit %s))" (qtext url) (qtext body)

let call_fetch url body = Printf.sprintf "(app (var workspace.call-fetch) %s)" (request url body)

let call_id call =
  show
    (Printf.sprintf "(app (var hash.to-text) (app (var governance.call-id) %s))" (unwrap_ok call))

let lookup name kind =
  match Store.lookup_kind store name kind with
  | Some entry -> entry.Resolve.hash
  | None -> Alcotest.failf "missing Workspace name %s" name

let checker () =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make Workspace checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register Workspace builtins" diagnostics);
  checker

let scheme name =
  let checker = checker () in
  match Check.force_term checker (lookup name Resolve.KTerm) with
  | Ok scheme -> Check.show_scheme checker scheme
  | Error diagnostics -> Eval_support.fail_diags ("force " ^ name) diagnostics

let check_expr source =
  let checker = checker () in
  match Reader.parse_one ~file:"workspace-bypass.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top checker (Kernel.Expr expression)))

let contains haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let test_schema_once_and_resolved_ids () =
  Alcotest.(check string)
    "Path HASH_V0 identity" "d457b6263e7106ef245d474b54114816216ef8873bcc43ed13d91c4a417edd7c"
    (Hash.to_hex (lookup "path" Resolve.KType));
  ignore (lookup "path-value" Resolve.KCon);
  let effect_id = lookup "workspace" Resolve.KEffect in
  Alcotest.(check string)
    "Workspace HASH_V0 interface" "d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0"
    (Hash.to_hex effect_id);
  match Store.locate store effect_id with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Whole; _ } ->
      Alcotest.(check (list string))
        "exact Workspace operation inventory"
        [ "read-file"; "write-file"; "fetch" ]
        (List.map (fun (operation : Kernel.opspec) -> operation.op_name) ops);
      List.iter
        (fun (operation : Kernel.opspec) ->
          Alcotest.(check bool)
            ("Workspace." ^ operation.op_name ^ " is once")
            true (operation.op_mode = Kernel.Once))
        ops;
      List.iter
        (fun (tag, name) ->
          let expected = Hash.to_hex (lookup name Resolve.KOp) in
          Alcotest.(check string)
            (name ^ " resolved identity in inspectable spec")
            (qtext expected)
            (show
               (Printf.sprintf
                  "(match (app (var workspace.operation-spec) (var %s)) (clause (pcon ok (pcon \
                   workspace-operation-spec-v0 (pwild) (pvar operation-id) (pwild) (pwild) (pwild) \
                   (pwild))) (app (var hash.to-text) (var operation-id))))"
                  tag)))
        [
          ("workspace-read-file", "workspace.read-file");
          ("workspace-write-file", "workspace.write-file");
          ("workspace-fetch", "workspace.fetch");
        ]
  | Ok _ -> Alcotest.fail "Workspace did not locate to one whole effect declaration"
  | Error diagnostics -> Eval_support.fail_diags "locate Workspace" diagnostics

let test_specs_are_inspectable_and_exact () =
  Alcotest.(check string)
    "read and write expose Fs; fetch exposes canonical Net,Secret and one safe ref"
    "(ok(workspace-operation-spec-v0(workspace-read-file, \
     #632071e3399c913a672c4bea7d4a8b394e64a9a517552eb296db824222fe2da1, \"workspace.read-file\", \
     cons(governance-effect(#8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84), \
     nil), (quote (tuple)), nil)), ok(workspace-operation-spec-v0(workspace-write-file, \
     #73140dde8e33c268fa589d9bfaeb28b156af2da52b22779257b2d3e9b696b03c, \"workspace.write-file\", \
     cons(governance-effect(#8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84), \
     nil), (quote (tuple)), nil)), ok(workspace-operation-spec-v0(workspace-fetch, \
     #f6536683575508ddcc2d5a6509df832e92897cbef2caf34219f993a110079b01, \"workspace.fetch\", \
     cons(governance-effect(#be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45), \
     cons(governance-effect(#6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31), \
     nil)), (quote (tuple)), cons(secret-ref(\"workspace\", none), nil))))"
    (show
       "(tuple (app (var workspace.operation-spec) (var workspace-read-file)) (app (var \
        workspace.operation-spec) (var workspace-write-file)) (app (var workspace.operation-spec) \
        (var workspace-fetch)))");
  Alcotest.(check string)
    "fetch argument Code contains URL, body digest, and SecretRef only"
    "\"(workspace-fetch-arguments-v0 (lit \\\"https://example.test/a\\\") (hash \
     #682308ac6f7dc9c257b527f6cde1d949d2b6f2ed7dbaa816cd50b94f35d8dce8) (secret-ref-v0 (lit \
     \\\"workspace\\\") (none-v0)))\""
    (show
       (Printf.sprintf "(app (var code.render) (app (var workspace.fetch-arguments) %s))"
          (request "https://example.test/a" "body must stay out")));
  Alcotest.(check string)
    "Path remains explicit in meaningful read arguments"
    "\"(workspace-read-file-arguments-v0 (path-value-v0 (lit \\\"docs/README.md\\\")))\""
    (show
       (Printf.sprintf "(app (var code.render) (app (var workspace.read-arguments) %s))"
          (path "docs/README.md")));
  Alcotest.(check string)
    "fetch Call copies the exact envelope and empty precondition byte for byte"
    "(cons(governance-effect(#be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45), \
     cons(governance-effect(#6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31), \
     nil)), (quote (tuple)))"
    (show
       (Printf.sprintf
          "(match %s (clause (pcon ok (pcon governance-call-v0 (pwild) (pwild) (pwild) (pwild) \
           (pwild) (pvar authority) (pwild) (pvar preconditions) (pwild))) (tuple (var authority) \
           (var preconditions))))"
          (call_fetch "https://example.test/a" "body")))

let test_call_hash_goldens_and_identity_laws () =
  let read = call_read "README.md" in
  let read_id = call_id read in
  Alcotest.(check string)
    "read-file Call HASH_V0 golden"
    "\"0eea80c98650bcc25c4a323464c8b112c48b991455d2c31f8dd0e8a99c6268c1\"" read_id;
  Alcotest.(check string)
    "write-file Call HASH_V0 golden"
    "\"08fb6f035d7077df0d24fbc4449caae6e8631a8092b1455435e42c59d1bbe571\""
    (call_id (call_write "generated.conf" "enabled=true"));
  Alcotest.(check string)
    "fetch Call HASH_V0 golden"
    "\"c38951269a7804fdf267e6100815198698366eac27f32ecec037055f107c1a0d\""
    (call_id (call_fetch "https://example.test/artifact" "request-body"));
  Alcotest.(check string)
    "typed normalizer is deterministic" read_id
    (call_id (call_read "README.md"));
  let reconstructed_with_changed_summary =
    Printf.sprintf
      "(match (app (var workspace.operation-spec) (var workspace-read-file)) (clause (pcon ok \
       (pcon workspace-operation-spec-v0 (pwild) (pwild) (pvar name) (pvar authority) (pvar \
       preconditions) (pwild))) (match %s (clause (pcon ok (pcon governance-call-v0 (pwild) \
       (pwild) (pwild) (pwild) (pvar arguments) (pwild) (pwild) (pwild) (pvar parent-call-id))) \
       (app (var governance.make-call) (var name) (var arguments) (var authority) (lit \
       \"Review-only summary wording\") (var preconditions) (var parent-call-id))))))"
      read
  in
  Alcotest.(check string)
    "canonical Workspace spec/call presentation summary is identity-inert" read_id
    (call_id reconstructed_with_changed_summary);
  List.iter
    (fun (label, changed) ->
      Alcotest.(check bool) label false (String.equal read_id (call_id changed)))
    [
      ("path changes call identity", call_read "docs/README.md");
      ("operation changes call identity", call_write "README.md" "");
    ];
  Alcotest.(check bool)
    "write content digest changes call identity" false
    (String.equal
       (call_id (call_write "generated.conf" "enabled=true"))
       (call_id (call_write "generated.conf" "enabled=false")));
  Alcotest.(check bool)
    "request body digest changes call identity" false
    (String.equal
       (call_id (call_fetch "https://example.test/artifact" "a"))
       (call_id (call_fetch "https://example.test/artifact" "b")));
  Alcotest.(check bool)
    "request URL changes call identity" false
    (String.equal
       (call_id (call_fetch "https://example.test/a" "same-body"))
       (call_id (call_fetch "https://example.test/b" "same-body")))

let test_no_generic_call_bypass () =
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not public") true
        (Store.lookup_kind store name Resolve.KTerm = None))
    [ "workspace.call"; "workspace.call-from-spec" ];
  let forged_spec =
    "(match (app (var governance.resolve-operation-id) (lit \"workspace.fetch\")) (clause (pcon ok \
     (pvar operation-id)) (app (var workspace-operation-spec-v0) (var workspace-read-file) (var \
     operation-id) (lit \"workspace.fetch\") (var nil) (quote (forged)) (var nil))))"
  in
  match check_expr (Printf.sprintf "(app (var workspace.call-read) %s)" forged_spec) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a forged public WorkspaceOperationSpec reached the typed read call"

let test_pure_schemes_and_safe_summaries () =
  List.iter
    (fun (name, expected) ->
      Alcotest.(check string) (name ^ " exact public scheme") expected (scheme name))
    [
      ("workspace.operation-spec", "(WorkspaceOperation) ->{} Result Text WorkspaceOperationSpec");
      ("workspace.call-read", "(Path) ->{} Result Text GovernanceCall");
      ("workspace.call-write", "(Path, Text) ->{} Result Text GovernanceCall");
      ("workspace.call-fetch", "(Request) ->{} Result Text GovernanceCall");
      ("workspace.summarize-read", "(Result ToolError Text) ->{} GovernanceOutcomeSummary");
      ("workspace.summarize-write", "(Result ToolError ()) ->{} GovernanceOutcomeSummary");
      ("workspace.summarize-fetch", "(Result ToolError Response) ->{} GovernanceOutcomeSummary");
    ];
  List.iter
    (fun name ->
      let inferred = scheme name in
      Alcotest.(check bool)
        (name ^ " has a closed pure outer arrow")
        true (contains inferred " ->{} "))
    [
      "workspace.operation-spec";
      "workspace.call-read";
      "workspace.call-write";
      "workspace.call-fetch";
      "workspace.summarize-read";
      "workspace.summarize-write";
      "workspace.summarize-fetch";
    ];
  let secret = "driver-secret-fixture" in
  let summaries =
    show
      (Printf.sprintf
         "(tuple (app (var workspace.summarize-read) (app (var ok) (lit %s))) (app (var \
          workspace.summarize-write) (app (var err) (app (var driver-failed) (lit %s)))) (app (var \
          workspace.summarize-fetch) (app (var ok) (app (var mk-response) (lit 201) (lit %s)))))"
         (qtext "contents") (qtext secret) (qtext secret))
  in
  Alcotest.(check bool)
    "outcome summaries omit typed payload and driver-error text" false (contains summaries secret);
  Alcotest.(check bool) "read payload is not rendered" false (contains summaries "contents");
  Alcotest.(check bool) "fetch status remains useful" true (contains summaries "fetch: HTTP 201");
  let source = Corpus_support.read_file "../prelude/23-workspace.jqd" in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool)
        ("Workspace source excludes " ^ forbidden)
        false (contains source forbidden))
    [ "debug.inspect"; "Tool.call"; "defeffect host"; "(tref secret))" ]

let suite =
  [
    Alcotest.test_case "once schema and resolved identities" `Quick
      test_schema_once_and_resolved_ids;
    Alcotest.test_case "inspectable exact operation specs" `Quick
      test_specs_are_inspectable_and_exact;
    Alcotest.test_case "Call hash goldens and identity laws" `Quick
      test_call_hash_goldens_and_identity_laws;
    Alcotest.test_case "no generic Call-spec bypass" `Quick test_no_generic_call_bypass;
    Alcotest.test_case "pure normalizers and safe typed summaries" `Quick
      test_pure_schemes_and_safe_summaries;
  ]
