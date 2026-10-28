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
  refused "foreign record" ("x" ^ bytes)

let suite =
  [
    Alcotest.test_case "model-result round trip" `Quick test_round_trip;
    Alcotest.test_case "model-result refuses uncacheable outcomes" `Quick test_uncacheable;
    Alcotest.test_case "model-result strict parse" `Quick test_strict_parse;
  ]
