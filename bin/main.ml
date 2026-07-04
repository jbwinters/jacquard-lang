(* The weft CLI (plan W2.7).

   Exit codes, pinned by cram tests: 0 ok, 1 diagnostics (parse/validate/resolve/store), 2
   runtime error, 3 unhandled effect (the capability refusal). CLI usage errors (unknown
   subcommand, missing argument) keep cmdliner's conventional 124.

   `weft run` and `weft check` operate on an ephemeral store seeded with the prelude
   (directory from --prelude, else $WEFT_PRELUDE, else ./prelude); `weft store ...`
   subcommands operate on a persistent store directory with no implicit prelude. *)

open Weft

let ok = 0
let exit_diags = 1
let exit_runtime = 2
let exit_unhandled = 3

let print_diags ds =
  List.iter (fun d -> prerr_endline (Diag.to_string d)) ds;
  exit_diags

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let rec rm_rf path =
  if Sys.is_directory path then begin
    Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

(* Ephemeral stores are removed at exit. *)
let fresh_tmp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "weft-run-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.) mod 100000))
  in
  at_exit (fun () -> try rm_rf dir with Sys_error _ -> ());
  dir

let prelude_dir_of = function
  | Some d -> d
  | None -> ( match Sys.getenv_opt "WEFT_PRELUDE" with Some d -> d | None -> "prelude")

(* Open a store (persistent dir or fresh temp) and seed the prelude into it. *)
let open_ctx ~prelude ~store_dir =
  let root = match store_dir with Some d -> d | None -> fresh_tmp_dir () in
  match Store.open_store root with
  | Error ds -> Error ds
  | Ok store -> (
      match Prelude.load ~dir:(prelude_dir_of prelude) store with
      | Error ds -> Error ds
      | Ok _ -> (
          let ctx = Eval.make_ctx store in
          match Prelude.wire_builtins ctx with Error ds -> Error ds | Ok () -> Ok (store, ctx)))

(* Process a file's top-level forms in order: declarations go into the store; expressions
   are handed to [on_expr]. *)
let process_forms store ~file src ~on_expr =
  match Reader.parse_string ~file src with
  | Error ds -> Error ds
  | Ok forms ->
      let rec go = function
        | [] -> Ok ()
        | f :: rest -> (
            match Kernel.of_form f with
            | Error ds -> Error ds
            | Ok (Kernel.Decl d) -> (
                match Resolve.resolve_decl (Store.names_view store) d with
                | Error ds -> Error ds
                | Ok d -> (
                    match Store.put_decl store d with Error ds -> Error ds | Ok _ -> go rest))
            | Ok (Kernel.Expr e) -> (
                match Resolve.resolve_expr (Store.names_view store) e with
                | Error ds -> Error ds
                | Ok e -> ( match on_expr e with Ok () -> go rest | Error _ as err -> err)))
      in
      go forms

(* --- run --- *)

(* effect hashes for the granted names, for the manifest check (W3.6) *)
let granted_hashes store allows =
  List.filter_map
    (fun name ->
      match Store.lookup_kind store (String.lowercase_ascii name) Resolve.KEffect with
      | Some { Resolve.hash; _ } -> Some hash
      | _ -> None)
    allows

let make_checker store =
  match Check.make_ctx store with
  | Error ds -> Error ds
  | Ok cctx ->
      (match Prelude.builtin_signatures store with
      | Ok sigs -> List.iter (fun (h, s) -> Hashtbl.replace cctx.Check.builtin_sigs h s) sigs
      | Error _ -> ());
      Ok cctx

