(* PKG.1: the project frontend; contracts in project_frontend.mli. *)

let ( let* ) = Result.bind

type project = { dir : string; manifest_file : string; manifest : Project_manifest.t }

let max_unit_bytes = 4 * 1024 * 1024

let summary = function
  | "E1703" -> "A project input exceeds a size budget."
  | "E1705" -> "A name is not visible in this project."
  | "E1706" -> "A library name does not carry the project's namespace."
  | "E1707" -> "Two projects' namespaces overlap."
  | "E1708" -> "A depended-on project has no namespace."
  | "E1709" -> "An explicit identity is not visible in this project."
  | "E1710" -> "A dependency's pin does not match its context identity."
  | "E1711" -> "A dependency is unpinned."
  | "E1712" -> "A transitive dependency's pin does not match its context identity."
  | "E1713" -> "The project graph has a dependency cycle."
  | "E1714" -> "One namespace appears at two context identities."
  | "E1719" -> "A call-ABI companion conflicts across the project graph."
  | "E1715" -> "A declarations-only unit contains a top-level expression."
  | "E1716" -> "A name is defined in two units."
  | "E1717" -> "An export selector names nothing the project defines."
  | "E1718" -> "The project declares no entry of that name and kind."
  | "E1722" -> "A unit path leaves the project directory."
  | "E1723" -> "A unit is missing or is not a regular file."
  | "E1724" -> "Two units' paths differ only by letter case."
  | "E1730" | "W1700" -> "An entry's declared grants differ from its checked authority."
  | "E1731" -> "Two visible constructors share a name."
  | "E1732" -> "The library refers to a name that only an entry defines."
  | "E1733" -> "A source or manifest file changed during pinning."
  | "E1734" -> "Two unit entries name the same file."
  | "E1735" -> "No project manifest was found or it could not be read."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown project code " ^ code))

let next_step = function
  | "E1703" -> "Split the unit into smaller units."
  | "E1705" | "E1709" ->
      "Use what the project's direct dependencies export, or export the name from the project that \
       defines it."
  | "E1707" -> "Give each project in the graph a namespace that is not a prefix of another's."
  | "E1708" -> "Add (namespace NAME) to the dependency's manifest."
  | "E1710" | "E1712" ->
      "Review the change, then run jacquard project pin in the project that declares the edge."
  | "E1711" -> "Run jacquard project pin in the project that declares the dependency."
  | "E1713" -> "Remove one dependency edge so that the graph has no cycle."
  | "E1714" -> "Depend on one version of the project throughout the graph."
  | "E1719" -> "Give the conflicting callables the same labels, or make their bodies differ."
  | "E1706" ->
      "Spell the name with the namespace prefix: `NS.name` for terms and operations, `NS-name` for \
       types and effects."
  | "E1715" -> "Move the expression into a run entry's unit."
  | "E1716" -> "Keep one definition, or rename one of them."
  | "E1717" -> "Export only names the project's own units define."
  | "E1718" -> "Use an entry the manifest declares, or add it to (entries ...)."
  | "E1722" -> "Keep every unit inside the project directory."
  | "E1723" -> "Point the manifest at an existing regular source file."
  | "E1733" -> "Run the command again once the files are stable."
  | "E1724" | "E1734" -> "List each source file once, spelled one way."
  | "E1735" -> "Run the command inside a project, or pass --project DIR."
  | "E1730" | "W1700" -> "Make the entry's (grants ...) list exactly the authority it needs."
  | "E1731" -> "Rename one constructor so every visible constructor name has one owner."
  | "E1732" ->
      "Move the definition into a library unit; the library is checked before, and without, any \
       entry."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown project code " ^ code))

let diag ?span code cause =
  Diag.error ?span ~domain:Diag.Project ~code ~summary:(summary code) ~cause
    ~next_step:(next_step code) ~contrast:None ()

let warn code cause =
  Diag.warning ~domain:Diag.Project ~code ~summary:(summary code) ~cause ~next_step:(next_step code)
    ~contrast:None ()

let error code fmt = Printf.ksprintf (fun cause -> Error [ diag code cause ]) fmt

(* --- loading: the manifest and its unit paths (design §10) --- *)

type unit_path = { written : string; canonical : string }

let canonical_unit dir written =
  let path = Filename.concat dir written in
  match Unix.realpath path with
  | exception Unix.Unix_error (e, _, _) ->
      Error
        (diag "E1723" (Printf.sprintf "unit %S cannot be read: %s" written (Unix.error_message e)))
  | canonical -> (
      let inside = String.starts_with ~prefix:(dir ^ "/") canonical in
      if not inside then
        Error
          (diag "E1722"
             (Printf.sprintf "unit %S resolves to %s, outside the project directory %s" written
                canonical dir))
      else
        match (Unix.stat canonical).Unix.st_kind with
        | Unix.S_REG -> Ok { written; canonical }
        | _ -> Error (diag "E1723" (Printf.sprintf "unit %S is not a regular file" written))
        | exception Unix.Unix_error (e, _, _) ->
            Error
              (diag "E1723"
                 (Printf.sprintf "unit %S cannot be read: %s" written (Unix.error_message e))))

(* E1734 and E1724 within one composition: each unit of [units] against [prior] (already checked
   among themselves) and the units before it; an identical file outranks a case-only clash *)
let distinct_units ?(prior = []) what (units : unit_path list) =
  let rec go acc seen = function
    | [] -> List.rev acc
    | u :: rest ->
        let same (v : unit_path) = String.equal v.canonical u.canonical in
        let folded (v : unit_path) =
          String.equal (String.lowercase_ascii v.canonical) (String.lowercase_ascii u.canonical)
        in
        let clash =
          match List.find_opt same seen with
          | Some v ->
              Some
                (diag "E1734"
                   (Printf.sprintf "%s lists %S and %S, which are the same file %s" what v.written
                      u.written u.canonical))
          | None ->
              Option.map
                (fun (v : unit_path) ->
                  diag "E1724"
                    (Printf.sprintf "%s lists %S and %S, which differ only by letter case" what
                       v.written u.written))
                (List.find_opt folded seen)
        in
        let acc = match clash with Some d -> d :: acc | None -> acc in
        go acc (seen @ [ u ]) rest
  in
  go [] prior units

let load manifest_file =
  let* manifest = Project_manifest.read manifest_file in
  match Unix.realpath (Filename.dirname manifest_file) with
  | exception Unix.Unix_error (e, _, _) ->
      Error
        [
          diag "E1735"
            (Printf.sprintf "cannot resolve the directory of %s: %s" manifest_file
               (Unix.error_message e));
        ]
  | dir ->
      let resolve written =
        match canonical_unit dir written with Ok u -> ([], Some u) | Error d -> ([ d ], None)
      in
      let resolve_all units =
        let results = List.map resolve units in
        (List.concat_map fst results, List.filter_map snd results)
      in
      let library_errors, library = resolve_all manifest.Project_manifest.units in
      let errors =
        library_errors
        @ distinct_units "the library" library
        @ List.concat_map
            (fun (entry : Project_manifest.entry) ->
              let entry_errors, own = resolve_all entry.eunits in
              entry_errors
              @ distinct_units ~prior:library
                  (Printf.sprintf "entry `%s` (after the library)" entry.ename)
                  own)
            manifest.entries
      in
      if errors = [] then Ok { dir; manifest_file; manifest } else Error errors

