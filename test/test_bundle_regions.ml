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
     (exports (type libp-score) (term libp.make) (term libp.wrap) (term libp.loop)))";
  write
    (Filename.concat work "libp/p.jac")
    "opaque type LibpScore = | LibpScore(value: Int)\n\
     libp.raw(n) = LibpScore(n)\n\
     libp.make(n) = libp.raw(int.max(0, n))\n\
     type LibpPlain = | LibpPlain(value: Int)\n\
     libp.plain(n) = LibpPlain(n)\n\
     libp.keep : (LibpPlain) ->{} LibpPlain\n\
     libp.keep(p) = p\n\
     libp.wrap(n) = libp.keep(libp.plain(n))\n\
     libp.seal(n) = if int.gt?(n, 100) then libp.loop(int.sub(n, 1)) else LibpScore(n)\n\
     libp.loop(n) = libp.seal(n)\n";
  write
    (Filename.concat work "app/project.jqd")
    "(project-v1 (name \"app\") (requires (core \"0.2\")) (namespace app) (units \"a.jac\") (deps \
     (dep (as p) (path \"../libp\"))) (entries (run demo (units \"demo.jac\"))))";
  write
    (Filename.concat work "app/a.jac")
    "opaque type AppToken = | AppToken(value: Int)\n\
     app.token(n) = AppToken(n)\n\
     app.go(n) = (libp.make(n), libp.wrap(n), app.token(n))\n";
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

let load bundle =
  expect "load" (Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "load") bundle)

let record_file bundle = Filename.concat bundle (Project_bundle_reader.version ^ ".jqd")
let replace s ~sub ~by = Str.global_replace (Str.regexp_string sub) by s

let exports_of (interface : Interface.t) =
  List.map (fun (e : Interface.export) -> ((e.name, e.kind), e.hash)) interface.exports

let bound (loaded : Project_bundle_reader.t) name =
  match Store.lookup_kind loaded.store name Resolve.KTerm with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.failf "%s is not bound in the bundle" name

(* rewrite context [id]'s record and interface so that it exports [exports], with the dependency
   edges named in [renamed] pointing at their new identities; the new identity is returned and the
   bundle record is left to [rename_contexts] *)
