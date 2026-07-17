(* The jacquard CLI (plan W2.7).

   Exit codes, pinned by cram tests: 0 ok, 1 diagnostics (parse/validate/resolve/store), 2
   runtime error, 3 unhandled effect (the capability refusal). CLI usage errors (unknown
   subcommand, missing argument) keep cmdliner's conventional 124. Operand and source errors,
   including [diff]'s file/store validation, are diagnostics and return 1.

   `jacquard run` and `jacquard check` operate on an ephemeral store seeded with the prelude
   (directory from --prelude, else $JACQUARD_PRELUDE, else ./prelude); `jacquard store ...`
   subcommands operate on a persistent store directory with no implicit prelude. *)

open Jacquard

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
      (Printf.sprintf "jacquard-run-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.) mod 100000))
  in
  at_exit (fun () -> try rm_rf dir with Sys_error _ -> ());
  dir

let prelude_dir_of = function
  | Some d -> d
  | None -> ( match Sys.getenv_opt "JACQUARD_PRELUDE" with Some d -> d | None -> "prelude")

type syntax = Auto | Bootstrap | Surface
type parsed_top = Bootstrap_form of Form.t | Surface_top of Kernel.top

let syntax_for_file syntax file =
  match syntax with
  | Auto when Filename.check_suffix file ".jac" -> Surface
  | Auto | Bootstrap -> Bootstrap
  | Surface -> Surface

let parse_tops ~syntax ~names ~file src =
  match syntax_for_file syntax file with
  | Auto -> assert false
  | Bootstrap ->
      Result.map
        (fun forms -> (List.map (fun form -> Bootstrap_form form) forms, []))
        (Reader.parse_string ~file src)
  | Surface ->
      let recovered = Surface_parse.recover_string ~file src in
      Result.bind (Surface_parse.strict recovered) (fun parsed ->
          let warnings = Surface_check.lint ~names parsed in
          Result.map
            (fun tops -> (List.map (fun top -> Surface_top top) tops, warnings))
            (Surface_lower.lower_tops parsed))

let validate_parsed_top = function
  | Bootstrap_form form -> Kernel.of_form form
  | Surface_top top -> Ok top

let print_warnings warnings =
  List.iter (fun warning -> prerr_endline (Diag.to_string warning)) warnings

(** [resolve_source_tops] parses, surface-lowers when selected, validates, and resolves a whole
    source artifact in order. Declarations are installed in [store] as they are encountered so later
    tops see exactly the same name context as [check] and [hash]. Parse, validation, resolution, and
    store failures are returned without producing a partial result. *)
let resolve_source_tops ~syntax store ~file src =
  match parse_tops ~syntax ~names:(Store.names_view store) ~file src with
  | Error _ as error -> error
  | Ok (parsed, surface_warnings) ->
      let rec go resolved warnings = function
        | [] -> Ok (List.rev resolved, surface_warnings @ List.rev warnings)
        | parsed_top :: rest -> (
            match validate_parsed_top parsed_top with
            | Error _ as error -> error
            | Ok top -> (
                match Resolve.resolve_w (Store.names_view store) top with
                | Error _ as error -> error
                | Ok (resolved_top, resolver_warnings) -> (
                    match resolved_top with
                    | Kernel.Expr _ ->
                        go (resolved_top :: resolved)
                          (List.rev_append resolver_warnings warnings)
                          rest
                    | Kernel.Decl declaration -> (
                        match Store.put_decl store declaration with
                        | Error _ as error -> error
                        | Ok _ ->
                            go (resolved_top :: resolved)
                              (List.rev_append resolver_warnings warnings)
                              rest))))
      in
      go [] [] parsed

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
let process_forms ?origin ?(on_decl = fun _ _ -> ()) ~syntax store ~file src ~on_expr =
  match parse_tops ~syntax ~names:(Store.names_view store) ~file src with
  | Error ds -> Error ds
  | Ok (tops, warnings) ->
      print_warnings warnings;
      let rec go = function
        | [] -> Ok ()
        | parsed :: rest -> (
            match validate_parsed_top parsed with
            | Error ds -> Error ds
            | Ok (Kernel.Decl d) -> (
                match Resolve.resolve_decl (Store.names_view store) d with
                | Error ds -> Error ds
                | Ok d -> (
                    match Store.put_decl ?origin store d with
                    | Error ds -> Error ds
                    | Ok hashes ->
                        on_decl d hashes;
                        go rest))
            | Ok (Kernel.Expr e) -> (
                match Resolve.resolve_expr (Store.names_view store) e with
                | Error ds -> Error ds
                | Ok e -> ( match on_expr e with Ok () -> go rest | Error _ as err -> err)))
      in
      go tops

(* --- run --- *)

(* effect hashes for the granted names, for the manifest check (W3.6) *)
let granted_hashes store allows =
  let explicit =
    List.filter_map
      (fun name ->
        match Store.lookup_kind store (String.lowercase_ascii name) Resolve.KEffect with
        | Some { Resolve.hash; _ } -> Some hash
        | _ -> None)
      allows
  in
  let scheduler_async =
    match Store.lookup_kind store "async" Resolve.KEffect with
    | Some { Resolve.hash; _ }
      when String.equal (Hash.to_hex hash) Concurrency_contract.async_effect_hash ->
        [ hash ]
    | Some _ | None -> []
  in
  explicit @ scheduler_async

let make_checker store =
  match Check.make_ctx store with
  | Error ds -> Error ds
  | Ok cctx ->
      (match Prelude.builtin_signatures store with
      | Ok sigs -> Check.register_builtin_signatures cctx sigs
      | Error _ -> ());
      Ok cctx

let schedule_file_error action path message =
  let prefix = path ^ ": " in
  let message =
    if String.starts_with ~prefix message then
      String.sub message (String.length prefix) (String.length message - String.length prefix)
    else message
  in
  [
    Diag.error ~code:"E0908" (Printf.sprintf "cannot %s schedule trace %s: %s" action path message);
  ]

let load_schedule path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Schedule_trace.parse_channel channel)
  with Sys_error message -> Error (schedule_file_error "read" path message)

let parse_schedule_fork spec =
  match String.index_opt spec '=' with
  | None -> Error [ Diag.error ~code:"E0908" "invalid --schedule-fork (expected DECISION=TASK)" ]
  | Some index ->
      let decision = String.sub spec 0 index in
      let task = String.sub spec (index + 1) (String.length spec - index - 1) in
      Result.bind
        (match int_of_string_opt decision with
        | Some decision when decision >= 0 -> Ok decision
        | Some _ | None ->
            Error [ Diag.error ~code:"E0908" "schedule fork decision must be non-negative" ])
        (fun decision ->
          Result.map (fun chosen -> (decision, chosen)) (Schedule_trace.task_id_of_string task))

let schedule_mode replay_file fork_spec =
  match (replay_file, fork_spec) with
  | None, None -> Ok None
  | None, Some _ -> Error [ Diag.error ~code:"E0908" "--schedule-fork requires --schedule-replay" ]
  | Some path, None ->
      Result.map (fun trace -> Some (Round_robin.Replay_schedule trace)) (load_schedule path)
  | Some path, Some spec ->
      Result.bind (load_schedule path) (fun trace ->
          Result.map
            (fun (decision, chosen) -> Some (Round_robin.Fork_schedule { trace; decision; chosen }))
            (parse_schedule_fork spec))

let write_schedule path trace =
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        output_string channel (Schedule_trace.serialize trace);
        close_out channel);
    Ok ()
  with Sys_error message -> Error (schedule_file_error "write" path message)

