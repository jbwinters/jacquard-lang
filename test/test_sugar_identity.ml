(* SX.31: surface sugar binds the prelude's constructors by identity. *)

open Jacquard

let prelude_dir = "../prelude"
let fail_diagnostics ds = String.concat "\n" (List.map Diag.to_string ds)

let expect_ok label = function
  | Ok value -> value
  | Error ds -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics ds)

let fresh_root =
  let serial = ref 0 in
  fun () ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-sugar-%d-%d" (Unix.getpid ()) !serial)

let session () =
  fst (expect_ok "open session" (Frontend.open_session ~prelude_dir ~root:(fresh_root ())))

(* the identity of [name] after walking [source] in a fresh session *)
let identity_of source name =
  let store = session () in
  let tops, _ =
    expect_ok "resolve"
      (Frontend.resolve_source_tops ~syntax:Frontend.Surface store ~file:"s.jac" source)
  in
  ignore tops;
  match Store.lookup_kind store name Resolve.KTerm with
  | Some { Resolve.hash; _ } -> Hash.to_hex hash
  | None -> Alcotest.failf "%s is not bound" name

let test_constants_pin_the_prelude () =
  let store = session () in
  List.iter
    (fun (name, hex) ->
      match Store.lookup_kind store name Resolve.KCon with
      | Some { Resolve.hash; _ } -> Alcotest.(check string) name hex (Hash.to_hex hash)
      | None -> Alcotest.failf "the prelude binds no constructor %s" name)
    Sugar_identity.constructors

let shadows =
  "type Light = | True | False\n\
   type Seq = | Nil | Cons Int Seq\n\
   type Outcome = | Ok Int | Err Text\n"

let test_sugar_ignores_file_constructors () =
  List.iter
    (fun (label, definition) ->
      Alcotest.(check string)
        (label ^ " keeps its identity beside same-named constructors")
        (identity_of definition "f")
        (identity_of (shadows ^ definition) "f"))
    [
      ("if", "f(x) = if x then 1 else 2\n");
      ("list literal", "f() = [1, 2]\n");
      ("empty list", "f() = []\n");
      ("try", "f(r) = {\n  let v = try r\n  v\n}\n");
    ];
  (* an explicit constructor still means the file's own *)
  let store = session () in
  match
    Frontend.resolve_source_tops ~syntax:Frontend.Surface store ~file:"s.jac"
      "type Light = | True | False\nf() = True\n"
  with
  | Ok _ -> (
      match (Store.lookup_kind store "true" Resolve.KCon, Sugar_identity.constructors) with
      | Some { Resolve.hash; _ }, (_, prelude_true) :: _ ->
          Alcotest.(check bool)
            "an explicit True is the file's constructor" true
            (Hash.to_hex hash <> prelude_true)
      | _ -> Alcotest.fail "no true constructor")
  | Error ds -> Alcotest.failf "resolve failed:\n%s" (fail_diagnostics ds)

let test_without_the_prelude_names_still_resolve () =
  (* an environment that does not hold the prelude's constructors resolves sugar by name *)
  let names = Corpus_support.stub_names in
  match Surface_parse.parse_string ~file:"s.jac" "f(x) = if x then 1 else 2\n" with
  | Error ds -> Alcotest.failf "parse failed:\n%s" (fail_diagnostics ds)
  | Ok parsed -> (
      match Surface_lower.lower_tops parsed with
      | Error ds -> Alcotest.failf "lower failed:\n%s" (fail_diagnostics ds)
      | Ok tops ->
          List.iter (fun top -> ignore (expect_ok "stub resolve" (Resolve.resolve names top))) tops)

let suite =
  [
    Alcotest.test_case "the pinned identities are the prelude's constructors" `Quick
      test_constants_pin_the_prelude;
    Alcotest.test_case "if, lists, and try ignore same-named file constructors" `Quick
      test_sugar_ignores_file_constructors;
    Alcotest.test_case "without the prelude, sugar resolves by name" `Quick
      test_without_the_prelude_names_still_resolve;
  ]
