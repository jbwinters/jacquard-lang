open Jacquard

(* TYPE.1 S2b2: a bundled term may construct or match a sealed type only inside its owner's region
   (E1738). Source refuses every route to such a bundle (E1705, E1709), so these tests forge one: a
   consumer's context re-exports the library's private constructing helper, with its interface and
   context record recomputed so every earlier check passes. *)

let prelude_dir = "../prelude"

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let expect label = function Ok v -> v | Error ds -> fail_diags label ds

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let fresh_dir =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-regions-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    at_exit (fun () -> try remove_tree dir with Unix.Unix_error _ | Sys_error _ -> ());
    dir

let write path contents =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)

let read path = In_channel.with_open_bin path In_channel.input_all

(* an opaque library with a private raw helper, and a consumer that only calls the validated one *)
let build_bundle () =
  let work = fresh_dir "work" in
  List.iter
    (fun d -> Unix.mkdir d 0o755)
    [ work; Filename.concat work "libp"; Filename.concat work "app" ];
  Unix.mkdir (Filename.concat work ".git") 0o755;
  write
    (Filename.concat work "libp/project.jqd")
    "(project-v1 (name \"libp\") (requires (core \"0.2\")) (namespace libp) (units \"p.jac\") \
     (exports (type libp-score) (term libp.make) (term libp.wrap)))";
  write
    (Filename.concat work "libp/p.jac")
    "opaque type LibpScore = | LibpScore(value: Int)\n\
     libp.raw(n) = LibpScore(n)\n\
     libp.make(n) = libp.raw(int.max(0, n))\n\
     type LibpPlain = | LibpPlain(value: Int)\n\
     libp.plain(n) = LibpPlain(n)\n\
     libp.keep : (LibpPlain) ->{} LibpPlain\n\
     libp.keep(p) = p\n\
     libp.wrap(n) = libp.keep(libp.plain(n))\n";
  write
    (Filename.concat work "app/project.jqd")
    "(project-v1 (name \"app\") (requires (core \"0.2\")) (namespace app) (units \"a.jac\") (deps \
     (dep (as p) (path \"../libp\"))) (entries (run demo (units \"demo.jac\"))))";
  write (Filename.concat work "app/a.jac") "app.go(n) = (libp.make(n), libp.wrap(n))\n";
  write (Filename.concat work "app/demo.jac") "app.go(1)\n";
  let manifest = Filename.concat work "app/project.jqd" in
  let session, graph =
    expect "pin graph"
      (Project_frontend.open_graph ~pinning:true ~prelude_dir ~root:(fresh_dir "pin") manifest)
  in
  let plans = expect "plan pins" (Project_frontend.plan_pins session graph ~only:[]) in
  expect "write pins" (Project_frontend.write_pins session graph plans);
  let out = Filename.concat work "app.bundle" in
  ignore
    (expect "bundle" (Project_bundle.write ~prelude_dir ~root:(fresh_dir "build") ~out manifest));
  out

let field name (f : Form.t) =
  List.find_map
    (function Form.F ({ Form.head; _ } as g) when head = name -> Some g | _ -> None)
    f.Form.args

(* re-export [helper] from the bundle's own context as [as_name], recomputing its records *)
let forge_reexport bundle ~helper ~as_name =
  let loaded =
    expect "load" (Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "load") bundle)
  in
  let store = loaded.Project_bundle_reader.store and checker = loaded.checker in
  let own = loaded.bundle.Project_bundle_reader.context in
  let _, form, (interface : Interface.t) =
    List.find (fun (id, _, _) -> Hash.equal id own) loaded.bundle.contexts
  in
  let hash =
    match Store.lookup_kind store helper Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "%s is not bound in the bundle" helper
  in
  let exports =
    ((as_name, Resolve.KTerm), hash)
    :: List.map (fun (e : Interface.export) -> ((e.name, e.kind), e.hash)) interface.exports
  in
  let derived =
    expect "derive" (Interface.of_side ~recorded:true checker { Diff.store; bindings = exports })
  in
  let deps =
    match field "deps" form with
    | Some d ->
        List.filter_map
          (function
            | Form.F { Form.head = "dep"; args = [ Form.Sym alias; Form.Hash h ]; _ } ->
                Some (alias, h)
            | _ -> None)
          d.Form.args
    | None -> []
  in
  let record = Project_context.form store ~interface:derived ~exports ~deps in
  let forged = Project_context.identity record in
  let old_name = Hash.to_hex own ^ ".jqd" and new_name = Hash.to_hex forged ^ ".jqd" in
  List.iter
    (fun d -> Sys.remove (Filename.concat bundle (Filename.concat d old_name)))
    [ "contexts"; "interfaces" ];
  write (Filename.concat bundle (Filename.concat "contexts" new_name)) (Printer.print record ^ "\n");
  write
    (Filename.concat bundle (Filename.concat "interfaces" new_name))
    (Interface.serialize derived);
  let head = Filename.concat bundle (Project_bundle_reader.version ^ ".jqd") in
  let text = read head in
  let replace s ~sub ~by = Str.global_replace (Str.regexp_string sub) by s in
  write head (replace text ~sub:(Hash.to_hex own) ~by:(Hash.to_hex forged))

