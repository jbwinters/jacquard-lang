open Jacquard

(* PKG.1 slice A: the project-v1 manifest reader, validator, and canonical printer. *)

let rota =
  {|(project-v1
  (name "rota-optimizer")
  (requires (core "0.2"))
  (namespace rota)
  (units "model.jac" "fixtures.jac" "report.jac")
  (exports (type rota-status) (term rota.solve) (type rota-problem))
  (entries
    (test suite (units "tests.jac" "interaction-tests.jac"))
    (run demo (units "demo.jac") (grants console) (native)))
  (metadata (license "Apache-2.0") (description "Shift rota optimizer")))|}

let parse src = Project_manifest.parse ~file:"project.jqd" src

let ok src =
  match parse src with
  | Ok t -> t
  | Error ds ->
      Alcotest.failf "expected a valid manifest: %s"
        (String.concat "; " (List.map Diag.to_string ds))

let codes src =
  match parse src with
  | Ok _ -> []
  | Error ds -> List.sort_uniq String.compare (List.map Diag.code_or_uncoded ds)

let with_fields fields =
  Printf.sprintf "(project-v1 (name \"p\") (requires (core \"0.2\")) %s)" fields

let test_valid_and_canonical () =
  let t = ok rota in
  Alcotest.(check (option string)) "namespace" (Some "rota") t.Project_manifest.namespace;
  Alcotest.(check (list string))
    "unit order kept"
    [ "model.jac"; "fixtures.jac"; "report.jac" ]
    t.units;
  let printed = Project_manifest.print t in
  let again = ok printed in
  Alcotest.(check string)
    "canonical spelling is a fixed point" printed (Project_manifest.print again);
  Alcotest.(check bool)
    "exports sorted in canonical form" true
    (let e = Str.search_forward (Str.regexp_string "(term rota.solve)") printed 0 in
     let ty = Str.search_forward (Str.regexp_string "(type rota-problem)") printed 0 in
     e < ty);
  Alcotest.(check bool)
    "entries keyed and sorted: run before test" true
    (Str.search_forward (Str.regexp_string "(run demo") printed 0
    < Str.search_forward (Str.regexp_string "(test suite") printed 0)

let test_digests () =
  let t = ok rota in
  let renamed = { t with Project_manifest.name = "other"; metadata = [ ("license", "MIT") ] } in
  Alcotest.(check bool)
    "metadata and name do not change the semantic digest" true
    (Hash.equal (Project_manifest.semantic_digest t) (Project_manifest.semantic_digest renamed));
  Alcotest.(check bool)
    "but they do change the document digest" false
    (Hash.equal (Project_manifest.document_digest t) (Project_manifest.document_digest renamed));
  let reordered = { t with Project_manifest.exports = List.rev t.exports } in
  Alcotest.(check bool)
    "export order is not semantic" true
    (Hash.equal (Project_manifest.semantic_digest t) (Project_manifest.semantic_digest reordered));
  let units_swapped = { t with Project_manifest.units = List.rev t.units } in
  Alcotest.(check bool)
    "unit order is semantic" false
    (Hash.equal
       (Project_manifest.semantic_digest t)
       (Project_manifest.semantic_digest units_swapped))

