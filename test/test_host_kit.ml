(* HB.3: the executable conformance kit agrees with the frozen vectors, the published recipe, and
   the installed worker. *)

open Jacquard
module Host = Host_protocol_v0
module K = Host_kit

let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

type fixture = {
  store : string;
  ids : K.identities;
  doc : K.document;
  kit : Yojson.Safe.t;
  transcripts : Yojson.Safe.t list;
}

let kit_path name = Filename.concat (K.kit_dir ()) name

let make_fixture () =
  let binary = K.default_binary () in
  let store = K.fresh_path "store" in
  (match
     K.build_store ~binary ~fixtures:(kit_path "fixtures.jac") ~prelude:(K.prelude_dir ()) ~store
   with
  | Ok () -> ()
  | Error message -> Alcotest.fail ("recipe failed: " ^ message));
  let handle =
    match Store.open_store store with
    | Ok handle -> handle
    | Error diagnostics -> Alcotest.fail (fail_diagnostics diagnostics)
  in
  let ids = match K.identities_of_store handle with Ok ids -> ids | Error m -> Alcotest.fail m in
  let doc = K.load_vectors (Filename.concat (Filename.dirname (K.kit_dir ())) "vectors.json") in
  let kit = Yojson.Safe.from_file (kit_path "kit.json") in
  let transcripts = K.items (Yojson.Safe.from_file (kit_path "transcripts.json")) in
  at_exit (fun () -> K.remove_tree store);
  { store; ids; doc; kit; transcripts }

let fixture = lazy (make_fixture ())
let fixture () = Lazy.force fixture
let binary () = K.default_binary ()

let check_json label expected actual =
  Alcotest.(check string) label (K.to_string expected) (K.to_string actual)

let test_recipe_reproduces_identities () =
  let f = fixture () in
  check_json "identities" (K.member "identities" f.kit) (K.identities_json f.ids);
  check_json "bindings" (K.member "bindings" f.kit) (K.bindings_json f.ids);
  Alcotest.(check string) "protocol" Host.protocol (K.text (K.member "protocol" f.kit));
  Alcotest.(check string) "carrier" Host.carrier (K.text (K.member "carrier" f.kit));
  Alcotest.(check string) "core version" Version.version (K.text (K.member "core_version" f.kit));
  check_json "hard limits" (Host.limits_to_yojson Host.hard_limits) (K.member "hard_limits" f.kit);
  check_json "vector hard limits" f.doc.K.hard_limits (K.member "hard_limits" f.kit)

let test_transcripts_cover_every_vector () =
  let f = fixture () in
  let names = List.map (fun t -> K.text (K.member "name" t)) f.transcripts in
  let expected =
    List.map (fun p -> p.K.positive_name) f.doc.K.positives
    @ List.map (fun h -> h.K.hostile_name) f.doc.K.hostiles
  in
  Alcotest.(check (list string)) "one transcript per vector" expected names;
  Alcotest.(check int)
    "manifest count" (List.length expected)
    (K.integer (K.member "transcript_count" f.kit))

let pending_names f =
  K.items (K.member "pending_decisions" f.kit) |> List.map (fun p -> K.text (K.member "name" p))

let test_every_transcript_replays () =
  let f = fixture () in
  List.iter2
    (fun case transcript ->
      let observed = K.play ~binary:(binary ()) ~store:f.store case in
      let fresh = K.transcript_of case observed in
      check_json (case.K.name ^ " transcript is reproducible") transcript fresh;
      let status = K.text (K.member "status" transcript) in
      if List.mem case.K.name (pending_names f) then
        Alcotest.(check string) (case.K.name ^ " is a recorded divergence") "diverges" status
      else Alcotest.(check string) (case.K.name ^ " conforms") "conforms" status)
    (K.cases f.doc f.ids) f.transcripts

let test_positive_frames_equal_templates () =
  let f = fixture () in
  List.iter
    (fun positive ->
      let case = K.positive_case f.doc f.ids positive in
      let observed = K.play ~binary:(binary ()) ~store:f.store case in
      Alcotest.(check int)
        (case.K.name ^ " frame count")
        (List.length case.K.expected_core)
        (List.length observed.K.core_frames);
      List.iter2
        (fun (template, expected) actual ->
          check_json (case.K.name ^ " " ^ template) (K.strip_prose expected) (K.strip_prose actual))
        case.K.expected_core observed.K.core_frames;
      Alcotest.(check bool)
        (case.K.name ^ " host message suffix")
        true
        (K.host_message_suffix_honoured case observed);
      Alcotest.(check (option int)) (case.K.name ^ " exit") (Some 0) observed.K.exit_code)
    f.doc.K.positives