let run_cmd file allows prelude store_dir seed infer_cache =
  match open_ctx ~prelude ~store_dir with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      let seed =
        (* OS-entropy seeded unless pinned; --seed makes sampling runs reproducible (SL.7) *)
        match seed with
        | Some s -> s
        | None ->
            Random.self_init ();
            Random.bits ()
      in
      let rec grant_all = function
        | [] -> Ok ()
        | a :: rest -> (
            match Prelude.grant ctx a ~infer_cache ~out:print_string ~seed with
            | Ok () -> grant_all rest
            | Error ds -> Error ds)
      in
      match grant_all allows with
      | Error ds -> print_diags ds
      | Ok () -> (
          match make_checker store with
          | Error ds -> print_diags ds
          | Ok cctx -> (
              let granted = granted_hashes store allows in
              let refused = ref false in
              let runtime_failure = ref None in
              let on_expr e =
                (* W3.6: the program's inferred row is its authority manifest; refuse to
                   start anything that needs an ungranted effect *)
                match Check.check_top cctx (Kernel.Expr e) with
                | Error ds -> Error ds
                | Ok { Check.row; warnings; _ } -> (
                    List.iter (fun w -> prerr_endline (Diag.to_string w)) warnings;
                    match
                      Check.manifest_errors cctx ~grantable:Prelude.grantable_names ~granted
                        (Option.value row ~default:Types.empty_row)
                    with
                    | _ :: _ as ds ->
                        refused := true;
                        Error ds
                    | [] -> (
                        match Eval.run_expr ctx e with
                        | Ok v ->
                            print_endline (Value.show v);
                            Ok ()
                        | Error err ->
                            runtime_failure := Some err;
                            Error []))
              in
              match process_forms store ~file (read_file file) ~on_expr with
              | Ok () -> ok
              | Error _ when !runtime_failure <> None -> (
                  match Option.get !runtime_failure with
                  | Runtime_err.Unhandled _ as e ->
                      prerr_endline (Runtime_err.to_string e);
                      exit_unhandled
                  | Runtime_err.Observe_at_root as e ->
                      prerr_endline
                        (Diag.to_string (Diag.error ~code:"E0904" (Runtime_err.to_string e)));
                      exit_runtime
                  | e ->
                      prerr_endline (Runtime_err.to_string e);
                      exit_runtime)
              | Error ds when !refused ->
                  (* the capability refusal keeps its own exit code, now at the type level *)
                  List.iter (fun d -> prerr_endline (Diag.to_string d)) ds;
                  exit_unhandled
              | Error ds -> print_diags ds)))

(* --- check --- *)

let check_cmd file prelude print_sigs manifest =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, _ctx) -> (
      match Check.make_ctx store with
      | Error ds -> print_diags ds
      | Ok cctx -> (
          (match Prelude.builtin_signatures store with
          | Ok sigs -> List.iter (fun (h, s) -> Hashtbl.replace cctx.Check.builtin_sigs h s) sigs
          | Error _ -> () (* prelude without builtins: marker bodies type as code *));
          let granted =
            match manifest with
            | None -> None
            | Some names ->
                Some (granted_hashes store (List.map String.trim (String.split_on_char ',' names)))
          in
          let on_top top =
            match Check.check_top cctx top with
            | Error ds -> Error ds
            | Ok { Check.names; warnings; row } -> (
                List.iter (fun w -> prerr_endline (Diag.to_string w)) warnings;
                if print_sigs then
                  List.iter
                    (fun (n, s) -> Printf.printf "%s : %s\n" n (Check.show_scheme cctx s))
                    names;
                match (granted, row) with
                | Some g, Some r -> (
                    match
                      Check.manifest_errors cctx ~grantable:Prelude.grantable_names ~granted:g r
                    with
                    | [] -> Ok ()
                    | ds -> Error ds)
                | _ -> Ok ())
          in
          (* process: decls also go into the store so later forms resolve *)
          match Reader.parse_string ~file (read_file file) with
          | Error ds -> print_diags ds
          | Ok forms ->
              let rec go = function
                | [] ->
                    if not print_sigs then print_endline "ok";
                    ok
                | f :: rest -> (
                    match Kernel.of_form f with
                    | Error ds -> print_diags ds
                    | Ok top -> (
                        match Resolve.resolve_w (Store.names_view store) top with
                        | Error ds -> print_diags ds
                        | Ok (resolved, warns) -> (
                            List.iter (fun w -> prerr_endline (Diag.to_string w)) warns;
                            match on_top resolved with
                            | Error ds -> print_diags ds
                            | Ok () -> (
                                match resolved with
                                | Kernel.Decl d -> (
                                    match Store.put_decl store d with
                                    | Ok _ -> go rest
                                    | Error ds -> print_diags ds)
                                | Kernel.Expr _ -> go rest))))
              in
              go forms))

(* --- hash --- *)