let codes bundle =
  match Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "verify") bundle with
  | Ok _ -> []
  | Error ds -> List.filter_map Diag.code ds

let test_owner_region () =
  let bundle = build_bundle () in
  Alcotest.(check (list string)) "the honest bundle verifies" [] (codes bundle)

let test_reexported_raw_helper () =
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.raw" ~as_name:"app.raw";
  Alcotest.(check (list string))
    "a consumer cannot carry the owner's raw helper in its own region" [ "E1738" ] (codes bundle)

let test_reexported_validated_function () =
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.make" ~as_name:"app.make";
  (* both contexts export one constructing term, so both regions contain it (design §2.3) *)
  Alcotest.(check (list string))
    "re-exporting the owner's constructing export puts it in the consumer's region" [ "E1738" ]
    (codes bundle)

let test_region_namespace () =
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.plain" ~as_name:"app.plain";
  Alcotest.(check (list string))
    "a consumer's region cannot construct a dependency's unexported type" [ "E1739" ] (codes bundle);
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.keep" ~as_name:"app.keep";
  Alcotest.(check (list string))
    "naming an unexported type only in an annotation is exempt" [] (codes bundle)

let test_export_of_wrong_kind () =
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.raw" ~as_name:"app.raw";
  (* the recorded export now claims a constructor's kind for a term identity *)
  let interfaces = Filename.concat bundle "interfaces" in
  Array.iter
    (fun name ->
      let path = Filename.concat interfaces name in
      let text = read path in
      let forged = Str.global_replace (Str.regexp_string "term\n  app.raw") "con\n  app.raw" text in
      if forged <> text then write path forged)
    (Sys.readdir interfaces);
  match Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "verify") bundle with
  | Ok _ -> Alcotest.fail "a mis-kinded export verified"
  | Error ds ->
      Alcotest.(check (list string)) "refused" [ "E1729" ] (List.filter_map Diag.code ds);
      Alcotest.(check bool)
        "directly, before derivation" true
        (List.exists
           (fun d ->
             let cause = Diag.cause d in
             let needle = "does not name a declaration of its kind" in
             let n = String.length needle in
             let rec has i =
               i + n <= String.length cause && (String.sub cause i n = needle || has (i + 1))
             in
             has 0)
           ds)

(* add a test entry to the bundle record whose root is [helper]: entries are author-trusted, but they
   cannot reach another context's unexported declarations *)
let forge_test_root bundle ~helper =
  let loaded =
    expect "load" (Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "load") bundle)
  in
  let hash =
    match Store.lookup_kind loaded.Project_bundle_reader.store helper Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "%s is not bound in the bundle" helper
  in
  let head = Filename.concat bundle (Project_bundle_reader.version ^ ".jqd") in
  let text = read head in
  let forged =
    Str.replace_first (Str.regexp_string "(entries ")
      (Printf.sprintf "(entries (test forged (root test \"forged\" #%s) (grants)) "
         (Hash.to_hex hash))
      text
  in
  if forged = text then Alcotest.fail "no (entries ...) in the record";
  write head forged

let test_entry_reaching_dependency_internals () =
  let bundle = build_bundle () in
  forge_test_root bundle ~helper:"libp.plain";
  Alcotest.(check (list string))
    "an entry cannot construct a dependency's unexported type" [ "E1739" ] (codes bundle);
  let bundle = build_bundle () in
  forge_test_root bundle ~helper:"libp.raw";
  Alcotest.(check (list string)) "nor the dependency's sealed type" [ "E1738" ] (codes bundle)

(* TYPE.1 S2c: a builtin runs a term from a runtime hash (a posterior model) only if the prelude or a
   context in the run exports it *)
let test_model_guard () =
  let bundle = build_bundle () in
  let loaded =
    expect "load" (Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "guard") bundle)
  in
  let ctx = loaded.Project_bundle_reader.ctx and store = loaded.store in
  let hash name =
    match Store.lookup_kind store name Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "%s is not bound" name
  in
  let admitted name = Result.is_ok (Posterior_risk.admit_model ctx (hash name)) in
  Alcotest.(check bool) "an exported term" true (admitted "libp.make");
  Alcotest.(check bool) "a prelude term" true (admitted "int.add");
  Alcotest.(check bool) "a private helper" false (admitted "libp.raw");
  (match Posterior_risk.admit_model ctx (hash "libp.raw") with
  | Error message -> Alcotest.(check string) "refused as E1709" "E1709" (String.sub message 0 5)
  | Ok () -> Alcotest.fail "a private helper was admitted");
  (* both posterior builtins refuse it before reading anything else *)
  let model_ref h =
    match Prelude_identity.lookup_kind store "posterior-risk-model-ref-v1" Resolve.KCon with
    | Some { Resolve.hash = con; _ } ->
        Value.VCon { con; name = "posterior-risk-model-ref-v1"; args = [ Value.VHash h ] }
    | None -> Alcotest.fail "no model reference constructor"
  in
  let filler = Value.VTuple [] in
  let refused label builtin =
    match
      builtin ctx ~builtin_signatures:[] [ model_ref (hash "libp.raw"); filler; filler; filler ]
    with
    | Ok (Value.VCon { name = "err"; args = [ Value.VText message ]; _ }) ->
        Alcotest.(check string) label "E1709" (String.sub message 0 5)
    | Ok v -> Alcotest.failf "%s: unexpected %s" label (Value.show v)
    | Error e -> Alcotest.failf "%s: %s" label (Runtime_err.to_string e)
  in
  refused "run-exact refuses a private model" Posterior_risk.run_exact_builtin;
  refused "sample-evidence refuses a private model" Posterior_risk.sample_evidence_builtin

