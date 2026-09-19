(* RF.1: the shared frontend services and the sealed checked artifact. *)

open Jacquard

let prelude_dir = "../prelude"
let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let fresh_root =
  let serial = ref 0 in
  fun label ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-frontend-%s-%d-%d" label (Unix.getpid ()) !serial)

let program =
  "safe-div(n, d) = if eq(d, 0) then abort() else div(n, d)\n\
   twice(n) = add(n, n)\n\
   safe-div(twice(3), 3)\n"

let declarations = "safe-div(n, d) = if eq(d, 0) then abort() else div(n, d)\n"

let check ?(file = "program.jac") ?root source =
  let root = match root with Some root -> root | None -> fresh_root "check" in
  (root, expect_ok "check" (Frontend.check ~prelude_dir ~root ~syntax:Frontend.Auto ~file source))

let checked ?file ?root source =
  match check ?file ?root source with
  | root, Frontend.Checked artifact -> (root, artifact)
  | _, Frontend.Recovered _ -> Alcotest.fail "a strict source produced a recovery report"

let session label =
  let store, ctx =
    expect_ok "open session" (Frontend.open_session ~prelude_dir ~root:(fresh_root label))
  in
  (store, ctx)

let effect_hash store name =
  match Store.lookup_kind store name Resolve.KEffect with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.failf "prelude effect %s missing" name

let hex_list hashes = List.map Hash.to_hex hashes

