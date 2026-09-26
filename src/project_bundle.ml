(* PKG.1: bundles, the runnable and verifiable form of a project; contracts in project_bundle.mli. *)

let ( let* ) = Result.bind

let summary = function
  | "E1721" -> "A bundle root can reach dynamic evaluation."
  | "E1725" -> "An output path overlaps an input."
  | "E1735" -> "No project manifest was found or it could not be read."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown bundle code " ^ code))

let next_step = function
  | "E1721" ->
      "Keep eval-code out of every run step, test root, and exported callable; bundles refuse \
       dynamic evaluation in v1."
  | "E1725" -> "Write the bundle outside every unit and dependency directory."
  | "E1735" -> "Check the output path and its permissions."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown bundle code " ^ code))

let diag code cause =
  Diag.error ~domain:Diag.Project ~code ~summary:(summary code) ~cause ~next_step:(next_step code)
    ~contrast:None ()

let error code fmt = Printf.ksprintf (fun cause -> Error [ diag code cause ]) fmt
let version = "bundle-v1"

(* --- the closure --- *)

(* Every declaration reachable from [roots], prelude declarations included; quoted data is not
   code, so [Store.decl_refs] follows only live splices. *)
let reachable store roots =
  let seen = Hashtbl.create 256 in
  let rec go = function
    | [] -> ()
    | hash :: rest -> (
        match Store.locate store hash with
        | Error _ -> go rest
        | Ok { Store.decl_hash; decl; _ } ->
            if Hashtbl.mem seen decl_hash then go rest
            else begin
              Hashtbl.add seen decl_hash decl;
              go (Store.decl_refs decl @ rest)
            end)
  in
  go roots;
  seen

let eval_identities store =
  List.filter_map Fun.id
    [
      Option.map
        (fun (e : Resolve.entry) -> e.hash)
        (Store.lookup_kind store "eval-code" Resolve.KOp);
      Option.map
        (fun (e : Resolve.entry) -> e.hash)
        (Store.lookup_kind store "eval" Resolve.KEffect);
    ]

(* --- paths --- *)

let within ~dir path = String.equal dir path || String.starts_with ~prefix:(dir ^ "/") path
let absolute path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

(* the output, its parent resolved, must not contain or lie inside any unit or project directory
   of the graph other than the root's own directory *)
let overlap session out =
  let root = Project_frontend.project session in
  let inputs =
    List.map
      (fun unit -> Filename.concat root.Project_frontend.dir unit)
      (root.manifest.Project_manifest.units
      @ List.concat_map (fun (e : Project_manifest.entry) -> e.eunits) root.manifest.entries)
    @ List.filter (fun d -> not (String.equal d root.dir)) (Project_frontend.graph_dirs session)
    @ [ root.manifest_file ]
  in
  List.find_opt (fun input -> within ~dir:out input || within ~dir:input out) inputs

(* --- writing --- *)

let hash_form h = Form.Hash h

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)

type summary = { identity : Hash.t; objects : int; companions : int }