let test_pending_decisions_are_explicit () =
  let f = fixture () in
  let pending = K.items (K.member "pending_decisions" f.kit) in
  List.iter
    (fun entry ->
      let name = K.text (K.member "name" entry) in
      let transcript = List.find (fun t -> K.text (K.member "name" t) = name) f.transcripts in
      Alcotest.(check string)
        (name ^ " expected code")
        (K.text (K.member "expected" entry))
        (K.text (K.member "code" (K.member "expect" transcript)));
      Alcotest.(check string)
        (name ^ " observed code")
        (K.text (K.member "observed" entry))
        (K.text (K.member "primary_code" (K.member "observed" transcript))))
    pending;
  Alcotest.(check (list string))
    "only the known discrepancy is pending" [ "noncanonical-target-hash" ]
    (List.map (fun e -> K.text (K.member "name" e)) pending)

let test_terminal_mappings_execute () =
  let f = fixture () in
  let mappings =
    K.items
      (K.member "terminal_mappings"
         (Yojson.Safe.from_file (Filename.concat (Filename.dirname (K.kit_dir ())) "vectors.json")))
  in
  let base = List.find (fun p -> p.K.positive_name = "one-once-effect-success") f.doc.K.positives in
  List.iter
    (fun mapping ->
      let kind = K.text (K.member "kind" mapping) in
      let response =
        `Assoc
          ([
             ("invocation_id", `String "0000000000000000");
             ("kind", `String kind);
             ("protocol", `String Host.protocol);
             ("request_id", `String "0000000000000001");
           ]
          @
          if kind = "effect_failure" then
            [
              ("category", K.member "category" mapping);
              ("completion", K.member "completion" mapping);
              ("message", `String "redacted");
            ]
          else
            [ ("reason", K.member "reason" mapping); ("completion", K.member "completion" mapping) ]
          )
      in
      let steps =
        List.map
          (function
            | K.Host_input (K.Frame ("effect_ok", _)) -> K.Host_input (K.Frame (kind, response))
            | step -> step)
          (K.steps_of f.doc f.ids base.K.sequence)
      in
      let case =
        {
          (K.positive_case f.doc f.ids base) with
          K.name = "mapping";
          kind = "hostile";
          phase = Some "effect_response";
          steps;
          expect =
            `Assoc
              [
                ("code", K.member "primary_code" mapping);
                ("effect_requests_before_failure", `Int 1);
                ("forbid_outside_action", `Bool false);
                ("terminal_frames_max", `Int 1);
              ];
        }
      in
      let observed = K.play ~binary:(binary ()) ~store:f.store case in
      let _, code, terminal, _, _ = K.summary observed in
      let label =
        kind ^ "/"
        ^ Yojson.Safe.to_string (K.member "category" mapping)
        ^ Yojson.Safe.to_string (K.member "reason" mapping)
        ^ "/"
        ^ K.text (K.member "completion" mapping)
      in
      Alcotest.(check (option string))
        (label ^ " code")
        (Some (K.text (K.member "primary_code" mapping)))
        code;
      Alcotest.(check (option string))
        (label ^ " terminal")
        (Some (K.text (K.member "terminal" mapping)))
        terminal)
    mappings

let test_prose_drift_is_recorded () =
  let f = fixture () in
  let drift = K.items (K.member "drift" (K.member "diagnostic_prose" f.kit)) in
  Alcotest.(check bool)
    "prose is declared non-normative" false
    (Yojson.Safe.Util.to_bool (K.member "normative" (K.member "diagnostic_prose" f.kit)));
  List.iter
    (fun entry ->
      let path = K.text (K.member "path" entry) in
      Alcotest.(check bool)
        (path ^ " is a prose field") true
        (List.exists (fun field -> Filename.check_suffix path ("/" ^ field)) K.prose_fields))
    drift;
  Alcotest.(check (list string))
    "drifting transcripts"
    [ "refused-authority"; "timeout-with-unknown-completion" ]
    (List.sort_uniq String.compare (List.map (fun e -> K.text (K.member "transcript" e)) drift))

let suite =
  [
    Alcotest.test_case "template prose drift is recorded, never silently normalised" `Quick
      test_prose_drift_is_recorded;
    Alcotest.test_case "recipe reproduces the published identities and limits" `Quick
      test_recipe_reproduces_identities;
    Alcotest.test_case "transcripts cover every positive and hostile vector" `Quick
      test_transcripts_cover_every_vector;
    Alcotest.test_case "every transcript replays byte-for-byte through the worker" `Quick
      test_every_transcript_replays;
    Alcotest.test_case "positive sequences equal the bound HB.1 templates" `Quick
      test_positive_frames_equal_templates;
    Alcotest.test_case "pending decisions are explicit and exact" `Quick
      test_pending_decisions_are_explicit;
    Alcotest.test_case "all thirteen terminal mappings execute" `Quick
      test_terminal_mappings_execute;
  ]