let hash_cmd file prelude =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, _ctx) -> (
      match Reader.parse_string ~file (read_file file) with
      | Error ds -> print_diags ds
      | Ok forms ->
          let rec go idx = function
            | [] -> ok
            | f :: rest -> (
                match Kernel.of_form f with
                | Error ds -> print_diags ds
                | Ok top -> (
                    match Resolve.resolve (Store.names_view store) top with
                    | Error ds -> print_diags ds
                    | Ok resolved -> (
                        match Canon.hash_top resolved with
                        | Error ds -> print_diags ds
                        | Ok { Canon.decl_hash; named } ->
                            Printf.printf "%d %s\n" idx (Hash.to_hex decl_hash);
                            List.iter
                              (fun (n, h) -> Printf.printf "%d:%s %s\n" idx n (Hash.to_hex h))
                              named;
                            (* keep later forms resolvable against earlier decls *)
                            (match resolved with
                            | Kernel.Decl d -> ignore (Store.put_decl store d)
                            | Kernel.Expr _ -> ());
                            go (idx + 1) rest)))
          in
          go 0 forms)

(* --- infer (M3) --- *)

(* Shared: load the file, put decls, return the resolved final expression (the model). *)
let load_model store ~file =
  match Reader.parse_string ~file (read_file file) with
  | Error ds -> Error ds
  | Ok forms ->
      let rec go last = function
        | [] -> (
            match last with
            | Some e -> Ok e
            | None -> Error [ Diag.error ~code:"E0903" "the model file has no expression" ])
        | f :: rest -> (
            match Kernel.of_form f with
            | Error ds -> Error ds
            | Ok (Kernel.Decl d) -> (
                match Resolve.resolve_decl (Store.names_view store) d with
                | Error ds -> Error ds
                | Ok d -> (
                    match Store.put_decl store d with Error ds -> Error ds | Ok _ -> go last rest))
            | Ok (Kernel.Expr e) -> (
                match Resolve.resolve_expr (Store.names_view store) e with
                | Error ds -> Error ds
                | Ok e -> go (Some e) rest))
      in
      go None forms

let infer_check store model =
  (* the model must typecheck; its row may include dist (granted by this command) but
     nothing else ungranted *)
  match make_checker store with
  | Error ds -> Error ds
  | Ok cctx -> (
      match Check.check_top cctx (Kernel.Expr model) with
      | Error ds -> Error ds
      | Ok { Check.row; _ } -> (
          let granted =
            match Store.lookup_kind store "dist" Resolve.KEffect with
            | Some { Resolve.hash; _ } -> [ hash ]
            | None -> []
          in
          match
            Check.manifest_errors cctx ~grantable:Prelude.grantable_names ~granted
              (Option.value row ~default:Types.empty_row)
          with
          | [] -> Ok ()
          | ds -> Error ds))

let infer_enumerate_cmd file prelude =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      match load_model store ~file with
      | Error ds -> print_diags ds
      | Ok model -> (
          match infer_check store model with
          | Error ds -> print_diags ds
          | Ok () -> (
              match Infer_dist.enumerate ctx (Eval.expr_state model) with
              | Error ds -> print_diags ds
              | Ok posterior ->
                  print_endline (Infer_dist.show_posterior posterior);
                  ok)))

let infer_lw_cmd file prelude seed samples =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      match load_model store ~file with
      | Error ds -> print_diags ds
      | Ok model -> (
          match infer_check store model with
          | Error ds -> print_diags ds
          | Ok () -> (
              match
                Infer_dist.likelihood_weighting ctx ~seed ~samples (fun () -> Eval.expr_state model)
              with
              | Error ds -> print_diags ds
              | Ok posterior ->
                  print_endline (Infer_dist.show_posterior posterior);
                  ok)))

(* --- fmt --- *)

let fmt_cmd file write =
  match Reader.parse_string ~file (read_file file) with
  | Error ds -> print_diags ds
  | Ok forms ->
      let out = Printer.format_all forms in
      if write then begin
        let oc = open_out_bin file in
        output_string oc out;
        close_out oc
      end
      else print_string out;
      ok

(* --- diff --- *)

(* --- test (Warp W6.2/W6.3/W6.8) --- *)

