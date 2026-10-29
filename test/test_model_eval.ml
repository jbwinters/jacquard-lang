open Jacquard
module E = Model_eval
module T = Observation_transcript

let dependency =
  {
    Model_doc.entry = Hash.of_string "entry";
    signature = Hash.of_string "sig";
    labels = None;
    prelude = "none";
    core = "0.3.0";
    driver = Model_doc.Enumerate { max_branches = 10 };
    fuel = 1000;
    policy = Hash.of_string "policy";
    arguments = [ Model_doc.Assumption (Hash.of_string "a") ];
  }

let cacheable =
  [
    E.Value (Some (T.Data "outcome value\nwith a newline"));
    E.Posterior
      {
        sampled = false;
        explored = 2;
        entries =
          Some
            [
              { E.probability = 0.7; value = T.Data "false#00" };
              { E.probability = 0.30000000000000004; value = T.Data "true#01" };
            ];
      };
    E.Posterior { sampled = true; explored = 5; entries = Some [] };
    E.Inference_failure { sampled = false; explored = 3; failure = "impossible" };
    E.Failure "arithmetic";
  ]

let test_round_trip () =
  List.iter
    (fun outcome ->
      Alcotest.(check (option string)) "cacheable" None (E.uncacheable outcome);
      let bytes = E.serialize dependency outcome in
      match E.parse bytes with
      | Ok (d, o) -> Alcotest.(check string) "re-serializes byte for byte" bytes (E.serialize d o)
      | Error m -> Alcotest.failf "parse failed: %s" m)
    cacheable

let test_uncacheable () =
  let reason label expected outcome =
    Alcotest.(check (option string)) label (Some expected) (E.uncacheable outcome);
    Alcotest.(check bool)
      (label ^ " is never parsed") true
      (Result.is_error (E.parse (E.serialize dependency outcome)))
  in
  reason "incomplete" "fuel" E.Incomplete;
  reason "excluded" "result-excluded" (E.Value None);
  reason "a secret" "secret" (E.Value (Some (T.Unsupported "secret")));
  reason "truncated" "truncated" (E.Value (Some (T.Truncated { total = 9; prefix = "ab" })));
  reason "a closure in a posterior" "closure"
    (E.Posterior
       {
         sampled = false;
         explored = 1;
         entries = Some [ { E.probability = 1.0; value = T.Unsupported "closure" } ];
       })

let test_strict_parse () =
  let bytes = E.serialize dependency (List.nth cacheable 1) in
  let refused label input = Alcotest.(check bool) label true (Result.is_error (E.parse input)) in
  let replace a b = Str.global_replace (Str.regexp_string a) b bytes in
  refused "trailing bytes" (bytes ^ "x");
  refused "truncated" (String.sub bytes 0 (String.length bytes - 1));
  refused "entry count" (replace "entries=2" "entries=3");
  refused "noncanonical probability" (replace "p=0.69999999999999996" "p=0.7");
  refused "payload length" (replace "data bytes=8" "data bytes=9");
  refused "no outcome" (Model_doc.serialize_dependency dependency);
  refused "an overflowing payload length"
    (E.serialize dependency (E.Value (Some (T.Data "x")))
    |> Str.global_replace (Str.regexp_string "data bytes=1") "data bytes=4611686018427387903");
  refused "foreign record" ("x" ^ bytes)

let history_dependency =
  {
    dependency with
    Model_doc.arguments =
      dependency.Model_doc.arguments
      @ [ Model_doc.Term { term = Hash.of_string "t"; signature = Hash.of_string "s" } ];
  }

let record =
  {
    Model_history.time = "2026-10-28T05:56:31Z";
    entry_name = "scale";
    entry_closure = Some (Hash.of_string "closure");
    key = Model_doc.key history_dependency;
    previous = Some (Hash.of_string "older");
    outcome = "fresh value";
    source = Hash.of_string "source";
    interface = Hash.of_string "interface";
    policy_snapshot = Hash.of_string "policy";
    bindings =
      [
        { Model_history.kind = "assumption"; name = "base"; snapshot = Some (Hash.of_string "3") };
        { Model_history.kind = "term"; name = "helper"; snapshot = None };
      ];
    dependency = history_dependency;
  }

