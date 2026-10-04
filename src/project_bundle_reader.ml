(* PKG.1: reading and verifying bundles; contracts in project_bundle_reader.mli. *)

let ( let* ) = Result.bind
let version = "bundle-v2"

(* TYPE.1: bundle-v2 records each carried context's namespace; a bundle-v1 bundle is still read
   when it carries no dependency context and no opaque declaration. *)
let legacy_version = "bundle-v1"

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

(* --- reading and verifying (design §9, "Import and run") --- *)

let max_file_bytes = 16 * 1024 * 1024
let max_objects = 100_000
let max_total_bytes = 512 * 1024 * 1024

type entry =
  | Run_entry of { name : string; steps : Hash.t list; grants : string list }
  | Test_entry of { name : string; roots : (string * string * Hash.t) list; grants : string list }

type verified = {
  path : string;
  identity : Hash.t;
  manifest : Project_manifest.t;
  context : Hash.t;
  entries : entry list;
  contexts : (Hash.t * Form.t * Interface.t) list;
  namespaces : (Hash.t * string) list;
  objects : (Kernel.decl * Canon.decl_hashes) list;
}

type t = { bundle : verified; store : Store.t; ctx : Eval.ctx; checker : Check.ctx }

let verify_summary = function
  | "E1720" -> "The bundle's prelude or Core does not match this tool."
  | "E1726" -> "A bundle object's hash does not match."
  | "E1727" -> "A bundle object's member ownership does not match."
  | "E1728" -> "A bundle closure is incomplete."
  | "E1721" -> "A bundle root can reach dynamic evaluation."
  | "E1729" -> "A derived interface or context does not match the bundle record."
  | "E1735" -> "The bundle cannot be read."
  | "E1736" -> "A bundle exports a sealed constructor."
  | "E1738" -> "A bundled term constructs a sealed type outside its owner."
  | "E1707" -> "Two projects' namespaces overlap."
  | "E1714" -> "One namespace appears at two context identities."
  | "E1739" -> "Recorded namespaces conflict with the contexts they name."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown bundle code " ^ code))

let verify_next = function
  | "E1720" -> "Run the bundle with the Core and prelude that built it, or rebuild it."
  | "E1726" | "E1727" | "E1728" | "E1729" | "E1736" | "E1738" | "E1739" | "E1707" | "E1714" ->
      "Rebuild the bundle with jacquard project bundle; do not edit its files."
  | "E1721" -> "Bundles refuse dynamic evaluation in v1; rebuild without eval-code."
  | "E1735" -> "Check the bundle path; a bundle is a directory written by jacquard project bundle."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown bundle code " ^ code))

let refuse code fmt =
  Printf.ksprintf
    (fun cause ->
      Error
        [
          Diag.error ~domain:Diag.Project ~code ~summary:(verify_summary code) ~cause
            ~next_step:(verify_next code) ~contrast:None ();
        ])
    fmt

(* regular files only, never through a symlink, each and all bounded *)
let total = ref 0

let read_bounded path =
  match Unix.lstat path with
  | exception Unix.Unix_error (e, _, _) ->
      refuse "E1735" "cannot read %s: %s" path (Unix.error_message e)
  | { Unix.st_kind = Unix.S_REG; st_size; _ } ->
      if st_size > max_file_bytes then refuse "E1735" "%s exceeds %d bytes" path max_file_bytes
      else if !total + st_size > max_total_bytes then
        refuse "E1735" "the bundle exceeds %d bytes" max_total_bytes
      else begin
        total := !total + st_size;
        match In_channel.with_open_bin path In_channel.input_all with
        | bytes when String.length bytes <= max_file_bytes -> Ok bytes
        | _ -> refuse "E1735" "%s exceeds %d bytes" path max_file_bytes
        | exception Sys_error message -> refuse "E1735" "cannot read %s: %s" path message
      end
  | _ -> refuse "E1735" "%s is not a regular file" path

let parse_one ~file bytes =
  match Reader.parse_string ~file bytes with
  | Ok [ form ] -> Ok form
  | Ok _ -> refuse "E1735" "%s must hold exactly one form" file
  | Error ds -> Error ds

let field name (form : Form.t) =
  List.find_map
    (function Form.F ({ Form.head; _ } as f) when head = name -> Some f | _ -> None)
    form.Form.args