(* a project run installs the guard too, through its entries; the root's own unexported model is
   refused like a dependency's (design §2.3: only prelude terms and graph exports run by hash) *)
let test_project_model_guard () =
  let work = fresh_dir "project" in
  Unix.mkdir work 0o755;
  Unix.mkdir (Filename.concat work ".git") 0o755;
  write
    (Filename.concat work "project.jqd")
    "(project-v1 (name \"own\") (requires (core \"0.2\")) (namespace own) (units \"o.jac\") \
     (exports (term own.public)) (entries (run demo (units \"demo.jac\"))))";
  write (Filename.concat work "o.jac") "own.public(n) = n\nown.private(n) = int.add(n, 1)\n";
  write (Filename.concat work "demo.jac") "own.public(1)\n";
  let session, _ =
    expect "open"
      (Project_frontend.open_graph ~prelude_dir ~root:(fresh_dir "store")
         (Filename.concat work "project.jqd"))
  in
  let entry =
    List.find
      (fun (e : Project_manifest.entry) -> e.ename = "demo")
      (Project_frontend.project session).Project_frontend.manifest.Project_manifest.entries
  in
  ignore (expect "check entry" (Project_frontend.check_entry session entry));
  let ctx = Project_frontend.eval_ctx session and store = Project_frontend.store session in
  let hash name =
    match Store.lookup_kind store name Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "%s is not bound" name
  in
  Alcotest.(check bool)
    "the root's export" true
    (Result.is_ok (Posterior_risk.admit_model ctx (hash "own.public")));
  Alcotest.(check bool)
    "the root's unexported term" false
    (Result.is_ok (Posterior_risk.admit_model ctx (hash "own.private")))

(* design §2.3: every place a term reference is built from a runtime hash, to be run. A new one must
   be reviewed against the construction boundary before it joins this inventory. *)
let test_runtime_executor_inventory () =
  let executors =
    [
      (* the model reference, guarded by [Posterior_risk.admit_model] (E1709), and [call_term],
         which calls frozen prelude identities only *)
      ("posterior_risk.ml", 2);
      (* the host worker runs the callable a trusted host names (design: host invocation is
         trusted) *)
      ("host_worker.ml", 1);
      (* Warp runs the tests its discovery found, from the CLI, not from a builtin *)
      ("warp.ml", 1);
      (* a bundle run executes the run steps the verified bundle record names (author-trusted) *)
      ("main.ml", 1);
    ]
  in
  (* a record field [it = Ref (_, Term)] builds a reference; [with it = ...] only rebuilds one *)
  let builds = Str.regexp {|\bit = \(Kernel\.\)?Ref (.*\(Kernel\.\)?Term)|} in
  let count path =
    In_channel.with_open_bin path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line ->
        (not (String.starts_with ~prefix:"|" (String.trim line)))
        && (try
              ignore (Str.search_forward builds line 0);
              true
            with Not_found -> false)
        && not
             (try
                ignore (Str.search_forward (Str.regexp_string " with ") line 0);
                true
              with Not_found -> false))
    |> List.length
  in
  let found =
    List.concat_map
      (fun dir ->
        Sys.readdir dir |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".ml")
        |> List.filter_map (fun f ->
            match count (Filename.concat dir f) with 0 -> None | n -> Some (f, n)))
      [ "../src"; "../src/native"; "../bin" ]
  in
  Alcotest.(check (list (pair string int)))
    "runtime term executors are exactly the reviewed ones" (List.sort compare executors)
    (List.sort compare found)

let suite =
  [
    Alcotest.test_case "owner region" `Quick test_owner_region;
    Alcotest.test_case "re-exported raw helper" `Quick test_reexported_raw_helper;
    Alcotest.test_case "mutually exported constructing term" `Quick
      test_reexported_validated_function;
    Alcotest.test_case "region namespace" `Quick test_region_namespace;
    Alcotest.test_case "export of the wrong kind" `Quick test_export_of_wrong_kind;
    Alcotest.test_case "entry reaching dependency internals" `Quick
      test_entry_reaching_dependency_internals;
    Alcotest.test_case "model guard" `Quick test_model_guard;
    Alcotest.test_case "project model guard" `Quick test_project_model_guard;
    Alcotest.test_case "runtime executor inventory" `Quick test_runtime_executor_inventory;
  ]