let test_refusals () =
  let check label expected src = Alcotest.(check (list string)) label expected (codes src) in
  Alcotest.(check bool)
    "not a form: E1700 plus the reader's own diagnostic" true
    (List.mem "E1700" (codes "(project-v1"));
  check "wrong head" [ "E1700" ] "(project-v2 (name \"p\") (requires (core \"0.2\")))";
  check "missing requires" [ "E1700" ] "(project-v1 (name \"p\"))";
  check "bad core version" [ "E1700" ] "(project-v1 (name \"p\") (requires (core \"0.2.1\")))";
  check "an unknown requirement beside a valid one is itemized" [ "E1701" ]
    "(project-v1 (name \"p\") (requires (core \"0.2\") (python \"3\")))";
  check "duplicate core requirement" [ "E1702" ]
    "(project-v1 (name \"p\") (requires (core \"0.2\") (core \"0.3\")))";
  check "unknown field" [ "E1701" ] (with_fields "(license \"MIT\")");
  check "unknown dependency field" [ "E1701" ]
    (with_fields "(deps (dep (as d) (path \"../d\") (version \"1\")))");
  check "native on a test entry" [ "E1701" ]
    (with_fields "(entries (test t (units \"t.jac\") (native)))");
  check "duplicate field" [ "E1702" ] (with_fields "(units \"a.jac\") (units \"b.jac\")");
  check "duplicate unit" [ "E1702" ] (with_fields "(units \"a.jac\" \"a.jac\")");
  check "duplicate export" [ "E1702" ] (with_fields "(exports (term a.x) (term a.x))");
  check "duplicate alias" [ "E1702" ]
    (with_fields "(deps (dep (as d) (path \"../a\")) (dep (as d) (path \"../b\")))");
  check "duplicate entry key" [ "E1702" ]
    (with_fields "(entries (run x (units \"a.jac\")) (run x (units \"b.jac\")))");
  check "absolute unit path" [ "E1700" ] (with_fields "(units \"/etc/passwd.jac\")");
  check "url unit path" [ "E1700" ] (with_fields "(units \"https://x/a.jac\")");
  check "non-source unit" [ "E1700" ] (with_fields "(units \"notes.txt\")");
  check "bad namespace" [ "E1700" ] (with_fields "(namespace rota.x)");
  check "unknown export kind" [ "E1700" ] (with_fields "(exports (module a))");
  check "entry without units" [ "E1700" ] (with_fields "(entries (run x))");
  check "oversized manifest" [ "E1703" ] (String.make (Project_manifest.max_bytes + 1) ' ');
  check "oversized text" [ "E1703" ]
    (Printf.sprintf "(project-v1 (name %S) (requires (core \"0.2\")))" (String.make 2000 'x'));
  check "oversized metadata key" [ "E1703" ]
    (with_fields (Printf.sprintf "(metadata (%s \"v\"))" (String.make 2000 'k')));
  check "too many units" [ "E1703" ]
    (with_fields
       (Printf.sprintf "(units %s)"
          (String.concat " " (List.init 300 (fun i -> Printf.sprintf "\"u%d.jac\"" i)))))

let test_requires () =
  let t = ok rota in
  let accepts core = Result.is_ok (Project_manifest.check_requires t ~core) in
  Alcotest.(check bool) "same release" true (accepts "0.2.0");
  Alcotest.(check bool) "later minor" true (accepts "0.3.1");
  Alcotest.(check bool) "earlier minor" false (accepts "0.1.9");
  Alcotest.(check bool) "different major" false (accepts "1.2.0");
  match Project_manifest.check_requires t ~core:"0.1.0" with
  | Error [ d ] -> Alcotest.(check (option string)) "code" (Some "E1704") (Diag.code d)
  | _ -> Alcotest.fail "expected E1704"

(* Every input is either accepted or refused with manifest codes; nothing raises. *)
let fuzz =
  let atoms =
    [
      "project-v1";
      "name";
      "requires";
      "core";
      "namespace";
      "units";
      "exports";
      "deps";
      "dep";
      "as";
      "path";
      "bundle";
      "pin";
      "entries";
      "run";
      "test";
      "grants";
      "native";
      "metadata";
      "term";
      "type";
      "\"0.2\"";
      "\"a.jac\"";
      "\"../x\"";
      "rota";
      "x";
      "#00";
      "42";
      "\"\"";
    ]
  in
  let rec gen depth =
    QCheck.Gen.(
      if depth = 0 then oneof_list atoms
      else
        oneof_weighted
          [
            (3, oneof_list atoms);
            ( 2,
              list_size (int_range 0 4) (gen (depth - 1)) >|= fun items ->
              "(" ^ String.concat " " items ^ ")" );
          ])
  in
  let arb =
    QCheck.make ~print:Fun.id
      QCheck.Gen.(
        list_size (int_range 0 6) (gen 3) >|= fun fields ->
        "(project-v1 " ^ String.concat " " fields ^ ")")
  in
  QCheck.Test.make ~name:"manifest parsing is total" ~count:2000 arb (fun src ->
      match parse src with
      | Ok _ -> true
      | Error ds ->
          ds <> []
          && List.for_all
               (fun d ->
                 match Diag.code d with
                 | Some c ->
                     String.length c = 5 && (String.sub c 0 3 = "E17" || c.[1] = '0' || c.[1] = '1')
                 | None -> true)
               ds
      | exception e -> QCheck.Test.fail_reportf "raised %s" (Printexc.to_string e))

let suite =
  [
    Alcotest.test_case "a valid manifest and its canonical spelling" `Quick test_valid_and_canonical;
    Alcotest.test_case "semantic and document digests" `Quick test_digests;
    Alcotest.test_case "every malformed manifest is refused with its code" `Quick test_refusals;
    Alcotest.test_case "the Core requirement" `Quick test_requires;
    QCheck_alcotest.to_alcotest fuzz;
  ]