let hash_arg = function Form.Hash h -> Some h | _ -> None

let list_dir dir =
  match Sys.readdir dir with
  | names -> Ok (List.sort String.compare (Array.to_list names))
  | exception Sys_error message -> refuse "E1735" "cannot list %s: %s" dir message

let parse_entries (record : Form.t) =
  let grants (f : Form.t) =
    match field "grants" f with
    | Some g -> List.filter_map (function Form.Sym s -> Some s | _ -> None) g.Form.args
    | None -> []
  in
  match field "entries" record with
  | None -> refuse "E1735" "the bundle record has no (entries ...)"
  | Some entries ->
      Ok
        (List.filter_map
           (function
             | Form.F ({ Form.head = "run"; args = Form.Sym name :: _; _ } as f) ->
                 let steps =
                   match field "steps" f with
                   | Some s -> List.filter_map hash_arg s.Form.args
                   | None -> []
                 in
                 Some (Run_entry { name; steps; grants = grants f })
             | Form.F ({ Form.head = "test"; args = Form.Sym name :: _; _ } as f) ->
                 let roots =
                   List.filter_map
                     (function
                       | Form.F
                           {
                             Form.head = "root";
                             args = [ Form.Sym kind; Form.Text display; Form.Hash h ];
                             _;
                           } ->
                           Some (kind, display, h)
                       | _ -> None)
                     f.Form.args
                 in
                 Some (Test_entry { name; roots; grants = grants f })
             | _ -> None)
           entries.Form.args)

let parse_companions forms =
  List.filter_map
    (function
      | { Form.head = "call-abi-v1"; args = Form.Hash h :: slots; _ } ->
          Some
            ( h,
              List.map
                (function
                  | Form.F { Form.head = "slot"; args = [ Form.Sym "named"; Form.Sym label ]; _ } ->
                      Some label
                  | _ -> None)
                slots )
      | _ -> None)
    forms

(* [snapshot_file dir] is the record file a bundle directory holds, and its format version. *)
let snapshot_file dir =
  let v2 = Filename.concat dir (version ^ ".jqd") in
  if Sys.file_exists v2 then (v2, version)
  else (Filename.concat dir (legacy_version ^ ".jqd"), legacy_version)

let parse_namespaces (record : Form.t) =
  match field "namespaces" record with
  | None -> refuse "E1735" "the bundle record has no (namespaces ...)"
  | Some f ->
      List.fold_left
        (fun acc arg ->
          Result.bind acc (fun pairs ->
              match arg with
              | Form.F { Form.head = "namespace"; args = [ Form.Hash id; Form.Sym ns ]; _ } ->
                  if List.mem_assoc id pairs then
                    refuse "E1739" "context %s records two namespaces" (Hash.to_hex id)
                  else Ok ((id, ns) :: pairs)
              | _ -> refuse "E1735" "malformed (namespaces ...) entry"))
        (Ok []) f.Form.args
      |> Result.map List.rev

(* [recorded_namespaces dir] reads a bundle's recorded namespaces, unverified, for graph-wide
   refusals (E1707) before the bundle is imported; a bundle-v1 bundle records none. *)
let recorded_namespaces dir =
  let file, v = snapshot_file dir in
  if v <> version then Ok []
  else
    let* bytes = read_bounded file in
    let* record = parse_one ~file bytes in
    Result.map (List.map snd) (parse_namespaces record)

let has_prefix ns sep name =
  let p = ns ^ sep in
  String.length name > String.length p && String.starts_with ~prefix:p name

(* E1739: kind-aware, as the source namespace rules are. A constructor is judged by its owning
   type's name; an operation carries the `ns.` prefix and so does its owning effect's name (`ns-`);
   a term named after a type, `ns-type.label`, lies inside the namespace. *)
let namespace_refusal store ns (e : Interface.export) =
  let owner_name () =
    match Store.locate store e.owner with
    | Ok { Store.decl = { Kernel.it = Kernel.DefType { tname; _ }; _ }; _ } -> Some tname
    | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ename; _ }; _ }; _ } -> Some ename
    | _ -> None
  in
  let ok =
    match e.kind with
    | Resolve.KType | Resolve.KEffect -> has_prefix ns "-" e.name
    | Resolve.KTerm -> (
        has_prefix ns "." e.name
        ||
        (* a term named after a type, `ns-type.label` (an accessor, a setter, or any term the source
           rule admits), lies inside the namespace too; the type itself need not be carried *)
        match String.index_opt e.name '.' with
        | Some i -> has_prefix ns "-" (String.sub e.name 0 i)
        | None -> false)
    | Resolve.KOp -> (
        has_prefix ns "." e.name
        && match owner_name () with Some ename -> has_prefix ns "-" ename | None -> false)
    | Resolve.KCon -> ( match owner_name () with Some t -> has_prefix ns "-" t | None -> false)
  in
  if ok then None else Some e.name

