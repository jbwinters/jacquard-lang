open Jacquard
module L = Exploration_log

let entry index kind ?site ?result ?output arguments =
  {
    L.e_index = index;
    e_kind = kind;
    e_operation = Hash.of_string ("op-" ^ string_of_int index);
    e_name = "op " ^ string_of_int index;
    e_site = site;
    e_arguments = arguments;
    e_result = result;
    e_output = output;
  }

let sample_log =
  {
    L.program =
      "program source="
      ^ Hash.to_hex (Hash.of_string "src")
      ^ " core=0.3.0 prelude=none engine=interpreter";
    seed = 7;
    grants = "console,Odd Name";
    policy_identity = Hash.of_string "policy";
    output_recorded = true;
    entries =
      [
        entry 0 L.Choice_step ~site:"m.jac:1:10-1:32" ~result:(Observation_transcript.Data "true")
          [ (0, Observation_transcript.Data "bernoulli(0.5)") ];
        entry 1 L.Operation_step
          ~output:(Observation_transcript.Truncated { total = 99; prefix = "line\nwith newline" })
          ~result:(Observation_transcript.Failure "E0901")
          [
            (0, Observation_transcript.Truncated { total = 9000; prefix = "abc\ndef" });
            (2, Observation_transcript.Unsupported "secret");
            (3, Observation_transcript.Missing);
            (4, Observation_transcript.Unfinished);
          ];
        entry 2 L.Observe_step [];
      ];
    ending = L.Exit 0;
  }

let test_round_trip () =
  let bytes = L.serialize sample_log in
  (match L.parse bytes with
  | Ok log -> Alcotest.(check string) "re-serializes byte for byte" bytes (L.serialize log)
  | Error m -> Alcotest.failf "parse failed: %s" m);
  let bounded = L.serialize { sample_log with ending = L.Bounded "steps" } in
  match L.parse bounded with
  | Ok { L.ending = L.Bounded "steps"; _ } -> ()
  | _ -> Alcotest.fail "bounded ending did not round-trip"

let test_strict_parse () =
  let bytes = L.serialize sample_log in
  let refused label input = Alcotest.(check bool) label true (Result.is_error (L.parse input)) in
  refused "trailing bytes" (bytes ^ "x");
  refused "truncated" (String.sub bytes 0 (String.length bytes - 2));
  refused "other format"
    ("jacquard-exploration-log format=2" ^ String.sub bytes 33 (String.length bytes - 33));
  refused "step count" (Str.global_replace (Str.regexp_string "end steps=3") "end steps=4" bytes);
  refused "negative argument count"
    (Str.global_replace (Str.regexp_string "kind=observe") "kind=observe" bytes
    |> Str.global_replace (Str.regexp "arguments=0") "arguments=-1");
  refused "bad program source"
    (Str.global_replace (Str.regexp "program source=[0-9a-f]*") "program source=garbage" bytes);
  refused "bad seed" (Str.global_replace (Str.regexp_string "seed 7") "seed nonsense" bytes);
  refused "bad grants frame"
    (Str.global_replace (Str.regexp_string "grants bytes=16") "grants bytes=99" bytes);
  refused "bad bound"
    (Str.global_replace (Str.regexp_string "end steps=3 exit=0") "end steps=3 bounded=nope" bytes);
  refused "negative argument index"
    (Str.global_replace (Str.regexp_string "argument index=2") "argument index=-2" bytes);
  refused "truncated total within prefix"
    (Str.global_replace (Str.regexp_string "truncated total=9000") "truncated total=3" bytes);
  refused "oversized frame"
    (Str.global_replace (Str.regexp_string "name bytes=4") "name bytes=4611686018427387903" bytes)

let suite =
  [
    Alcotest.test_case "exploration-log round trip" `Quick test_round_trip;
    Alcotest.test_case "exploration-log strict parse" `Quick test_strict_parse;
  ]