let run_cmd file allows prelude store_dir seed infer_cache origin dry_run schedule_record
    schedule_replay schedule_fork syntax =
  match schedule_mode schedule_replay schedule_fork with
  | Error diagnostics -> print_diags diagnostics
  | Ok requested_mode -> (
      match open_ctx ~prelude ~store_dir with
      | Error ds -> print_diags ds
      | Ok (store, ctx) -> (
          let source = read_file file in
          let trace_enabled = Option.is_some schedule_record || Option.is_some requested_mode in
          let expression_count =
            if not trace_enabled then Ok ()
            else
              Result.bind
                (parse_tops ~syntax ~names:(Store.names_view store) ~file source)
                (fun (tops, _warnings) ->
                  let rec count_expressions count = function
                    | [] -> Ok count
                    | parsed :: rest ->
                        Result.bind (validate_parsed_top parsed) (function
                          | Kernel.Expr _ -> count_expressions (count + 1) rest
                          | Kernel.Decl _ -> count_expressions count rest)
                  in
                  Result.bind (count_expressions 0 tops) (fun count ->
                      if count = 1 then Ok ()
                      else
                        Error
                          [
                            Diag.error ~code:"E0908"
                              (Printf.sprintf
                                 "schedule record/replay requires exactly one top-level \
                                  expression, found %d"
                                 count);
                          ]))
          in
          match expression_count with
          | Error diagnostics -> print_diags diagnostics
          | Ok () -> (
              (* run never reads coverage; skip the per-reference bookkeeping (PF.2 phase 2) *)
              Eval.set_coverage_tracking ctx false;
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
              let audit : string list ref = ref [] in
              let grants_result =
                if dry_run then Prelude.install_dry ctx ~audit else grant_all allows
              in
              match grants_result with
              | Error ds -> print_diags ds
              | Ok () -> (
                  match make_checker store with
                  | Error ds -> print_diags ds
                  | Ok cctx -> (
                      let granted =
                        if dry_run then
                          (* the dry handlers discharge the whole world; the manifest sees it granted *)
                          granted_hashes store [ "console"; "clock"; "fs"; "net"; "infer"; "dist" ]
                        else granted_hashes store allows
                      in
                      let eval_hash =
                        match Store.lookup_kind store "eval" Resolve.KEffect with
                        | Some { Resolve.hash; _ } -> Some hash
                        | None -> None
                      in
                      let refused = ref false in
                      let runtime_failure = ref None in
                      let completed_schedule = ref None in
                      let on_expr e =
                        (* W3.6: the program's inferred row is its authority manifest; refuse to
                   start anything that needs an ungranted effect *)
                        match Check.check_top cctx (Kernel.Expr e) with
                        | Error ds -> Error ds
                        | Ok { Check.row; warnings; _ } -> (
                            List.iter (fun w -> prerr_endline (Diag.to_string w)) warnings;
                            (if dry_run then
                               let r = Types.repr_row (Option.value row ~default:Types.empty_row) in
                               match eval_hash with
                               | Some eh when List.exists (Hash.equal eh) r.Types.effects ->
                                   raise
                                     (Invalid_argument
                                        "error[E1002]: --dry-run cannot sandbox eval: eval'd code \
                                         runs at root authority and bypasses the dry handlers")
                               | _ -> ());
                            match
                              Check.manifest_errors cctx ~grantable:Prelude.grantable_names ~granted
                                (Option.value row ~default:Types.empty_row)
                            with
                            | _ :: _ as ds ->
                                refused := true;
                                Error ds
                            | [] -> (
                                let execution =
                                  match requested_mode with
                                  | Some mode ->
                                      Result.map
                                        (fun (scheduled : Round_robin.scheduled) ->
                                          completed_schedule := Some scheduled.Round_robin.schedule;
                                          scheduled.value)
                                        (Round_robin.run_expr_scheduled ctx ~mode e)
                                  | None when Option.is_some schedule_record ->
                                      Result.map
                                        (fun (scheduled : Round_robin.scheduled) ->
                                          completed_schedule := Some scheduled.Round_robin.schedule;
                                          scheduled.value)
                                        (Round_robin.run_expr_scheduled ctx
                                           ~mode:Round_robin.Record_schedule e)
                                  | None -> Round_robin.run_expr ctx e
                                in
                                match execution with
                                | Ok v ->
                                    print_endline (Value.show v);
                                    Ok ()
                                | Error err ->
                                    runtime_failure := Some err;
                                    Error []))
                      in
                      match process_forms ?origin ~syntax store ~file source ~on_expr with
                      | exception Invalid_argument msg
                        when String.length msg > 6 && String.sub msg 0 5 = "error" ->
                          prerr_endline msg;
                          exit_diags
                      | Ok () -> (
                          let write_result =
                            match (schedule_record, !completed_schedule) with
                            | Some path, Some trace -> write_schedule path trace
                            | None, _ -> Ok ()
                            | Some _, None ->
                                Error
                                  [
                                    Diag.error ~code:"E0908" "scheduled execution produced no trace";
                                  ]
                          in
                          match write_result with
                          | Error diagnostics -> print_diags diagnostics
                          | Ok () ->
                              if dry_run then begin
                                (* the consent sheet: each world effect's disposition, then the trail *)
                                print_endline
                                  "dry-run dispositions: console=forwarded clock=forwarded \
                                   fs.read=forwarded fs.write=audited net.fetch=audited+simulated \
                                   infer.complete=audited+simulated dist=simulated(seed 0) \
                                   eval=refused";
                                print_endline "dry-run: this run WOULD have:";
                                if !audit = [] then print_endline "  (no world mutations)"
                                else List.iter (fun l -> print_endline ("  " ^ l)) (List.rev !audit)
                              end;
                              ok)
                      | Error _ when !runtime_failure <> None -> (
                          match Option.get !runtime_failure with
                          | Runtime_err.Unhandled _ as e ->
                              prerr_endline (Runtime_err.to_string e);
                              exit_unhandled
                          | Runtime_err.Observe_at_root as e ->
                              prerr_endline
                                (Diag.to_string
                                   (Diag.error ~code:"E0904" (Runtime_err.to_string e)));
                              exit_runtime
                          | e ->
                              prerr_endline (Runtime_err.to_string e);
                              exit_runtime)
                      | Error ds when !refused ->
                          (* the capability refusal keeps its own exit code, now at the type level *)
                          List.iter (fun d -> prerr_endline (Diag.to_string d)) ds;
                          exit_unhandled
                      | Error ds -> print_diags ds)))))

(* --- check --- *)

let check_cmd file prelude print_sigs manifest origin syntax =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, _ctx) -> (
      match Check.make_ctx store with
      | Error ds -> print_diags ds
      | Ok cctx -> (
          (match Prelude.builtin_signatures store with
          | Ok sigs -> Check.register_builtin_signatures cctx sigs
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
                    (fun (n, s) ->
                      let tag =
                        match origin with
                        | Some t -> " [" ^ t ^ "]" (* the decls being checked ARE stamped by us *)
                        | None -> (
                            match
                              Option.bind (Store.lookup_name store n) (fun e ->
                                  Store.origin store e.Resolve.hash)
                            with
                            | Some t -> " [" ^ t ^ "]"
                            | None -> "")
                      in
                      Printf.printf "%s : %s%s\n" n (Check.show_scheme cctx s) tag)
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
          let source = read_file file in
          let malformed_surface_report =
            match syntax_for_file syntax file with
            | Surface -> (
                let recovered = Surface_parse.recover_string ~file source in
                match Surface_parse.strict recovered with
                | Ok _ -> None
                | Error _ ->
                    Some (Surface_check.analyze ~names:(Store.names_view store) cctx recovered))
            | Auto -> assert false
            | Bootstrap -> None
          in
          (* process: decls also go into the store so later forms resolve *)
          match malformed_surface_report with
          | Some report ->
              if print_sigs then
                List.iter
                  (fun (name, scheme) ->
                    Printf.printf "%s : %s\n" name (Check.show_scheme cctx scheme))
                  report.Surface_check.signatures;
              print_diags report.diagnostics
          | None -> (
              match parse_tops ~syntax ~names:(Store.names_view store) ~file source with
              | Error ds -> print_diags ds
              | Ok (tops, surface_warnings) ->
                  print_warnings surface_warnings;
                  let rec go = function
                    | [] ->
                        if not print_sigs then print_endline "ok";
                        ok
                    | parsed :: rest -> (
                        match validate_parsed_top parsed with
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
                                        match Store.put_decl ?origin store d with
                                        | Ok _ -> go rest
                                        | Error ds -> print_diags ds)
                                    | Kernel.Expr _ -> go rest))))
                  in
                  go tops)))

(* --- hash --- *)