let rewrite_context (loaded : Project_bundle_reader.t) bundle id ~exports ~renamed =
  let store = loaded.store and checker = loaded.checker in
  let _, form, _ = List.find (fun (id', _, _) -> Hash.equal id id') loaded.bundle.contexts in
  let derived =
    expect "derive" (Interface.of_side ~recorded:true checker { Diff.store; bindings = exports })
  in
  let deps =
    match field "deps" form with
    | Some d ->
        List.filter_map
          (function
            | Form.F { Form.head = "dep"; args = [ Form.Sym alias; Form.Hash h ]; _ } -> (
                match List.find_opt (fun (old, _) -> Hash.equal old h) renamed with
                | Some (_, h') -> Some (alias, h')
                | None -> Some (alias, h))
            | _ -> None)
          d.Form.args
    | None -> []
  in
  let record = Project_context.form store ~interface:derived ~exports ~deps in
  let forged = Project_context.identity record in
  let old_name = Hash.to_hex id ^ ".jqd" and new_name = Hash.to_hex forged ^ ".jqd" in
  List.iter
    (fun d -> Sys.remove (Filename.concat bundle (Filename.concat d old_name)))
    [ "contexts"; "interfaces" ];
  write (Filename.concat bundle (Filename.concat "contexts" new_name)) (Printer.print record ^ "\n");
  write
    (Filename.concat bundle (Filename.concat "interfaces" new_name))
    (Interface.serialize derived);
  forged

let rename_contexts bundle pairs =
  let head = record_file bundle in
  write head
    (List.fold_left
       (fun text (old, forged) -> replace text ~sub:(Hash.to_hex old) ~by:(Hash.to_hex forged))
       (read head) pairs)

(* re-export [helper] from the bundle's own context as [as_name], recomputing its records *)
let forge_reexport bundle ~helper ~as_name =
  let loaded = load bundle in
  let own = loaded.bundle.Project_bundle_reader.context in
  let _, _, interface = List.find (fun (id, _, _) -> Hash.equal id own) loaded.bundle.contexts in
  let exports = ((as_name, Resolve.KTerm), bound loaded helper) :: exports_of interface in
  rename_contexts bundle [ (own, rewrite_context loaded bundle own ~exports ~renamed:[]) ]

(* add the declaration bootstrap [src] declares, resolved against the bundle's names, to the bundle
   as a hash-valid object, and recount the record's objects *)
let forge_object (loaded : Project_bundle_reader.t) bundle src =
  let hashes = Eval_support.put_src loaded.store (Store.names_view loaded.store) src in
  let objects = Filename.concat bundle "objects" in
  write
    (Filename.concat objects (Hash.to_hex hashes.Canon.decl_hash ^ ".jqd"))
    (read (Store.object_path loaded.store hashes.Canon.decl_hash));
  let head = record_file bundle in
  write head
    (Str.global_replace (Str.regexp "(objects [0-9]+)")
       (Printf.sprintf "(objects %d)" (Array.length (Sys.readdir objects)))
       (read head));
  hashes

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
let add_test_root bundle hash =
  let head = record_file bundle in
  let text = read head in
  let forged =
    Str.replace_first (Str.regexp_string "(entries ")
      (Printf.sprintf "(entries (test forged (root test \"forged\" #%s) (grants)) "
         (Hash.to_hex hash))
      text
  in
  if forged = text then Alcotest.fail "no (entries ...) in the record";
  write head forged

let forge_test_root bundle ~helper = add_test_root bundle (bound (load bundle) helper)

let test_entry_reaching_dependency_internals () =
  let bundle = build_bundle () in
  forge_test_root bundle ~helper:"libp.plain";
  Alcotest.(check (list string))
    "an entry cannot construct a dependency's unexported type" [ "E1739" ] (codes bundle);
  let bundle = build_bundle () in
  forge_test_root bundle ~helper:"libp.raw";
  Alcotest.(check (list string)) "nor the dependency's sealed type" [ "E1738" ] (codes bundle)

(* the codes a bundle's verification refuses with; an E1738 from the region rule is marked
   [E1738/region], since the fallback for a constructing object in no region reports E1738 too *)
let region_codes bundle =
  let has text needle =
    let n = String.length needle in
    let rec go i = i + n <= String.length text && (String.sub text i n = needle || go (i + 1)) in
    go 0
  in
  match Project_bundle_reader.load ~prelude_dir ~root:(fresh_dir "verify") bundle with
  | Ok _ -> []
  | Error ds ->
      List.map
        (fun d ->
          match Diag.code d with
          | Some "E1738" when has (Diag.cause d) "in the region of context" -> "E1738/region"
          | Some code -> code
          | None -> "uncoded")
        ds

(* hash-valid forged objects, rooted by a forged test entry of the consumer: a sealed constructor is
   used whether it is applied, passed unapplied, built inside a live splice, or matched in a pattern;
   quoted data is not a use, even when it carries the constructor's identity. [CON] in [body] stands
   for that identity. *)
let forged body =
  let bundle = build_bundle () in
  let loaded = load bundle in
  let con =
    match Store.lookup_kind loaded.store "libp-score" Resolve.KCon with
    | Some { Resolve.hash; _ } -> Hash.to_hex hash
    | None -> Alcotest.fail "libp-score is not bound in the bundle"
  in
  let body = Str.global_replace (Str.regexp_string "CON") con body in
  let hashes =
    forge_object loaded bundle (Printf.sprintf "(defterm ((binding app.forged () %s)))" body)
  in
  add_test_root bundle (List.assoc "app.forged" hashes.Canon.named);
  region_codes bundle

let test_forged_constructor_objects () =
  let refused = [ "E1738/region" ] in
  Alcotest.(check (list string))
    "an applied constructor" refused
    (forged "(app (var libp-score) (lit 1))");
  Alcotest.(check (list string)) "an unapplied constructor" refused (forged "(var libp-score)");
  Alcotest.(check (list string))
    "a constructor inside a splice" refused
    (forged
       "(quote (pair (unquote (match (app (var libp-score) (lit 1)) (clause (pwild) (quote (lit \
        1)))))))");
  Alcotest.(check (list string))
    "a constructor pattern" refused
    (forged "(lam ((pvar s)) (match (var s) (clause (pcon libp-score (pvar n)) (var n))))");
  Alcotest.(check (list string))
    "constructor syntax in quoted data is not a use" [] (forged "(quote (libp-score 1))");
  Alcotest.(check (list string))
    "nor is the constructor's identity in quoted data" []
    (forged "(quote (app (ref #CON con) (lit 1)))")

(* a region stops at the exact member identities other contexts export, not at their groups: a
   consumer's term calling the exported member of a dependency's recursive group stops there, while
   one calling the group's private constructing member brings the group into its region *)
let test_private_group_member () =
  let loaded = load (build_bundle ()) in
  let decl name =
    match Store.locate loaded.store (bound loaded name) with
    | Ok { Store.decl_hash; _ } -> Hash.to_hex decl_hash
    | Error _ -> Alcotest.failf "%s does not locate" name
  in
  Alcotest.(check string)
    "the two members share one declaration" (decl "libp.loop") (decl "libp.seal");
  Alcotest.(check (list string))
    "calling the group's exported member" []
    (forged "(app (var libp.loop) (lit 1))");
  Alcotest.(check (list string))
    "calling the group's private constructing member" [ "E1738/region" ]
    (forged "(app (var libp.seal) (lit 1))")

let test_dependency_constructing_consumer_type () =
  let bundle = build_bundle () in
  let loaded = load bundle in
  let own = loaded.bundle.Project_bundle_reader.context in
  let find id = List.find (fun (id', _, _) -> Hash.equal id id') loaded.bundle.contexts in
  let lib, _, lib_interface =
    List.find (fun (id, _, _) -> not (Hash.equal id own)) loaded.bundle.contexts
  in
  let hashes =
    forge_object loaded bundle "(defterm ((binding libp.mint () (app (var app-token) (lit 1)))))"
  in
  let lib' =
    rewrite_context loaded bundle lib
      ~exports:
        ((("libp.mint", Resolve.KTerm), List.assoc "libp.mint" hashes.Canon.named)
        :: exports_of lib_interface)
      ~renamed:[]
  in
  let _, _, own_interface = find own in
  let own' =
    rewrite_context loaded bundle own ~exports:(exports_of own_interface) ~renamed:[ (lib, lib') ]
  in
  rename_contexts bundle [ (lib, lib'); (own, own') ];
  Alcotest.(check (list string))
    "a dependency's export constructing the consumer's opaque type" [ "E1738/region" ]
    (region_codes bundle)

(* a refused import leaves none of its objects or names in the importing store: its name index
   file, object directory and bindings are as they were, and no bundle object locates *)
let test_refused_import_leaves_nothing () =
  let bundle = build_bundle () in
  forge_reexport bundle ~helper:"libp.raw" ~as_name:"app.raw";
  let store, _ = expect "open" (Frontend.open_session ~prelude_dir ~root:(fresh_dir "import")) in
  let checker = expect "checker" (Frontend.make_checker store) in
  let hexes () = List.sort compare (List.map Hash.to_hex (Store.all_decl_hashes store)) in
  let before = hexes () and state = Test_frontend.store_state store in
  (match Project_bundle_reader.verify ~store ~checker bundle with
  | Ok _ -> Alcotest.fail "the forged bundle verified"
  | Error ds ->
      Alcotest.(check (list string)) "refused late" [ "E1738" ] (List.filter_map Diag.code ds));
  Alcotest.(check (list string)) "the store's declarations are unchanged" before (hexes ());
  Alcotest.(check bool)
    "the name file, object directory and bindings are unchanged" true
    (Test_frontend.store_state store = state);
  let objects = Filename.concat bundle "objects" in
  Array.iter
    (fun name ->
      match Hash.of_hex (Filename.chop_suffix name ".jqd") with
      | Some h ->
          Alcotest.(check bool)
            (name ^ " left no object file") false
            (Sys.file_exists (Store.object_path store h));
          Alcotest.(check bool)
            (name ^ " does not locate") true
            (Result.is_error (Store.locate store h))
      | None -> Alcotest.failf "object %s is not named by a hash" name)
    (Sys.readdir objects);
  Alcotest.(check bool)
    "the bundle's names are unbound" true
    (Option.is_none (Store.lookup_kind store "libp.raw" Resolve.KTerm))

(* the reader refuses (E1721) when the prelude it verifies against lacks the eval identities: a
   bundle's record is forged to name a prelude copy without the [eval] effect, so the earlier
   prelude comparison (E1720) passes *)
let test_reader_without_eval_identities () =
  let bundle = build_bundle () in
  let noeval = fresh_dir "noeval-prelude" in
  Unix.mkdir noeval 0o755;
  Array.iter
    (fun name ->
      let text = read (Filename.concat prelude_dir name) in
      let kept =
        String.split_on_char '\n' text
        |> List.filter (fun line -> not (String.starts_with ~prefix:"(defeffect eval " line))
      in
      write (Filename.concat noeval name) (String.concat "\n" kept))
    (Sys.readdir prelude_dir);
  Alcotest.(check bool)
    "the copy dropped the eval effect" false
    (read (Filename.concat noeval "03-effects.jqd")
    = read (Filename.concat prelude_dir "03-effects.jqd"));
  let store, _ =
    expect "open" (Frontend.open_session ~prelude_dir:noeval ~root:(fresh_dir "noeval"))
  in
  let prelude_form =
    Form.form "prelude"
      (List.map
         (fun (f, d) -> Form.F (Form.form "file" [ Form.Text f; Form.Text d ]))
         (List.sort compare (Option.value ~default:[] (Store.prelude_manifest store))))
  in
  let with_prelude (form : Form.t) =
    {
      form with
      Form.args =
        List.map
          (function Form.F { Form.head = "prelude"; _ } -> Form.F prelude_form | arg -> arg)
          form.Form.args;
    }
  in
  (* a context's identity covers the prelude manifest, so each context is re-derived against the
     eval-less prelude, dependencies first, and its consumers and the record follow the rename *)
  let contexts = Filename.concat bundle "contexts" in
  let parsed =
    List.map
      (fun name ->
        let path = Filename.concat contexts name in
        ( Filename.chop_suffix name ".jqd",
          expect "context" (Reader.parse_one ~file:path (read path)) ))
      (Array.to_list (Sys.readdir contexts))
  in
  let deps_of form =
    match field "deps" form with
    | Some d ->
        List.filter_map
          (function
            | Form.F { Form.head = "dep"; args = [ _; Form.Hash h ]; _ } -> Some (Hash.to_hex h)
            | _ -> None)
          d.Form.args
    | None -> []
  in
  let renamed mapping (form : Form.t) =
    let dep = function
      | Form.F ({ Form.head = "dep"; args = [ alias; Form.Hash h ]; _ } as d) ->
          let h = Option.value ~default:h (List.assoc_opt (Hash.to_hex h) mapping) in
          Form.F { d with Form.args = [ alias; Form.Hash h ] }
      | arg -> arg
    in
    {
      form with
      Form.args =
        List.map
          (function
            | Form.F ({ Form.head = "deps"; _ } as d) ->
                Form.F { d with Form.args = List.map dep d.Form.args }
            | arg -> arg)
          form.Form.args;
    }
  in
  let rec rederive mapping = function
    | [] -> mapping
    | pending ->
        let ready, rest =
          List.partition
            (fun (_, form) -> List.for_all (fun d -> List.mem_assoc d mapping) (deps_of form))
            pending
        in
        if ready = [] then Alcotest.fail "the bundle's contexts do not form a graph";
        let mapping =
          List.fold_left
            (fun mapping (id, form) ->
              let form = with_prelude (renamed mapping form) in
              let forged = Project_context.identity form in
              let path dir hex = Filename.concat bundle (Filename.concat dir (hex ^ ".jqd")) in
              Sys.remove (path "contexts" id);
              write (path "contexts" (Hash.to_hex forged)) (Printer.print form ^ "\n");
              Sys.rename (path "interfaces" id) (path "interfaces" (Hash.to_hex forged));
              (id, forged) :: mapping)
            mapping ready
        in
        rederive mapping rest
  in
  let mapping = rederive [] parsed in
  let head = record_file bundle in
  let record = with_prelude (expect "record" (Reader.parse_one ~file:head (read head))) in
  write head
    (List.fold_left
       (fun text (old, forged) -> replace text ~sub:old ~by:(Hash.to_hex forged))
       (Printer.print record ^ "\n")
       mapping);
  let codes =
    match Project_bundle_reader.load ~prelude_dir:noeval ~root:(fresh_dir "verify") bundle with
    | Ok _ -> []
    | Error ds -> List.filter_map Diag.code ds
  in
  Alcotest.(check (list string)) "refused for the absent identities" [ "E1721" ] codes

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
      (* a behavior review runs the entry, domain, field and model terms its CLI caller names, from
         the review's own private scratch stores, from the CLI, not from a builtin *)
      ("behavior_review.ml", 1);
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
    Alcotest.test_case "forged constructor objects" `Quick test_forged_constructor_objects;
    Alcotest.test_case "private group member" `Quick test_private_group_member;
    Alcotest.test_case "dependency constructing its consumer's type" `Quick
      test_dependency_constructing_consumer_type;
    Alcotest.test_case "refused import leaves nothing" `Quick test_refused_import_leaves_nothing;
    Alcotest.test_case "reader without eval identities" `Quick test_reader_without_eval_identities;
    Alcotest.test_case "model guard" `Quick test_model_guard;
    Alcotest.test_case "project model guard" `Quick test_project_model_guard;
    Alcotest.test_case "runtime executor inventory" `Quick test_runtime_executor_inventory;
  ]