let test_artifact_binds_shared_facts () =
  let _root, artifact = checked program in
  let store, _ctx = session "facts" in
  Alcotest.(check string)
    "source digest"
    (Hash.to_hex (Hash.of_string program))
    (Hash.to_hex (Frontend.Checked.source_digest artifact));
  Alcotest.(check bool)
    "prelude identity recorded" true
    (Frontend.Checked.prelude artifact = Store.prelude_manifest store
    && Frontend.Checked.prelude artifact <> None);
  let tops = Frontend.Checked.tops artifact in
  Alcotest.(check int) "tops in source order" 3 (List.length tops);
  let names = List.concat_map (fun top -> List.map fst top.Frontend.Checked.signatures) tops in
  (* an expression's scheme is reported under [_], as [check --print-sigs] shows it *)
  Alcotest.(check (list string)) "signatures" [ "safe-div"; "twice"; "_" ] names;
  let expression = List.nth tops 2 in
  Alcotest.(check (list string))
    "expression effects"
    [ Hash.to_hex (effect_hash store "abort") ]
    (hex_list expression.Frontend.Checked.effects);
  Alcotest.(check bool) "expression has no identity" true (expression.identity = None);
  let introduced =
    List.concat_map
      (fun top ->
        match top.Frontend.Checked.identity with
        | Some { Canon.decl_hash; named } -> decl_hash :: List.map snd named
        | None -> [])
      tops
  in
  let dependencies = Frontend.Checked.dependencies artifact in
  Alcotest.(check bool) "depends on the prelude" true (dependencies <> []);
  Alcotest.(check bool)
    "own identities are not dependencies" false
    (List.exists (fun hash -> List.exists (Hash.equal hash) introduced) dependencies);
  let div =
    match Store.lookup_kind store "div" Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "prelude div missing"
  in
  Alcotest.(check bool) "div is a dependency" true (List.exists (Hash.equal div) dependencies)

(* The same source through the build-style preparation (resolve everything, then check) and the
   host preparation over the resulting store yields the facts the artifact sealed. *)
let test_commands_share_facts () =
  let _root, artifact = checked program in
  let store, _ctx = session "build" in
  let resolved, warnings =
    expect_ok "resolve source"
      (Frontend.resolve_source_tops ~syntax:Frontend.Auto store ~file:"program.jac" program)
  in
  Alcotest.(check int) "no warnings" 0 (List.length warnings);
  let checker = expect_ok "checker" (Frontend.make_checker store) in
  let tops = Frontend.Checked.tops artifact in
  List.iter2
    (fun top sealed ->
      let { Check.names; row; _ } = expect_ok "check resolved top" (Check.check_top checker top) in
      Alcotest.(check (list (pair string string)))
        "signatures agree" sealed.Frontend.Checked.signatures
        (List.map (fun (name, scheme) -> (name, Check.show_scheme checker scheme)) names);
      (match (top, sealed.identity) with
      | Kernel.Decl _, Some { Canon.decl_hash; _ } ->
          let { Canon.decl_hash = rebuilt; _ } = expect_ok "hash" (Canon.hash_top top) in
          Alcotest.(check string) "identity agrees" (Hash.to_hex decl_hash) (Hash.to_hex rebuilt)
      | Kernel.Expr _, None -> ()
      | _ -> Alcotest.fail "identity shape differs");
      let effects = match row with Some row -> (Types.repr_row row).Types.effects | None -> [] in
      Alcotest.(check (list string)) "effects agree" (hex_list sealed.effects) (hex_list effects))
    resolved tops;
  ignore (expect_ok "host preparation" (Host_worker.prepare store));
  let host_checker =
    expect_ok "host checker" (Frontend.make_checker ~require_builtins:true store)
  in
  let expression = List.nth resolved 2 in
  let { Check.row; _ } = expect_ok "host check" (Check.check_top host_checker expression) in
  Alcotest.(check (list string))
    "host effects agree"
    (hex_list (List.nth tops 2).Frontend.Checked.effects)
    (hex_list (Types.repr_row (Option.get row)).Types.effects)

let test_recovery_never_seals () =
  match check "twice(n) = add(n,\nthrice(n) = add(n, twice(n))\n" with
  | _, Frontend.Recovered { diagnostics; _ } ->
      Alcotest.(check bool) "damage reported" true (diagnostics <> [])
  | _, Frontend.Checked _ -> Alcotest.fail "a damaged source sealed an artifact"

let test_check_failure_is_returned () =
  match
    Frontend.check ~prelude_dir ~root:(fresh_root "ill-typed") ~syntax:Frontend.Auto
      ~file:"program.jac" "bad(n) = add(n, \"text\")\n"
  with
  | Error (_ :: _) -> ()
  | Error [] -> Alcotest.fail "a failure without diagnostics"
  | Ok _ -> Alcotest.fail "an ill-typed source checked"

let test_check_refuses_used_root () =
  let store, _ctx = session "persistent" in
  let names_before = Store.names store in
  match
    Frontend.check ~prelude_dir ~root:store.Store.root ~syntax:Frontend.Auto ~file:"program.jac"
      program
  with
  | exception Invalid_argument _ ->
      let reopened = expect_ok "reopen" (Store.open_store store.Store.root) in
      Alcotest.(check int)
        "persistent store untouched" (List.length names_before)
        (List.length (Store.names reopened))
  | _ -> Alcotest.fail "check used a non-fresh root"

let store_state store =
  let names_file = Filename.concat store.Store.root "names.jqd" in
  let objects = Sys.readdir (Filename.concat store.Store.root "objects") in
  Array.sort String.compare objects;
  ( In_channel.with_open_bin names_file In_channel.input_all,
    Array.to_list objects,
    List.map (fun (name, entry) -> (name, Hash.to_hex entry.Resolve.hash)) (Store.names store) )

let refusal =
  Diag.error ~domain:Diag.Process ~code:"E0704" ~summary:"refused" ~cause:"refused"
    ~next_step:"none" ~contrast:None ()

let test_failed_install_leaves_store_unchanged () =
  let store, _ctx = session "install" in
  let before = store_state store in
  let install source =
    Frontend.install_declarations ~expression_refusal:refusal ~syntax:Frontend.Auto store
      ~file:"lib.jac" source
  in
  (match install "kept(n) = add(n, 1)\nbroken(n) = missing-name(n)\n" with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "an unresolved declaration installed");
  Alcotest.(check bool) "refused part-way: unchanged" true (store_state store = before);
  (match install "kept(n) = add(n, 1)\nkept(2)\n" with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "refusal" "E0704" (Diag.code_or_uncoded diagnostic)
  | _ -> Alcotest.fail "an expression was not refused");
  Alcotest.(check bool) "expression: unchanged" true (store_state store = before);
  expect_ok "declarations install" (install "kept(n) = add(n, 1)\n");
  Alcotest.(check bool) "success changes the store" false (store_state store = before);
  let reopened = expect_ok "reopen" (Store.open_store store.Store.root) in
  Alcotest.(check bool) "installed on disk" true (Store.lookup_name reopened "kept" <> None)

let expect_stale label expected = function
  | Ok () -> Alcotest.failf "%s: a stale artifact verified" label
  | Error stale ->
      let kind =
        match stale with
        | Frontend.Checked.Prelude_changed -> "prelude"
        | Missing_dependency _ -> "dependency"
        | Rebound { name; _ } -> "rebound:" ^ name
      in
      Alcotest.(check string) label expected kind

let test_stale_artifacts_are_refused () =
  let root, artifact = checked declarations in
  let own = expect_ok "reopen scratch store" (Store.open_store root) in
  Alcotest.(check bool)
    "verifies where it was checked" true
    (Frontend.Checked.verify artifact own = Ok ());
  let install store source =
    expect_ok "install"
      (Frontend.install_declarations ~expression_refusal:refusal ~syntax:Frontend.Auto store
         ~file:"lib.jac" source)
  in
  install own "safe-div(n, d) = div(n, d)\n";
  expect_stale "same session, rebound" "rebound:safe-div" (Frontend.Checked.verify artifact own);
  (* another session: facts must be established there, not assumed *)
  let other, _ctx = session "other" in
  expect_stale "other session, not installed" "rebound:safe-div"
    (Frontend.Checked.verify artifact other);
  install other declarations;
  Alcotest.(check bool)
    "identities agree across sessions" true
    (Frontend.Checked.verify artifact other = Ok ());
  let bare = expect_ok "store without prelude" (Store.open_store (fresh_root "bare")) in
  expect_stale "different prelude" "prelude" (Frontend.Checked.verify artifact bare)

let test_walk_hook_order () =
  let store, _ctx = session "walk" in
  let events = ref [] in
  let result =
    Frontend.walk ~syntax:Frontend.Auto ~file:"walk.jac" store "one(n) = n\nunknown-name(1)\n"
      ~before_resolve:(function
        | Kernel.Expr _ -> Error [ refusal ]
        | Kernel.Decl _ ->
            events := "before" :: !events;
            Ok ())
      ~on_resolved:(fun _ _ ->
        events := "resolved" :: !events;
        Ok ())
      ~on_installed:(fun _ _ ->
        events := "installed" :: !events;
        Ok ())
  in
  (match result with
  | Error [ diagnostic ] ->
      Alcotest.(check string)
        "pre-resolution refusal wins" "E0704" (Diag.code_or_uncoded diagnostic)
  | _ -> Alcotest.fail "expected the pre-resolution refusal");
  Alcotest.(check (list string))
    "hook order"
    [ "before"; "resolved"; "installed" ]
    (List.rev !events);
  let seen = ref 0 in
  expect_ok "best effort continues"
    (Frontend.walk ~install:Frontend.Install_best_effort ~syntax:Frontend.Auto ~file:"again.jac"
       store "two(n) = n\ntwo(1)\n" ~on_resolved:(fun _ _ ->
         incr seen;
         Ok ()));
  Alcotest.(check int) "every top visited" 2 !seen

let suite =
  [
    Alcotest.test_case "the artifact binds shared checked facts" `Quick
      test_artifact_binds_shared_facts;
    Alcotest.test_case "check, build, and host preparation share facts" `Quick
      test_commands_share_facts;
    Alcotest.test_case "recovery analysis never seals an artifact" `Quick test_recovery_never_seals;
    Alcotest.test_case "a failed check returns its diagnostics" `Quick
      test_check_failure_is_returned;
    Alcotest.test_case "check refuses a store root in use" `Quick test_check_refuses_used_root;
    Alcotest.test_case "a refused installation leaves the store unchanged" `Quick
      test_failed_install_leaves_store_unchanged;
    Alcotest.test_case "stale and cross-session artifacts are refused" `Quick
      test_stale_artifacts_are_refused;
    Alcotest.test_case "walk hooks run in pipeline order" `Quick test_walk_hook_order;
  ]