let hash_cmd file prelude syntax =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, _ctx) -> (
      match parse_tops ~syntax ~names:(Store.names_view store) ~file (read_file file) with
      | Error ds -> print_diags ds
      | Ok (tops, surface_warnings) ->
          print_warnings surface_warnings;
          let rec go idx = function
            | [] -> ok
            | parsed :: rest -> (
                match validate_parsed_top parsed with
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
          go 0 tops)

(* --- infer (M3) --- *)

(* Shared: load the file, put decls, return the resolved final expression (the model). *)
let load_model store ~syntax ~file =
  match parse_tops ~syntax ~names:(Store.names_view store) ~file (read_file file) with
  | Error ds -> Error ds
  | Ok (forms, warnings) ->
      print_warnings warnings;
      let rec go last = function
        | [] -> (
            match last with
            | Some e -> Ok e
            | None -> Error [ Diag.error ~code:"E0903" "the model file has no expression" ])
        | parsed :: rest -> (
            match validate_parsed_top parsed with
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

let infer_enumerate_cmd file prelude syntax =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      match load_model store ~syntax ~file with
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

let infer_lw_cmd file prelude seed samples syntax =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      match load_model store ~syntax ~file with
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

let fmt_cmd file write syntax =
  let src = read_file file in
  let formatted =
    match syntax_for_file syntax file with
    | Auto -> assert false
    | Bootstrap -> Result.map Printer.format_all (Reader.parse_string ~file src)
    | Surface ->
        let recovered = Surface_parse.recover_string ~file src in
        Result.bind (Surface_parse.strict_file recovered) (fun parsed ->
            print_warnings (Surface_check.lint ~names:Resolve.empty_names parsed.tops);
            Result.bind (Surface_lower.lower_file parsed) (fun lowered ->
                Surface_print.print_file_with_trivia ~file_meta:lowered.meta lowered.tops))
  in
  match formatted with
  | Error ds -> print_diags ds
  | Ok out ->
      if write then begin
        let oc = open_out_bin file in
        output_string oc out;
        close_out oc
      end
      else print_string out;
      ok

(* --- diff --- *)

(* --- dist-diff (TL.1): posterior divergence between model versions, with the
   enumeration cache that content addressing gives for free --- *)

let posterior_cache_lookup ~cache_dir key : (Value.t * float) list option =
  match cache_dir with
  | None -> None
  | Some dir -> (
      let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".jqd") in
      match read_file path with
      | exception Sys_error _ -> None
      | src -> (
          match Reader.parse_one ~file:path src with
          | Ok { Form.head = "posterior"; args; _ } ->
              let entry = function
                | Form.F { Form.head = "entry"; args = [ Form.F v; Form.Real p ]; _ } -> Some (v, p)
                | _ -> None
              in
              let parsed = List.map entry args in
              if List.exists (( = ) None) parsed then None
              else Some (List.filter_map (Option.map (fun (v, p) -> (Value.VCode v, p))) parsed)
          | _ -> None))

(* posterior entries cached as (posterior (entry FORM prob) ...). Values are re-rendered
   from their printed forms for display, so keys compare by rendering on both paths. *)
let posterior_cache_store ~cache_dir key (entries : (Form.t * float) list) : unit =
  match cache_dir with
  | None -> ()
  | Some dir -> (
      try
        if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
        let path = Filename.concat dir (Hash.to_hex (Hash.of_string key) ^ ".jqd") in
        let oc = open_out_bin path in
        output_string oc
          (Printer.print
             (Form.form "posterior"
                (List.map
                   (fun (v, p) -> Form.F (Form.form "entry" [ Form.F v; Form.Real p ]))
                   entries))
          ^ "\n");
        close_out oc
      with Sys_error m -> Printf.eprintf "dist-cache unavailable (%s)\n%!" m)

(* a rendered posterior: (display key, probability) sorted for deterministic diffing *)
let enumerate_rendered ctx store ~cache_dir model_expr : ((string * float) list, Diag.t list) result
    =
  let key =
    match Canon.hash_top (Kernel.Expr model_expr) with
    | Ok hs -> "dist-diff|" ^ Hash.to_hex hs.Canon.decl_hash
    | Error _ -> "dist-diff|unhashable"
  in
  ignore store;
  ignore ();
  match posterior_cache_lookup ~cache_dir key with
  | Some entries ->
      Printf.eprintf "dist-diff: cached posterior %s\n%!" (String.sub key 10 8);
      Ok
        (List.map
           (fun (v, p) ->
             ( (match v with
               | Value.VCode { Form.head = "shown"; args = [ Form.Text shown ]; _ } -> shown
               | Value.VCode f -> Printer.inline_form f
               | v -> Value.show v),
               p ))
           entries)
  | None -> (
      match Infer_dist.enumerate ctx (Eval.expr_state model_expr) with
      | Error ds -> Error ds
      | Ok posterior ->
          Printf.eprintf "dist-diff: enumerated %s\n%!" (String.sub key 10 8);
          let rendered = List.map (fun (v, p) -> (Value.show v, p)) posterior.Infer_dist.entries in
          (* cache as forms when the values have literal spellings; ints/cons/bools do *)
          let form_of (v, p) =
            match Reader.parse_one ~file:"cache" (Printf.sprintf "(lit %s)" (fst (v, p))) with
            | Ok f -> Some (f, p)
            | Error _ -> None
          in
          ignore form_of;
          posterior_cache_store ~cache_dir key
            (List.filter_map
               (fun (shown, p) ->
                 match
                   Reader.parse_one ~file:"cache"
                     ("(shown " ^ "\"" ^ Printer.escape_text shown ^ "\")")
                 with
                 | Ok f -> Some (f, p)
                 | Error _ -> None)
               rendered);
          Ok rendered)

let dist_diff_cmd model_a model_b tolerance cache_dir no_cache sweep prelude =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      let cache_dir =
        if no_cache then None else Some (Option.value cache_dir ~default:"dist-cache")
      in

      let apply_sweep src =
        (* --sweep NAME=v1,v2: textually rebind (binding NAME () BODY) per value *)
        match sweep with
        | None -> [ (None, src) ]
        | Some spec -> (
            match String.index_opt spec '=' with
            | None -> [ (None, src) ]
            | Some i ->
                let name = String.sub spec 0 i in
                let values =
                  String.split_on_char ',' (String.sub spec (i + 1) (String.length spec - i - 1))
                in
                List.map
                  (fun v ->
                    let re = Str.regexp ("(binding " ^ Str.quote name ^ " () (lit [^)]*))") in
                    let swept =
                      Str.replace_first re ("(binding " ^ name ^ " () (lit " ^ v ^ "))") src
                    in
                    if swept = src then
                      Printf.eprintf
                        "warning: --sweep parameter %s matched no (binding %s () (lit ...)); \
                         variant equals the base\n\
                         %!"
                        name name;
                    (Some (name ^ "=" ^ v), swept))
                  values)
      in
      let posterior_of ?(label = None) file src_override =
        let src = match src_override with Some s -> s | None -> read_file file in
        ignore label;
        match Reader.parse_string ~file src with
        | Error ds -> Error ds
        | Ok forms -> (
            (* load decls, take the last expr as the model *)
            let rec go last = function
              | [] -> (
                  match last with
                  | Some e -> Ok e
                  | None -> Error [ Diag.error ~code:"E0903" (file ^ " has no model expression") ])
              | f :: rest -> (
                  match Kernel.of_form f with
                  | Error ds -> Error ds
                  | Ok (Kernel.Decl d) -> (
                      match Resolve.resolve_decl (Store.names_view store) d with
                      | Error ds -> Error ds
                      | Ok d -> (
                          match Store.put_decl store d with
                          | Error ds -> Error ds
                          | Ok _ -> go last rest))
                  | Ok (Kernel.Expr e) -> (
                      match Resolve.resolve_expr (Store.names_view store) e with
                      | Error ds -> Error ds
                      | Ok e -> go (Some e) rest))
            in
            match go None forms with
            | Error ds -> Error ds
            | Ok e -> enumerate_rendered ctx store ~cache_dir e)
      in
      (* result types must AGREE before probabilities are comparable: check both
         models and compare their elaborated value types *)
      let model_type file src_override =
        let src = match src_override with Some s -> s | None -> read_file file in
        match Reader.parse_string ~file src with
        | Error ds -> Error ds
        | Ok forms -> (
            match make_checker store with
            | Error ds -> Error ds
            | Ok cctx ->
                let rec go last = function
                  | [] -> (
                      match last with
                      | Some t -> Ok t
                      | None ->
                          Error [ Diag.error ~code:"E0903" (file ^ " has no model expression") ])
                  | f :: rest -> (
                      match Kernel.of_form f with
                      | Error ds -> Error ds
                      | Ok top -> (
                          match Resolve.resolve (Store.names_view store) top with
                          | Error ds -> Error ds
                          | Ok resolved -> (
                              match Check.check_top cctx resolved with
                              | Error ds -> Error ds
                              | Ok { Check.names = [ ("_", sc) ]; _ } ->
                                  go (Some (Check.show_scheme cctx sc)) rest
                              | Ok _ -> (
                                  (* the model's own declarations must land so later
                                     forms (and the enumeration pass) resolve them *)
                                  match resolved with
                                  | Kernel.Decl d -> (
                                      match Store.put_decl store d with
                                      | Error ds -> Error ds
                                      | Ok _ -> go last rest)
                                  | Kernel.Expr _ -> go last rest))))
                in
                go None forms)
      in
      let render_diff label pa pb =
        let mass table k = Option.value (List.assoc_opt k table) ~default:0.0 in
        let keys = List.sort_uniq compare (List.map fst pa @ List.map fst pb) in
        let gained = List.filter (fun k -> not (List.mem_assoc k pa)) keys in
        let lost = List.filter (fun k -> not (List.mem_assoc k pb)) keys in
        let deltas =
          List.filter_map
            (fun k ->
              if List.mem_assoc k pa && List.mem_assoc k pb then
                let d = mass pb k -. mass pa k in
                if Float.abs d > tolerance then Some (k, mass pa k, mass pb k, d) else None
              else None)
            keys
          |> List.sort (fun (_, _, _, d1) (_, _, _, d2) -> compare (Float.abs d2) (Float.abs d1))
        in
        (match label with Some l -> Printf.printf "-- sweep %s --\n" l | None -> ());
        if gained = [] && lost = [] && deltas = [] then print_endline "no divergence"
        else begin
          List.iter (fun k -> Printf.printf "support gained: %s\n" k) gained;
          List.iter (fun k -> Printf.printf "support lost:   %s\n" k) lost;
          List.iter
            (fun (k, a, b, d) -> Printf.printf "P(%s): %.6f -> %.6f (delta %+.6f)\n" k a b d)
            deltas
        end
      in
      let variants = apply_sweep (read_file model_b) in
      let type_gate =
        match (model_type model_a None, model_type model_b None) with
        | Ok ta, Ok tb when ta <> tb ->
            Some
              [
                Diag.error ~code:"E0801"
                  (Printf.sprintf
                     "dist-diff: model result types differ (%s : %s, %s : %s); probabilities over \
                      different types are not comparable"
                     model_a ta model_b tb);
              ]
        | Error ds, _ | _, Error ds -> Some ds
        | _ -> None
      in
      match type_gate with
      | Some ds -> print_diags ds
      | None -> (
          match posterior_of model_a None with
          | Error ds -> print_diags ds
          | Ok pa ->
              let rec run_variants = function
                | [] -> ok
                | (label, src) :: rest -> (
                    match posterior_of ~label model_b (Some src) with
                    | Error ds -> print_diags ds
                    | Ok pb ->
                        render_diff label pa pb;
                        run_variants rest)
              in
              run_variants variants))