let test_cmd files allows prelude cache_dir no_cache coverage seed =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      let seed =
        match seed with
        | Some s -> s
        | None ->
            Random.self_init ();
            Random.bits ()
      in
      let rec grant_all = function
        | [] -> Ok ()
        | a :: rest -> (
            match Prelude.grant ctx a ~infer_cache:None ~out:print_string ~seed with
            | Ok () -> grant_all rest
            | Error ds -> Error ds)
      in
      match grant_all allows with
      | Error ds -> print_diags ds
      | Ok () -> (
          (* test files are declarations only: a top-level expression is a mistake *)
          let loaded = ref [] in
          let load_file file =
            match Reader.parse_string ~file (read_file file) with
            | Error ds -> Error ds
            | Ok forms ->
                let rec go = function
                  | [] -> Ok ()
                  | f :: rest -> (
                      match Kernel.of_form f with
                      | Error ds -> Error ds
                      | Ok (Kernel.Expr _) ->
                          Error
                            [
                              Diag.error ~code:"E1001"
                                (Printf.sprintf
                                   "%s: test files hold declarations only; found a top-level \
                                    expression"
                                   file);
                            ]
                      | Ok (Kernel.Decl d) -> (
                          match Resolve.resolve_decl (Store.names_view store) d with
                          | Error ds -> Error ds
                          | Ok d -> (
                              match Store.put_decl store d with
                              | Error ds -> Error ds
                              | Ok _ ->
                                  loaded := d :: !loaded;
                                  go rest)))
                in
                go forms
          in
          let rec load_all = function
            | [] -> Ok ()
            | f :: rest -> ( match load_file f with Ok () -> load_all rest | e -> e)
          in
          match load_all files with
          | Error ds -> print_diags ds
          | Ok () -> (
              match make_checker store with
              | Error ds -> print_diags ds
              | Ok cctx -> (
                  (* an ill-typed test must FAIL the run, not silently vanish from
                     discovery (review finding: false green) *)
                  let rec check_loaded = function
                    | [] -> Ok ()
                    | d :: rest -> (
                        match Check.check_top cctx (Kernel.Decl d) with
                        | Error ds -> Error ds
                        | Ok { Check.warnings; _ } ->
                            List.iter (fun w -> prerr_endline (Diag.to_string w)) warnings;
                            check_loaded rest)
                  in
                  match check_loaded (List.rev !loaded) with
                  | Error ds -> print_diags ds
                  | Ok () -> (
                      match Store.lookup_kind store "test.run" Resolve.KTerm with
                      | None -> print_diags [ Diag.error ~code:"E0702" "prelude has no test.run" ]
                      | Some { Resolve.hash = tr; _ } -> (
                          match Warp.value_of ctx tr with
                          | Error e ->
                              prerr_endline (Runtime_err.to_string e);
                              exit_runtime
                          | Ok test_run -> (
                              let discovered = Warp.discover store cctx in
                              let test_hashes =
                                List.map
                                  (function Warp.Hermetic (_, h) | Warp.World (_, h) -> h)
                                  discovered
                              in
                              let granted = granted_hashes store allows in
                              let cache_dir =
                                if no_cache then None
                                else Some (Option.value cache_dir ~default:"test-cache")
                              in
                              let totals =
                                {
                                  Warp.passed = 0;
                                  failed = 0;
                                  skipped = 0;
                                  refused = 0;
                                  hits = 0;
                                  ran = 0;
                                }
                              in
                              let union = Hashtbl.create 64 in
                              let rec go = function
                                | [] -> Ok ()
                                | d :: rest -> (
                                    match
                                      Warp.run_discovered ctx cctx ~test_run ~cache_dir ~granted d
                                    with
                                    | Error e -> Error e
                                    | Ok outcomes ->
                                        List.iter
                                          (fun (o : Warp.outcome) ->
                                            List.iter
                                              (fun h -> Hashtbl.replace union h ())
                                              o.Warp.coverage;
                                            List.iter print_endline (Warp.render_outcome totals o))
                                          outcomes;
                                        go rest)
                              in
                              match go discovered with
                              | Error e ->
                                  prerr_endline ("test runner error: " ^ e);
                                  exit_runtime
                              | Ok () ->
                                  Printf.printf "%d passed, %d failed, %d skipped, %d refused\n"
                                    totals.Warp.passed totals.Warp.failed totals.Warp.skipped
                                    totals.Warp.refused;
                                  if cache_dir <> None then
                                    Printf.printf "cache: %d hit, %d ran\n" totals.Warp.hits
                                      totals.Warp.ran;
                                  (if coverage then
                                     let rings =
                                       Warp.parse_rings
                                         (Filename.concat (prelude_dir_of prelude) "rings.manifest")
                                     in
                                     List.iter print_endline
                                       (Warp.coverage_report store ~rings ~tests:test_hashes union));
                                  if totals.Warp.failed > 0 then exit_diags else ok)))))))