let input_dependency =
  {
    history_dependency with
    Model_doc.arguments =
      [
        Model_doc.Input (Hash.of_string "bytes");
        Model_doc.Term { term = Hash.of_string "t"; signature = Hash.of_string "s" };
      ];
  }

let frame r =
  let b = Model_history.serialize_record r in
  Printf.sprintf "entry bytes=%d\n%s\n" (String.length b) b

let test_history_round_trip () =
  let bytes =
    frame record ^ frame { record with Model_history.previous = None; outcome = "cached value" }
  in
  match Model_history.parse_history bytes with
  | Ok [ a; b ] ->
      Alcotest.(check string) "first" (frame record) (frame a);
      Alcotest.(check string) "second" "cached value" b.Model_history.outcome
  | Ok _ -> Alcotest.fail "expected two records"
  | Error m -> Alcotest.failf "parse failed: %s" m

(* a record written before closure manifests existed has no entry-closure line, and still parses *)
let test_history_without_closure () =
  let old = { record with Model_history.entry_closure = None } in
  let bytes = frame old in
  Alcotest.(check bool)
    "no entry-closure line" false
    (Str.string_match (Str.regexp ".*entry-closure") bytes 0);
  match Model_history.parse_history bytes with
  | Ok [ r ] -> Alcotest.(check string) "round trip" bytes (frame r)
  | _ -> Alcotest.fail "a record without a closure did not parse"

let test_history_strict () =
  let bytes = frame record in
  let refused label input =
    Alcotest.(check bool) label true (Result.is_error (Model_history.parse_history input))
  in
  let replace a b = Str.global_replace (Str.regexp_string a) b bytes in
  refused "trailing bytes" (bytes ^ "x");
  refused "frame length" (replace "entry bytes=" "entry bytes=9");
  refused "an overflowing frame length"
    (Str.global_replace (Str.regexp "entry bytes=[0-9]*") "entry bytes=4611686018427387903" bytes);
  refused "binding count" (replace "bindings 2" "bindings 3");
  refused "binding order" (replace "binding 1 term" "binding 0 term");
  let reframe r = frame r in
  refused "a key that is not the dependency record's"
    (reframe { record with Model_history.key = Hash.of_string "another" });
  refused "a binding kind that does not match its argument"
    (reframe
       {
         record with
         Model_history.bindings =
           [
             { Model_history.kind = "input"; name = "base"; snapshot = Some (Hash.of_string "3") };
             { Model_history.kind = "term"; name = "helper"; snapshot = None };
           ];
       });
  refused "an input snapshot that is not its identity"
    (reframe
       {
         record with
         Model_history.bindings =
           [
             {
               Model_history.kind = "input";
               name = "note";
               snapshot = Some (Hash.of_string "other");
             };
             { Model_history.kind = "term"; name = "helper"; snapshot = None };
           ];
         dependency = input_dependency;
         key = Model_doc.key input_dependency;
       });
  refused "a missing binding"
    (reframe { record with Model_history.bindings = [ List.hd record.Model_history.bindings ] });
  Alcotest.(check bool)
    "an empty history is no records" true
    (Model_history.parse_history "" = Ok [])

let suite =
  [
    Alcotest.test_case "model history round trip" `Quick test_history_round_trip;
    Alcotest.test_case "model history strict parse" `Quick test_history_strict;
    Alcotest.test_case "model history without closures" `Quick test_history_without_closure;
    Alcotest.test_case "model-result round trip" `Quick test_round_trip;
    Alcotest.test_case "model-result refuses uncacheable outcomes" `Quick test_uncacheable;
    Alcotest.test_case "model-result strict parse" `Quick test_strict_parse;
  ]