(* --- replay (TL.3): record, scrub, fork — counterfactual debugging over logs --- *)

(* Parse a (log (op "fetch" ARGS RESULT) ...) payload file into entry forms. *)
let log_entries_of_file file =
  match Reader.parse_one ~file (read_file file) with
  | Error ds -> Error ds
  | Ok { Form.head = "log"; args; _ } ->
      Ok (List.filter_map (function Form.F f -> Some f | _ -> None) args)
  | Ok f ->
      Error
        [
          Diag.error ~code:"E0104"
            (Printf.sprintf "%s is not a log payload (head %s)" file f.Form.head);
        ]

let entry_result_form (entry : Form.t) : Form.t option =
  match entry.Form.args with [ _; _; Form.F result ] -> Some result | _ -> None

(* The counterfactual driver: serve ops 1..to_n from the log; forks override single
   positions with evaluated forms; past the log (or after --to) the DRY handlers take
   over, recording the fork's world ops as forms for --compare. *)
let replay_cmd log_file program forks to_n compare prelude =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, ctx) -> (
      match log_entries_of_file log_file with
      | Error ds -> print_diags ds
      | Ok entries -> (
          let audit_forms : Form.t list ref = ref [] in
          (match Prelude.install_dry ctx ~audit:(ref []) with
          | Ok () -> ()
          | Error ds -> ignore (print_diags ds));
          (* override fetch: positional serving with fork injection, then dry recording *)
          let pos = ref 0 in
          let parse_fork spec =
            match String.index_opt spec '=' with
            | Some i -> (
                let n = int_of_string_opt (String.sub spec 0 i) in
                let form_src = String.sub spec (i + 1) (String.length spec - i - 1) in
                match (n, Reader.parse_one ~file:"fork" form_src) with
                | Some n, Ok f -> Some (n, f)
                | _ -> None)
            | None -> None
          in
          let parsed_forks = List.map (fun spec -> (spec, parse_fork spec)) forks in
          let bad =
            List.filter_map (fun (spec, p) -> if p = None then Some spec else None) parsed_forks
          in
          if bad <> [] then
            print_diags
              (List.map
                 (fun spec ->
                   Diag.error ~code:"E0104"
                     (Printf.sprintf "invalid --fork %S (expected N=FORM with a parseable form)"
                        spec))
                 bad)
          else
            let forks = List.filter_map snd parsed_forks in
            let serve_fetch req_form =
              incr pos;
              let n = !pos in
              audit_forms := req_form :: !audit_forms;
              match List.assoc_opt n forks with
              | Some override -> `Form override
              | None ->
                  if n <= to_n && n <= List.length entries then
                    match entry_result_form (List.nth entries (n - 1)) with
                    | Some r -> `Form r
                    | None -> `Stub
                  else `Stub
            in
            (match
               ( Store.lookup_kind store "fetch" Resolve.KOp,
                 Store.lookup_kind store "mk-response" Resolve.KCon )
             with
            | Some { Resolve.hash = fetch_op; _ }, Some { Resolve.hash = resp_con; _ } ->
                Eval.register_root_handler ctx fetch_op (fun args ->
                    match args with
                    | [
                     Value.VCon
                       { name = "mk-request"; args = [ Value.VText url; Value.VText body ]; _ };
                    ] -> (
                        let req_form =
                          Form.form "request"
                            [
                              Form.F (Form.form "lit" [ Form.Text url ]);
                              Form.F (Form.form "lit" [ Form.Text body ]);
                            ]
                        in
                        let response_parts (f : Form.t) =
                          (* accept both the codec's lit-wrapped spelling and the bare
                           user-typed one: (response (lit 500) (lit "x")) / (response 500 "x") *)
                          match f with
                          | {
                           Form.head = "response";
                           args =
                             [
                               Form.F { Form.args = [ Form.Int st ]; _ };
                               Form.F { Form.args = [ Form.Text b ]; _ };
                             ];
                           _;
                          } ->
                              Some (st, b)
                          | { Form.head = "response"; args = [ Form.Int st; Form.Text b ]; _ } ->
                              Some (st, b)
                          | _ -> None
                        in
                        match
                          Option.map response_parts
                            (match serve_fetch req_form with `Form f -> Some f | `Stub -> None)
                        with
                        | Some (Some (status, b)) ->
                            Ok
                              (Value.VCon
                                 {
                                   con = resp_con;
                                   name = "mk-response";
                                   args = [ Value.VInt status; Value.VText b ];
                                 })
                        | Some None ->
                            Error
                              (Runtime_err.Type_error
                                 "fork/log form is not a (response N \"...\") payload")
                        | None ->
                            Ok
                              (Value.VCon
                                 {
                                   con = resp_con;
                                   name = "mk-response";
                                   args = [ Value.VInt 200; Value.VText "<live-after-log>" ];
                                 }))
                    | args ->
                        Error
                          (Runtime_err.Type_error
                             (Printf.sprintf "fetch expects one request, got %s"
                                (String.concat ", " (List.map Value.show args)))))
            | _ -> ());
            let on_expr e =
              match Round_robin.run_expr ctx e with
              | Ok v ->
                  print_endline (Value.show v);
                  Ok ()
              | Error err ->
                  prerr_endline (Runtime_err.to_string err);
                  Error []
            in
            match
              process_forms ~syntax:Bootstrap store ~file:program (read_file program) ~on_expr
            with
            | Error ds -> print_diags ds
            | Ok () ->
                if compare then begin
                  (* the divergence report: each original log entry's REQUEST vs what the
                   fork actually asked, via the semantic differ *)
                  print_endline "divergence report (original log vs fork):";
                  let fork_reqs = List.rev !audit_forms in
                  List.iteri
                    (fun i entry ->
                      let original_req =
                        match entry.Form.args with [ _; Form.F r; _ ] -> Some r | _ -> None
                      in
                      match (original_req, List.nth_opt fork_reqs i) with
                      | Some o, Some f ->
                          let ds =
                            Diff.form_divergences ~path:(Printf.sprintf "op%d" (i + 1)) o f
                          in
                          if ds = [] then Printf.printf "  op%d: identical request\n" (i + 1)
                          else
                            List.iter
                              (fun { Diff.path; a; b } ->
                                Printf.printf "  at %s: - %s + %s\n" path a b)
                              ds
                      | Some _, None -> Printf.printf "  op%d: not reached by the fork\n" (i + 1)
                      | None, _ -> ())
                    entries;
                  let extra = List.length !audit_forms - List.length entries in
                  if extra > 0 then Printf.printf "  fork made %d additional op(s)\n" extra;
                  ok
                end
                else ok))