let diff_cmd store_a store_b =
  match List.find_opt (fun d -> not (Sys.file_exists d)) [ store_a; store_b ] with
  | Some missing ->
      print_diags [ Diag.error ~code:"E0606" (Printf.sprintf "store %s does not exist" missing) ]
  | None -> (
      match (Store.open_store store_a, Store.open_store store_b) with
      | Error ds, _ | _, Error ds -> print_diags ds
      | Ok old_side, Ok new_side -> (
          match Diff.render (Diff.diff ~old_side ~new_side) with
          | None ->
              print_endline "no semantic changes";
              ok
          | Some report ->
              print_endline report;
              ok))

(* --- store subcommands (persistent, no implicit prelude) --- *)

let with_store store_dir f =
  match Store.open_store store_dir with Error ds -> print_diags ds | Ok store -> f store

let store_add_cmd store_dir file =
  with_store store_dir (fun store ->
      match
        process_forms store ~file (read_file file) ~on_expr:(fun _ ->
            Error [ Diag.error ~code:"E0704" "store add expects declarations only" ])
      with
      | Ok () ->
          print_endline "ok";
          ok
      | Error ds -> print_diags ds)

let store_name_cmd store_dir name hex =
  with_store store_dir (fun store ->
      match Hash.of_hex hex with
      | None -> print_diags [ Diag.error ~code:"E0104" "invalid hash" ]
      | Some h -> (
          match Store.bind_name store name h with Ok () -> ok | Error ds -> print_diags ds))

let kind_of_flag = function
  | None -> Ok None
  | Some "term" -> Ok (Some Resolve.KTerm)
  | Some "con" -> Ok (Some Resolve.KCon)
  | Some "op" -> Ok (Some Resolve.KOp)
  | Some "type" -> Ok (Some Resolve.KType)
  | Some "effect" -> Ok (Some Resolve.KEffect)
  | Some other -> Error other

let store_rename_cmd store_dir old_name new_name kind =
  with_store store_dir (fun store ->
      match kind_of_flag kind with
      | Error other ->
          print_diags
            [
              Diag.error ~code:"E0608"
                (Printf.sprintf "unknown kind %S (expected term, con, op, type, or effect)" other);
            ]
      | Ok kind -> (
          match Store.rename store ~old_name ~new_name ?kind () with
          | Ok () -> ok
          | Error ds -> print_diags ds))

(* --- cmdliner wiring --- *)

open Cmdliner

let file_arg = Arg.(required & pos 0 (some file) None & info [] ~docv:"FILE")

let prelude_arg =
  Arg.(
    value
    & opt (some dir) None
    & info [ "prelude" ] ~docv:"DIR"
        ~doc:"Prelude directory (default: \\$WEFT_PRELUDE or ./prelude).")

let store_dir_opt_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "store" ] ~docv:"DIR" ~doc:"Persistent store directory (default: ephemeral).")

let allows_arg =
  Arg.(
    value & opt_all string []
    & info [ "allow" ] ~docv:"EFFECT"
        ~doc:"Grant an effect at the root (repeatable), e.g. --allow console --allow eval.")

let seed_arg =
  Arg.(
    value
    & opt (some int) None
    & info [ "seed" ] ~docv:"SEED"
        ~doc:"Seed for the dist sampling handler (default: OS entropy); use for reproducible runs.")

let infer_cache_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "infer-cache" ] ~docv:"DIR"
        ~doc:
          "Cache directory for infer completions (content-addressed by prompt); the second \
           identical run is a full hit.")

let run_t =
  Cmd.v
    (Cmd.info "run" ~doc:"Run a .wft file: declarations load, expressions evaluate and print.")
    Term.(
      const run_cmd $ file_arg $ allows_arg $ prelude_arg $ store_dir_opt_arg $ seed_arg
      $ infer_cache_arg)

let print_sigs_arg =
  Arg.(
    value & flag
    & info [ "print-sigs" ] ~doc:"Print the elaborated signature of every top-level form.")

let manifest_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "manifest" ] ~docv:"EFFECTS"
        ~doc:"Typecheck against a granted effect set (comma-separated), without running.")

let check_t =
  Cmd.v
    (Cmd.info "check"
       ~doc:"Parse, validate, resolve, and typecheck a .wft file (grammar + names + types).")
    Term.(const check_cmd $ file_arg $ prelude_arg $ print_sigs_arg $ manifest_arg)

let hash_t =
  Cmd.v
    (Cmd.info "hash" ~doc:"Print the canonical HASH_V0 hashes of each top-level form.")
    Term.(const hash_cmd $ file_arg $ prelude_arg)