let find_entry project name =
  match
    List.find_opt
      (fun (e : Project_manifest.entry) -> String.equal e.ename name)
      project.manifest.Project_manifest.entries
  with
  | Some entry -> Ok entry
  | None ->
      let declared =
        match project.manifest.entries with
        | [] -> "it declares no entries"
        | entries ->
            "it declares "
            ^ String.concat ", "
                (List.map (fun (e : Project_manifest.entry) -> "`" ^ e.ename ^ "`") entries)
      in
      error "E1718" "%s has no entry `%s`; %s" project.manifest_file name declared

let find_entry_of_kind project name kind =
  let* entry = find_entry project name in
  if entry.Project_manifest.ekind = kind then Ok entry
  else
    let word = function Project_manifest.Run -> "run" | Project_manifest.Test -> "test" in
    error "E1718" "`%s` is a %s entry, not a %s entry; use jacquard project %s %s" name
      (word entry.ekind) (word kind) (word entry.ekind) name

(* --- reading and composing units (design §6) --- *)

let read_unit project written =
  let path = Filename.concat project.dir written in
  (* non-blocking, so a unit swapped for a FIFO after loading cannot stall the read *)
  match Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
  | exception Unix.Unix_error (e, _, _) ->
      error "E1723" "unit %S cannot be read: %s" written (Unix.error_message e)
  | fd ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          match (Unix.fstat fd).Unix.st_kind with
          | Unix.S_REG ->
              Unix.clear_nonblock fd;
              let buffer = Buffer.create 4096 and chunk = Bytes.create 65536 in
              let rec fill () =
                if Buffer.length buffer > max_unit_bytes then ()
                else
                  match Unix.read fd chunk 0 (Bytes.length chunk) with
                  | 0 -> ()
                  | n ->
                      Buffer.add_subbytes buffer chunk 0 n;
                      fill ()
              in
              fill ();
              if Buffer.length buffer > max_unit_bytes then
                error "E1703" "unit %S exceeds the unit limit of %d bytes" written max_unit_bytes
              else Ok (path, Buffer.contents buffer)
          | _ -> error "E1723" "unit %S is not a regular file" written)

let span_file meta = Option.map (fun (s : Span.t) -> s.Span.file) (Meta.span meta)

(* Definitions spelled in two different units; checked before lowering, which would otherwise
   report a cross-unit duplicate in one definition run as E0303. *)
let surface_duplicates (items : Surface_ast.top list) =
  let seen = Hashtbl.create 64 in
  List.filter_map
    (fun (top : Surface_ast.top) ->
      match (top.Surface_ast.it, span_file top.meta) with
      | Surface_ast.Definition { name; _ }, Some file -> (
          match Hashtbl.find_opt seen name with
          | Some first when not (String.equal first file) ->
              Some
                (diag ?span:(Meta.span top.meta) "E1716"
                   (Printf.sprintf "`%s` is defined in %s and again in %s" name first file))
          | Some _ -> None
          | None ->
              Hashtbl.add seen name file;
              None)
      | _ -> None)
    items

(* Units compose in order: a run of surface units is parsed as one program and lowered once; a
   bootstrap unit contributes its kernel forms at its position. *)
let compose ~names ~on_warning (units : (string * string) list) =
  let is_surface (file, _) = Filename.check_suffix (String.lowercase_ascii file) ".jac" in
  let rec runs acc = function
    | [] -> List.rev acc
    | u :: _ as all when is_surface u ->
        let rec take run = function
          | v :: rest when is_surface v -> take (v :: run) rest
          | rest -> (List.rev run, rest)
        in
        let run, rest = take [] all in
        runs (`Surface run :: acc) rest
    | u :: rest -> runs (`Bootstrap u :: acc) rest
  in
  let lower = function
    | `Surface run ->
        let* items = Surface_parse.compose_units run in
        let* () = match surface_duplicates items with [] -> Ok () | ds -> Error ds in
        List.iter on_warning (Surface_check.lint ~names items);
        Surface_lower.lower_tops items
    | `Bootstrap (file, source) ->
        let* forms = Reader.parse_string ~file source in
        let tops = List.map Kernel.of_form forms in
        let errors = List.concat_map (function Error ds -> ds | Ok _ -> []) tops in
        if errors = [] then Ok (List.filter_map Result.to_option tops) else Error errors
  in
  let results = List.map lower (runs [] units) in
  match List.concat_map (function Error ds -> ds | Ok _ -> []) results with
  | [] -> Ok (List.concat_map (function Ok tops -> tops | Error _ -> []) results)
  | errors -> Error errors

let read_units project units =
  let results = List.map (read_unit project) units in
  match List.concat_map (function Error ds -> ds | Ok _ -> []) results with
  | [] -> Ok (List.filter_map Result.to_option results)
  | errors -> Error errors

(* --- the names a top binds --- *)

type binder = { kind : Resolve.nkind; name : string; file : string option; meta : Meta.t }

let binders (top : Kernel.top) =
  match top with
  | Kernel.Expr _ -> []
  | Kernel.Decl d -> (
      let file = span_file d.Kernel.meta in
      match d.Kernel.it with
      | Kernel.DefTerm bindings ->
          List.map
            (fun (b : Kernel.binding) ->
              let file = match span_file b.bmeta with Some f -> Some f | None -> file in
              { kind = Resolve.KTerm; name = b.bname; file; meta = b.bmeta })
            bindings
      | Kernel.DefType { tname; cons; _ } ->
          { kind = Resolve.KType; name = tname; file; meta = d.meta }
          :: List.map
               (fun (c : Kernel.conspec) ->
                 { kind = Resolve.KCon; name = c.con_name; file; meta = c.kmeta })
               cons
      | Kernel.DefEffect { ename; ops; _ } ->
          { kind = Resolve.KEffect; name = ename; file; meta = d.meta }
          :: List.map
               (fun (o : Kernel.opspec) ->
                 { kind = Resolve.KOp; name = o.op_name; file; meta = o.smeta })
               ops)

let kind_word = function
  | Resolve.KTerm -> "term"
  | Resolve.KType -> "type"
  | Resolve.KEffect -> "effect"
  | Resolve.KCon -> "constructor"
  | Resolve.KOp -> "operation"

let where = function Some file -> file | None -> "an unnamed unit"

(* E1716 for kernel bindings: types, effects, operations, generated accessors, bootstrap units.
   Constructors are owned by their types; their collisions are E1731. *)