(* --- test (Warp W6.2/W6.3/W6.8) --- *)

let test_cmd files allows prelude cache_dir no_cache coverage seed samples exhaustive budget
    schedules =
  let configuration =
    match (schedules, seed) with
    | Some count, _ when count <= 0 ->
        Error
          [
            Diag.error ~code:"E0908" ~hint:"pass --schedules N with N greater than zero"
              "--schedules must be positive";
          ]
    | Some _, None ->
        Error
          [
            Diag.error ~code:"E0908" ~hint:"add an explicit --seed S"
              "--schedules requires --seed so every interleaving is reproducible";
          ]
    | Some schedules, Some seed ->
        let command =
          String.concat " "
            ([ "jacquard"; "test" ] @ List.map Filename.quote files
            @ [
                "--prelude";
                Filename.quote (prelude_dir_of prelude);
                "--schedules";
                string_of_int schedules;
                "--seed";
                string_of_int seed;
                "--no-cache";
              ])
        in
        Ok (seed, Warp.Seeded_schedules { seed; schedules; replay_command = command })
    | None, seed ->
        let seed =
          match seed with
          | Some seed -> seed
          | None ->
              Random.self_init ();
              Random.bits ()
        in
        Ok (seed, Warp.Default_schedule)
  in
  match configuration with
  | Error diagnostics -> print_diags diagnostics
  | Ok (seed, schedule_plan) -> (
      match open_ctx ~prelude ~store_dir:None with
      | Error ds -> print_diags ds
      | Ok (store, ctx) -> (
          let prop_mode =
            if exhaustive then Warp.Exhaustive { budget } else Warp.Sampling { seed; samples }
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
                match
                  parse_tops ~syntax:Auto ~names:(Store.names_view store) ~file (read_file file)
                with
                | Error ds -> Error ds
                | Ok (tops, warnings) ->
                    print_warnings warnings;
                    let rec go = function
                      | [] -> Ok ()
                      | parsed :: rest -> (
                          match validate_parsed_top parsed with
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
                    go tops
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
                          | None ->
                              print_diags [ Diag.error ~code:"E0702" "prelude has no test.run" ]
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
                                          Warp.run_discovered ctx cctx ~test_run ~prop_mode
                                            ~schedule_plan ~cache_dir ~granted d
                                        with
                                        | Error e -> Error e
                                        | Ok outcomes ->
                                            List.iter
                                              (fun (o : Warp.outcome) ->
                                                List.iter
                                                  (fun h -> Hashtbl.replace union h ())
                                                  o.Warp.coverage;
                                                List.iter print_endline
                                                  (Warp.render_outcome totals o))
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
                                             (Filename.concat (prelude_dir_of prelude)
                                                "rings.manifest")
                                         in
                                         List.iter print_endline
                                           (Warp.coverage_report store ~rings ~tests:test_hashes
                                              union));
                                      if totals.Warp.failed > 0 then exit_diags else ok))))))))

type diff_operand = Source_file | Store_dir | Missing | Unsupported

let classify_diff_operand path =
  match (Unix.stat path).Unix.st_kind with
  | Unix.S_REG -> Source_file
  | Unix.S_DIR -> Store_dir
  | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unsupported
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Missing
  | exception Unix.Unix_error _ -> Unsupported

let read_diff_source file =
  try Ok (read_file file)
  with Sys_error message ->
    Error
      [ Diag.error ~code:"E0609" (Printf.sprintf "cannot read diff source %s: %s" file message) ]

let open_diff_store dir =
  try Store.open_store dir with
  | Sys_error message ->
      Error
        [ Diag.error ~code:"E0609" (Printf.sprintf "cannot read diff store %s: %s" dir message) ]
  | Unix.Unix_error (error, operation, path) ->
      Error
        [
          Diag.error ~code:"E0609"
            (Printf.sprintf "cannot read diff store %s: %s (%s, %s)" dir (Unix.error_message error)
               operation path);
        ]

let load_diff_source ~prelude ~syntax file =
  match read_diff_source file with
  | Error _ as error -> error
  | Ok source -> (
      match open_ctx ~prelude ~store_dir:None with
      | Error _ as error -> error
      | Ok (store, _ctx) ->
          let declarations = ref [] in
          Result.map
            (fun () -> Diff.source_side store (List.rev !declarations))
            (process_forms ~syntax store ~file source
               ~on_decl:(fun decl hashes -> declarations := (decl, hashes) :: !declarations)
               ~on_expr:(fun _ ->
                 Error
                   [
                     Diag.error ~code:"E0610"
                       (Printf.sprintf
                          "%s: diff source files must contain declarations only; found a top-level \
                           expression"
                          file);
                   ])))

let render_diff ~syntax ~old_side ~new_side =
  match Diff.render (Diff.diff_sides_with_syntax ~syntax ~old_side ~new_side) with
  | None ->
      print_endline "no semantic changes";
      ok
  | Some report ->
      print_endline report;
      ok

let diff_cmd operand_a operand_b syntax prelude =
  match (classify_diff_operand operand_a, classify_diff_operand operand_b) with
  | Missing, Store_dir ->
      print_diags [ Diag.error ~code:"E0606" (Printf.sprintf "store %s does not exist" operand_a) ]
  | Store_dir, Missing ->
      print_diags [ Diag.error ~code:"E0606" (Printf.sprintf "store %s does not exist" operand_b) ]
  | Missing, _ ->
      print_diags
        [ Diag.error ~code:"E0606" (Printf.sprintf "diff operand %s does not exist" operand_a) ]
  | _, Missing ->
      print_diags
        [ Diag.error ~code:"E0606" (Printf.sprintf "diff operand %s does not exist" operand_b) ]
  | Unsupported, _ | _, Unsupported ->
      print_diags
        [
          Diag.error ~code:"E0609"
            "diff operands must both be regular source files or both be store directories";
        ]
  | Source_file, Store_dir | Store_dir, Source_file ->
      print_diags
        [
          Diag.error ~code:"E0609"
            "cannot compare a source file with a store directory; pass two files or two stores";
        ]
  | Store_dir, Store_dir -> (
      match (open_diff_store operand_a, open_diff_store operand_b) with
      | Error ds, _ | _, Error ds -> print_diags ds
      | Ok old_side, Ok new_side ->
          let render_syntax =
            match syntax with Surface -> Diff.Surface | Auto | Bootstrap -> Diff.Bootstrap
          in
          render_diff ~syntax:render_syntax ~old_side:(Diff.store_side old_side)
            ~new_side:(Diff.store_side new_side))
  | Source_file, Source_file -> (
      match
        (load_diff_source ~prelude ~syntax operand_a, load_diff_source ~prelude ~syntax operand_b)
      with
      | Error ds, _ | _, Error ds -> print_diags ds
      | Ok old_side, Ok new_side ->
          let render_syntax =
            match syntax with
            | Surface -> Diff.Surface
            | Bootstrap -> Diff.Bootstrap
            | Auto ->
                if
                  syntax_for_file Auto operand_a = Surface
                  || syntax_for_file Auto operand_b = Surface
                then Diff.Surface
                else Diff.Bootstrap
          in
          render_diff ~syntax:render_syntax ~old_side ~new_side)

(* --- store subcommands (persistent, no implicit prelude) --- *)

let with_store store_dir f =
  match Store.open_store store_dir with Error ds -> print_diags ds | Ok store -> f store

