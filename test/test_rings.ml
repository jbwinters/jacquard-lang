open Jacquard

(* SL.9: the layering audit ("rings are literal", made executable) and the ring-0
   freeze. Pure store-graph traversal over Store.deps — no new machinery. *)

let prelude_store () =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "open_store" ds
  in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "prelude load" ds);
  store

let manifest () = Corpus_support.parse_rings "../prelude/rings.manifest"

(* the whole shipped prelude stays ring-monotone, and the manifest is complete *)
let test_prelude_audit_green () =
  let violations = Corpus_support.ring_violations (prelude_store ()) (manifest ()) in
  Alcotest.(check (list string)) "no ring violations, no manifest gaps" [] violations

(* the audit can actually fail: a fixture store where a "ring 0" definition calls a
   "ring 2" one is reported with the offending edge named *)
let test_audit_catches_violation () =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "open_store" ds
  in
  let put src = ignore (Eval_support.put_src store (Store.names_view store) src) in
  put "(defterm ((binding fancy-helper () (lit 42))))";
  put "(defterm ((binding humble-base () (app (var fancy-helper)))))";
  let fixture = [ ("humble-base", 0); ("fancy-helper", 2) ] in
  match Corpus_support.ring_violations store fixture with
  | [ v ] -> Alcotest.(check string) "edge named" "humble-base (ring 0) -> fancy-helper (ring 2)" v
  | vs -> Alcotest.failf "expected exactly one violation, got [%s]" (String.concat "; " vs)

(* the manifest-gap arm: an unmapped name is reported, not silently skipped *)
let test_audit_reports_manifest_gap () =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "open_store" ds
  in
  ignore (Eval_support.put_src store Resolve.empty_names "(defterm ((binding stray () (lit 1))))");
  match Corpus_support.ring_violations store [] with
  | [ v ] -> Alcotest.(check string) "gap named" "missing from rings.manifest: stray" v
  | vs -> Alcotest.failf "expected the gap report, got [%s]" (String.concat "; " vs)

(* D8's convention, asserted: nothing in the shipped prelude references debug.inspect *)
let test_debug_inspect_unused_in_library () =
  let store = prelude_store () in
  match Store.lookup_kind store "debug.inspect" Resolve.KTerm with
  | None -> Alcotest.fail "debug.inspect missing"
  | Some { Resolve.hash; _ } -> (
      match Store.dependents store hash with
      | Ok [] -> ()
      | Ok deps -> Alcotest.failf "debug.inspect has %d library dependents" (List.length deps)
      | Error ds -> Eval_support.fail_diags "dependents" ds)

(* the freeze artifact: ring-0 names + elaborated signatures, golden-pinned *)
let test_ring0_freeze_golden () =
  match
    Corpus_support.freeze_lines ~prelude_dir:"../prelude" ~manifest:"../prelude/rings.manifest"
  with
  | Error ds -> Eval_support.fail_diags "freeze" ds
  | Ok lines ->
      let golden =
        Corpus_support.read_file "../corpus/golden/ring0-freeze.golden"
        |> String.split_on_char '\n'
        |> List.filter (fun l -> l <> "")
      in
      Alcotest.(check (list string))
        "ring-0 freeze (regenerate with `dune exec test/gen_freeze_goldens.exe` and review)" golden
        lines

(* the grid's deliberate blanks stay absent: nobody "helpfully" fills them in *)
let test_grid_blanks_absent () =
  let store = prelude_store () in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " must not exist") true (Store.lookup_all store name = []))
    [
      "result.filter";
      "option.length";
      "option.reverse";
      "list.with-default";
      "map";
      "fold";
      "append";
      "not";
      "and";
      "or";
    ]

let suite =
  [
    Alcotest.test_case "prelude layering audit is green" `Quick test_prelude_audit_green;
    Alcotest.test_case "audit catches a planted violation" `Quick test_audit_catches_violation;
    Alcotest.test_case "audit reports manifest gaps" `Quick test_audit_reports_manifest_gap;
    Alcotest.test_case "debug.inspect unused in the library" `Quick
      test_debug_inspect_unused_in_library;
    Alcotest.test_case "ring-0 freeze golden" `Quick test_ring0_freeze_golden;
    Alcotest.test_case "grid blanks stay absent" `Quick test_grid_blanks_absent;
  ]