let cross_unit_duplicates tops =
  let seen = Hashtbl.create 64 in
  List.concat_map
    (fun top ->
      List.filter_map
        (fun b ->
          if b.kind = Resolve.KCon then None
          else
            match Hashtbl.find_opt seen (b.kind, b.name) with
            | Some first when first <> b.file ->
                Some
                  (diag ?span:(Meta.span b.meta) "E1716"
                     (Printf.sprintf "%s `%s` is defined in %s and again in %s" (kind_word b.kind)
                        b.name (where first) (where b.file)))
            | Some _ -> None
            | None ->
                Hashtbl.add seen (b.kind, b.name) b.file;
                None)
        (binders top))
    tops

let expressions_refused what tops =
  List.filter_map
    (function
      | Kernel.Expr e ->
          Some
            (diag ?span:(Meta.span e.Kernel.meta) "E1715"
               (Printf.sprintf "%s holds declarations only; found a top-level expression" what))
      | Kernel.Decl _ -> None)
    tops

(* --- the namespace contract (design §4): checked, never rewritten --- *)

let has_prefix ns sep name =
  let p = ns ^ sep in
  String.length name > String.length p && String.starts_with ~prefix:p name

let namespace_violations ns tops =
  let types =
    List.concat_map
      (fun top ->
        List.filter_map
          (fun b -> if b.kind = Resolve.KType then Some b.name else None)
          (binders top))
      tops
  in
  (* a generated accessor `<type>.<label>` follows its type *)
  let accessor name =
    match String.index_opt name '.' with
    | Some i -> List.mem (String.sub name 0 i) types && has_prefix ns "-" name
    | None -> false
  in
  List.concat_map
    (fun top ->
      List.filter_map
        (fun b ->
          let ok, required =
            match b.kind with
            | Resolve.KCon -> (true, "")
            | Resolve.KTerm | Resolve.KOp ->
                (has_prefix ns "." b.name || (b.kind = Resolve.KTerm && accessor b.name), ns ^ ".")
            | Resolve.KType | Resolve.KEffect -> (has_prefix ns "-" b.name, ns ^ "-")
          in
          if ok then None
          else
            Some
              (diag ?span:(Meta.span b.meta) "E1706"
                 (Printf.sprintf "%s `%s` (%s) does not begin with `%s`, as namespace `%s` requires"
                    (kind_word b.kind) b.name (where b.file) required ns)))
        (binders top))
    tops

(* --- the dependency graph (design §8) --- *)

type node = {
  project : project;
  deps : (Project_manifest.dep * node) list;
  from_bundle : bool;  (** a verified bundle, not a source directory *)
}

let project_label project =
  match project.manifest.Project_manifest.namespace with
  | Some ns -> ns
  | None -> project.manifest.name

(* Files read while preparing a graph, with their digests: [project pin] rechecks them before it
   writes (E1733). *)
type snapshot = (string, Hash.t) Hashtbl.t

let record_file (snapshot : snapshot) path bytes =
  Hashtbl.replace snapshot path (Hash.of_string bytes)

let read_bytes path =
  match In_channel.with_open_bin path In_channel.input_all with
  | bytes -> Some bytes
  | exception Sys_error _ -> None

let load_graph ?(pinning = false) ~snapshot manifest_file =
  let loaded : (string, node) Hashtbl.t = Hashtbl.create 8 in
  let errors = ref [] in
  let add ds = errors := !errors @ ds in
  let rec visit ~chain ~stack manifest_file =
    match load manifest_file with
    | Error ds ->
        add ds;
        None
    | Ok project when List.mem project.dir stack ->
        add [ diag "E1713" (Printf.sprintf "dependency cycle: %s" (String.concat " -> " chain)) ];
        None
    | Ok project -> (
        match Hashtbl.find_opt loaded project.dir with
        | Some node -> Some node
        | None ->
            Option.iter (record_file snapshot manifest_file) (read_bytes manifest_file);
            let chain = if chain = [] then [ project_label project ] else chain in
            let is_root = List.length chain = 1 in
            let deps =
              List.filter_map
                (fun (dep : Project_manifest.dep) ->
                  let where = String.concat " -> " (chain @ [ dep.alias ]) in
                  if dep.pin = None && not (pinning && is_root) then
                    add
                      [
                        diag "E1711"
                          (Printf.sprintf "dependency %s is unpinned; run jacquard project pin%s"
                             where
                             (if is_root then "" else " in the project that declares it"));
                      ];
                  match dep.source with
                  | Project_manifest.Bundle path -> (
                      (* a bundle is verified when the graph is composed; here only its manifest is
                         read, and its own dependencies travel inside it *)
                      let dir = Filename.concat project.dir path in
                      let manifest_file = Filename.concat dir Project_manifest.file_name in
                      match (Unix.realpath dir, Project_manifest.read manifest_file) with
                      | exception Unix.Unix_error (e, _, _) ->
                          add
                            [
                              diag "E1735"
                                (Printf.sprintf "dependency %s: bundle %S cannot be read: %s" where
                                   path (Unix.error_message e));
                            ];
                          None
                      | _, Error ds ->
                          add ds;
                          None
                      | dir, Ok manifest ->
                          Option.iter
                            (record_file snapshot (Filename.concat dir "bundle-v1.jqd"))
                            (read_bytes (Filename.concat dir "bundle-v1.jqd"));
                          if manifest.Project_manifest.namespace = None then
                            add
                              [
                                diag "E1708"
                                  (Printf.sprintf
                                     "dependency %s (bundle %s) declares no namespace; a project \
                                      that others depend on must declare one"
                                     where path);
                              ];
                          Some
                            ( dep,
                              {
                                project = { dir; manifest_file; manifest };
                                deps = [];
                                from_bundle = true;
                              } ))
                  | Project_manifest.Path path -> (
                      let dir = Filename.concat project.dir path in
                      match
                        visit ~chain:(chain @ [ dep.alias ]) ~stack:(project.dir :: stack)
                          (Filename.concat dir Project_manifest.file_name)
                      with
                      | None -> None
                      | Some child ->
                          if child.project.manifest.namespace = None then
                            add
                              [
                                diag "E1708"
                                  (Printf.sprintf
                                     "dependency %s (%s) declares no namespace; a project that \
                                      others depend on must declare one"
                                     where child.project.manifest_file);
                              ];
                          Some (dep, child)))
                project.manifest.deps
            in
            let node = { project; deps; from_bundle = false } in
            Hashtbl.replace loaded project.dir node;
            Some node)
  in
  let root = visit ~chain:[] ~stack:[] manifest_file in
  (* the namespaces of distinct projects must not be boundary-prefixes of one another (E1707); one
     namespace at two projects is judged by context identity after composition (E1714) *)
  let nodes = Hashtbl.fold (fun _ node acc -> node :: acc) loaded [] in
  let namespaces =
    List.sort_uniq compare
      (List.filter_map (fun n -> n.project.manifest.Project_manifest.namespace) nodes)
  in
  List.iter
    (fun a ->
      List.iter
        (fun b ->
          if (not (String.equal a b)) && (has_prefix a "-" b || has_prefix a "." b) then
            add
              [
                diag "E1707"
                  (Printf.sprintf
                     "namespace `%s` is a boundary-prefix of namespace `%s` in one project graph" a
                     b);
              ])
        namespaces)
    namespaces;
  match (root, !errors) with Some root, [] -> Ok root | _, errors -> Error errors