let store_add_cmd store_dir file origin =
  with_store store_dir (fun store ->
      match
        process_forms ?origin ~syntax:Bootstrap store ~file (read_file file) ~on_expr:(fun _ ->
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

(* --- Audit chain subcommands (ET.3) --- *)

let audit_head_arg label spelling =
  match Hash.of_canonical_hex spelling with
  | Some hash -> Ok hash
  | None ->
      Error
        [
          Diag.error ~code:"E1307"
            (Printf.sprintf "%s must be exactly 64 lowercase hexadecimal HASH_V0 digits" label);
        ]

let audit_genesis_cmd () =
  Printf.printf "head %s\n" (Hash.to_hex Audit_chain.genesis);
  ok

let audit_append_cmd log_file entry_file previous_spelling =
  match audit_head_arg "--previous" previous_spelling with
  | Error diagnostics -> print_diags diagnostics
  | Ok previous -> (
      match Audit_chain.read_entry_file ~file:entry_file with
      | Error diagnostics -> print_diags diagnostics
      | Ok entry -> (
          match Audit_chain.append_file ~file:log_file ~previous entry with
          | Error diagnostics -> print_diags diagnostics
          | Ok head ->
              Printf.printf "head %s\n" (Hash.to_hex head);
              ok))

let audit_verify_cmd log_file head_spelling =
  match audit_head_arg "--head" head_spelling with
  | Error diagnostics -> print_diags diagnostics
  | Ok expected_head -> (
      match Audit_chain.verify_file ~file:log_file ~expected_head with
      | Error diagnostics -> print_diags diagnostics
      | Ok head ->
          Printf.printf "ok %s\n" (Hash.to_hex head);
          ok)

(* --- cmdliner wiring --- *)

open Cmdliner

let file_arg = Arg.(required & pos 0 (some file) None & info [] ~docv:"FILE")

let syntax_arg =
  Arg.(
    value
    & opt
        (enum
           [
             ("auto", Auto);
             ("surface", Surface);
             ("jac", Surface);
             ("bootstrap", Bootstrap);
             ("jqd", Bootstrap);
           ])
        Auto
    & info [ "syntax" ] ~docv:"SYNTAX"
        ~doc:
          "Source or rendering syntax: auto selects surface for .jac files and bootstrap \
           otherwise; explicit values are surface/jac or bootstrap/jqd.")

let prelude_arg =
  Arg.(
    value
    & opt (some dir) None
    & info [ "prelude" ] ~docv:"DIR"
        ~doc:"Prelude directory (default: \\$JACQUARD_PRELUDE or ./prelude).")

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

let origin_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "origin" ] ~docv:"TAG"
        ~doc:
          "Provenance tag stamped onto every ingested declaration (recommended grammar: \
           'agent:<model>' or 'human:<name>'; free-form, never hashed).")

let dry_run_arg =
  Arg.(
    value & flag
    & info [ "dry-run" ]
        ~doc:
          "Run with consequence-free world handlers: reads and the clock are real, writes and \
           fetches become an audit trail, nothing mutates, no grants required (TL.2).")

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

let schedule_record_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "schedule-record" ] ~docv:"TRACE"
        ~doc:"Write the successful run's canonical versioned scheduler trace to TRACE.")

let schedule_replay_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "schedule-replay" ] ~docv:"TRACE"
        ~doc:
          "Strictly replay TRACE: every header, creation, ordered runnable queue, chosen task, and \
           operation must match; drift never falls back.")

let schedule_fork_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "schedule-fork" ] ~docv:"DECISION=TASK"
        ~doc:
          "With --schedule-replay, strictly replay before DECISION, choose the named runnable \
           TASK, then continue FIFO and record fork provenance.")

let run_t =
  Cmd.v
    (Cmd.info "run" ~doc:"Run a .jac surface or .jqd bootstrap file in top-level order.")
    Term.(
      const run_cmd $ file_arg $ allows_arg $ prelude_arg $ store_dir_opt_arg $ seed_arg
      $ infer_cache_arg $ origin_arg $ dry_run_arg $ schedule_record_arg $ schedule_replay_arg
      $ schedule_fork_arg $ syntax_arg)

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
    (Cmd.info "check" ~doc:"Parse, validate, resolve, and typecheck a .jac or .jqd file.")
    Term.(
      const check_cmd $ file_arg $ prelude_arg $ print_sigs_arg $ manifest_arg $ origin_arg
      $ syntax_arg)

let hash_t =
  Cmd.v
    (Cmd.info "hash" ~doc:"Print the canonical HASH_V0 hashes of each top-level form.")
    Term.(const hash_cmd $ file_arg $ prelude_arg $ syntax_arg)

let write_arg = Arg.(value & flag & info [ "write"; "w" ] ~doc:"Rewrite the file in place.")

let fmt_t =
  Cmd.v
    (Cmd.info "fmt" ~doc:"Format a .jac or .jqd file canonically, preserving comments.")
    Term.(const fmt_cmd $ file_arg $ write_arg $ syntax_arg)

let infer_t =
  let enumerate =
    Cmd.v
      (Cmd.info "enumerate" ~doc:"Exact posterior by multi-shot enumeration.")
      Term.(const infer_enumerate_cmd $ file_arg $ prelude_arg $ syntax_arg)
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
        $ Arg.(value & opt int 10000 & info [ "samples" ] ~docv:"K" ~doc:"Number of runs.")
        $ syntax_arg)
  in
  Cmd.group
    (Cmd.info "infer" ~doc:"Probabilistic inference: handlers over an unchanged model.")
    [ enumerate; lw ]

let diff_t =
  Cmd.v
    (Cmd.info "diff"
       ~doc:
         "Semantically compare two source files or two stores: renames are renames, reformatting \
          is nothing, and real edits localize to the smallest changed subtrees.")
    Term.(
      const diff_cmd
      $ Arg.(required & pos 0 (some string) None & info [] ~docv:"FILE_OR_STORE_A")
      $ Arg.(required & pos 1 (some string) None & info [] ~docv:"FILE_OR_STORE_B")
      $ syntax_arg $ prelude_arg)

let store_pos_dir = Arg.(required & pos 0 (some string) None & info [] ~docv:"STORE")

let store_t =
  let add =
    Cmd.v
      (Cmd.info "add" ~doc:"Add the file's declarations to a persistent store.")
      Term.(
        const store_add_cmd $ store_pos_dir
        $ Arg.(required & pos 1 (some file) None & info [] ~docv:"FILE")
        $ origin_arg)
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

let audit_t =
  let genesis =
    Cmd.v
      (Cmd.info "genesis" ~doc:"Print the fixed predecessor/head of an empty Audit v1 chain.")
      Term.(const audit_genesis_cmd $ const ())
  in
  let append =
    Cmd.v
      (Cmd.info "append"
         ~doc:
           "Verify LOG against its published predecessor, append one canonical AuditEntry, and \
            print the new publishable head.")
      Term.(
        const audit_append_cmd
        $ Arg.(required & pos 0 (some string) None & info [] ~docv:"LOG")
        $ Arg.(required & pos 1 (some string) None & info [] ~docv:"AUDIT_ENTRY")
        $ Arg.(
            required
            & opt (some string) None
            & info [ "previous" ] ~docv:"HASH"
                ~doc:
                  "Previously published lowercase head; use `jac audit genesis` for an empty log."))
  in
  Cmd.group
    (Cmd.info "audit" ~doc:"Append ET.3 hash-chained Audit records and publish their heads.")
    [ genesis; append ]

let governance_t =
  let verify_log =
    Cmd.v
      (Cmd.info "verify-log"
         ~doc:"Strictly verify a canonical Audit v1 chain against an independently published head.")
      Term.(
        const audit_verify_cmd
        $ Arg.(required & pos 0 (some string) None & info [] ~docv:"LOG")
        $ Arg.(
            required
            & opt (some string) None
            & info [ "head" ] ~docv:"HASH" ~doc:"Expected published lowercase chain head."))
  in
  Cmd.group
    (Cmd.info "governance" ~doc:"Verify governance artifacts and review surfaces.")
    [ verify_log ]

let dist_diff_t =
  Cmd.v
    (Cmd.info "dist-diff"
       ~doc:
         "Posterior divergence between two model versions (TL.1): per-outcome deltas over \
          tolerance, support gains/losses called out, enumerations cached by content hash.")
    Term.(
      const dist_diff_cmd
      $ Arg.(required & pos 0 (some file) None & info [] ~docv:"MODEL_A")
      $ Arg.(required & pos 1 (some file) None & info [] ~docv:"MODEL_B")
      $ Arg.(value & opt float 1e-9 & info [ "tolerance" ] ~docv:"T")
      $ Arg.(value & opt (some string) None & info [ "cache-dir" ] ~docv:"DIR")
      $ Arg.(value & flag & info [ "no-cache" ])
      $ Arg.(value & opt (some string) None & info [ "sweep" ] ~docv:"NAME=V1,V2")
      $ prelude_arg)

let replay_t =
  Cmd.v
    (Cmd.info "replay"
       ~doc:
         "Counterfactual debugging (TL.3): serve world ops from a recorded log, scrub with --to, \
          fork with --fork N=FORM; forked futures run under the dry handlers.")
    Term.(
      const replay_cmd
      $ Arg.(required & pos 0 (some file) None & info [] ~docv:"LOG")
      $ Arg.(required & pos 1 (some file) None & info [] ~docv:"PROGRAM")
      $ Arg.(value & opt_all string [] & info [ "fork" ] ~docv:"N=FORM")
      $ Arg.(value & opt int max_int & info [ "to" ] ~docv:"N")
      $ Arg.(value & flag & info [ "compare" ])
      $ prelude_arg)

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

let samples_arg =
  Arg.(
    value & opt int 100
    & info [ "samples" ] ~docv:"N" ~doc:"Cases per sampled property (W6.4; default 100).")

