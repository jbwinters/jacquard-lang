open Jacquard

(* ET.2: typed governance evidence, canonical Code encoding, and the two standard handlers. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_value source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error -> Alcotest.failf "audit evaluation failed: %s" (Runtime_err.to_string error)

let show source = Value.show (eval_value source)
let qtext value = "\"" ^ Printer.escape_text value ^ "\""
let call_hash = String.make 64 'a'
let policy_hash = String.make 64 'b'
let proposal_hash = String.make 64 'c'
let outcome_hash = String.make 64 'd'

let hash value =
  Printf.sprintf
    "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed-hash)) (var \
     parsed-hash)))"
    (qtext value)

let check_expr source =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> Eval_support.fail_diags "make Audit checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> Eval_support.fail_diags "register Audit builtins" diagnostics);
  match Reader.parse_one ~file:"audit-direct-ref.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top checker (Kernel.Expr expression)))

let evaluated ?(sequence = 0) ?(confidence = "0.75") ?(reason = "rule matched")
    ?(evidence = "(quote (evidence (lit \"typed\")))") () =
  Printf.sprintf
    "(app (var evaluated) (var governance-v0) (lit %d) %s %s (app (var governance-assessment-v0) \
     (var governance-v0) (var medium) (lit %s) (app (var cons) (lit %s) (var nil)) %s) (var ask))"
    sequence (hash call_hash) (hash policy_hash) confidence (qtext reason) evidence

let consented ?(sequence = 1) ?(approver = "reviewer")
    ?(evidence = "(quote (ticket (lit \"T-7\")))") () =
  Printf.sprintf
    "(app (var consented) (var governance-v0) (lit %d) %s %s (app (var approved) %s (lit %s) %s))"
    sequence (hash call_hash) (hash proposal_hash) (hash proposal_hash) (qtext approver) evidence

let completed ?(sequence = 2) ?(detail = "receipt-7") () =
  Printf.sprintf
    "(app (var completed) (var governance-v0) (lit %d) %s (lit \"live\") (app (var \
     governance-outcome-summary-v0) (var governance-v0) (lit \"succeeded\") %s (lit %s)))"
    sequence (hash call_hash) (hash outcome_hash) (qtext detail)

let render entry =
  match
    eval_value (Printf.sprintf "(app (var code.render) (app (var audit.entry-code) %s))" entry)
  with
  | Value.VText line -> line
  | value -> Alcotest.failf "audit encoder returned %s" (Value.show value)

let rec value_list = function
  | Value.VCon { name = "nil"; args = []; _ } -> []
  | Value.VCon { name = "cons"; args = [ value; rest ]; _ } -> value :: value_list rest
  | value -> Alcotest.failf "expected list, got %s" (Value.show value)

let test_released_types_and_once_effect () =
  let lookup name kind =
    match Store.lookup_kind store name kind with
    | Some entry -> entry.Resolve.hash
    | None -> Alcotest.failf "missing released audit name %s" name
  in
  let audit = lookup "audit" Resolve.KEffect in
  Alcotest.(check string)
    "released Audit interface hash"
    "40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372" (Hash.to_hex audit);
  List.iter
    (fun name -> ignore (lookup name Resolve.KCon))
    [ "evaluated"; "consented"; "completed" ];
  Alcotest.(check bool)
    "opaque Hash marker is not public" true
    (Store.lookup_kind store "hash-opaque" Resolve.KCon = None);
  match Store.locate store audit with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops = [ operation ]; _ }; _ }; _ } ->
      Alcotest.(check bool) "Audit.record is once" true (operation.op_mode = Kernel.Once)
  | Ok _ -> Alcotest.fail "Audit identity did not locate to its one-operation declaration"
  | Error diagnostics -> Eval_support.fail_diags "locate Audit" diagnostics