(* dependency-first, each project once *)
let topological root =
  let seen = Hashtbl.create 8 in
  let rec go acc node =
    if Hashtbl.mem seen node.project.dir then acc
    else begin
      Hashtbl.add seen node.project.dir ();
      let acc = List.fold_left (fun acc (_, child) -> go acc child) acc node.deps in
      node :: acc
    end
  in
  List.rev (go [] root)

(* --- views: what a project's checked code may name (design §5) --- *)

type layer = (string, Resolve.entry list) Hashtbl.t

let add_binding (layer : layer) ((name, kind), hash) =
  let others =
    List.filter
      (fun (e : Resolve.entry) -> e.kind <> kind)
      (Option.value ~default:[] (Hashtbl.find_opt layer name))
  in
  Hashtbl.replace layer name ({ Resolve.hash; kind } :: others)

let layer_of bindings =
  let layer = Hashtbl.create 64 in
  List.iter (add_binding layer) bindings;
  layer

(* The first layer that binds a (name, kind) wins. Views are built from each project's own
   bindings rather than the store's single name index, where one project's constructor could
   otherwise replace another's. *)
let view store (layers : layer list) =
  let base = Store.names_view store in
  let lookup name =
    List.fold_left
      (fun acc layer ->
        List.fold_left
          (fun acc (e : Resolve.entry) ->
            if List.exists (fun (a : Resolve.entry) -> a.kind = e.kind) acc then acc
            else acc @ [ e ])
          acc
          (Option.value ~default:[] (Hashtbl.find_opt layer name)))
      [] layers
  in
  let all_names () =
    List.sort_uniq String.compare
      (List.concat_map (fun layer -> Hashtbl.fold (fun name _ acc -> name :: acc) layer []) layers)
  in
  { base with Resolve.lookup; all_names }

(* --- sessions --- *)

type composed = {
  node : node;
  local : layer;  (** the library's own bindings *)
  bound_in : ((string * Resolve.nkind) * string option) list;  (** each binding's unit *)
  exports : ((string * Resolve.nkind) * Hash.t) list;  (** the export projection *)
  export_layer : layer;
  interface : Interface.t;
  context : Form.t;
  identity : Hash.t;
  declarations : int;
}

type session = {
  project : project;
  store : Store.t;
  ctx : Eval.ctx;
  checker : Check.ctx;
  prelude : layer;
  owners : (Hash.t, string) Hashtbl.t;  (** identity -> directory of a project that installed it *)
  composed : (string, composed) Hashtbl.t;  (** by project directory *)
  mutable root : composed option;
  snapshot : snapshot;
  prelude_objects : (Hash.t, unit) Hashtbl.t;  (** declarations the prelude installed *)
}

let store s = s.store
let eval_ctx s = s.ctx
let checker s = s.checker

let root_composed s =
  match s.root with Some c -> c | None -> invalid_arg "Project_frontend: no library"

let library_declarations s = (root_composed s).declarations
let interface s = (root_composed s).interface
let context_identity s = (root_composed s).identity
let context_record s = (root_composed s).context

let direct_deps session (node : node) =
  List.filter_map
    (fun (_, (child : node)) -> Hashtbl.find_opt session.composed child.project.dir)
    node.deps

let layers_for session ?entry (node : node) local =
  (match entry with Some layer -> [ layer ] | None -> [])
  @ [ local ]
  @ List.map (fun c -> c.export_layer) (direct_deps session node)
  @ [ session.prelude ]

(* An identity is visible to [node] unless another project installed it and does not export it to
   [node] as a direct dependency. The prelude and the project's own objects are always visible. *)
let visible_hash session (node : node) hash =
  match Hashtbl.find_all session.owners hash with
  | [] -> true
  | owners ->
      List.exists
        (fun owner ->
          String.equal owner node.project.dir
          || List.exists
               (fun c ->
                 String.equal c.node.project.dir owner
                 && List.exists (fun (_, h) -> Hash.equal h hash) c.exports)
               (direct_deps session node))
        owners

let top_refs = function Kernel.Decl d -> Store.decl_refs d | Kernel.Expr e -> Store.expr_refs e
let meta_of = function Kernel.Decl d -> d.Kernel.meta | Kernel.Expr e -> e.Kernel.meta

let owner_label session hash =
  match Hashtbl.find_all session.owners hash with
  | dir :: _ -> (
      match Hashtbl.find_opt session.composed dir with
      | Some c -> Printf.sprintf "project `%s`" (project_label c.node.project)
      | None -> "another project")
  | [] -> "the prelude"

let hash_refusals session (node : node) top =
  List.filter_map
    (fun hash ->
      if visible_hash session node hash then None
      else
        Some
          (diag
             ?span:(Meta.span (meta_of top))
             "E1709"
             (Printf.sprintf
                "hash %s is not visible in project `%s`: it belongs to %s, which does not export \
                 it to this project"
                (Hash.to_hex hash) (project_label node.project) (owner_label session hash))))
    (List.sort_uniq Hash.compare (top_refs top))

(* an unknown name that another project binds is a visibility refusal (E1705) *)
let name_refusal session (node : node) d =
  match (Diag.code d, Resolve.reference_of d) with
  | Some ("E0301" | "E0302"), Some (name, kinds) -> (
      let direct = direct_deps session node in
      (* another project binds the name with a kind this position accepts *)
      let binds (c : composed) =
        List.exists
          (fun (e : Resolve.entry) -> kinds = [] || List.mem e.kind kinds)
          (Option.value ~default:[] (Hashtbl.find_opt c.local name))
      in
      (* every other project that binds it, in a stable order; a direct dependency first *)
      let owners =
        Hashtbl.fold
          (fun _ c acc ->
            if String.equal c.node.project.dir node.project.dir || not (binds c) then acc
            else c :: acc)
          session.composed []
        |> List.sort (fun a b ->
            compare
              (not (List.memq a direct), project_label a.node.project)
              (not (List.memq b direct), project_label b.node.project))
      in
      match owners with
      | [] -> None
      | c :: _ ->
          let labels =
            String.concat ", " (List.map (fun c -> "`" ^ project_label c.node.project ^ "`") owners)
          in
          let why =
            if List.memq c direct then Printf.sprintf "`%s` is private to project %s" name labels
            else
              Printf.sprintf "`%s` belongs to project %s, which `%s` does not depend on directly"
                name labels (project_label node.project)
          in
          Some (diag ?span:(Diag.span d) "E1705" why))
  | _ -> None

let map_name_refusals session node ds =
  List.map (fun d -> Option.value (name_refusal session node d) ~default:d) ds

(* E1731: visible constructors with one name and two owners *)
let owning_type store hash =
  match Store.locate store hash with
  | Ok { Store.decl = { Kernel.it = Kernel.DefType { tname; _ }; _ }; _ } -> tname
  | _ -> Hash.to_hex hash

let constructor_collisions ?(own = []) session (node : node) tops =
  let store = session.store in
  let describe hash =
    let owner =
      if List.mem node.project.dir (Hashtbl.find_all session.owners hash) then "the library"
      else owner_label session hash
    in
    Printf.sprintf "type `%s` of %s" (owning_type store hash) owner
  in
  (* among what the project sees from its direct dependencies and the prelude *)
  let seen = Hashtbl.create 64 in
  let visible_clashes =
    List.concat_map
      (fun (layer : layer) ->
        Hashtbl.fold
          (fun name entries acc ->
            List.fold_left
              (fun acc (e : Resolve.entry) ->
                if e.kind <> Resolve.KCon then acc
                else
                  match Hashtbl.find_opt seen name with
                  | Some other when not (Hash.equal other e.hash) ->
                      diag "E1731"
                        (Printf.sprintf
                           "constructor `%s` of %s and constructor `%s` of %s are both visible in \
                            project `%s`"
                           name (describe other) name (describe e.hash) (project_label node.project))
                      :: acc
                  | Some _ -> acc
                  | None ->
                      Hashtbl.add seen name e.hash;
                      acc)
              acc entries)
          layer [])
      (own @ List.map (fun c -> c.export_layer) (direct_deps session node) @ [ session.prelude ])
  in
  let local = Hashtbl.create 32 in
  let local_clashes =
    List.concat_map
      (function
        | Kernel.Decl { Kernel.it = Kernel.DefType { tname; cons; _ }; meta } ->
            List.filter_map
              (fun (c : Kernel.conspec) ->
                let clash =
                  match Hashtbl.find_opt local c.con_name with
                  | Some other when not (String.equal other tname) ->
                      Some (Printf.sprintf "type `%s` of this project" other)
                  | Some _ -> None
                  | None -> (
                      Hashtbl.add local c.con_name tname;
                      match Hashtbl.find_opt seen c.con_name with
                      | Some hash when not (String.equal (owning_type store hash) tname) ->
                          Some (describe hash)
                      | _ -> None)
                in
                Option.map
                  (fun other ->
                    diag
                      ?span:
                        (match Meta.span c.kmeta with Some s -> Some s | None -> Meta.span meta)
                      "E1731"
                      (Printf.sprintf "constructor `%s` of type `%s` is also a constructor of %s"
                         c.con_name tname other))
                  clash)
              cons
        | _ -> [])
      tops
  in
  List.rev visible_clashes @ local_clashes

(* --- context identity (design §8) --- *)

let context_form = Project_context.form
let context_identity_of = Project_context.identity

(* --- composing one library --- *)

(* the names every entry of the root binds, for E1732; entries that fail to compose contribute
   nothing *)
let entry_defined_names project ~names =
  List.concat_map
    (fun (entry : Project_manifest.entry) ->
      match Result.bind (read_units project entry.eunits) (compose ~names ~on_warning:ignore) with
      | Ok tops ->
          List.concat_map (fun top -> List.map (fun b -> (b.name, entry.ename)) (binders top)) tops
      | Error _ -> [])
    project.manifest.entries

let bindings_of store decl hashes = (Diff.source_side store [ (decl, hashes) ]).Diff.bindings

let entry_boundary project ~names ds =
  (* an unresolved name that only an entry defines is the library/entry boundary (E1732) *)
  let entry_names = lazy (entry_defined_names project ~names) in
  List.map
    (fun d ->
      match Resolve.reference_of d with
      | Some (name, _) when Diag.code d = Some "E0301" -> (
          match List.assoc_opt name (Lazy.force entry_names) with
          | Some entry ->
              diag ?span:(Diag.span d) "E1732"
                (Printf.sprintf
                   "the library refers to `%s`, which only entry `%s` defines; entries are \
                    composed after the library and cannot be referenced by it"
                   name entry)
          | None -> d)
      | _ -> d)
    ds

let export_projection project local =
  List.partition_map
    (fun (s : Project_manifest.selector) ->
      let kind =
        match s.kind with
        | Project_manifest.Term -> Resolve.KTerm
        | Con -> Resolve.KCon
        | Op -> Resolve.KOp
        | Type -> Resolve.KType
        | Effect -> Resolve.KEffect
      in
      match
        List.find_opt
          (fun (e : Resolve.entry) -> e.kind = kind)
          (Option.value ~default:[] (Hashtbl.find_opt local s.name))
      with
      | Some e -> Left ((s.name, kind), e.hash)
      | None ->
          Right
            (diag "E1717"
               (Printf.sprintf "project `%s` exports (%s %s), which its own units do not define"
                  (project_label project)
                  (Project_manifest.kind_name s.kind)
                  s.name)))
    project.manifest.Project_manifest.exports

(* one namespace at two context identities is refused in v1 (E1714) *)
let register session composed =
  let project = composed.node.project in
  let clash =
    Hashtbl.fold
      (fun _ c acc ->
        match (c.node.project.manifest.namespace, project.manifest.namespace) with
        | Some a, Some b when String.equal a b && not (Hash.equal c.identity composed.identity) ->
            Some c
        | _ -> acc)
      session.composed None
  in
  match clash with
  | Some c ->
      error "E1714" "namespace `%s` appears at two context identities: %s (%s) and %s (%s)"
        (project_label project) c.node.project.dir (Hash.to_hex c.identity) project.dir
        (Hash.to_hex composed.identity)
  | None ->
      Hashtbl.replace session.composed project.dir composed;
      Ok composed

(* A bundle dependency: verified into the session's store, then seen through its recorded export
   projection. Every object it carries, its own dependencies' included, belongs to it. *)
let import_bundle session (node : node) =
  let* verified =
    Project_bundle_reader.verify ~store:session.store ~checker:session.checker node.project.dir
  in
  let context, interface =
    match
      List.find_opt
        (fun (id, _, _) -> Hash.equal id verified.Project_bundle_reader.context)
        verified.contexts
    with
    | Some (_, form, interface) -> (form, interface)
    | None -> assert false (* verify checked the bundle's own context is among them *)
  in
  let exports =
    List.map (fun (e : Interface.export) -> ((e.name, e.kind), e.hash)) interface.Interface.exports
  in
  let local = Hashtbl.create 64 in
  List.iter
    (fun (decl, ({ Canon.decl_hash; named } as hashes)) ->
      List.iter (add_binding local) (bindings_of session.store decl hashes);
      List.iter
        (fun hash ->
          if not (List.mem node.project.dir (Hashtbl.find_all session.owners hash)) then
            Hashtbl.add session.owners hash node.project.dir)
        (decl_hash :: List.map snd named))
    verified.objects;
  register session
    {
      node;
      local;
      bound_in = [];
      exports;
      export_layer = layer_of exports;
      interface;
      context;
      identity = verified.context;
      declarations = List.length verified.objects;
    }

let compose_library ?(on_lint = ignore) ?(on_warning = ignore) ~is_root session (node : node) =
  let project = node.project in
  let local = Hashtbl.create 64 in
  let names = view session.store (layers_for session node local) in
  let* units = read_units project project.manifest.Project_manifest.units in
  List.iter (fun (file, bytes) -> record_file session.snapshot file bytes) units;
  let* tops = compose ~names ~on_warning:on_lint units in
  let rules =
    expressions_refused "a library unit" tops
    @ cross_unit_duplicates tops
    @ (match project.manifest.namespace with Some ns -> namespace_violations ns tops | None -> [])
    @ constructor_collisions session node tops
  in
  let* () = if rules = [] then Ok () else Error rules in
  let installed = ref 0 in
  let walked =
    Frontend.walk_tops session.store tops ~names
      ~on_resolved:(fun top warnings ->
        List.iter on_warning warnings;
        let* () = match hash_refusals session node top with [] -> Ok () | ds -> Error ds in
        let* { Check.warnings; _ } = Check.check_top session.checker top in
        List.iter on_warning warnings;
        Ok ())
      ~on_installed:(fun decl ({ Canon.decl_hash; named } as hashes) ->
        incr installed;
        List.iter (add_binding local) (bindings_of session.store decl hashes);
        List.iter
          (fun hash ->
            if not (List.mem project.dir (Hashtbl.find_all session.owners hash)) then
              Hashtbl.add session.owners hash project.dir)
          (decl_hash :: List.map snd named);
        Ok ())
  in
  match walked with
  | Error ds ->
      (* a call-ABI companion that conflicts with one already composed into the graph (E1719) *)
      let ds =
        List.map
          (fun d ->
            if Diag.code d = Some "E0612" then
              diag ?span:(Diag.span d) "E1719"
                (Printf.sprintf "project `%s` conflicts with the graph: %s" (project_label project)
                   (Diag.cause d))
            else d)
          (map_name_refusals session node ds)
      in
      Error (if is_root then entry_boundary project ~names ds else ds)
  | Ok () ->
      let exports, missing = export_projection project local in
      let* () = if missing = [] then Ok () else Error missing in
      (* derived now, while this project's own bindings are the store's current ones *)
      let* interface =
        Interface.of_side session.checker { Diff.store = session.store; bindings = exports }
      in
      let deps =
        List.filter_map
          (fun ((dep : Project_manifest.dep), (child : node)) ->
            Option.map
              (fun c -> (dep.alias, c.identity))
              (Hashtbl.find_opt session.composed child.project.dir))
          node.deps
      in
      let context = context_form session.store ~interface ~exports ~deps in
      let composed =
        {
          node;
          local;
          bound_in =
            List.concat_map
              (fun top -> List.map (fun b -> ((b.name, b.kind), b.file)) (binders top))
              tops;
          exports;
          export_layer = layer_of exports;
          interface;
          context;
          identity = context_identity_of context;
          declarations = !installed;
        }
      in
      register session composed

(* --- pins (design §8) --- *)

let jacquard_dir project = Filename.concat project.dir ".jacquard"
let contexts_dir project = Filename.concat (jacquard_dir project) "contexts"
let interfaces_dir project = Filename.concat (jacquard_dir project) "interfaces"
let record_path dir identity = Filename.concat dir (Hash.to_hex identity ^ ".jqd")

let changed_components root ~old ~(new_ : Form.t) =
  match read_bytes (record_path (contexts_dir root) old) with
  | None -> "previous context record unavailable"
  | Some bytes -> (
      match Reader.parse_string ~file:"context" bytes with
      | Ok [ { Form.head = "project-context-v1"; args = old_args; _ } ] ->
          let component name args =
            List.find_map
              (function Form.F ({ Form.head; _ } as f) when head = name -> Some f | _ -> None)
              args
          in
          let changed =
            List.filter
              (fun name ->
                match (component name old_args, component name new_.Form.args) with
                | Some a, Some b -> not (Form.equal_ignoring_meta a b)
                | _ -> true)
              [ "interface"; "companions"; "prelude"; "core"; "deps" ]
          in
          "changed: " ^ String.concat ", " changed
      | _ -> "previous context record unreadable")

let interface_report root ~old interface =
  match read_bytes (record_path (interfaces_dir root) old) with
  | None -> "previous interface unavailable"
  | Some bytes -> (
      match Interface.parse ~file:"interface" bytes with
      | Error _ -> "previous interface unreadable"
      | Ok previous -> (
          match Interface.render_report (Interface.diff ~old:previous ~new_:interface) with
          | Some report -> report
          | None -> "interface unchanged"))

(* every edge whose pin disagrees with the dependency's computed identity; a root edge is E1710, a
   transitive one E1712, each with its alias chain *)
let pin_mismatches ?(skip_root = false) session (root_node : node) =
  let root = root_node.project in
  let seen = Hashtbl.create 8 in
  let rec go chain (node : node) =
    if Hashtbl.mem seen node.project.dir then []
    else begin
      Hashtbl.add seen node.project.dir ();
      let is_root = List.length chain = 1 in
      List.concat_map
        (fun ((dep : Project_manifest.dep), (child : node)) ->
          let here =
            match (dep.pin, Hashtbl.find_opt session.composed child.project.dir) with
            | Some pin, Some c when (not (Hash.equal pin c.identity)) && not (is_root && skip_root)
              ->
                [
                  diag
                    (if is_root then "E1710" else "E1712")
                    (Printf.sprintf
                       "dependency %s is pinned to %s but its context identity is %s (%s; %s)"
                       (String.concat " -> " (chain @ [ dep.alias ]))
                       (Hash.to_hex pin) (Hash.to_hex c.identity)
                       (changed_components root ~old:pin ~new_:c.context)
                       (interface_report root ~old:pin c.interface));
                ]
            | _ -> []
          in
          here @ go (chain @ [ dep.alias ]) child)
        node.deps
    end
  in
  go [ project_label root ] root_node

let open_graph ?(on_lint = ignore) ?(on_warning = ignore) ?(pinning = false) ~prelude_dir ~root
    manifest_file =
  if Sys.file_exists root && ((not (Sys.is_directory root)) || Array.length (Sys.readdir root) > 0)
  then invalid_arg ("Project_frontend.open_graph: root is not a fresh directory: " ^ root);
  let snapshot = Hashtbl.create 32 in
  let* root_node = load_graph ~pinning ~snapshot manifest_file in
  let* store, ctx = Frontend.open_session ~prelude_dir ~root in
  let* checker = Frontend.make_checker store in
  let session =
    {
      project = root_node.project;
      store;
      ctx;
      checker;
      prelude =
        layer_of
          (List.map (fun (n, (e : Resolve.entry)) -> ((n, e.kind), e.hash)) (Store.names store));
      owners = Hashtbl.create 256;
      composed = Hashtbl.create 8;
      root = None;
      snapshot;
      prelude_objects =
        (let table = Hashtbl.create 1024 in
         List.iter (fun h -> Hashtbl.replace table h ()) (Store.all_decl_hashes store);
         table);
    }
  in
  let rec compose_all = function
    | [] -> Ok ()
    | node :: rest ->
        let is_root = node == root_node in
        let on_lint, on_warning = if is_root then (on_lint, on_warning) else (ignore, ignore) in
        let* composed =
          if node.from_bundle then import_bundle session node
          else compose_library ~on_lint ~on_warning ~is_root session node
        in
        if is_root then session.root <- Some composed;
        compose_all rest
  in
  let* () = compose_all (topological root_node) in
  match pin_mismatches ~skip_root:pinning session root_node with
  | [] -> Ok (session, root_node)
  | ds -> Error ds

let open_library ?on_lint ?on_warning ~prelude_dir ~root project =
  Result.map fst (open_graph ?on_lint ?on_warning ~prelude_dir ~root project.manifest_file)

(* --- entries --- *)

let entry_view session =
  let root = root_composed session in
  let entry = Hashtbl.create 32 in
  (entry, view session.store (layers_for session ~entry root.node root.local))

(* An entry adds names; it never replaces the library's. A name the library binds is E1716 and a
   constructor that collides with a visible one (the library's, a dependency's, or the prelude's) is
   E1731, as they would be inside the library. *)
let entry_rules session tops =
  let root = root_composed session in
  let redefined =
    List.concat_map
      (fun top ->
        List.filter_map
          (fun b ->
            if b.kind = Resolve.KCon then None
            else
              match List.assoc_opt (b.name, b.kind) root.bound_in with
              | Some library_file ->
                  Some
                    (diag ?span:(Meta.span b.meta) "E1716"
                       (Printf.sprintf "%s `%s` is defined in %s and again in entry unit %s"
                          (kind_word b.kind) b.name (where library_file) (where b.file)))
              | None -> None)
          (binders top))
      tops
  in
  cross_unit_duplicates tops @ redefined
  @ constructor_collisions ~own:[ root.local ] session root.node tops

let entry_tops ?(on_lint = ignore) session (entry : Project_manifest.entry) =
  let* units = read_units session.project entry.eunits in
  let* tops = compose ~names:(snd (entry_view session)) ~on_warning:on_lint units in
  match entry_rules session tops with [] -> Ok tops | ds -> Error ds

(* Walk an entry's tops with the root project's view: the entry's own bindings, its library, its
   direct dependencies' exports, and the prelude. Explicit identities are checked (E1709), unknown
   names that another project binds are E1705, and [eval-code] payloads go through the same gate. *)
let walk_entry ?(on_resolved = fun _ _ -> Ok ()) ?(on_installed = fun _ _ -> Ok ()) session tops =
  let root = root_composed session in
  let layer, names = entry_view session in
  Eval.set_code_resolver session.ctx (fun e ->
      let* e =
        Result.map_error (map_name_refusals session root.node) (Resolve.resolve_expr names e)
      in
      match hash_refusals session root.node (Kernel.Expr e) with [] -> Ok e | ds -> Error ds);
  Result.map_error
    (map_name_refusals session root.node)
    (Frontend.walk_tops session.store tops ~names
       ~on_resolved:(fun top warnings ->
         let* () = match hash_refusals session root.node top with [] -> Ok () | ds -> Error ds in
         on_resolved top warnings)
       ~on_installed:(fun decl hashes ->
         List.iter (add_binding layer) (bindings_of session.store decl hashes);
         on_installed decl hashes))

(* --- checking an entry and its authority (design §7) --- *)

type authority = { required : Hash.t list; owned_tests : Warp.discovered list }

let owned_tests session hashes =
  List.filter
    (function
      | Warp.Hermetic (_, h) | Warp.World (_, h) | Warp.Relational (_, h) ->
          List.exists (Hash.equal h) hashes)
    (Warp.discover session.store session.checker)

let infrastructure session = Frontend.granted_effects session.store []

let check_entry ?on_lint ?(on_warning = ignore) session (entry : Project_manifest.entry) =
  let* tops = entry_tops ?on_lint session entry in
  let* () =
    match entry.ekind with
    | Project_manifest.Test -> (
        match expressions_refused (Printf.sprintf "test entry `%s`" entry.ename) tops with
        | [] -> Ok ()
        | ds -> Error ds)
    | Project_manifest.Run -> Ok ()
  in
  let effects = ref [] and members = ref [] in
  let* () =
    walk_entry session tops
      ~on_resolved:(fun top warnings ->
        List.iter on_warning warnings;
        let* { Check.row; warnings; _ } = Check.check_top session.checker top in
        List.iter on_warning warnings;
        (match (top, row) with
        | Kernel.Expr _, Some row -> effects := (Types.repr_row row).Types.effects @ !effects
        | _ -> ());
        Ok ())
      ~on_installed:(fun _ { Canon.decl_hash; named } ->
        members := (decl_hash :: List.map snd named) @ !members;
        Ok ())
  in
  let infrastructure = infrastructure session in
  let not_infrastructure h = not (List.exists (Hash.equal h) infrastructure) in
  match entry.ekind with
  | Project_manifest.Run ->
      Ok
        {
          required = List.sort_uniq Hash.compare (List.filter not_infrastructure !effects);
          owned_tests = [];
        }
  | Project_manifest.Test ->
      let owned = owned_tests session !members in
      let world = List.exists (function Warp.World _ -> true | _ -> false) owned in
      let required = if world then Warp.world_required session.checker session.store else [] in
      Ok
        {
          required = List.sort_uniq Hash.compare (List.filter not_infrastructure required);
          owned_tests = owned;
        }

let effect_name session hash =
  match
    List.find_map
      (fun (name, { Resolve.hash = h; kind }) ->
        if kind = Resolve.KEffect && Hash.equal h hash then Some name else None)
      (Store.names session.store)
  with
  | Some name -> name
  | None -> Hash.to_hex hash

let compare_grants ~strict session (entry : Project_manifest.entry) authority =
  let report cause = if strict then diag "E1730" cause else warn "W1700" cause in
  let infrastructure = infrastructure session in
  let own grant =
    List.filter
      (fun h -> not (List.exists (Hash.equal h) infrastructure))
      (Frontend.granted_effects session.store [ grant ])
  in
  let covered = List.concat_map own entry.grants in
  let missing =
    List.filter_map
      (fun h ->
        if List.exists (Hash.equal h) covered then None
        else
          Some
            (report
               (Printf.sprintf "entry `%s` requires `%s` but its (grants ...) does not declare it"
                  entry.ename (effect_name session h))))
      authority.required
  in
  let unused =
    List.filter_map
      (fun grant ->
        let effects = own grant in
        if not (List.mem grant Prelude.grantable_names) then
          Some
            (report
               (Printf.sprintf "entry `%s` declares `%s`, which is not a grantable effect"
                  entry.ename grant))
        else if List.exists (fun h -> List.exists (Hash.equal h) authority.required) effects then
          None
        else
          Some
            (report
               (Printf.sprintf "entry `%s` declares `%s` but its checked code never requires it"
                  entry.ename grant)))
      entry.grants
  in
  missing @ unused

(* --- pinning --- *)

type pin_plan = {
  alias : string;
  old_pin : Hash.t option;
  new_pin : Hash.t;
  changes : string option;  (** components and interface report when the pin moves *)
}

let plan_pins session (root_node : node) ~only =
  let root = root_node.project in
  let unknown =
    List.filter
      (fun alias ->
        not (List.exists (fun ((d : Project_manifest.dep), _) -> d.alias = alias) root_node.deps))
      only
  in
  if unknown <> [] then
    error "E1711" "%s declares no dependency %s" root.manifest_file
      (String.concat ", " (List.map (Printf.sprintf "`%s`") unknown))
  else
    Ok
      (List.filter_map
         (fun ((dep : Project_manifest.dep), (child : node)) ->
           if only <> [] && not (List.mem dep.alias only) then None
           else
             Option.map
               (fun c ->
                 let changes =
                   match dep.pin with
                   | Some old when Hash.equal old c.identity -> None
                   | Some old ->
                       Some
                         (Printf.sprintf "%s; %s"
                            (changed_components root ~old ~new_:c.context)
                            (interface_report root ~old c.interface))
                   | None -> None
                 in
                 { alias = dep.alias; old_pin = dep.pin; new_pin = c.identity; changes })
               (Hashtbl.find_opt session.composed child.project.dir))
         root_node.deps)

let write_file path contents =
  let temp = Printf.sprintf "%s.%d.tmp" path (Unix.getpid ()) in
  Out_channel.with_open_bin temp (fun oc -> Out_channel.output_string oc contents);
  Unix.rename temp path

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let unchanged_snapshot session =
  let changed =
    Hashtbl.fold
      (fun path digest acc ->
        match read_bytes path with
        | Some bytes when Hash.equal (Hash.of_string bytes) digest -> acc
        | _ -> path :: acc)
      session.snapshot []
  in
  match List.sort String.compare changed with
  | [] -> Ok ()
  | paths ->
      error "E1733" "%s changed while pinning; nothing was written" (String.concat ", " paths)

let write_pins session (root_node : node) plans =
  let root = root_node.project in
  let* () = unchanged_snapshot session in
  match
    (* the records of every dependency in the graph, for future mismatch reports *)
    mkdir_p (contexts_dir root);
    mkdir_p (interfaces_dir root);
    Hashtbl.iter
      (fun _ c ->
        if not (String.equal c.node.project.dir root.dir) then begin
          write_file (record_path (contexts_dir root) c.identity) (Printer.print c.context ^ "\n");
          write_file
            (record_path (interfaces_dir root) c.identity)
            (Interface.serialize c.interface)
        end)
      session.composed
  with
  | exception (Unix.Unix_error _ | Sys_error _) ->
      error "E1735" "cannot write pin records under %s" (jacquard_dir root)
  | () ->
      let* () = unchanged_snapshot session in
      let deps =
        List.map
          (fun (dep : Project_manifest.dep) ->
            match List.find_opt (fun p -> String.equal p.alias dep.alias) plans with
            | Some plan -> { dep with pin = Some plan.new_pin }
            | None -> dep)
          root.manifest.Project_manifest.deps
      in
      Project_manifest.write_canonical root.manifest_file { root.manifest with deps }

(* --- what a bundle needs from a composed graph (design §9) --- *)

let project s = s.project
let is_prelude_object s hash = Hashtbl.mem s.prelude_objects hash
let root_exports s = (root_composed s).exports

let graph_contexts s =
  List.sort
    (fun (a, _, _) (b, _, _) -> Hash.compare a b)
    (Hashtbl.fold (fun _ c acc -> (c.identity, c.context, c.interface) :: acc) s.composed [])

let graph_dirs s = Hashtbl.fold (fun dir _ acc -> dir :: acc) s.composed []

type bundled_entry =
  | Steps of Hash.t list  (** a run entry's generated thunks, in source order *)
  | Roots of (string * string * Hash.t) list  (** a test entry's (kind, display, identity) *)

(* A run entry's top-level expressions become generated terms [entry.NAME.step-1], [entry.NAME.step-2], ...,
   each a checked thunk of its own type; a test entry's owned Warp tests become typed roots. *)
let bundle_entry session (entry : Project_manifest.entry) =
  match entry.ekind with
  | Project_manifest.Test ->
      let* authority = check_entry session entry in
      Ok
        (Roots
           (List.map
              (function
                | Warp.Hermetic (name, h) -> ("test", name, h)
                | Warp.World (name, h) -> ("world-test", name, h)
                | Warp.Relational (name, h) -> ("warp-decl", name, h))
              authority.owned_tests))
  | Project_manifest.Run ->
      let* tops = entry_tops session entry in
      let expressions = ref [] in
      let* () =
        walk_entry session tops ~on_resolved:(fun top _ ->
            let* _ = Check.check_top session.checker top in
            (match top with Kernel.Expr e -> expressions := e :: !expressions | _ -> ());
            Ok ())
      in
      let steps =
        List.mapi
          (fun i (e : Kernel.expr) ->
            let binding =
              {
                Kernel.bname = Printf.sprintf "entry.%s.step-%d" entry.ename (i + 1);
                annot = None;
                value = { Kernel.it = Kernel.Lam ([], e); meta = Meta.empty };
                bmeta = Meta.empty;
              }
            in
            { Kernel.it = Kernel.DefTerm [ binding ]; meta = Meta.empty })
          (List.rev !expressions)
      in
      let rec install acc = function
        | [] -> Ok (Steps (List.rev acc))
        | decl :: rest -> (
            let* _ = Check.check_top session.checker (Kernel.Decl decl) in
            match Store.put_decl session.store decl with
            | Ok { Canon.named = [ (_, member) ]; _ } -> install (member :: acc) rest
            | Ok _ -> install acc rest
            | Error _ as error -> error)
      in
      install [] steps

let library_bindings s =
  List.sort compare
    (Hashtbl.fold
       (fun name entries acc ->
         List.map (fun (e : Resolve.entry) -> ((name, e.kind), e.hash)) entries @ acc)
       (root_composed s).local [])