let exhaustive_arg =
  Arg.(
    value & flag
    & info [ "exhaustive" ]
        ~doc:"Verify properties by exhaustive enumeration instead of sampling (W6.5).")

let budget_arg =
  Arg.(
    value & opt int 10000
    & info [ "budget" ] ~docv:"N"
        ~doc:
          "Exploration budget for exhaustive verification (default 10000); exceeding it is a clean \
           refusal, never a partial pass.")

let schedules_arg =
  Arg.(
    value
    & opt (some int) None
    & info [ "schedules" ] ~docv:"N"
        ~doc:
          "Run each hermetic Case under N SplitMix64 scheduler interleavings. Requires --seed; a \
           failure prints its decision seed and canonical replay log.")

let test_t =
  Cmd.v
    (Cmd.info "test"
       ~doc:
         "Discover tests by checked type (decision D12) and run them: the hermetic lane under \
          test.run, the world lane behind --allow grants.")
    Term.(
      const test_cmd $ test_files_arg $ allows_arg $ prelude_arg $ cache_dir_arg $ no_cache_arg
      $ coverage_arg $ seed_arg $ samples_arg $ exhaustive_arg $ budget_arg $ schedules_arg)

(* --- tiers (PF.2 phase 1) --- *)

(* Tier statistics: one checker context sweeps the prelude plus FILES, stamps every named term's
   tier sidecar into the store, and prints the tables docs/native-compilation.md publishes. *)
