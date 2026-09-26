(* PKG.1: the project frontend; contracts in project_frontend.mli. *)

let ( let* ) = Result.bind

type project = { dir : string; manifest_file : string; manifest : Project_manifest.t }

let max_unit_bytes = 4 * 1024 * 1024

let summary = function
  | "E1703" -> "A project input exceeds a size budget."
  | "E1706" -> "A library name does not carry the project's namespace."
  | "E1715" -> "A declarations-only unit contains a top-level expression."
  | "E1716" -> "A name is defined in two units."
  | "E1718" -> "The project declares no entry of that name and kind."
  | "E1722" -> "A unit path leaves the project directory."
  | "E1723" -> "A unit is missing or is not a regular file."
  | "E1724" -> "Two units' paths differ only by letter case."
  | "E1730" | "W1700" -> "An entry's declared grants differ from its checked authority."
  | "E1731" -> "Two visible constructors share a name."
  | "E1732" -> "The library refers to a name that only an entry defines."
  | "E1734" -> "Two unit entries name the same file."
  | "E1735" -> "No project manifest was found or it could not be read."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown project code " ^ code))

let next_step = function
  | "E1703" -> "Split the unit into smaller units."
  | "E1706" ->
      "Spell the name with the namespace prefix: `NS.name` for terms and operations, `NS-name` for \
       types and effects."
  | "E1715" -> "Move the expression into a run entry's unit."
  | "E1716" -> "Keep one definition, or rename one of them."
  | "E1718" -> "Use an entry the manifest declares, or add it to (entries ...)."
  | "E1722" -> "Keep every unit inside the project directory."
  | "E1723" -> "Point the manifest at an existing regular source file."
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

(* E1731: a constructor name visible with two owners. [visible] is the store as it stands before
   the library is installed (the prelude). *)
let constructor_collisions ?(library_types = []) store tops =
  let owner_of hash =
    match Store.locate store hash with
    | Ok { Store.decl = { Kernel.it = Kernel.DefType { tname; _ }; _ }; _ } -> tname
    | _ -> Hash.to_hex hash
  in
  let local = Hashtbl.create 32 in
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
                    match Store.lookup_kind store c.con_name Resolve.KCon with
                    | Some { Resolve.hash; _ } ->
                        let owner = owner_of hash in
                        let whose =
                          if List.mem owner library_types then "the library" else "the prelude"
                        in
                        if String.equal owner tname then None
                        else Some (Printf.sprintf "type `%s` of %s" owner whose)
                    | None -> None)
              in
              Option.map
                (fun other ->
                  diag
                    ?span:(match Meta.span c.kmeta with Some s -> Some s | None -> Meta.span meta)
                    "E1731"
                    (Printf.sprintf "constructor `%s` of type `%s` is also a constructor of %s"
                       c.con_name tname other))
                clash)
            cons
      | _ -> [])
    tops

(* --- sessions --- *)

type session = {
  project : project;
  store : Store.t;
  ctx : Eval.ctx;
  checker : Check.ctx;
  library_declarations : int;
  library_bindings : ((string * Resolve.nkind) * string option) list;
      (** what the library binds, with the unit that binds it *)
}

let store s = s.store
let eval_ctx s = s.ctx
let checker s = s.checker
let library_declarations s = s.library_declarations

(* the names every entry binds, for E1732; entries that fail to compose contribute nothing *)
let entry_defined_names project ~names =
  List.concat_map
    (fun (entry : Project_manifest.entry) ->
      match Result.bind (read_units project entry.eunits) (compose ~names ~on_warning:ignore) with
      | Ok tops ->
          List.concat_map (fun top -> List.map (fun b -> (b.name, entry.ename)) (binders top)) tops
      | Error _ -> [])
    project.manifest.entries

let open_library ?(on_lint = ignore) ?(on_warning = ignore) ~prelude_dir ~root project =
  if Sys.file_exists root && ((not (Sys.is_directory root)) || Array.length (Sys.readdir root) > 0)
  then invalid_arg ("Project_frontend.open_library: root is not a fresh directory: " ^ root);
  let* store, ctx = Frontend.open_session ~prelude_dir ~root in
  let* checker = Frontend.make_checker store in
  let names = Store.names_view store in
  let* units = read_units project project.manifest.Project_manifest.units in
  let* tops = compose ~names ~on_warning:on_lint units in
  let rules =
    expressions_refused "a library unit" tops
    @ cross_unit_duplicates tops
    @ (match project.manifest.namespace with Some ns -> namespace_violations ns tops | None -> [])
    @ constructor_collisions store tops
  in
  let* () = if rules = [] then Ok () else Error rules in
  let installed = ref 0 in
  let walked =
    Frontend.walk_tops store tops
      ~on_resolved:(fun top warnings ->
        List.iter on_warning warnings;
        let* { Check.warnings; _ } = Check.check_top checker top in
        List.iter on_warning warnings;
        Ok ())
      ~on_installed:(fun _ _ ->
        incr installed;
        Ok ())
  in
  let library_bindings =
    List.concat_map (fun top -> List.map (fun b -> ((b.name, b.kind), b.file)) (binders top)) tops
  in
  match walked with
  | Ok () ->
      Ok { project; store; ctx; checker; library_declarations = !installed; library_bindings }
  | Error ds ->
      (* an unresolved name that only an entry defines is the library/entry boundary (E1732) *)
      let entry_names = lazy (entry_defined_names project ~names) in
      Error
        (List.map
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
           ds)

(* An entry adds names; it never replaces the library's. A name the library binds is E1716 and a
   constructor that collides with a visible one (the library's or the prelude's) is E1731, as they
   would be inside the library. *)
let entry_rules session tops =
  let redefined =
    List.concat_map
      (fun top ->
        List.filter_map
          (fun b ->
            if b.kind = Resolve.KCon then None
            else
              match List.assoc_opt (b.name, b.kind) session.library_bindings with
              | Some library_file ->
                  Some
                    (diag ?span:(Meta.span b.meta) "E1716"
                       (Printf.sprintf "%s `%s` is defined in %s and again in entry unit %s"
                          (kind_word b.kind) b.name (where library_file) (where b.file)))
              | None -> None)
          (binders top))
      tops
  in
  let library_types =
    List.filter_map
      (fun ((name, kind), _) -> if kind = Resolve.KType then Some name else None)
      session.library_bindings
  in
  cross_unit_duplicates tops @ redefined @ constructor_collisions ~library_types session.store tops

let entry_tops ?(on_lint = ignore) session (entry : Project_manifest.entry) =
  let* units = read_units session.project entry.eunits in
  let* tops = compose ~names:(Store.names_view session.store) ~on_warning:on_lint units in
  match entry_rules session tops with [] -> Ok tops | ds -> Error ds

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
    Frontend.walk_tops session.store tops
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
