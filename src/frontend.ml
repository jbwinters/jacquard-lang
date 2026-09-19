(* RF.1: the shared frontend services; contracts in frontend.mli. *)

let ( let* ) = Result.bind

type syntax = Auto | Bootstrap | Surface
type parsed_top = Bootstrap_form of Form.t | Surface_top of Kernel.top

let syntax_for_file syntax file =
  match syntax with
  | Auto when Filename.check_suffix file ".jac" -> Surface
  | Auto | Bootstrap -> Bootstrap
  | Surface -> Surface

let parse_tops ~syntax ~names ~file source =
  match syntax_for_file syntax file with
  | Auto -> assert false
  | Bootstrap ->
      Result.map
        (fun forms -> (List.map (fun form -> Bootstrap_form form) forms, []))
        (Reader.parse_string ~file source)
  | Surface ->
      let recovered = Surface_parse.recover_string ~file source in
      let* parsed = Surface_parse.strict recovered in
      let warnings = Surface_check.lint ~names parsed in
      Result.map
        (fun tops -> (List.map (fun top -> Surface_top top) tops, warnings))
        (Surface_lower.lower_tops parsed)

let validate_parsed_top = function
  | Bootstrap_form form -> Kernel.of_form form
  | Surface_top top -> Ok top

(* --- sessions and checkers --- *)

let open_session ~prelude_dir ~root =
  let* store = Store.open_store root in
  let* _loaded = Prelude.load ~dir:prelude_dir store in
  let ctx = Eval.make_ctx store in
  let* () = Prelude.wire_builtins ctx in
  Ok (store, ctx)

let make_checker ?(require_builtins = false) store =
  let* checker = Check.make_ctx store in
  match Prelude.builtin_signatures store with
  | Ok signatures ->
      Check.register_builtin_signatures checker signatures;
      Ok checker
  | Error diagnostics -> if require_builtins then Error diagnostics else Ok checker

(* --- the shared per-top pipeline --- *)

type installation = Install | Install_best_effort

let no_hook _ = Ok ()

(* One loop for every command: validate, pre-resolution hook, resolve against the store's current
   names, post-resolution hook, then install a declaration so later tops see it. *)
let walk_items ?origin ?(install = Install) ?(before_resolve = no_hook)
    ?(on_resolved = fun _ _ -> Ok ()) ?(on_installed = fun _ _ -> Ok ()) store validate items =
  let rec go = function
    | [] -> Ok ()
    | item :: rest -> (
        let* top = validate item in
        let* () = before_resolve top in
        let* resolved, warnings = Resolve.resolve_w (Store.names_view store) top in
        let* () = on_resolved resolved warnings in
        match resolved with
        | Kernel.Expr _ -> go rest
        | Kernel.Decl declaration -> (
            match Store.put_decl ?origin store declaration with
            | Ok hashes ->
                let* () = on_installed declaration hashes in
                go rest
            | Error _ when install = Install_best_effort -> go rest
            | Error _ as error -> error))
  in
  go items

let walk ?origin ?install ?(on_parsed = ignore) ?before_resolve ?on_resolved ?on_installed ~syntax
    ~file store source =
  let* parsed, warnings = parse_tops ~syntax ~names:(Store.names_view store) ~file source in
  on_parsed warnings;
  walk_items ?origin ?install ?before_resolve ?on_resolved ?on_installed store validate_parsed_top
    parsed

let walk_tops ?origin ?install ?before_resolve ?on_resolved ?on_installed store tops =
  walk_items ?origin ?install ?before_resolve ?on_resolved ?on_installed store Result.ok tops

let resolve_source_tops ~syntax store ~file source =
  let surface_warnings = ref [] and resolved = ref [] and resolver_warnings = ref [] in
  let* () =
    walk ~syntax ~file store source
      ~on_parsed:(fun warnings -> surface_warnings := warnings)
      ~on_resolved:(fun top warnings ->
        resolved := top :: !resolved;
        resolver_warnings := List.rev_append warnings !resolver_warnings;
        Ok ())
  in
  Ok (List.rev !resolved, !surface_warnings @ List.rev !resolver_warnings)

let install_declarations ?origin ?on_parsed ~expression_refusal ~syntax store ~file source =
  (* refuse before installing anything: a file with a top-level expression must leave the store
     exactly as it was *)
  let* parsed, _warnings = parse_tops ~syntax ~names:(Store.names_view store) ~file source in
  let rec declarations_only = function
    | [] -> Ok ()
    | top :: rest -> (
        match validate_parsed_top top with
        | Error _ as error -> error
        | Ok (Kernel.Expr _) -> Error [ expression_refusal ]
        | Ok (Kernel.Decl _) -> declarations_only rest)
  in
  let* () = declarations_only parsed in
  (* a failure part-way through the file must leave the store as it was *)
  Store.transaction store (fun () ->
      walk ?origin ?on_parsed ~syntax ~file store source ~on_resolved:(fun top _warnings ->
          match top with Kernel.Expr _ -> Error [ expression_refusal ] | Kernel.Decl _ -> Ok ()))

(* --- read-only checking --- *)