let tiers_cmd files prelude =
  match open_ctx ~prelude ~store_dir:None with
  | Error ds -> print_diags ds
  | Ok (store, _ctx) -> (
      match Check.make_ctx store with
      | Error ds -> print_diags ds
      | Ok cctx -> (
          (match Prelude.builtin_signatures store with
          | Ok sigs -> Check.register_builtin_signatures cctx sigs
          | Error _ -> ());
          (* decls are checked at load, so type errors carry source positions and fail the
             command outright — an error is an error, never a partial table *)
          let rec load_forms = function
            | [] -> Ok ()
            | top :: rest -> (
                match top with
                | Kernel.Decl d -> (
                    match Resolve.resolve_decl (Store.names_view store) d with
                    | Error ds -> Error ds
                    | Ok d -> (
                        match Store.put_decl store d with
                        | Error ds -> Error ds
                        | Ok _ -> (
                            match Check.check_top cctx (Kernel.Decl d) with
                            | Error ds -> Error ds
                            | Ok _ -> load_forms rest)))
                | Kernel.Expr e -> (
                    match Resolve.resolve_expr (Store.names_view store) e with
                    | Error ds -> Error ds
                    | Ok e -> (
                        match Check.check_top cctx (Kernel.Expr e) with
                        | Error ds -> Error ds
                        | Ok _ -> load_forms rest)))
          in
          let load_file f =
            match Reader.parse_string ~file:f (read_file f) with
            | Error ds -> Error ds
            | Ok forms -> (
                match
                  List.fold_left
                    (fun acc form ->
                      Result.bind acc (fun tops ->
                          Result.map (fun t -> t :: tops) (Kernel.of_form form)))
                    (Ok []) forms
                with
                | Error ds -> Error ds
                | Ok rev_tops -> load_forms (List.rev rev_tops))
          in
          let rec load = function
            | [] -> Ok ()
            | f :: rest -> ( match load_file f with Error ds -> Error ds | Ok () -> load rest)
          in
          match load files with
          | Error ds -> print_diags ds
          | Ok () -> (
              (* sweep every named term (prelude + the files' declarations) *)
              let named_terms =
                List.filter (fun (_, e) -> e.Resolve.kind = Resolve.KTerm) store.Store.names
              in
              let sweep =
                List.fold_left
                  (fun acc (n, (e : Resolve.entry)) ->
                    Result.bind acc (fun schemes ->
                        match Check.force_term cctx e.Resolve.hash with
                        | Ok s -> Ok ((n, e.Resolve.hash, s) :: schemes)
                        | Error ds -> Error ds))
                  (Ok []) named_terms
              in
              match sweep with
              | Error ds -> print_diags ds
              | Ok rev_schemes ->
                  let schemes = List.rev rev_schemes in
                  List.iter
                    (fun (_, h, (s : Types.scheme)) ->
                      Store.stamp_tier store h (Tier.classify_ty s.Types.ty))
                    schemes;
                  let pct n total = if total = 0 then 0 else 100 * n / total in
                  let line ?(indent = "") label n total =
                    Printf.printf "%s%-18s %5d %3d%%\n" indent label n (pct n total)
                  in
                  (* declarations by signature row *)
                  let decl_tiers =
                    List.map (fun (_, _, s) -> Tier.classify_ty s.Types.ty) schemes
                  in
                  let count p l = List.length (List.filter p l) in
                  let dt = List.length decl_tiers in
                  Printf.printf "== declarations: %d named terms ==\n" dt;
                  line "pure" (count (( = ) Tier.Pure) decl_tiers) dt;
                  line "row-poly" (count (( = ) Tier.RowPoly) decl_tiers) dt;
                  line "effectful"
                    (count (function Tier.Effectful _ -> true | _ -> false) decl_tiers)
                    dt;
                  line "data" (count (( = ) Tier.Data) decl_tiers) dt;
                  (* call sites by callee row, solved *)
                  let apps =
                    List.map (fun (r, k) -> (Tier.classify_row r, k)) (Check.tier_applications cctx)
                  in
                  let at = List.length apps in
                  Printf.printf "\n== call sites: %d applications ==\n" at;
                  line "constructor" (count (fun (_, k) -> k = Tier.KCon) apps) at;
                  line "op-perform" (count (fun (_, k) -> k = Tier.KOp) apps) at;
                  let fn_apps = List.filter (fun (_, k) -> k = Tier.KFn) apps in
                  line "fn pure" (count (fun (t, _) -> t = Tier.Pure) fn_apps) at;
                  line "fn row-poly" (count (fun (t, _) -> t = Tier.RowPoly) fn_apps) at;
                  line "fn effectful"
                    (count
                       (fun (t, _) -> match t with Tier.Effectful _ -> true | _ -> false)
                       fn_apps)
                    at;
                  let by_effect : (Hash.t, int) Hashtbl.t = Hashtbl.create 16 in
                  List.iter
                    (fun (t, _) ->
                      match t with
                      | Tier.Effectful { effects; _ } ->
                          List.iter
                            (fun h ->
                              Hashtbl.replace by_effect h
                                (1 + Option.value ~default:0 (Hashtbl.find_opt by_effect h)))
                            effects
                      | _ -> ())
                    fn_apps;
                  Hashtbl.fold (fun h n acc -> (Check.name_of cctx h, n) :: acc) by_effect []
                  |> List.sort compare
                  |> List.iter (fun (name, n) -> Printf.printf "  %-16s %5d\n" name n);
                  (* Handler clauses have two related classifications: [discipline] is syntax,
                     while native lowering also depends on the declared operation mode. *)
                  let ops = Check.tier_operations cctx in
                  let operation_mode h =
                    match Store.locate store h with
                    | Ok
                        {
                          Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ };
                          role = Store.Operation i;
                          _;
                        } -> (
                        match List.nth_opt ops i with
                        | Some { Kernel.op_mode; _ } -> op_mode
                        | None -> failwith "Bug_tiers: operation ordinal is out of range")
                    | _ -> failwith "Bug_tiers: checked operation does not resolve"
                  in
                  let op_rows =
                    List.map
                      (fun (h, discipline) ->
                        let mode = operation_mode h in
                        (h, mode, discipline, Tier.native_lowering ~mode discipline))
                      ops
                  in
                  let ot = List.length ops in
                  Printf.printf "\n== handler op clauses: %d (syntactic resumption shape) ==\n" ot;
                  List.iter
                    (fun d ->
                      line (Tier.discipline_to_string d) (count (fun (_, d') -> d' = d) ops) ot)
                    [ Tier.TailResumptive; Tier.Aborting; Tier.OneShot; Tier.MultiShot ];
                  Printf.printf "== native handler lowering: %d (shape + operation mode) ==\n" ot;
                  let native_line label n = Printf.printf "%-24s %5d %3d%%\n" label n (pct n ot) in
                  List.iter
                    (fun lowering ->
                      native_line
                        (Tier.native_lowering_to_string lowering)
                        (count (fun (_, _, _, l) -> l = lowering) op_rows))
                    [ Tier.TokenlessTailMulti; Tier.MaterializedResume ];
                  let by_op = Hashtbl.create 16 in
                  List.iter
                    (fun (h, mode, discipline, lowering) ->
                      let key = (Check.name_of cctx h, mode, discipline, lowering) in
                      Hashtbl.replace by_op key
                        (1 + Option.value ~default:0 (Hashtbl.find_opt by_op key)))
                    op_rows;
                  Hashtbl.fold
                    (fun (name, mode, discipline, lowering) n acc ->
                      (name, mode, discipline, lowering, n) :: acc)
                    by_op []
                  |> List.sort compare
                  |> List.iter (fun (name, mode, discipline, lowering, n) ->
                      Printf.printf "  %-16s %-6s %-16s %-24s %3d\n" name
                        (match mode with Kernel.Multi -> "multi" | Kernel.Once -> "once")
                        (Tier.discipline_to_string discipline)
                        (Tier.native_lowering_to_string lowering)
                        n);
                  Printf.printf "\nstamped %d tier sidecars\n" (List.length schemes);
                  0)))

(* --- export (DX.2: explicit evidence/debug bootstrap carrier) --- *)

let read_export_source file =
  match Export.read_regular_file file with
  | Ok source -> Ok source
  | Error Export.Stdin ->
      Error
        [
          Diag.error ~code:"E1302"
            "jacquard export requires a named regular input file; materialize stdin first";
        ]
  | Error Export.Not_regular ->
      Error
        [
          Diag.error ~code:"E1302"
            (Printf.sprintf
               "export input %s is not a regular seekable file; materialize the source first" file);
        ]
  | Error (Export.Read_failure message) ->
      Error
        [ Diag.error ~code:"E1302" (Printf.sprintf "cannot read export input %s: %s" file message) ]

let export_cmd file out prelude syntax =
  match read_export_source file with
  | Error ds -> print_diags ds
  | Ok source -> (
      match open_ctx ~prelude ~store_dir:None with
      | Error ds -> print_diags ds
      | Ok (store, _ctx) -> (
          match resolve_source_tops ~syntax store ~file source with
          | Error ds -> print_diags ds
          | Ok (tops, warnings) -> (
              print_warnings warnings;
              let rec validate_identity = function
                | [] -> Ok ()
                | top :: rest -> (
                    match Canon.hash_top top with
                    | Error _ as error -> error
                    | Ok _ -> validate_identity rest)
              in
              match validate_identity tops with
              | Error ds -> print_diags ds
              | Ok () -> (
                  let contents = Printer.print_all (List.map Kernel.to_form tops) in
                  match Export.write_atomic_exclusive ~path:out contents with
                  | Ok () -> ok
                  | Error Export.Collision ->
                      print_diags
                        [
                          Diag.error ~code:"E1301"
                            (Printf.sprintf
                               "export output %s already exists; choose a new path or remove it \
                                explicitly"
                               out);
                        ]
                  | Error (Export.Atomic_failure message) ->
                      print_diags
                        [
                          Diag.error ~code:"E1303"
                            (Printf.sprintf "cannot publish export atomically: %s" message);
                        ]))))

(* --- build (native compilation, docs/native-plan.md task 67) --- *)

let build_cmd file out prelude dry_run syntax =
  if dry_run then begin
    (* the consent sheet is an interpreter run: the dry handlers wrap live
       evaluation, and a compiled binary has nothing to wrap after the fact *)
    prerr_endline
      "error[E1103]: jacquard build does not support --dry-run; the consent sheet is an \
       interpreter run (use jacquard run --dry-run)";
    exit_diags
  end
  else
    match open_ctx ~prelude ~store_dir:None with
    | Error ds -> print_diags ds
    | Ok (store, _ctx) -> (
        match make_checker store with
        | Error ds -> print_diags ds
        | Ok cctx -> (
            let tops = ref [] in
            let rec check_forms = function
              | [] -> Ok ()
              | top :: rest -> (
                  match top with
                  | Kernel.Decl d -> (
                      match Check.check_top cctx (Kernel.Decl d) with
                      | Error ds -> Error ds
                      | Ok _ -> check_forms rest)
                  | Kernel.Expr e -> (
                      match Check.check_top cctx (Kernel.Expr e) with
                      | Error ds -> Error ds
                      | Ok _ ->
                          tops := e :: !tops;
                          check_forms rest))
            in
            match resolve_source_tops ~syntax store ~file (read_file file) with
            | Error ds -> print_diags ds
            | Ok (resolved_tops, warnings) -> (
                print_warnings warnings;
                match check_forms resolved_tops with
                | Error ds -> print_diags ds
                | Ok () -> (
                    (* warnings and manifests are harvested from a SECOND, run-alike
                         checker context that checks only the top expressions: the loader's
                         eager decl checking seeds Check's origin map in a different order
                         than run_cmd's lazy checking, and the E0814 origins
                         (`performed via ...`) must match run byte-for-byte *)
                    let baked =
                      match make_checker store with
                      | Error _ -> None
                      | Ok cctx2 ->
                          List.fold_left
                            (fun acc e ->
                              Option.bind acc (fun acc ->
                                  match Check.check_top cctx2 (Kernel.Expr e) with
                                  | Error _ -> None
                                  | Ok { Check.warnings; row; _ } ->
                                      let r =
                                        Types.repr_row (Option.value row ~default:Types.empty_row)
                                      in
                                      let msgs =
                                        Check.manifest_errors cctx2
                                          ~grantable:Prelude.grantable_names ~granted:[] r
                                      in
                                      let manifest =
                                        List.map2
                                          (fun h d -> (h, Diag.to_string d))
                                          r.Types.effects msgs
                                      in
                                      Some ((e, List.map Diag.to_string warnings, manifest) :: acc)))
                            (Some []) (List.rev !tops)
                    in
                    match baked with
                    | None ->
                        prerr_endline
                          "error[E1103]: internal: the manifest pass diverged from the load pass";
                        exit_diags
                    | Some rev_baked -> (
                        match
                          Jacquard_native.Build.build ~store ~tops:(List.rev rev_baked)
                            ~prelude_dir:(prelude_dir_of prelude) ~out
                        with
                        | Ok n ->
                            Printf.printf "native: compiled %d unit(s)\n" n;
                            ok
                        | Error (`Refused rs) ->
                            List.iter
                              (fun (r : Jacquard_native.Compile.refusal) ->
                                (* eval is policy (E1102): dynamically loaded code runs at
                                       the interpreter tier; everything else is E1101, a
                                       not-yet-compiled surface *)
                                let what = r.Jacquard_native.Compile.what in
                                let sub = "requires the interpreter tier" in
                                let is_eval =
                                  let n = String.length sub in
                                  let rec go i =
                                    i + n <= String.length what
                                    && (String.sub what i n = sub || go (i + 1))
                                  in
                                  go 0
                                in
                                if is_eval then
                                  Printf.eprintf "error[E1102]: %s %s\n"
                                    r.Jacquard_native.Compile.where what
                                else
                                  Printf.eprintf
                                    "error[E1101]: not yet compilable in native v1: %s %s\n"
                                    r.Jacquard_native.Compile.where what)
                              rs;
                            exit_diags
                        | Error (`Toolchain m) ->
                            Printf.eprintf "error[E1103]: %s\n" m;
                            exit_diags)))))

let out_arg =
  Arg.(required & opt (some string) None & info [ "o"; "output" ] ~docv:"OUT" ~doc:"Output path.")

let export_file_arg = Arg.(required & pos 0 (some string) None & info [] ~docv:"INPUT.jac")

let export_t =
  Cmd.v
    (Cmd.info "export"
       ~doc:
         "Export a .jac source artifact as deterministic canonical .jqd for conformance or \
          debugging; the output is created atomically and never replaces an existing path.")
    Term.(const export_cmd $ export_file_arg $ out_arg $ prelude_arg $ syntax_arg)

let build_t =
  Cmd.v
    (Cmd.info "build"
       ~doc:
         "Compile a .jac surface or .jqd bootstrap file and its reachable declarations to a \
          standalone native executable without generating an intermediate twin.")
    Term.(const build_cmd $ file_arg $ out_arg $ prelude_arg $ dry_run_arg $ syntax_arg)

let tiers_t =
  Cmd.v
    (Cmd.info "tiers"
       ~doc:
         "Tier statistics for the native route (PF.2 phase 1): declarations and call sites by \
          effect row, handler clauses by resume discipline; stamps tier sidecars.")
    Term.(const tiers_cmd $ test_files_arg $ prelude_arg)

let main =
  Cmd.group
    (Cmd.info "jacquard" ~version:Version.version ~doc:"The Jacquard language toolchain")
    [
      run_t;
      check_t;
      hash_t;
      fmt_t;
      diff_t;
      infer_t;
      store_t;
      audit_t;
      governance_t;
      test_t;
      replay_t;
      dist_diff_t;
      tiers_t;
      export_t;
      build_t;
    ]

let () = exit (Cmd.eval' main)