let test_opaque_constructor_direct_hash_is_sealed () =
  let opaque_hex = "d48426af83dd64417666d11346b732136f39950871f9c4708e947515f9eda3db" in
  let opaque = Option.get (Hash.of_hex opaque_hex) in
  (match Store.locate store opaque with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0601" -> ()
  | Error diagnostics -> Eval_support.fail_diags "opaque member lookup" diagnostics
  | Ok _ -> Alcotest.fail "opaque constructor remained addressable by its derived hash");
  (match Store.bind_name store "forged-hash" opaque with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0601" -> ()
  | Error diagnostics -> Eval_support.fail_diags "opaque member rebinding" diagnostics
  | Ok () -> Alcotest.fail "opaque constructor could be rebound to a public name");
  let reopened =
    match Store.open_store store.Store.root with
    | Ok reopened -> reopened
    | Error diagnostics -> Eval_support.fail_diags "reopen opaque store" diagnostics
  in
  (match Store.locate reopened opaque with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0601" -> ()
  | Error diagnostics -> Eval_support.fail_diags "reopened opaque member lookup" diagnostics
  | Ok _ -> Alcotest.fail "reopen restored the opaque derived-hash index entry");
  Alcotest.(check bool)
    "reopen preserves hidden name" true
    (Store.lookup_kind reopened "hash-opaque" Resolve.KCon = None);
  (match check_expr (Printf.sprintf "(ref #%s con)" opaque_hex) with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0805" ->
      Alcotest.(check bool)
        "direct hash is diagnosed unknown" true
        (String.starts_with ~prefix:"E0601:" (Diag.cause diagnostic)
        && String.ends_with ~suffix:(opaque_hex ^ ")") (Diag.cause diagnostic))
  | Error diagnostics -> Eval_support.fail_diags "check opaque direct reference" diagnostics
  | Ok _ -> Alcotest.fail "opaque constructor direct reference typechecked");
  (match Eval_support.eval_with ctx store (Printf.sprintf "(ref #%s con)" opaque_hex) with
  | Error (Runtime_err.Unresolved message) ->
      Alcotest.(check bool)
        "unchecked evaluator also fails closed" true
        (String.starts_with ~prefix:"E0601:" message)
  | Error error ->
      Alcotest.failf "opaque direct reference failed with the wrong runtime error: %s"
        (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "opaque direct reference constructed %s" (Value.show value));
  let lookup name kind =
    match Store.lookup_kind store name kind with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "missing ordinary direct-reference witness %s" name
  in
  let true_hash = lookup "true" Resolve.KCon in
  let to_text_hash = lookup "hash.to-text" Resolve.KTerm in
  let ordinary =
    Printf.sprintf
      "(match (app (var hash.parse) (lit %s)) (clause (pcon ok (pvar parsed)) (tuple (ref #%s con) \
       (app (ref #%s term) (var parsed)))) (clause (pcon err (pvar message)) (tuple (ref #%s con) \
       (var message))))"
      (qtext call_hash) (Hash.to_hex true_hash) (Hash.to_hex to_text_hash) (Hash.to_hex true_hash)
  in
  (match check_expr ordinary with
  | Ok _ -> ()
  | Error diagnostics -> Eval_support.fail_diags "ordinary direct references" diagnostics);
  Alcotest.(check string)
    "ordinary constructor/member direct references still evaluate"
    (Printf.sprintf "(true, \"%s\")" call_hash)
    (show ordinary)

let test_in_memory_preserves_order () =
  Alcotest.(check string)
    "records append in occurrence order"
    (Printf.sprintf
       "(7, cons(evaluated(governance-v0, 0, #%s, #%s, governance-assessment-v0(governance-v0, \
        medium, 0.75, cons(\"rule matched\", nil), (quote (evidence (lit \"typed\")))), ask), \
        cons(consented(governance-v0, 1, #%s, #%s, approved(#%s, \"reviewer\", (quote (ticket (lit \
        \"T-7\"))))), cons(completed(governance-v0, 2, #%s, \"live\", \
        governance-outcome-summary-v0(governance-v0, \"succeeded\", #%s, \"receipt-7\")), nil))))"
       call_hash policy_hash call_hash proposal_hash proposal_hash call_hash outcome_hash)
    (show
       (Printf.sprintf
          "(app (var audit.in-memory) (lam () (let nonrec (pwild) (app (var record) %s) (let \
           nonrec (pwild) (app (var record) %s) (let nonrec (pwild) (app (var record) %s) (lit \
           7))))))"
          (evaluated ()) (consented ()) (completed ())))

let test_canonical_encoding_all_variants () =
  let lines = List.map render [ evaluated (); consented (); completed () ] in
  List.iter
    (fun line ->
      Alcotest.(check bool) "one physical line" false (String.contains line '\n');
      match Reader.parse_one ~file:"audit.log" line with
      | Ok { Form.head = "audit-entry-v2"; _ } -> ()
      | Ok form -> Alcotest.failf "wrong audit root %s" form.Form.head
      | Error diagnostics -> Eval_support.fail_diags "reparse audit line" diagnostics)
    lines;
  Alcotest.(check (list string))
    "golden deterministic v2 encodings"
    [
      Printf.sprintf
        "(audit-entry-v2 (evaluated-v2 (governance-v0) (lit 0) (hash #%s) (hash #%s) \
         (governance-assessment-v0 (governance-v0) (medium) (lit 0.75) (text-list-v1 (lit \"rule \
         matched\")) (evidence (lit \"typed\"))) (ask)))"
        call_hash policy_hash;
      Printf.sprintf
        "(audit-entry-v2 (consented-v2 (governance-v0) (lit 1) (hash #%s) (hash #%s) (approved-v1 \
         (hash #%s) (lit \"reviewer\") (ticket (lit \"T-7\")))))"
        call_hash proposal_hash proposal_hash;
      Printf.sprintf
        "(audit-entry-v2 (completed-v2 (governance-v0) (lit 2) (hash #%s) (lit \"live\") \
         (governance-outcome-summary-v0 (governance-v0) (lit \"succeeded\") (hash #%s) (lit \
         \"receipt-7\"))))"
        call_hash outcome_hash;
    ]
    lines

let test_log_path_has_no_generic_inspection () =
  let source = Corpus_support.read_file "../prelude/19-audit.jqd" in
  let contains needle =
    try
      ignore (Str.search_forward (Str.regexp_string needle) source 0);
      true
    with Not_found -> false
  in
  Alcotest.(check bool)
    "audit prelude never references debug.inspect" false (contains "debug.inspect");
  Alcotest.(check bool)
    "typed Code renderer is the only rendering boundary" true (contains "code.render")

let test_hash_boundary_rejects_noncanonical_spellings () =
  let uppercase = String.uppercase_ascii call_hash in
  let nonhex = String.make 64 'g' in
  let alternate = "#" ^ call_hash in
  Alcotest.(check string)
    "only canonical HASH_V0 text crosses the boundary"
    (Printf.sprintf
       "(ok(#%s), err(\"expected 64 lowercase hexadecimal HASH_V0 digits\"), err(\"expected 64 \
        lowercase hexadecimal HASH_V0 digits\"), err(\"expected 64 lowercase hexadecimal HASH_V0 \
        digits\"), err(\"expected 64 lowercase hexadecimal HASH_V0 digits\"))"
       call_hash)
    (show
       (Printf.sprintf
          "(tuple (app (var hash.parse) (lit %s)) (app (var hash.parse) (lit \"abc\")) (app (var \
           hash.parse) (lit %s)) (app (var hash.parse) (lit %s)) (app (var hash.parse) (lit %s)))"
          (qtext call_hash) (qtext uppercase) (qtext nonhex) (qtext alternate)));
  Alcotest.(check string)
    "validated Hash renders to its unique spelling" (qtext call_hash)
    (show (Printf.sprintf "(app (var hash.to-text) %s)" (hash call_hash)))

let test_line_log_order_and_append () =
  let writer =
    "(lam ((pvar line)) (let nonrec (pwild) (app (var emit) (var line)) (app (var ok) (tuple))))"
  in
  let value =
    eval_value
      (Printf.sprintf
         "(app (var emit.collect) (lam () (let nonrec (pvar first) (app (var audit.line-log) (lam \
          () (let nonrec (pwild) (app (var record) %s) (lit 1))) %s) (let nonrec (pvar second) \
          (app (var audit.line-log) (lam () (let nonrec (pwild) (app (var record) %s) (lit 2))) \
          %s) (tuple (var first) (var second))))))"
         (evaluated ()) writer (completed ()) writer)
  in
  match value with
  | Value.VTuple [ results; entries ] ->
      Alcotest.(check string) "both handler runs succeed" "(ok(1), ok(2))" (Value.show results);
      Alcotest.(check (list string))
        "second handler appends after the first"
        [ render (evaluated ()) ^ "\n"; render (completed ()) ^ "\n" ]
        (value_list entries
        |> List.map (function
          | Value.VText line -> line
          | value -> Alcotest.failf "line sink received %s" (Value.show value)))
  | value -> Alcotest.failf "line-log/emit result had wrong shape: %s" (Value.show value)

let test_injected_pre_write_failure_is_closed () =
  let expression before_record =
    let body =
      if before_record then
        Printf.sprintf
          "(let nonrec (pwild) (app (var put) (lit 1)) (let nonrec (pwild) (app (var record) %s) \
           (lit 9)))"
          (completed ())
      else
        Printf.sprintf
          "(let nonrec (pwild) (app (var record) %s) (let nonrec (pwild) (app (var put) (lit 1)) \
           (lit 9)))"
          (evaluated ())
    in
    Printf.sprintf
      "(app (var state.run) (lam () (app (var audit.line-log) (lam () %s) (lam ((pwild)) (app (var \
       err) (lit \"disk full\"))))) (lit 0))"
      body
  in
  Alcotest.(check string)
    "failed pre-action write prevents continuation/action" "(err(\"disk full\"), 0)"
    (show (expression false));
  Alcotest.(check string)
    "failed completion write cannot roll back prior action" "(err(\"disk full\"), 1)"
    (show (expression true))

let prop_encoding_is_deterministic =
  QCheck.Test.make ~count:40
    ~name:"all AuditEntry variants, nested Code, text edges, and nonfinite reals are canonical"
    (QCheck.make QCheck.Gen.(string_size ~gen:printable (int_bound 18)))
    (fun suffix ->
      let edge = "control:\n\t\001 utf8:h\195\169llo \226\134\146 \240\159\142\137 " ^ suffix in
      let nested = Printf.sprintf "(quote (outer (inner (lit %s))))" (qtext edge) in
      let entries =
        [
          evaluated ~reason:edge ~evidence:nested ();
          evaluated ~confidence:"+inf.0" ~reason:edge ~evidence:nested ();
          evaluated ~confidence:"-inf.0" ~reason:edge ~evidence:nested ();
          evaluated ~confidence:"+nan.0" ~reason:edge ~evidence:nested ();
          consented ~approver:edge ~evidence:nested ();
          completed ~detail:edge ();
        ]
      in
      List.for_all
        (fun entry ->
          let first = render entry and second = render entry in
          String.equal first second
          && (not (String.contains first '\n'))
          &&
          match Reader.parse_one ~file:"audit-property.log" first with
          | Ok { Form.head = "audit-entry-v2"; _ } -> true
          | Ok _ | Error _ -> false)
        entries)

let suite =
  [
    Alcotest.test_case "released types and once effect" `Quick test_released_types_and_once_effect;
    Alcotest.test_case "opaque direct hash sealed" `Quick
      test_opaque_constructor_direct_hash_is_sealed;
    Alcotest.test_case "in-memory order" `Quick test_in_memory_preserves_order;
    Alcotest.test_case "canonical encoding variants" `Quick test_canonical_encoding_all_variants;
    Alcotest.test_case "opaque canonical Hash boundary" `Quick
      test_hash_boundary_rejects_noncanonical_spellings;
    Alcotest.test_case "no generic inspection in log path" `Quick
      test_log_path_has_no_generic_inspection;
    Alcotest.test_case "line-log order and append" `Quick test_line_log_order_and_append;
    Alcotest.test_case "pre-write and completion failures" `Quick
      test_injected_pre_write_failure_is_closed;
    QCheck_alcotest.to_alcotest prop_encoding_is_deterministic;
  ]