let write_arg = Arg.(value & flag & info [ "write"; "w" ] ~doc:"Rewrite the file in place.")

let fmt_t =
  Cmd.v
    (Cmd.info "fmt" ~doc:"Format a .wft file canonically, preserving comments.")
    Term.(const fmt_cmd $ file_arg $ write_arg)

let infer_t =
  let enumerate =
    Cmd.v
      (Cmd.info "enumerate" ~doc:"Exact posterior by multi-shot enumeration.")
      Term.(const infer_enumerate_cmd $ file_arg $ prelude_arg)
  in
  let lw =
    Cmd.v
      (Cmd.info "lw" ~doc:"Approximate posterior by likelihood weighting.")
      Term.(
        const infer_lw_cmd $ file_arg $ prelude_arg
        $ Arg.(
            required
            & opt (some int) None
            & info [ "seed" ] ~docv:"N" ~doc:"PRNG seed (required, D4).")
        $ Arg.(value & opt int 10000 & info [ "samples" ] ~docv:"K" ~doc:"Number of runs."))
  in
  Cmd.group
    (Cmd.info "infer" ~doc:"Probabilistic inference: handlers over an unchanged model.")
    [ enumerate; lw ]

let diff_t =
  Cmd.v
    (Cmd.info "diff"
       ~doc:
         "Semantically compare two stores: renames are renames, reformatting is nothing, real \
          edits localize to the smallest changed subtrees.")
    Term.(
      const diff_cmd
      $ Arg.(required & pos 0 (some string) None & info [] ~docv:"STORE_A")
      $ Arg.(required & pos 1 (some string) None & info [] ~docv:"STORE_B"))

let store_pos_dir = Arg.(required & pos 0 (some string) None & info [] ~docv:"STORE")

let store_t =
  let add =
    Cmd.v
      (Cmd.info "add" ~doc:"Add the file's declarations to a persistent store.")
      Term.(
        const store_add_cmd $ store_pos_dir
        $ Arg.(required & pos 1 (some file) None & info [] ~docv:"FILE"))
  in
  let name =
    Cmd.v
      (Cmd.info "name" ~doc:"Bind NAME to a hash already in the store.")
      Term.(
        const store_name_cmd $ store_pos_dir
        $ Arg.(required & pos 1 (some string) None & info [] ~docv:"NAME")
        $ Arg.(required & pos 2 (some string) None & info [] ~docv:"HASH"))
  in
  let rename =
    Cmd.v
      (Cmd.info "rename" ~doc:"Rebind OLD to NEW; object files are untouched.")
      Term.(
        const store_rename_cmd $ store_pos_dir
        $ Arg.(required & pos 1 (some string) None & info [] ~docv:"OLD")
        $ Arg.(required & pos 2 (some string) None & info [] ~docv:"NEW")
        $ Arg.(
            value
            & opt (some string) None
            & info [ "kind" ] ~docv:"KIND"
                ~doc:"Disambiguate when OLD is bound to several kinds (term|con|op|type|effect)."))
  in
  Cmd.group
    (Cmd.info "store" ~doc:"Operate on a persistent content-addressed store.")
    [ add; name; rename ]

let test_files_arg = Arg.(value & pos_all file [] & info [] ~docv:"FILES")

let cache_dir_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "cache-dir" ] ~docv:"DIR" ~doc:"Hermetic result cache directory (default: test-cache).")

let no_cache_arg =
  Arg.(value & flag & info [ "no-cache" ] ~doc:"Bypass the hermetic result cache entirely.")

let coverage_arg =
  Arg.(
    value & flag & info [ "coverage" ] ~doc:"Report definitions never executed by any test (W6.8).")

let test_t =
  Cmd.v
    (Cmd.info "test"
       ~doc:
         "Discover tests by checked type (decision D12) and run them: the hermetic lane under \
          test.run, the world lane behind --allow grants.")
    Term.(
      const test_cmd $ test_files_arg $ allows_arg $ prelude_arg $ cache_dir_arg $ no_cache_arg
      $ coverage_arg $ seed_arg)

let main =
  Cmd.group
    (Cmd.info "weft" ~version:Version.version ~doc:"The Weft language toolchain")
    [ run_t; check_t; hash_t; fmt_t; diff_t; infer_t; store_t; test_t ]

let () = exit (Cmd.eval' main)