let write ~prelude_dir ~root:store_root ~out manifest_file =
  let* session, _graph = Project_frontend.open_graph ~prelude_dir ~root:store_root manifest_file in
  let project = Project_frontend.project session in
  let manifest = project.Project_frontend.manifest in
  let store = Project_frontend.store session in
  let out =
    let out = absolute out in
    match Unix.realpath (Filename.dirname out) with
    | parent -> Filename.concat parent (Filename.basename out)
    | exception Unix.Unix_error _ -> out
  in
  let* () =
    match overlap session out with
    | Some input -> error "E1725" "bundle %s overlaps the input %s" out input
    | None when Sys.file_exists out -> error "E1725" "bundle %s already exists" out
    | None -> Ok ()
  in
  let entries =
    List.sort
      (fun (a : Project_manifest.entry) (b : Project_manifest.entry) ->
        compare (a.ekind = Project_manifest.Test, a.ename) (b.ekind = Project_manifest.Test, b.ename))
      manifest.Project_manifest.entries
  in
  let rec bundle acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
        let* bundled = Project_frontend.bundle_entry session entry in
        bundle ((entry, bundled) :: acc) rest
  in
  let* bundled = bundle [] entries in
  let entry_roots =
    List.concat_map
      (fun (_, b) ->
        match b with
        | Project_frontend.Steps steps -> steps
        | Project_frontend.Roots roots -> List.map (fun (_, _, h) -> h) roots)
      bundled
  in
  let roots = entry_roots @ List.map snd (Project_frontend.root_exports session) in
  let closure = reachable store roots in
  (* E1721: dynamic evaluation reachable from any root, through the prelude too *)
  let evals = eval_identities store in
  let* () =
    let reaching =
      Hashtbl.fold
        (fun decl_hash decl acc ->
          if List.exists (fun r -> List.exists (Hash.equal r) evals) (Store.decl_refs decl) then
            decl_hash :: acc
          else acc)
        closure []
    in
    match List.sort Hash.compare reaching with
    | [] -> Ok ()
    | first :: _ ->
        error "E1721"
          "declaration %s, reachable from a run step, test root, or export, refers to eval-code or \
           the Eval effect"
          (Hash.to_hex first)
  in
  let objects =
    List.sort Hash.compare
      (Hashtbl.fold
         (fun h _ acc -> if Project_frontend.is_prelude_object session h then acc else h :: acc)
         closure [])
  in
  let in_bundle hash =
    match Store.locate store hash with
    | Ok { Store.decl_hash; _ } -> List.exists (Hash.equal decl_hash) objects
    | Error _ -> false
  in
  let companions =
    List.filter (fun (hash, _) -> in_bundle hash) store.Store.call_abis
    |> List.sort (fun (a, _) (b, _) -> Hash.compare a b)
  in
  let prelude =
    List.map
      (fun (file, digest) -> Form.F (Form.form "file" [ Form.Text file; Form.Text digest ]))
      (List.sort compare (Option.value ~default:[] (Store.prelude_manifest store)))
  in
  let entry_form ((entry : Project_manifest.entry), bundled) =
    let grants = Form.F (Form.form "grants" (List.map (fun g -> Form.Sym g) entry.grants)) in
    match bundled with
    | Project_frontend.Steps steps ->
        Form.F
          (Form.form "run"
             [ Form.Sym entry.ename; Form.F (Form.form "steps" (List.map hash_form steps)); grants ])
    | Project_frontend.Roots roots ->
        Form.F
          (Form.form "test"
             (Form.Sym entry.ename
              :: List.map
                   (fun (kind, display, h) ->
                     Form.F (Form.form "root" [ Form.Sym kind; Form.Text display; Form.Hash h ]))
                   roots
             @ [ grants ]))
  in
  let record =
    Form.form version
      [
        Form.F (Form.form "manifest" [ Form.Hash (Project_manifest.semantic_digest manifest) ]);
        Form.F (Form.form "context" [ Form.Hash (Project_frontend.context_identity session) ]);
        Form.F (Form.form "prelude" prelude);
        Form.F (Form.form "core" [ Form.Text Version.version ]);
        Form.F (Form.form "entries" (List.map entry_form bundled));
        Form.F (Form.form "objects" [ Form.Int (List.length objects) ]);
        Form.F (Form.form "companions" [ Form.Int (List.length companions) ]);
      ]
  in
  let identity = Hash.of_string (Printer.print record) in
  let provenance =
    Form.form "provenance"
      ([
         Form.F (Form.form "document" [ Form.Hash (Project_manifest.document_digest manifest) ]);
         Form.F (Form.form "tool" [ Form.Text ("jacquard " ^ Version.version) ]);
       ]
      @
      match Sys.getenv_opt "SOURCE_DATE_EPOCH" with
      | Some epoch -> [ Form.F (Form.form "built" [ Form.Text epoch ]) ]
      | None -> [])
  in
  (* built beside the destination, published by one rename *)
  let temp = Printf.sprintf "%s.%d.tmp" out (Unix.getpid ()) in
  match
    Unix.mkdir temp 0o755;
    List.iter
      (fun d -> Unix.mkdir (Filename.concat temp d) 0o755)
      [ "objects"; "interfaces"; "contexts" ];
    let file name contents = write_file (Filename.concat temp name) contents in
    file "bundle-v1.jqd" (Printer.print record ^ "\n");
    file "project.jqd" (Project_manifest.print manifest);
    file "provenance.jqd" (Printer.print provenance ^ "\n");
    file "companions.jqd"
      (Printer.print_all
         (List.map
            (fun (hash, slots) ->
              Form.form "call-abi-v1"
                (Form.Hash hash
                :: List.map (fun slot -> Form.F (Store.call_abi_slot_form slot)) slots))
            companions));
    List.iter
      (fun (context_identity, context, interface) ->
        let name = Hash.to_hex context_identity ^ ".jqd" in
        file (Filename.concat "contexts" name) (Printer.print context ^ "\n");
        file (Filename.concat "interfaces" name) (Interface.serialize interface))
      (Project_frontend.graph_contexts session);
    List.iter
      (fun h ->
        let name = Hash.to_hex h ^ ".jqd" in
        file (Filename.concat "objects" name)
          (In_channel.with_open_bin (Store.object_path store h) In_channel.input_all))
      objects;
    Unix.rename temp out
  with
  | () -> Ok { identity; objects = List.length objects; companions = List.length companions }
  | exception (Unix.Unix_error _ | Sys_error _) ->
      (try remove_tree temp with Unix.Unix_error _ | Sys_error _ -> ());
      error "E1735" "cannot write bundle %s" out
