open Jacquard

let test_schedule_seed_law () =
  let expected =
    [
      42;
      4_456_085_495_900_499_605;
      2_949_826_092_126_892_291;
      -4_084_088_288_392_011_950;
      -2_874_173_976_596_520_044;
      701_532_786_141_963_250;
      -2_430_762_948_046_562_554;
      4_028_864_712_777_624_925;
    ]
  in
  let first = Relate.schedule_seeds ~root_seed:42 ~count:8 in
  let second = Relate.schedule_seeds ~root_seed:42 ~count:8 in
  Alcotest.(check (list int)) "exact SplitMix64 vector" expected first;
  Alcotest.(check (list int)) "repeated derivation is identical" first second;
  Alcotest.(check int) "requested cardinality" 8 (List.length first);
  Alcotest.(check int) "pairwise uniqueness" 8 (List.length (List.sort_uniq Int.compare first));
  Alcotest.(check (list int))
    "zero count is empty" []
    (Relate.schedule_seeds ~root_seed:42 ~count:0);
  Alcotest.(check (list int))
    "negative count is empty" []
    (Relate.schedule_seeds ~root_seed:42 ~count:(-1))

let test_secret_payload_and_redaction_laws () =
  let expected = ("rw-secret-v0-a-bdd732262feb6e95", "rw-secret-v0-b-28efe333b266f103") in
  let first_a, first_b = Relate.secret_payloads ~root_seed:42 in
  let second = Relate.secret_payloads ~root_seed:42 in
  Alcotest.(check (pair string string)) "exact SplitMix64 payload vector" expected (first_a, first_b);
  Alcotest.(check (pair string string)) "repeated derivation is identical" (first_a, first_b) second;
  Alcotest.(check bool) "payloads are distinct" false (String.equal first_a first_b);
  List.iter
    (fun payload ->
      Alcotest.(check bool)
        "recognizable prefix" true
        (String.starts_with ~prefix:"rw-secret-v0-" payload))
    [ first_a; first_b ];
  Alcotest.(check string)
    "embedded and repeated payloads are replaced" "before/<secret redacted>/<secret redacted>/after"
    (Relate.redact ~secrets:[ first_a; first_b ] ("before/" ^ first_a ^ "/" ^ first_b ^ "/after"));
  Alcotest.(check string)
    "longest overlapping payload wins" "<secret redacted>/<secret redacted>"
    (Relate.redact ~secrets:[ "token"; "token-long" ] "token-long/token");
  Alcotest.(check string)
    "empty payload is ignored" "unchanged"
    (Relate.redact ~secrets:[ "" ] "unchanged")

let test_secret_divergence_rendering () =
  let first, second = Relate.secret_payloads ~root_seed:42 in
  let redact = Relate.redact ~secrets:[ first; second ] in
  let value_divergence : Run_transcript.divergence =
    {
      position = Value_position 3;
      kind = Value_divergence;
      left = Value_side ("prefix-" ^ first ^ "-suffix\n");
      right = Value_side ("prefix-" ^ second ^ "-suffix\n");
    }
  in
  Alcotest.(check string)
    "value position and marker remain visible"
    "  at observation[3].value:\n\
    \    - \"prefix-<secret redacted>-suffix\\n\"\n\
    \    + \"prefix-<secret redacted>-suffix\\n\""
    (Run_transcript.render_redacted ~redact value_divergence);
  let control : Run_transcript.divergence =
    {
      position = Value_position 0;
      kind = Value_divergence;
      left = Value_side "left\n";
      right = Value_side "right\n";
    }
  in
  Alcotest.(check string)
    "ordinary values retain the canonical renderer" (Run_transcript.render control)
    (Run_transcript.render_redacted ~redact control);
  let operation =
    match
      Hash.of_canonical_hex "28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e"
    with
    | Some operation -> operation
    | None -> Alcotest.fail "frozen Console.print hash is malformed"
  in
  let trace_divergence : Run_transcript.divergence =
    {
      position = Trace_position { observation_index = 1; trace_index = 2 };
      kind = Trace_divergence;
      left = Trace_side { operation; output = first };
      right = Trace_side { operation; output = second };
    }
  in
  let rendered = Run_transcript.render_redacted ~redact trace_divergence in
  Alcotest.(check string)
    "trace path, operation, and redacted output"
    (Printf.sprintf
       "  at observation[1].trace[2]:\n\
       \    - operation=%s output=\"<secret redacted>\"\n\
       \    + operation=%s output=\"<secret redacted>\""
       (Hash.to_hex operation) (Hash.to_hex operation))
    rendered

let suite =
  [
    Alcotest.test_case "schedule seed vector and laws" `Quick test_schedule_seed_law;
    Alcotest.test_case "secret payload and redaction laws" `Quick
      test_secret_payload_and_redaction_laws;
    Alcotest.test_case "secret divergence rendering" `Quick test_secret_divergence_rendering;
  ]
