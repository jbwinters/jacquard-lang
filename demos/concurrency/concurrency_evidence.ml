open Jacquard

let fail message =
  prerr_endline message;
  exit 1

let fail_diagnostics context diagnostics =
  fail (context ^ ":\n" ^ String.concat "\n" (List.map Diag.to_string diagnostics))

let fail_runtime context error = fail (context ^ ": " ^ Runtime_err.to_string error)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun child -> remove_tree (Filename.concat path child)) (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

let resolve_demo store path =
  let source = read_file path in
  let parsed =
    match Surface_parse.strict (Surface_parse.recover_string ~file:path source) with
    | Ok parsed -> parsed
    | Error diagnostics -> fail_diagnostics "surface parse failed" diagnostics
  in
  let tops =
    match Surface_lower.lower_tops parsed with
    | Ok tops -> tops
    | Error diagnostics -> fail_diagnostics "surface lowering failed" diagnostics
  in
  let rec resolve expression = function
    | [] -> (
        match expression with
        | Some expression -> expression
        | None -> fail "the concurrency demo has no top-level task expression")
    | Kernel.Decl declaration :: rest -> (
        let declaration =
          match Resolve.resolve_decl (Store.names_view store) declaration with
          | Ok declaration -> declaration
          | Error diagnostics -> fail_diagnostics "declaration resolution failed" diagnostics
        in
        match Store.put_decl store declaration with
        | Ok _ -> resolve expression rest
        | Error diagnostics -> fail_diagnostics "declaration installation failed" diagnostics)
    | Kernel.Expr candidate :: rest ->
        if Option.is_some expression then
          fail "the concurrency demo must contain exactly one expression";
        let candidate =
          match Resolve.resolve_expr (Store.names_view store) candidate with
          | Ok candidate -> candidate
          | Error diagnostics -> fail_diagnostics "expression resolution failed" diagnostics
        in
        resolve (Some candidate) rest
  in
  resolve None tops

let decision_count (scheduled : Round_robin.scheduled) = List.length scheduled.outcome.decisions

let trace_identity (scheduled : Round_robin.scheduled) =
  Hash.to_hex (Schedule_trace.identity scheduled.schedule)

let run_scheduled ctx expression mode =
  match
    Round_robin.run_expr_scheduled ctx ~policy:Concurrency_contract.Fail_fast ~mode expression
  with
  | Ok scheduled -> scheduled
  | Error error -> fail_runtime "scheduled execution failed" error

let replay_world ctx expression (world : Exhaustive_schedule.world) =
  match
    Round_robin.run_expr_outcome_scheduled ctx ~policy:Concurrency_contract.Fail_fast
      ~bounds:{ max_tasks = 8; max_decisions = 16 }
      ~allow_routed:false ~mode:(Round_robin.Replay_schedule world.schedule) expression
  with
  | Error error -> fail_runtime "exhaustive-world replay failed" error
  | Ok replayed ->
      String.equal
        (Schedule_trace.serialize world.schedule)
        (Schedule_trace.serialize replayed.execution_schedule)

let () =
  if Array.length Sys.argv <> 3 then fail "usage: concurrency_evidence PRELUDE_DIR TASK_PROGRAM.jac";
  let prelude = Sys.argv.(1) in
  let program = Sys.argv.(2) in
  let temp_root =
    Option.value ~default:".scratch/tmp" (Sys.getenv_opt "TMPDIR") |> fun parent ->
    let path = Filename.concat parent (Printf.sprintf "sc16-demo-%d" (Unix.getpid ())) in
    remove_tree path;
    Unix.mkdir path 0o700;
    path
  in
  Fun.protect
    ~finally:(fun () -> remove_tree temp_root)
    (fun () ->
      let store =
        match Store.open_store temp_root with
        | Ok store -> store
        | Error diagnostics -> fail_diagnostics "store creation failed" diagnostics
      in
      (match Prelude.load ~dir:prelude store with
      | Ok _ -> ()
      | Error diagnostics -> fail_diagnostics "prelude loading failed" diagnostics);
      let ctx = Eval.make_ctx store in
      (match Prelude.wire_builtins ctx with
      | Ok () -> ()
      | Error diagnostics -> fail_diagnostics "prelude builtin wiring failed" diagnostics);
      let expression = resolve_demo store program in
      let program_hash =
        match Canon.hash_expr expression with
        | Ok hash -> Hash.to_hex hash
        | Error diagnostics -> fail_diagnostics "program hashing failed" diagnostics
      in
      let fifo = run_scheduled ctx expression Round_robin.Record_schedule in
      let seed = 20_260_717 in
      let seeded = run_scheduled ctx expression (Round_robin.Seeded_schedule { seed }) in
      let exhaustive =
        match
          Exhaustive_schedule.run_expr ctx ~policy:Concurrency_contract.Fail_fast
            ~bounds:{ max_tasks = 8; max_decisions = 16; max_worlds = 32 }
            expression
        with
        | Ok report -> report
        | Error diagnostics -> fail_diagnostics "exhaustive execution failed" diagnostics
      in
      let replay = run_scheduled ctx expression (Round_robin.Replay_schedule fifo.schedule) in
      let serialized_fifo = Schedule_trace.serialize fifo.schedule in
      let serialized_replay = Schedule_trace.serialize replay.schedule in
      let exhaustive_traces =
        List.map
          (fun world -> Schedule_trace.serialize world.Exhaustive_schedule.schedule)
          exhaustive.worlds
      in
      let unique_traces = List.sort_uniq String.compare exhaustive_traces |> List.length in
      let all_zero =
        List.for_all
          (fun world ->
            match world.Exhaustive_schedule.result with
            | Ok (Value.VInt 0) -> true
            | Ok _ | Error _ -> false)
          exhaustive.worlds
      in
      let all_replay = List.for_all (replay_world ctx expression) exhaustive.worlds in
      let completeness =
        match exhaustive.completeness with
        | Exhaustive_schedule.Complete -> "complete"
        | Incomplete reasons ->
            "incomplete:"
            ^ String.concat "," (List.map Exhaustive_schedule.incomplete_reason_to_string reasons)
      in
      Printf.printf "program-hash=%s\n" program_hash;
      Printf.printf "trace-format=%d\n" Schedule_trace.format_version;
      Printf.printf "round-robin scheduler=%s result=%s tasks=%d decisions=%d trace=%s\n"
        fifo.schedule.scheduler (Value.show fifo.value) fifo.outcome.task_count
        (decision_count fifo) (trace_identity fifo);
      Printf.printf "seeded scheduler=%s seed=%d result=%s tasks=%d decisions=%d trace=%s\n"
        seeded.schedule.scheduler seed (Value.show seeded.value) seeded.outcome.task_count
        (decision_count seeded) (trace_identity seeded);
      Printf.printf
        "exhaustive completeness=%s explored=%d worlds-started=%d unique-traces=%d all-zero=%b\n"
        completeness exhaustive.explored exhaustive.worlds_started unique_traces all_zero;
      Printf.printf "replay source=round-robin result=%s byte-identical=%b\n"
        (Value.show replay.value)
        (String.equal serialized_fifo serialized_replay);
      Printf.printf "exhaustive-replay worlds=%d byte-identical=%b\n"
        (List.length exhaustive.worlds) all_replay)
