(* PKG.1: reading and verifying bundles; contracts in project_bundle_reader.mli. *)

let ( let* ) = Result.bind
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
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown bundle code " ^ code))

let verify_next = function
  | "E1720" -> "Run the bundle with the Core and prelude that built it, or rebuild it."
  | "E1726" | "E1727" | "E1728" | "E1729" ->
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
  | None -> refuse "E1735" "bundle-v1.jqd has no (entries ...)"
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

let verify ~store ~checker path =
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
  let* record_bytes = read_bounded (file "bundle-v1.jqd") in
  let* record = parse_one ~file:(file "bundle-v1.jqd") record_bytes in
  let* () =
    if record.Form.head = version then Ok ()
    else refuse "E1735" "bundle-v1.jqd has head %s, not %s" record.Form.head version
  in
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
    | None, _ | _, None -> refuse "E1735" "bundle-v1.jqd lacks (prelude ...) or (core ...)"
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
  let* () =
    List.fold_left
      (fun acc (decl, _) ->
        Result.bind acc (fun () -> Result.map ignore (Store.put_decl store decl)))
      (Ok ()) objects
  in
  (* 3: closure completeness from every object and every root *)
  let present hash = Result.is_ok (Store.locate store hash) in
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
                    let* derived =
                      Result.map_error
                        (fun _ -> [])
                        (Interface.of_side checker { Diff.store; bindings = exports })
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
  let* verified = contexts [] pending in
  let* context =
    match
      Option.bind (field "context" record) (fun f ->
          match f.Form.args with [ Form.Hash h ] -> Some h | _ -> None)
    with
    | Some c when List.mem c verified -> Ok c
    | _ -> refuse "E1729" "the bundle's own context is not among its verified contexts"
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
  (* the objects are exactly the closure of the roots: steps, test roots, and the exports *)
  let own_exports =
    List.concat_map
      (fun (id, _, _, (i : Interface.t)) ->
        if Hash.equal id context then List.map (fun (e : Interface.export) -> e.hash) i.exports
        else [])
      pending
  in
  let closure = reachable store (roots @ own_exports) in
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
  Ok { path; identity; manifest; context; entries; contexts; objects }

let load ~prelude_dir ~root path =
  let* store, ctx = Frontend.open_session ~prelude_dir ~root in
  let* checker = Frontend.make_checker store in
  let* bundle = verify ~store ~checker path in
  Ok { bundle; store; ctx; checker }