let verify_unguarded ?prelude ~store ~checker path =
  total := 0;
  let file name = Filename.concat path name in
  let* () =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } -> Ok ()
    | _ -> refuse "E1735" "%s is not a bundle directory" path
    | exception Unix.Unix_error (e, _, _) ->
        refuse "E1735" "cannot read %s: %s" path (Unix.error_message e)
  in
  let* () =
    List.fold_left
      (fun acc sub ->
        Result.bind acc (fun () ->
            match Unix.lstat (file sub) with
            | { Unix.st_kind = Unix.S_DIR; _ } -> Ok ()
            | _ -> refuse "E1735" "%s is not a directory" (file sub)
            | exception Unix.Unix_error (e, _, _) ->
                refuse "E1735" "cannot read %s: %s" (file sub) (Unix.error_message e)))
      (Ok ())
      [ "objects"; "contexts"; "interfaces" ]
  in
  let record_file, format = snapshot_file path in
  let* record_bytes = read_bounded record_file in
  let* record = parse_one ~file:record_file record_bytes in
  let* () =
    if record.Form.head = format then Ok ()
    else refuse "E1735" "%s has head %s, not %s" record_file record.Form.head format
  in
  let* recorded_namespaces = if format = version then parse_namespaces record else Ok [] in
  let identity = Hash.of_string (Printer.print record) in
  let* manifest_bytes = read_bounded (file "project.jqd") in
  let* manifest = Project_manifest.parse ~file:(file "project.jqd") manifest_bytes in
  let* entries = parse_entries record in
  (* 7 (checked first, since nothing else can be judged against another prelude) *)
  let prelude_form =
    Form.form "prelude"
      (List.map
         (fun (f, d) -> Form.F (Form.form "file" [ Form.Text f; Form.Text d ]))
         (List.sort compare (Option.value ~default:[] (Store.prelude_manifest store))))
  in
  let* () =
    match (field "prelude" record, field "core" record) with
    | Some p, _ when not (Form.equal_ignoring_meta p prelude_form) ->
        refuse "E1720" "%s was built against another prelude" path
    | _, Some { Form.args = [ Form.Text core ]; _ } when not (String.equal core Version.version) ->
        refuse "E1720" "%s was built by Core %s; this is Core %s" path core Version.version
    | None, _ | _, None -> refuse "E1735" "%s lacks (prelude ...) or (core ...)" record_file
    | Some _, Some _ -> Ok ()
  in
  (* 1-2: budgets and object hashes *)
  let* names = list_dir (file "objects") in
  let* () =
    if List.length names > max_objects then
      refuse "E1735" "the bundle holds more than %d objects" max_objects
    else Ok ()
  in
  let rec objects acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest -> (
        let path = Filename.concat (file "objects") name in
        let* bytes = read_bounded path in
        match Store.load_object ~file:path bytes with
        | Error _ -> refuse "E1726" "object %s does not parse as a declaration" name
        | Ok (decl, hashes) ->
            if String.equal (Hash.to_hex hashes.Canon.decl_hash ^ ".jqd") name then
              objects ((decl, hashes) :: acc) rest
            else refuse "E1726" "object %s hashes to %s" name (Hash.to_hex hashes.Canon.decl_hash))
  in
  let* objects = objects [] names in
  (* what the store held before this bundle: the prelude, unless the caller says otherwise *)
  let is_prelude =
    match prelude with
    | Some is_prelude -> is_prelude
    | None ->
        let before = Hashtbl.create 1024 in
        List.iter (fun (h, _) -> Hashtbl.replace before h ()) store.Store.index;
        Hashtbl.mem before
  in
  let* () =
    List.fold_left
      (fun acc (decl, _) ->
        Result.bind acc (fun () -> Result.map ignore (Store.put_decl store decl)))
      (Ok ()) objects
  in
  (* 3: closure completeness from every object and every root. A bundle is self-contained: a
     reference resolves to its own objects or to the prelude, never to objects an earlier import
     left in the session store (TYPE.1). *)
  let own = Hashtbl.create 64 in
  List.iter
    (fun (_, (h : Canon.decl_hashes)) ->
      List.iter (fun x -> Hashtbl.replace own x ()) (h.decl_hash :: List.map snd h.named))
    objects;
  let present hash =
    Hashtbl.mem own hash || (Result.is_ok (Store.locate store hash) && is_prelude hash)
  in
  let roots =
    List.concat_map
      (function
        | Run_entry { steps; _ } -> steps
        | Test_entry { roots; _ } -> List.map (fun (_, _, h) -> h) roots)
      entries
  in
  let* () =
    match
      List.find_opt
        (fun h -> not (present h))
        (roots @ List.concat_map (fun (decl, _) -> Store.decl_refs decl) objects)
    with
    | Some missing ->
        refuse "E1728" "%s is referenced but not in the bundle or the prelude" (Hash.to_hex missing)
    | None -> Ok ()
  in
  (* 4: type-check the whole closure *)
  let* () =
    List.fold_left
      (fun acc (decl, _) ->
        Result.bind acc (fun () -> Result.map ignore (Check.check_top checker (Kernel.Decl decl))))
      (Ok ()) objects
  in
  (* the companions of the closure *)
  let* companion_bytes = read_bounded (file "companions.jqd") in
  let* companion_forms = Reader.parse_string ~file:(file "companions.jqd") companion_bytes in
  let* () =
    Result.map_error (fun _ -> []) (Store.add_call_abis store (parse_companions companion_forms))
    |> function
    | Ok () -> Ok ()
    | Error _ -> refuse "E1729" "companions.jqd conflicts with the bundle's objects"
  in
  (* 5-6: interfaces and contexts, bottom-up by their recorded dependency edges *)
  let* context_names = list_dir (file "contexts") in
  let rec contexts verified = function
    | [] -> Ok verified
    | pending ->
        let ready, waiting =
          List.partition
            (fun (_, deps, _, _) -> List.for_all (fun (_, d) -> List.mem d verified) deps)
            pending
        in
        if ready = [] then refuse "E1729" "the bundle's context records do not form a graph"
        else
          let* () =
            List.fold_left
              (fun acc (id, deps, record_form, (recorded : Interface.t)) ->
                Result.bind acc (fun () ->
                    let exports =
                      List.map
                        (fun (e : Interface.export) -> ((e.name, e.kind), e.hash))
                        recorded.exports
                    in
                    (* each recorded (name, kind) names one identity *)
                    let* () =
                      match
                        List.find_opt
                          (fun ((key, _) as binding) ->
                            List.exists
                              (fun ((other, _) as b) -> other = key && b != binding)
                              exports)
                          exports
                      with
                      | Some ((name, _), _) ->
                          refuse "E1729" "interface %s records `%s` twice" (Hash.to_hex id) name
                      | None -> Ok ()
                    in
                    let* () =
                      match
                        List.find_opt
                          (fun (e : Interface.export) ->
                            match Store.locate store e.hash with
                            | Ok { Store.decl_hash; _ } -> not (Hash.equal decl_hash e.owner)
                            | Error _ -> true)
                          recorded.exports
                      with
                      | Some e ->
                          refuse "E1727" "export %s is not owned by %s" e.name (Hash.to_hex e.owner)
                      | None -> Ok ()
                    in
                    let* () =
                      match
                        List.find_opt
                          (fun (e : Interface.export) ->
                            e.kind = Resolve.KCon
                            && Option.is_some (Store.sealed_constructor store e.hash))
                          recorded.exports
                      with
                      | Some e ->
                          refuse "E1736" "context %s exports (con %s), a sealed constructor"
                            (Hash.to_hex id) e.name
                      | None -> Ok ()
                    in
                    (* each recorded export names a declaration of its kind under its own name *)
                    let* () =
                      match
                        List.find_opt
                          (fun (e : Interface.export) ->
                            not (Interface.kind_matches store e.name e.kind e.hash))
                          recorded.exports
                      with
                      | Some e ->
                          refuse "E1729" "export %s does not name a declaration of its kind" e.name
                      | None -> Ok ()
                    in
                    let* derived =
                      Result.map_error
                        (fun _ -> [])
                        (Interface.of_side ~recorded:true checker
                           { Diff.store; bindings = exports })
                      |> function
                      | Ok d -> Ok d
                      | Error _ -> refuse "E1729" "interface %s cannot be derived" (Hash.to_hex id)
                    in
                    let* () =
                      if Hash.equal (Interface.identity derived) (Interface.identity recorded) then
                        Ok ()
                      else
                        refuse "E1729" "interface %s differs from its derivation" (Hash.to_hex id)
                    in
                    let recomputed = Project_context.form store ~interface:derived ~exports ~deps in
                    if
                      Hash.equal (Hash.of_string (Printer.print recomputed)) id
                      && Form.equal_ignoring_meta recomputed record_form
                    then Ok ()
                    else
                      refuse "E1729" "context %s does not match its recomputation" (Hash.to_hex id)))
              (Ok ()) ready
          in
          contexts (List.map (fun (id, _, _, _) -> id) ready @ verified) waiting
  in
  let rec read_contexts acc = function
    | [] -> Ok acc
    | name :: rest ->
        let* id =
          match
            if Filename.check_suffix name ".jqd" then Hash.of_hex (Filename.chop_suffix name ".jqd")
            else None
          with
          | Some h -> Ok h
          | None -> refuse "E1735" "unexpected context file %s" name
        in
        let* bytes = read_bounded (Filename.concat (file "contexts") name) in
        let* form = parse_one ~file:name bytes in
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
        let* ibytes = read_bounded (Filename.concat (file "interfaces") name) in
        let* interface = Interface.parse ~file:name ibytes in
        read_contexts ((id, deps, form, interface) :: acc) rest
  in
  let* pending = read_contexts [] context_names in
  (* every recorded export is itself one of the bundle's objects or the prelude's, so no export, and
     nothing it reaches, is borrowed from an earlier import (TYPE.1) *)
  let* () =
    match
      List.find_map
        (fun (_, _, _, (i : Interface.t)) ->
          List.find_opt
            (fun (e : Interface.export) -> not (present e.hash && present e.owner))
            i.exports)
        pending
    with
    | Some e ->
        refuse "E1728" "export %s (%s) is not in the bundle or the prelude" e.name
          (Hash.to_hex e.hash)
    | None -> Ok ()
  in
  let* verified = contexts [] pending in
  (* every carried context is a dependency, direct or transitive, of the bundle's own: an orphan's
     exports would otherwise be admitted as roots (E1729) *)
  let* () =
    match
      Option.bind (field "context" record) (fun f ->
          match f.Form.args with [ Form.Hash h ] -> Some h | _ -> None)
    with
    | None -> Ok ()
    | Some own -> (
        let reached = Hashtbl.create 8 in
        let rec visit id =
          if not (Hashtbl.mem reached id) then begin
            Hashtbl.replace reached id ();
            match List.find_opt (fun (id', _, _, _) -> Hash.equal id id') pending with
            | Some (_, deps, _, _) -> List.iter (fun (_, d) -> visit d) deps
            | None -> ()
          end
        in
        visit own;
        match List.find_opt (fun id -> not (Hashtbl.mem reached id)) verified with
        | Some id ->
            refuse "E1729" "context %s is not a dependency of the bundle's own context"
              (Hash.to_hex id)
        | None -> Ok ())
  in
  let* context =
    match
      Option.bind (field "context" record) (fun f ->
          match f.Form.args with [ Form.Hash h ] -> Some h | _ -> None)
    with
    | Some c when List.mem c verified -> Ok c
    | _ -> refuse "E1729" "the bundle's own context is not among its verified contexts"
  in
  (* TYPE.1: every carried dependency context records its namespace (E1739); the bundle's own root
     records its manifest's namespace, or none. A bundle-v1 bundle has no record, so it is read only
     when it carries no dependency context and no opaque declaration. *)
  let* namespaces =
    if format = version then
      let own_ns = manifest.Project_manifest.namespace in
      let* () =
        match List.find_opt (fun (id, _) -> not (List.mem id verified)) recorded_namespaces with
        | Some (id, _) ->
            refuse "E1739" "a namespace is recorded for unknown context %s" (Hash.to_hex id)
        | None -> Ok ()
      in
      let* () =
        match
          List.find_opt
            (fun id -> (not (Hash.equal id context)) && not (List.mem_assoc id recorded_namespaces))
            verified
        with
        | Some id -> refuse "E1739" "carried context %s records no namespace" (Hash.to_hex id)
        | None -> Ok ()
      in
      let* () =
        if List.assoc_opt context recorded_namespaces = own_ns then Ok ()
        else refuse "E1739" "the root context's recorded namespace differs from project.jqd"
      in
      Ok recorded_namespaces
    else
      let* () =
        if List.length verified = 1 then Ok ()
        else
          refuse "E1735"
            "a %s bundle carries dependency contexts but records no namespaces; rebuild it as %s"
            legacy_version version
      in
      let* () =
        if
          List.exists
            (fun (decl, _) ->
              match decl.Kernel.it with Kernel.DefType { opaque; _ } -> opaque | _ -> false)
            objects
        then refuse "E1735" "a %s bundle cannot carry an opaque declaration" legacy_version
        else Ok ()
      in
      Ok
        (match manifest.Project_manifest.namespace with Some ns -> [ (context, ns) ] | None -> [])
  in
  (* within one bundle: no namespace at two identities (E1714), none a boundary-prefix of another
     (E1707) *)
  let* () =
    match
      List.find_opt
        (fun (id, ns) ->
          List.exists (fun (id', ns') -> ns = ns' && not (Hash.equal id id')) namespaces)
        namespaces
    with
    | Some (_, ns) -> refuse "E1714" "namespace `%s` is recorded at two context identities" ns
    | None -> Ok ()
  in
  let* () =
    let names = List.sort_uniq compare (List.map snd namespaces) in
    match
      List.find_map
        (fun a ->
          List.find_map
            (fun b ->
              if a <> b && (has_prefix a "-" b || has_prefix a "." b) then Some (a, b) else None)
            names)
        names
    with
    | Some (a, b) ->
        refuse "E1707" "namespace `%s` is a boundary-prefix of namespace `%s` in one bundle" a b
    | None -> Ok ()
  in
  let* () =
    List.fold_left
      (fun acc (id, _, _, (i : Interface.t)) ->
        Result.bind acc (fun () ->
            match List.assoc_opt id namespaces with
            | None -> Ok ()
            | Some ns -> (
                match List.find_map (namespace_refusal store ns) i.exports with
                | Some name ->
                    refuse "E1739" "context %s exports `%s`, which is outside its namespace `%s`"
                      (Hash.to_hex id) name ns
                | None -> Ok ())))
      (Ok ())
      (List.filter (fun (id, _, _, _) -> List.mem id verified) pending)
  in
  let* () =
    match field "manifest" record with
    | Some { Form.args = [ Form.Hash h ]; _ }
      when Hash.equal h (Project_manifest.semantic_digest manifest) ->
        Ok ()
    | _ -> refuse "E1729" "project.jqd does not match the bundle's manifest digest"
  in
  (* every run step is a generated zero-argument thunk, every test root a term member *)
  let member_value hash =
    match Store.locate store hash with
    | Ok { Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ }; role = Store.Member i; _ } ->
        Option.map (fun (b : Kernel.binding) -> b.value) (List.nth_opt bindings i)
    | _ -> None
  in
  let* () =
    List.fold_left
      (fun acc e ->
        Result.bind acc (fun () ->
            match e with
            | Run_entry { name; steps; _ } -> (
                match
                  List.find_opt
                    (fun h ->
                      match member_value h with
                      | Some { Kernel.it = Kernel.Lam ([], _); _ } -> false
                      | _ -> true)
                    steps
                with
                | Some h ->
                    refuse "E1728" "run entry `%s` step %s is not a thunk" name (Hash.to_hex h)
                | None -> Ok ())
            | Test_entry { name; roots; _ } -> (
                match List.find_opt (fun (_, _, h) -> member_value h = None) roots with
                | Some (_, _, h) ->
                    refuse "E1728" "test entry `%s` root %s is not a term" name (Hash.to_hex h)
                | None -> Ok ())))
      (Ok ()) entries
  in
  (* the objects are exactly the closure of the roots: steps, test roots, and every verified
     context's exports *)
  let exports =
    List.concat_map
      (fun (id, _, _, (i : Interface.t)) ->
        if List.mem id verified then List.map (fun (e : Interface.export) -> e.hash) i.exports
        else [])
      pending
  in
  let closure = reachable store (roots @ exports) in
  let* () =
    match
      List.find_opt
        (fun (_, (h : Canon.decl_hashes)) -> not (Hashtbl.mem closure h.decl_hash))
        objects
    with
    | Some (_, h) ->
        refuse "E1728" "object %s is not reachable from any root; a bundle carries its closure only"
          (Hash.to_hex h.Canon.decl_hash)
    | None -> Ok ()
  in
  let* () =
    let evals = eval_identities store in
    match
      Hashtbl.fold
        (fun decl_hash decl acc ->
          if List.exists (fun r -> List.exists (Hash.equal r) evals) (Store.decl_refs decl) then
            Some decl_hash
          else acc)
        closure None
    with
    | Some h ->
        refuse "E1721" "declaration %s, reachable from a bundle root, refers to eval-code or Eval"
          (Hash.to_hex h)
    | None -> Ok ()
  in
  (* TYPE.1 (design §2.3): each context's region is the closure of its own roots, its exports
     and, for the bundle's own context, its entry roots, stopping at the exact identities other
     contexts export and at the prelude. A term in a region that constructs or matches a sealed
     constructor must belong to the type's owning context (E1738); a type or effect a region reaches
     through a live reference must carry that context's namespace (E1739). *)
  let* () =
    let live_contexts = List.filter (fun (id, _, _, _) -> List.mem id verified) pending in
    let exports_of id =
      List.concat_map
        (fun (id', _, _, (i : Interface.t)) ->
          if Hash.equal id id' then List.map (fun (e : Interface.export) -> e.hash) i.exports
          else [])
        live_contexts
    in
    let exported_by = Hashtbl.create 64 in
    List.iter
      (fun (id, _, _, _) -> List.iter (fun h -> Hashtbl.add exported_by h id) (exports_of id))
      live_contexts;
    (* an unprefixed type is the root's: its entry units may declare one, and a namespaced library
       cannot (E1706) *)
    let owner_of_type tname =
      match List.find_opt (fun (_, ns) -> has_prefix ns "-" tname) namespaces with
      | Some (id, _) -> id
      | None -> context
    in
    let region ~entries id =
      let own_roots = exports_of id @ if entries && Hash.equal id context then roots else [] in
      let own = Hashtbl.create 64 in
      List.iter (fun h -> Hashtbl.replace own h ()) own_roots;
      let live = Hashtbl.create 64 and typed = Hashtbl.create 64 in
      let stops h =
        (not (Hashtbl.mem own h))
        && (is_prelude h
           || List.exists (fun other -> not (Hash.equal other id)) (Hashtbl.find_all exported_by h)
           )
      in
      let rec go ~is_live h =
        if not (stops h) then
          match Store.locate store h with
          | Error _ -> ()
          | Ok { Store.decl; decl_hash; _ } ->
              let seen = if is_live then live else typed in
              if not (Hashtbl.mem seen decl_hash || Hashtbl.mem live decl_hash) then begin
                Hashtbl.replace seen decl_hash decl;
                let live_refs, typed_refs = Store.split_refs decl in
                List.iter (go ~is_live) live_refs;
                List.iter (go ~is_live:false) typed_refs
              end
      in
      List.iter (go ~is_live:true) own_roots;
      (live, typed)
    in
    let regions = List.map (fun (id, _, _, _) -> (id, region ~entries:true id)) live_contexts in
    (* E1739 judges what a context's exports reach: its entries are author-trusted and may declare
       types outside the namespace, which nothing exported can reach (E1732) *)
    let export_regions =
      List.map (fun (id, _, _, _) -> (id, region ~entries:false id)) live_contexts
    in
    let constructing decl =
      List.filter_map
        (fun r -> Option.map (fun s -> (r, s)) (Store.sealed_constructor store r))
        (fst (Store.split_refs decl))
    in
    let* () =
      List.fold_left
        (fun acc (id, (live, _)) ->
          Result.bind acc (fun () ->
              Hashtbl.fold
                (fun decl_hash decl acc ->
                  Result.bind acc (fun () ->
                      match
                        List.find_opt
                          (fun (_, (tname, _, _)) -> not (Hash.equal (owner_of_type tname) id))
                          (constructing decl)
                      with
                      | Some (_, (tname, con_name, _)) ->
                          refuse "E1738"
                            "declaration %s in the region of context %s uses constructor `%s` of \
                             the opaque type `%s`, which another context owns"
                            (Hash.to_hex decl_hash) (Hash.to_hex id) con_name tname
                      | None -> Ok ()))
                live (Ok ())))
        (Ok ()) regions
    in
    let* () =
      List.fold_left
        (fun acc (id, (live, _)) ->
          Result.bind acc (fun () ->
              match List.assoc_opt id namespaces with
              | None -> Ok ()
              | Some ns ->
                  Hashtbl.fold
                    (fun _ (decl : Kernel.decl) acc ->
                      Result.bind acc (fun () ->
                          match decl.Kernel.it with
                          | Kernel.DefType { tname = name; _ }
                          | Kernel.DefEffect { ename = name; _ }
                            when not (has_prefix ns "-" name) ->
                              refuse "E1739"
                                "context %s reaches `%s`, which is outside its namespace `%s`"
                                (Hash.to_hex id) name ns
                          | _ -> Ok ()))
                    live (Ok ())))
        (Ok ()) export_regions
    in
    (* the whole region, entries included and a root without a namespace too, reaches no type or
       effect inside another context's namespace through a live reference: the bundle form of
       E1737, which keeps a forged entry from using a dependency's unexported declarations *)
    let* () =
      List.fold_left
        (fun acc (id, (live, _)) ->
          Result.bind acc (fun () ->
              Hashtbl.fold
                (fun _ (decl : Kernel.decl) acc ->
                  Result.bind acc (fun () ->
                      let name =
                        match decl.Kernel.it with
                        | Kernel.DefType { tname; _ } -> Some tname
                        | Kernel.DefEffect { ename; _ } -> Some ename
                        | Kernel.DefTerm _ -> None
                      in
                      match name with
                      | None -> Ok ()
                      | Some name -> (
                          match
                            List.find_opt
                              (fun (other, ns) ->
                                (not (Hash.equal other id)) && has_prefix ns "-" name)
                              namespaces
                          with
                          | Some (_, ns) ->
                              refuse "E1739"
                                "context %s reaches `%s`, which is inside namespace `%s` of \
                                 another context"
                                (Hash.to_hex id) name ns
                          | None -> Ok ())))
                live (Ok ())))
        (Ok ()) regions
    in
    (* every constructing term lies in some region (defence in depth behind E1728) *)
    match
      List.find_opt
        (fun (decl, (h : Canon.decl_hashes)) ->
          constructing decl <> []
          && not (List.exists (fun (_, (live, _)) -> Hashtbl.mem live h.decl_hash) regions))
        objects
    with
    | Some (_, h) ->
        refuse "E1738" "declaration %s constructs a sealed type but lies in no context's region"
          (Hash.to_hex h.Canon.decl_hash)
    | None -> Ok ()
  in
  let count name =
    match field name record with Some { Form.args = [ Form.Int n ]; _ } -> Some n | _ -> None
  in
  let* () =
    if
      count "objects" = Some (List.length objects)
      && count "companions" = Some (List.length (parse_companions companion_forms))
    then Ok ()
    else refuse "E1729" "the record's object or companion count does not match the bundle"
  in
  let contexts =
    List.map
      (fun (id, _, form, interface) -> (id, form, interface))
      (List.filter (fun (id, _, _, _) -> List.mem id verified) pending)
  in
  Ok { path; identity; manifest; context; entries; contexts; namespaces; objects }

(* a refused bundle leaves none of its objects behind (TYPE.1) *)
let verify ?prelude ~store ~checker path =
  Store.transaction store (fun () -> verify_unguarded ?prelude ~store ~checker path)

(* [load] verifies against a fresh session, whose store holds exactly the prelude: that is what
   [verify]'s default prelude membership assumes *)
let load ~prelude_dir ~root path =
  if Sys.file_exists root && Sys.is_directory root && Sys.readdir root <> [||] then
    invalid_arg "Project_bundle_reader.load: root must be absent or empty";
  let* store, ctx = Frontend.open_session ~prelude_dir ~root in
  let* checker = Frontend.make_checker store in
  let* bundle = verify ~store ~checker path in
  Ok { bundle; store; ctx; checker }