module Checked = struct
  type top = {
    resolved : Kernel.top;
    identity : Canon.decl_hashes option;
    signatures : (string * string) list;
    effects : Hash.t list;
    call_abis : (Hash.t * string option list) list;
    warnings : Diag.t list;
  }

  type t = {
    file : string;
    source_digest : Hash.t;
    prelude : (string * string) list option;
    tops : top list;
    dependencies : Hash.t list;
  }

  let file t = t.file
  let source_digest t = t.source_digest
  let prelude t = t.prelude
  let tops t = t.tops
  let dependencies t = t.dependencies

  let seal ~file ~source ~prelude tops =
    let introduced =
      List.concat_map
        (fun top ->
          match top.identity with
          | Some { Canon.decl_hash; named } -> decl_hash :: List.map snd named
          | None -> [])
        tops
    in
    let references =
      List.concat_map
        (fun top ->
          match top.resolved with
          | Kernel.Decl declaration -> Store.decl_refs declaration
          | Kernel.Expr expression -> Store.expr_refs expression)
        tops
    in
    let dependencies =
      List.sort_uniq Hash.compare references
      |> List.filter (fun hash -> not (List.exists (Hash.equal hash) introduced))
    in
    { file; source_digest = Hash.of_string source; prelude; tops; dependencies }

  type stale =
    | Prelude_changed
    | Missing_dependency of Hash.t
    | Rebound of { name : string; expected : Hash.t; found : Hash.t option }

  (* The identities each name was last bound to by the source: a later declaration introducing a
     name supersedes every binding an earlier one gave it, as the store's own rebinding does. *)
  let final_bindings t =
    List.fold_left
      (fun bindings top ->
        match top.identity with
        | None -> bindings
        | Some { Canon.named; _ } ->
            let names = List.sort_uniq String.compare (List.map fst named) in
            List.filter (fun (name, _) -> not (List.mem name names)) bindings @ named)
      [] t.tops

  let verify t store =
    if Store.prelude_manifest store <> t.prelude then Error Prelude_changed
    else
      match
        List.find_opt (fun hash -> Result.is_error (Store.locate store hash)) t.dependencies
      with
      | Some hash -> Error (Missing_dependency hash)
      | None -> (
          let rebound (name, expected) =
            let entries = Store.lookup_all store name in
            if List.exists (fun entry -> Hash.equal entry.Resolve.hash expected) entries then None
            else
              Some
                (Rebound
                   {
                     name;
                     expected;
                     found =
                       (match entries with [] -> None | entry :: _ -> Some entry.Resolve.hash);
                   })
          in
          match List.find_map rebound (final_bindings t) with
          | Some stale -> Error stale
          | None -> Ok ())
end

type recovery = { diagnostics : Diag.t list; signatures : (string * string) list }
type outcome = Checked of Checked.t | Recovered of recovery

let check ?origin ?(on_parsed = ignore) ?(on_resolved = fun _ _ -> ())
    ?(on_checked = fun _ _ _ -> Ok ()) ~prelude_dir ~root ~syntax ~file source =
  if Sys.file_exists root && ((not (Sys.is_directory root)) || Array.length (Sys.readdir root) > 0)
  then invalid_arg ("Frontend.check: scratch root is not a fresh directory: " ^ root);
  let* store, _ctx = open_session ~prelude_dir ~root in
  let* checker = make_checker store in
  let recovery =
    match syntax_for_file syntax file with
    | Surface -> (
        let recovered = Surface_parse.recover_string ~file source in
        match Surface_parse.strict recovered with
        | Ok _ -> None
        | Error _ -> Some (Surface_check.analyze ~names:(Store.names_view store) checker recovered))
    | Auto -> assert false
    | Bootstrap -> None
  in
  match recovery with
  | Some { Surface_check.diagnostics; signatures } ->
      let signatures =
        List.map (fun (name, scheme) -> (name, Check.show_scheme checker scheme)) signatures
      in
      Ok (Recovered { diagnostics; signatures })
  | None ->
      let checked = ref [] and awaiting_installation = ref None in
      let on_resolved top resolver_warnings =
        on_resolved top resolver_warnings;
        let* ({ Check.names; row; warnings } as signature) = Check.check_top checker top in
        let entry =
          {
            Checked.resolved = top;
            identity = None;
            signatures =
              List.map (fun (name, scheme) -> (name, Check.show_scheme checker scheme)) names;
            effects = (match row with Some row -> (Types.repr_row row).Types.effects | None -> []);
            call_abis = [];
            warnings = resolver_warnings @ warnings;
          }
        in
        let* () = on_checked checker top signature in
        (match top with
        | Kernel.Expr _ -> checked := entry :: !checked
        | Kernel.Decl _ -> awaiting_installation := Some entry);
        Ok ()
      in
      let on_installed declaration hashes =
        match !awaiting_installation with
        | None -> assert false (* walk installs a declaration only after on_resolved accepts it *)
        | Some entry ->
            awaiting_installation := None;
            checked :=
              {
                entry with
                Checked.identity = Some hashes;
                call_abis = Store.declaration_call_abis declaration hashes;
              }
              :: !checked;
            Ok ()
      in
      let* () = walk ?origin ~on_parsed ~on_resolved ~on_installed ~syntax ~file store source in
      Ok
        (Checked
           (Checked.seal ~file ~source ~prelude:(Store.prelude_manifest store) (List.rev !checked)))
